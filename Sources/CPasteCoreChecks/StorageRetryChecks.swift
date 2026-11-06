import CPasteCore
import Foundation

private final class RetryFaultFileManager: FileManager, @unchecked Sendable {
    var deniedAttributePath: String?
    var deniedWriteFragment: String?

    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if path == deniedAttributePath { throw CocoaError(.fileWriteNoPermission) }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }

    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        if let deniedWriteFragment, path.contains(deniedWriteFragment) { return false }
        return super.createFile(atPath: path, contents: data, attributes: attr)
    }
}

private func writeRetryHistory(_ items: [ClipboardItem], to url: URL) -> Data {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let bytes = try! encoder.encode(items)
    try! bytes.write(to: url, options: .atomic)
    return bytes
}

private func retryPersistedItems(_ items: [ClipboardItem]) -> [ClipboardItem] {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try! decoder.decode([ClipboardItem].self, from: encoder.encode(items))
}

func testReadOnlyStorageCanRetryAfterRepair() {
    let directory = makeTemporaryDirectory()
    let history = directory.appendingPathComponent("history.json")
    let original = ClipboardItem(
        kind: .text, title: "Original", text: "Original complete body", contentHash: "retry-original",
        sourceAppName: "Fixture", sourceBundleIdentifier: "local.fixture",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastCopiedAt: Date(timeIntervalSince1970: 1_700_000_010), isPinned: true
    )
    _ = writeRetryHistory([original], to: history)
    let manager = RetryFaultFileManager()
    manager.deniedAttributePath = history.path
    let store = ClipboardStore(storageDirectory: directory, fileManager: manager)
    defer { manager.deniedAttributePath = nil; _ = store.save(); try? FileManager.default.removeItem(at: directory) }
    check(store.storageIssue == .readOnly && store.items == [original], "read-only fixture must retain readable history")
    store.insertCaptured(.init(kind: .text, title: "Pending", text: "Unsaved new body", contentHash: "retry-pending"))
    let expected = retryPersistedItems(store.items)
    check(!store.save(), "the injected permission failure must block writes")
    manager.deniedAttributePath = nil

    store.reloadFromDisk()
    check(store.save(), "repairing storage must permit retry without first requiring a successful save")
    let reloaded = ClipboardStore(storageDirectory: directory)
    check(reloaded.items == expected, "retry must retain the original history and the complete unsaved in-memory item")
}

func testInitiallyUnreadableHistoryMergesCapturedItemsWithoutTrimming() {
    let directory = makeTemporaryDirectory()
    let history = directory.appendingPathComponent("history.json")
    try! FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
    let store = ClipboardStore(storageDirectory: directory, maxItems: 50)
    defer { _ = store.save(); try? FileManager.default.removeItem(at: directory) }
    check(store.storageIssue == .readOnly && store.items.isEmpty, "unreadable primary fixture must enter protected storage")
    store.insertCaptured(.init(kind: .text, title: "Pending", text: "Full in-memory item", contentHash: "retry-unreadable-pending"))
    store.togglePinned(store.items[0].id)
    let pending = retryPersistedItems(store.items)[0]
    check(!store.save(), "an unpreservable primary must not be overwritten")
    try! FileManager.default.removeItem(at: history)
    let diskItems = (0..<60).map { index in
        ClipboardItem(
            kind: .text, title: "Disk \(index)", text: "Full disk body \(index)", contentHash: "retry-disk-\(index)",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
            lastCopiedAt: Date(timeIntervalSince1970: 1_700_000_100 + Double(index)), isPinned: index == 0
        )
    }
    _ = writeRetryHistory(diskItems, to: history)

    store.reloadFromDisk()
    check(store.items.count == 61, "retry must combine recovered disk history and unsaved new captures without trimming to capacity")
    let byID = Dictionary(uniqueKeysWithValues: retryPersistedItems(store.items).map { ($0.id, $0) })
    for item in diskItems + [pending] {
        check(byID[item.id] == item, "retry must preserve every recovered and pending item's IDs, complete body and metadata")
    }
    check(store.save() && ClipboardStore(storageDirectory: directory).items.count == 61,
          "the non-destructive retry result must survive a restart")
}

func testExternalHistoryConflictKeepsBothVersions() {
    let directory = makeTemporaryDirectory()
    let history = directory.appendingPathComponent("history.json")
    let original = ClipboardItem(kind: .text, title: "Original", text: "Original", contentHash: "retry-conflict-original")
    _ = writeRetryHistory([original], to: history)
    let manager = RetryFaultFileManager()
    let store = ClipboardStore(storageDirectory: directory, fileManager: manager)
    defer { manager.deniedWriteFragment = nil; try? FileManager.default.removeItem(at: directory) }
    manager.deniedWriteFragment = ".history.json-"
    store.insertCaptured(.init(kind: .text, title: "Unsaved", text: "Unique unsaved body", contentHash: "retry-conflict-unsaved"))
    check(!store.save(), "conflict fixture must retain an unsaved in-memory update")
    let expectedMemory = retryPersistedItems(store.items)
    let external = ClipboardItem(kind: .text, title: "External", text: "Unique external body", contentHash: "retry-conflict-external")
    let externalBytes = writeRetryHistory([external, original], to: history)
    manager.deniedWriteFragment = nil

    store.reloadFromDisk()
    check((try! Data(contentsOf: history)) == externalBytes, "retry must never overwrite independently updated valid disk history")
    check(retryPersistedItems(store.items) == expectedMemory, "conflict must preserve the unsaved current in-memory history")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let recovery = directory.appendingPathComponent("Recovery")
    let enumerator = FileManager.default.enumerator(at: recovery, includingPropertiesForKeys: [.isRegularFileKey])
    let preserved = enumerator?.compactMap { $0 as? URL }.contains { url in
        guard let data = try? Data(contentsOf: url), let items = try? decoder.decode([ClipboardItem].self, from: data) else { return false }
        return items == expectedMemory
    } ?? false
    check(preserved, "an external-history conflict must also preserve a complete independent recovery copy of unsaved memory")
}

func testOldSuccessCannotClearANewerCaptureFailure() {
    let directory = makeTemporaryDirectory()
    let manager = RetryFaultFileManager()
    let store = ClipboardStore(storageDirectory: directory, fileManager: manager)
    defer { manager.deniedWriteFragment = nil; _ = store.save(); try? FileManager.default.removeItem(at: directory) }
    store.insertCaptured(.init(kind: .text, title: "Saved", text: "Saved body", contentHash: "retry-status-saved"))
    check(store.save(), "the old successful snapshot must finish while its main-queue report remains pending")
    manager.deniedWriteFragment = ".failed-image.png-"
    store.insertCaptured(.init(kind: .image, title: "Failed image", imagePNGData: Data([1, 2, 3]), contentHash: "failed-image"))
    let captureFailure = store.storageIssue
    check(captureFailure != nil, "the injected attachment write failure must publish an error")
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    check(store.storageIssue == captureFailure, "a queued old successful report must not clear a newer attachment capture failure")
}
