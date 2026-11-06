import CPasteCore
import Foundation

private final class RepeatedInitialConflictManager: FileManager, @unchecked Sendable {
    var replaceAtPrimaryPublication: (() -> Void)?

    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        let created = super.createFile(atPath: path, contents: data, attributes: attr)
        if created && path.contains("/.history.json-"), let replace = replaceAtPrimaryPublication {
            replaceAtPrimaryPublication = nil
            replace()
        }
        return created
    }
}

private func repeatedInitialConflictEncode(_ items: [ClipboardItem]) -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try! encoder.encode(items)
}

private func repeatedInitialConflictRows(_ data: Data) -> [ClipboardItem] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try! decoder.decode([ClipboardItem].self, from: data)
}

private func repeatedInitialConflictMatches(_ expected: [ClipboardItem], in data: Data) -> Bool {
    let expected = repeatedInitialConflictRows(repeatedInitialConflictEncode(expected))
    let actual = repeatedInitialConflictRows(data)
    let byID = Dictionary(uniqueKeysWithValues: actual.map { ($0.id, $0) })
    return byID.count == expected.count && expected.allSatisfy {
        byID[$0.id] == $0 && byID[$0.id]?.text.utf8.elementsEqual($0.text.utf8) == true
    }
}

func testInitialRecoveryConflictRemainsProtectedUntilOriginalDiskReturns() {
    let directory = makeTemporaryDirectory()
    let history = directory.appendingPathComponent("history.json")
    try! FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
    let manager = RepeatedInitialConflictManager()
    let store = ClipboardStore(storageDirectory: directory, fileManager: manager)
    defer { _ = store.save(); try? FileManager.default.removeItem(at: directory) }
    check(store.storageIssue == .readOnly, "the repeated-conflict fixture must start without an adopted disk baseline")
    store.insertCaptured(.init(kind: .text, title: "Pending", text: "Pending complete text 中文 e\u{301}", contentHash: "repeat-initial-pending"))
    check(!store.save() && store.items.count == 1, "the pending item must remain in memory while the initial primary is unreadable")
    let pending = store.items[0]
    let disk = ClipboardItem(
        kind: .text, title: "Original disk", subtitle: "Original metadata", text: "Original complete text 中文 e\u{301}",
        contentHash: "repeat-initial-disk", sourceAppName: "Original App", sourceBundleIdentifier: "local.cpaste.original",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), lastCopiedAt: Date(timeIntervalSince1970: 1_700_000_100), isPinned: true
    )
    let original = repeatedInitialConflictEncode([disk])
    let external = repeatedInitialConflictEncode([ClipboardItem(
        kind: .text, title: "External", text: "Independent complete external body", contentHash: "repeat-initial-external",
        createdAt: Date(timeIntervalSince1970: 1_700_000_001), lastCopiedAt: Date(timeIntervalSince1970: 1_700_000_101)
    )])
    try! FileManager.default.removeItem(at: history)
    try! original.write(to: history)
    manager.replaceAtPrimaryPublication = { try! external.write(to: history, options: .atomic) }
    check(!store.retrySaving() && store.storageIssue == .historyConflict,
          "the repaired initial history must first encounter the controlled final-publication conflict")
    guard let initialCopy = store.recoveryCopyURL else {
        check(false, "the first initial-recovery conflict must provide its independent checkpoint")
        return
    }
    let initialCopyHistory = initialCopy.appendingPathComponent("history.json")
    let initialCopyBytes = try! Data(contentsOf: initialCopyHistory)
    check(repeatedInitialConflictMatches([disk, pending], in: initialCopyBytes),
          "the first checkpoint must include both the unadopted original disk row and pending memory")

    for _ in 0..<2 {
        check(!store.retrySaving() && store.storageIssue == .historyConflict,
              "a persistent external primary must remain a conflict rather than become an automatically adopted initial baseline")
        check(store.items.count == 1 && store.items[0] == pending && (try! Data(contentsOf: history)) == external,
              "repeated initial-recovery conflicts must leave pending memory and the exact external primary unchanged")
        guard let repeatedCopy = store.recoveryCopyURL else {
            check(false, "each repeated initial-recovery conflict must expose a complete checkpoint")
            return
        }
        check(repeatedInitialConflictMatches([disk, pending], in: try! Data(contentsOf: repeatedCopy.appendingPathComponent("history.json"))),
              "a repeated conflict checkpoint must retain the unadopted original disk row as well as pending memory")
        check((try! Data(contentsOf: initialCopyHistory)) == initialCopyBytes,
              "repeated retries must preserve the first complete checkpoint byte for byte")
    }

    try! original.write(to: history, options: .atomic)
    check(store.retrySaving() && repeatedInitialConflictMatches([disk, pending], in: repeatedInitialConflictEncode(store.items)),
          "only restoration of the original probed disk version may finish the initial recovery merge")
    check(store.save() && repeatedInitialConflictMatches([disk, pending], in: repeatedInitialConflictEncode(ClipboardStore(storageDirectory: directory).items)),
          "the completed initial merge must persist both complete rows after repeated protected conflicts")
    check((try! Data(contentsOf: initialCopyHistory)) == initialCopyBytes,
          "successful recovery must also retain the original complete conflict checkpoint")
}
