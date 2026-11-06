import CPasteCore
import Foundation

private final class RetryPublicationFailureManager: FileManager, @unchecked Sendable {
    var rejectPrimary = false
    var rejectPrimaryAttributes = false
    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        if rejectPrimary && path.contains(".history.json-") { return false }
        return super.createFile(atPath: path, contents: data, attributes: attr)
    }
    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if rejectPrimaryAttributes && path.contains(".history.json-") { throw CocoaError(.fileWriteNoPermission) }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}

func testFailedInitialRecoveryKeepsDiskRowsThroughRetryAndNormalMutation() {
    for normalMutationBeforeRetry in [false, true] {
        let directory = makeTemporaryDirectory()
        let history = directory.appendingPathComponent("history.json")
        try! FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let manager = RetryPublicationFailureManager()
        let store = ClipboardStore(storageDirectory: directory, fileManager: manager)
        defer {
            manager.rejectPrimary = false; manager.rejectPrimaryAttributes = false
            _ = store.save(); try? FileManager.default.removeItem(at: directory)
        }
        check(store.storageIssue == .readOnly, "initial recovery fixture must start with unreadable protected history")
        store.insertCaptured(.init(kind: .text, title: "Pending", text: "Complete pending body", contentHash: "failed-recovery-pending"))
        let pendingID = store.items[0].id
        try! FileManager.default.removeItem(at: history)
        let diskItems = (0..<3).map { index in
            ClipboardItem(
                kind: .text, title: "Recovered \(index)", text: "Recovered full Unicode body 中文 \(index)",
                contentHash: "failed-recovery-disk-\(index)",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                lastCopiedAt: Date(timeIntervalSince1970: 1_700_000_100 + Double(index)), isPinned: index == 0
            )
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try! encoder.encode(diskItems).write(to: history)
        manager.rejectPrimary = !normalMutationBeforeRetry
        manager.rejectPrimaryAttributes = normalMutationBeforeRetry
        check(!store.retrySaving(), "first recovery publication must fail at the injected write boundary")
        manager.rejectPrimary = false
        manager.rejectPrimaryAttributes = false
        if normalMutationBeforeRetry {
            store.togglePinned(pendingID)
            check(store.save(), "normal mutation must remain saveable after the repaired recovery write")
            store.insertCaptured(.init(kind: .text, title: "Later", text: "Later complete body", contentHash: "failed-recovery-later"))
            check(store.save(), "a later capture must survive another backup rotation")
        } else {
            check(store.retrySaving(), "a second recovery attempt must succeed after repairing the write")
        }
        let reloaded = ClipboardStore(storageDirectory: directory)
        let byID = Dictionary(uniqueKeysWithValues: reloaded.items.map { ($0.id, $0) })
        check(reloaded.items.count == (normalMutationBeforeRetry ? 5 : 4),
              "a failed first recovery must keep all disk rows through later retry or ordinary saves")
        for item in diskItems {
            check(byID[item.id] == item, "failed recovery must preserve every recovered ID, full body, pin and timestamp")
        }
        check(byID[pendingID] != nil, "failed recovery must also retain the pending in-memory item")
    }
}
