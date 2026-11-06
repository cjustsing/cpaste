import CPasteCore
import Foundation

func testLargeTextStorageRegression() {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let text = String(repeating: "完整正文 Unicode 👨‍👩‍👧‍👦\n", count: 12_000) + "TailNeedle"
    let store = ClipboardStore(storageDirectory: directory)
    store.insertCaptured(.init(kind: .text, title: "Large fixture", text: text, contentHash: "regression-large"))
    store.save()

    let index = try! Data(contentsOf: directory.appendingPathComponent("history.json"))
    check(index.count < 16_384, "large text must be stored outside the small history index")
    let reloaded = ClipboardStore(storageDirectory: directory)
    check(reloaded.items.first?.text == text, "separate text storage must preserve every Unicode scalar and the tail")
}

func testUnreadableHistoryPreservationRegression() {
    let directory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let original = Data("{invalid synthetic history fixture".utf8)
    try! original.write(to: directory.appendingPathComponent("history.json"))
    let store = ClipboardStore(storageDirectory: directory)
    store.insertCaptured(.init(kind: .text, title: "New capture", text: "New capture", contentHash: "new-capture"))
    store.save()

    let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
    let preserved = enumerator.compactMap { $0 as? URL }.contains { url in
        (try? Data(contentsOf: url)) == original
    }
    check(preserved, "a failed history load must preserve the original bytes before any later save")
}
