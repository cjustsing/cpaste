import CPasteCore
import Foundation

private final class RecoveryCopyFaultFileManager: FileManager, @unchecked Sendable {
    var deniedFragment: String?
    var beforePrimaryPublication: (() -> Void)?
    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        if let deniedFragment, path.contains(deniedFragment) { return false }
        let created = super.createFile(atPath: path, contents: data, attributes: attr)
        if created, path.contains("/.history.json-"), let action = beforePrimaryPublication {
            beforePrimaryPublication = nil
            action()
        }
        return created
    }
}

private func retryCopyWrite(_ items: [ClipboardItem], to url: URL) -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let bytes = try! encoder.encode(items)
    try! bytes.write(to: url, options: .atomic)
    return bytes
}

func testConflictCopyContainsFullTextAndBinaryDependencies() {
    let directory = makeTemporaryDirectory()
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let history = directory.appendingPathComponent("history.json")
    let base = ClipboardItem(kind: .text, title: "Base", text: "Base body", contentHash: "copy-base")
    _ = retryCopyWrite([base], to: history)
    let manager = RecoveryCopyFaultFileManager()
    let store = ClipboardStore(storageDirectory: directory, fileManager: manager)
    defer { manager.deniedFragment = nil; try? FileManager.default.removeItem(at: directory) }
    manager.deniedFragment = ".history.json-"
    let image = Data([0, 1, 2, 3, 255, 0])
    let text = String(repeating: "Full Unicode body e\u{301} 中文\n", count: 5_000) + "tail preserved"
    store.insertCaptured(.init(kind: .image, title: "Image", imagePNGData: image, contentHash: "copy-image"))
    store.insertCaptured(.init(kind: .text, title: "Long", text: text, contentHash: "copy-text"))
    check(!store.save(), "checkpoint fixture must retain unsaved history")
    let external = ClipboardItem(kind: .text, title: "External", text: "External body", contentHash: "copy-external")
    let externalBytes = retryCopyWrite([external, base], to: history)
    manager.deniedFragment = nil
    check(!store.retrySaving() && store.storageIssue == .historyConflict, "independent valid history must require conflict protection")
    guard let copy = store.recoveryCopyURL else { check(false, "conflict must expose its verified recovery directory"); return }
    check((try! Data(contentsOf: history)) == externalBytes, "creating a checkpoint must not replace the external primary")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let recovered = try! decoder.decode([ClipboardItem].self, from: Data(contentsOf: copy.appendingPathComponent("history.json")))
    check(recovered.count == store.items.count, "checkpoint must include every in-memory record")
    check(recovered.first { $0.contentHash == "copy-text" }?.text.utf8.elementsEqual(text.utf8) == true,
          "checkpoint must contain inline complete Unicode text, independent of the managed Text directory")
    check((try! Data(contentsOf: copy.appendingPathComponent("Blobs/copy-image.png"))) == image,
          "checkpoint must include complete independent binary attachments")
    for url in [copy, copy.appendingPathComponent("Blobs")] {
        let mode = (try! FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
        check(mode == 0o700, "checkpoint directories must remain owner-only")
    }
    for url in [copy.appendingPathComponent("history.json"), copy.appendingPathComponent("Blobs/copy-image.png")] {
        let mode = (try! FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
        check(mode == 0o600, "checkpoint data must remain owner-only")
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    check(store.storageIssue == .historyConflict && store.recoveryCopyURL == copy,
          "queued reports from before retry must not clear its newer conflict state")
    check(!store.save() && store.storageIssue == .historyConflict,
          "a later durability barrier must retain the actionable conflict cause")
    let recoveredStore = ClipboardStore(storageDirectory: copy)
    check(recoveredStore.items.count == recovered.count && recoveredStore.save(), "a complete recovery copy must be independently loadable")
}

func testRecoveryCopyFailureKeepsMemoryAndExternalHistory() {
    let directory = makeTemporaryDirectory()
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let history = directory.appendingPathComponent("history.json")
    let base = ClipboardItem(kind: .text, title: "Base", text: "Base", contentHash: "failed-copy-base")
    _ = retryCopyWrite([base], to: history)
    let manager = RecoveryCopyFaultFileManager()
    let store = ClipboardStore(storageDirectory: directory, fileManager: manager)
    defer { manager.deniedFragment = nil; try? FileManager.default.removeItem(at: directory) }
    manager.deniedFragment = ".history.json-"
    store.insertCaptured(.init(kind: .text, title: "Pending", text: "Unwritten complete text", contentHash: "failed-copy-pending"))
    check(!store.save(), "recovery-copy failure fixture must start with unsaved memory")
    let memory = store.items
    let external = ClipboardItem(kind: .text, title: "External", text: "External", contentHash: "failed-copy-external")
    let externalBytes = retryCopyWrite([external, base], to: history)
    manager.deniedFragment = "/Recovery/"
    check(!store.retrySaving() && store.storageIssue == .recoveryCopyFailed && store.recoveryCopyURL == nil,
          "a failed checkpoint must report failure instead of claiming the memory was archived")
    check(store.items == memory && (try! Data(contentsOf: history)) == externalBytes,
          "checkpoint failure must retain both in-memory and independently changed disk versions")
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    check(store.storageIssue == .recoveryCopyFailed, "old reports must not hide a failed recovery checkpoint")
}

func testHistoryChangedDuringRetryPublicationIsNotOverwritten() {
    let directory = makeTemporaryDirectory()
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let history = directory.appendingPathComponent("history.json")
    let base = ClipboardItem(kind: .text, title: "Base", text: "Base", contentHash: "publication-base")
    _ = retryCopyWrite([base], to: history)
    let manager = RecoveryCopyFaultFileManager()
    let store = ClipboardStore(storageDirectory: directory, fileManager: manager)
    defer { manager.deniedFragment = nil; try? FileManager.default.removeItem(at: directory) }
    manager.deniedFragment = ".history.json-"
    store.insertCaptured(.init(kind: .text, title: "Pending", text: "Pending", contentHash: "publication-pending"))
    check(!store.save(), "publication fixture must start from unsaved memory")
    manager.deniedFragment = nil
    let external = ClipboardItem(kind: .text, title: "Concurrent", text: "Concurrent body", contentHash: "publication-external")
    var externalBytes = Data()
    manager.beforePrimaryPublication = { externalBytes = retryCopyWrite([external, base], to: history) }
    check(!store.retrySaving() && store.storageIssue == .historyConflict,
          "a history replacement during body/index preparation must turn into a protected conflict")
    check(!externalBytes.isEmpty && (try! Data(contentsOf: history)) == externalBytes,
          "the final publication check must retain the concurrently replaced valid primary")
    check(store.recoveryCopyURL != nil && store.items.contains { $0.contentHash == "publication-pending" },
          "publication conflict must retain both the live pending item and its recovery copy")
}
