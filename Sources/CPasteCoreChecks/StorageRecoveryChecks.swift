import CPasteCore
import Foundation

private final class PersistenceFaultFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var deniedFragment: String?
    private var blockedFragment: String?
    private var didBlock = false
    private var blockedOnMain = false
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func deny(_ fragment: String?) {
        lock.lock()
        deniedFragment = fragment
        lock.unlock()
    }

    func blockOnce(_ fragment: String) {
        lock.lock()
        blockedFragment = fragment
        didBlock = false
        lock.unlock()
    }

    var writerWasMain: Bool {
        lock.lock()
        defer { lock.unlock() }
        return blockedOnMain
    }

    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        lock.lock()
        let denied = deniedFragment.map { path.contains($0) } ?? false
        let shouldBlock = !didBlock && (blockedFragment.map { path.contains($0) } ?? false)
        if shouldBlock {
            didBlock = true
            blockedOnMain = Thread.isMainThread
        }
        lock.unlock()
        if shouldBlock {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        if denied { return false }
        return super.createFile(atPath: path, contents: data, attributes: attr)
    }
}

private func writeLegacy(_ items: [ClipboardItem], directory: URL) -> Data {
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try! encoder.encode(items)
    try! data.write(to: directory.appendingPathComponent("history.json"))
    return data
}

private func directoryContains(_ data: Data, directory: URL) -> Bool {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
    return enumerator.compactMap { $0 as? URL }.contains { (try? Data(contentsOf: $0)) == data }
}

// The existing on-disk ISO8601 contract has second precision. Compare the
// complete model after normalizing that precision, not the capture clock's
// subsecond values that were never part of the persisted representation.
private func persistedRepresentation(_ items: [ClipboardItem]) -> [ClipboardItem] {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try! decoder.decode([ClipboardItem].self, from: encoder.encode(items))
}

func testLegacyTextMigrationKeepsFullMetadataAndPrivateFiles() {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let text = String(repeating: "UTF8 中文 e\u{301} 👨‍👩‍👧‍👦\r\n", count: 8_000) + "完整末尾"
    let item = ClipboardItem(
        kind: .text, title: "Migration", subtitle: "Full body", text: text,
        contentHash: "legacy-migration", sourceAppName: "Legacy App", sourceBundleIdentifier: "local.legacy",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastCopiedAt: Date(timeIntervalSince1970: 1_700_001_000), isPinned: true
    )
    let original = writeLegacy([item], directory: directory)
    let store = ClipboardStore(storageDirectory: directory, maxItems: 0)
    check(store.items == [item], "migration must not trim or alter a legacy item, even above the configured limit")
    check(store.save(), "legacy migration must commit successfully")
    check((try! Data(contentsOf: store.historyURL)).count < 4_096, "migrated text must leave a small index")
    check((try! Data(contentsOf: directory.appendingPathComponent("history.legacy-backup.json"))) == original,
          "migration must preserve the original index bytes")
    let bodies = try! FileManager.default.contentsOfDirectory(at: store.textDirectory, includingPropertiesForKeys: nil)
    check(bodies.count == 1 && (try! Data(contentsOf: bodies[0])) == Data(text.utf8), "body file must be lossless UTF8")
    for url in [store.historyURL, store.historyBackupURL, directory.appendingPathComponent("history.legacy-backup.json"), bodies[0]] {
        let mode = (try! FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
        check(mode == 0o600, "history, backup and text files must be private")
    }
    let reloaded = ClipboardStore(storageDirectory: directory)
    check(reloaded.items == [item], "migrated reload must preserve every model field")
    check(reloaded.save(), "a migrated no-op save must succeed")
    check((try! FileManager.default.contentsOfDirectory(atPath: store.textDirectory.path)).count == 1,
          "repeated migration must not duplicate body files")
}

func testRecoveryRetainsBackupDependenciesAndOriginalBytes() {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ClipboardStore(storageDirectory: directory)
    let text = String(repeating: "Recover full body\n", count: 8_000)
    store.insertCaptured(.init(kind: .text, title: "Body", text: text, contentHash: "recovery-body"))
    store.insertCaptured(.init(kind: .image, title: "Image", imagePNGData: Data([1, 2, 3]), contentHash: "recovery-image"))
    check(store.save(), "recovery fixture must save")
    let expected = persistedRepresentation(store.items)
    store.clearUnpinned()
    check(store.save(), "clear must commit a new index")
    check(FileManager.default.fileExists(atPath: store.blobDirectory.appendingPathComponent("recovery-image.png").path),
          "clear must retain images referenced by the previous valid backup")
    check(!(try! FileManager.default.contentsOfDirectory(atPath: store.textDirectory.path)).isEmpty,
          "clear must retain bodies referenced by the previous valid backup")
    let damaged = Data("{damaged primary fixture".utf8)
    try! damaged.write(to: store.historyURL)
    let recovered = ClipboardStore(storageDirectory: directory)
    check(recovered.storageIssue == .recoveredFromBackup, "a valid previous snapshot must recover with a visible notice")
    check(recovered.items == expected, "backup recovery must include complete text and image references")
    check(directoryContains(damaged, directory: directory.appendingPathComponent("Recovery")),
          "automatic recovery must preserve damaged primary bytes")
    check(recovered.save(), "capture may continue after a protected recovery")
}

func testMissingTextRecoversLegacyBackupInsteadOfEmptyBody() {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let text = String(repeating: "完整正文\n", count: 12_000)
    let item = ClipboardItem(kind: .text, title: "Legacy body", text: text, contentHash: "missing-text",
                             createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                             lastCopiedAt: Date(timeIntervalSince1970: 1_700_000_001))
    _ = writeLegacy([item], directory: directory)
    let store = ClipboardStore(storageDirectory: directory)
    check(store.save(), "missing-body fixture migration must save")
    let damagedIndex = try! Data(contentsOf: store.historyURL)
    for body in try! FileManager.default.contentsOfDirectory(at: store.textDirectory, includingPropertiesForKeys: nil) {
        try! FileManager.default.removeItem(at: body)
    }
    try! Data("{damaged backup".utf8).write(to: store.historyBackupURL)
    let recovered = ClipboardStore(storageDirectory: directory)
    check(recovered.storageIssue == .recoveredFromBackup, "an intact legacy backup must be used when the newer body is missing")
    check(recovered.items == [item], "missing text must recover full text, never silently become an empty body")
    check(directoryContains(damagedIndex, directory: directory.appendingPathComponent("Recovery")),
          "an index with a missing dependency must be preserved")
    check(recovered.save(), "recovered legacy text must be safely migrated again")
    check(ClipboardStore(storageDirectory: directory).items == [item], "recovered body must survive another restart")
}

func testUnpreservableHistoryBlocksWrites() {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let history = directory.appendingPathComponent("history.json", isDirectory: true)
    try! FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
    let store = ClipboardStore(storageDirectory: directory)
    check(store.storageIssue == .readOnly, "an unreadable and unpreservable primary must report read-only storage")
    store.insertCaptured(.init(kind: .text, title: "Pending", text: "Pending", contentHash: "blocked"))
    check(!store.save(), "save must refuse to replace an unpreserved history")
    check(store.items.count == 1, "a failed disk save must keep the captured item in memory")
    check((try! history.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
          "failed history must remain untouched")
}

func testBackgroundPersistenceFlushAndBlobReservation() {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = PersistenceFaultFileManager()
    let store = ClipboardStore(storageDirectory: directory, fileManager: manager)
    store.insertCaptured(.init(kind: .text, title: "Base", text: "Base", contentHash: "base"))
    check(store.save(), "background fixture must initialize")
    manager.blockOnce(".history.json-")
    store.insertCaptured(.init(kind: .text, title: "First", text: "First", contentHash: "first"))
    check(manager.entered.wait(timeout: .now() + 2) == .success, "writer must enter the controlled persistence step")
    check(!manager.writerWasMain, "normal capture must save on the background writer")
    // The old snapshot is in flight while a new blob is persisted and queued.
    store.insertCaptured(.init(kind: .image, title: "Pending image", imagePNGData: Data([4, 5, 6]), contentHash: "pending-image"))
    let newest = store.items[0]
    store.togglePinned(newest.id)
    manager.release.signal()
    check(store.save(), "flush must wait for the actual latest snapshot")
    let reloaded = ClipboardStore(storageDirectory: directory)
    check(reloaded.items == persistedRepresentation(store.items), "flush must preserve all coalesced updates in order")
    check(reloaded.items.first?.isPinned == true, "flush must include the latest metadata update")
    check(FileManager.default.fileExists(atPath: store.blobDirectory.appendingPathComponent("pending-image.png").path),
          "collection must not delete the next snapshot's newly persisted blob")
}

func testWriteFailuresKeepLastGoodIndexAndCanRetry() {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = PersistenceFaultFileManager()
    let store = ClipboardStore(storageDirectory: directory, fileManager: manager)
    store.insertCaptured(.init(kind: .text, title: "Good", text: "Good", contentHash: "good"))
    check(store.save(), "failure fixture must initialize")
    let original = try! Data(contentsOf: store.historyURL)
    manager.deny(".txt-")
    let text = String(repeating: "Body that cannot yet be written\n", count: 4_000)
    store.insertCaptured(.init(kind: .text, title: "Long", text: text, contentHash: "long"))
    check(!store.save() && store.storageIssue == .saveFailed, "body failure must be observable")
    check((try! Data(contentsOf: store.historyURL)) == original, "body failure must not publish an incomplete index")
    manager.deny(".history.backup.json-")
    check(!store.save(), "backup failure must fail the commit")
    check((try! Data(contentsOf: store.historyURL)) == original, "backup failure must keep the last good primary")
    manager.deny(".history.json-")
    check(!store.save(), "primary publication failure must fail the commit")
    check((try! Data(contentsOf: store.historyURL)) == original, "publication failure must leave the original primary intact")
    manager.deny(nil)
    check(store.save(), "failed saves must be retryable")
    check(ClipboardStore(storageDirectory: directory).items == persistedRepresentation(store.items), "retry must save complete pending history")
}

func testCorruptBackupIsPreservedBeforeRotation() {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ClipboardStore(storageDirectory: directory)
    store.insertCaptured(.init(kind: .text, title: "Good", text: "Good", contentHash: "good"))
    check(store.save(), "backup corruption fixture must initialize")
    let damagedBackup = Data("{unique damaged previous history".utf8)
    try! damagedBackup.write(to: store.historyBackupURL)
    let reloaded = ClipboardStore(storageDirectory: directory)
    check(reloaded.items == persistedRepresentation(store.items), "a bad backup must not discard a valid primary")
    reloaded.insertCaptured(.init(kind: .text, title: "New", text: "New", contentHash: "new"))
    check(reloaded.save(), "capture must continue after the failed backup is preserved")
    check(directoryContains(damagedBackup, directory: directory.appendingPathComponent("Recovery")),
          "a corrupt backup must be retained before a valid primary rotates over it")
}

func testActiveBodyDamageIsRepairedFromCompleteMemoryText() {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ClipboardStore(storageDirectory: directory)
    let text = String(repeating: "Complete body that remains in memory\n", count: 4_000)
    store.insertCaptured(.init(kind: .text, title: "Body", text: text, contentHash: "active-damage"))
    check(store.save(), "body damage fixture must save")
    let body = try! FileManager.default.contentsOfDirectory(at: store.textDirectory, includingPropertiesForKeys: nil)[0]
    try! Data("damaged body".utf8).write(to: body)
    check(store.save(), "a changed body must be repaired from the full in-memory text")
    check((try! Data(contentsOf: body)) == Data(text.utf8), "repair must restore the exact body bytes")
    check(ClipboardStore(storageDirectory: directory).items == persistedRepresentation(store.items),
          "body repair must keep both the current snapshot and reload usable")
}

func testActiveMissingTextCannotPoisonBackupOnRemoval() {
    for trimInsteadOfDelete in [false, true] {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(storageDirectory: directory)
        store.insertCaptured(.init(kind: .text, title: "Base", text: "Base", contentHash: "base"))
        check(store.save(), "removal fixture base must save")
        let text = String(repeating: "Complete previous body\n", count: 5_000)
        store.insertCaptured(.init(kind: .text, title: "Long", text: text, contentHash: "long"))
        check(store.save(), "removal fixture long text must save")
        let expectedBackup = persistedRepresentation(store.items)
        let body = try! FileManager.default.contentsOfDirectory(at: store.textDirectory, includingPropertiesForKeys: nil)[0]
        try! FileManager.default.removeItem(at: body)
        if trimInsteadOfDelete {
            store.maxItems = 1
            store.insertCaptured(.init(kind: .text, title: "Newest", text: "Newest", contentHash: "newest"))
        } else {
            store.delete(store.items.first { $0.contentHash == "long" }!.id)
        }
        check(store.save(), "a previous text body should be repairable from the complete in-memory snapshot")
        check(FileManager.default.fileExists(atPath: body.path),
              "delete and trim must repair prior text dependencies before rotating a snapshot into backup")
        let damaged = Data("{force backup recovery after removal".utf8)
        try! damaged.write(to: store.historyURL)
        let recovered = ClipboardStore(storageDirectory: directory)
        check(recovered.storageIssue == .recoveredFromBackup && recovered.items == expectedBackup,
              "the backup produced by delete or trim must still restore every full text and metadata field")
    }
}

func testActiveCorruptBackupIsPreservedBeforeRotation() {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ClipboardStore(storageDirectory: directory)
    store.insertCaptured(.init(kind: .text, title: "Base", text: "Base", contentHash: "base"))
    check(store.save(), "active backup fixture must initialize")
    let damaged = Data("{unique backup damage while the app stays running".utf8)
    try! damaged.write(to: store.historyBackupURL)
    store.insertCaptured(.init(kind: .text, title: "New capture", text: "New capture", contentHash: "new"))
    check(store.save(), "a bad active backup should be preservable before rotating the valid primary")
    check(directoryContains(damaged, directory: directory.appendingPathComponent("Recovery")),
          "an actively damaged backup must retain its original bytes before rotation")
    check(ClipboardStore(storageDirectory: directory).items == persistedRepresentation(store.items),
          "preserving an active bad backup must not discard the new capture")
}
