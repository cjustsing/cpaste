import CPasteCore
import Foundation

func testRepeatedDamagedBackupArchivingIsIdempotent() {
    let fileManager = FileManager.default
    let directory = makeTemporaryDirectory()
    defer { try? fileManager.removeItem(at: directory) }
    let store = ClipboardStore(storageDirectory: directory)
    store.insertCaptured(.init(kind: .text, title: "Good", text: "Good", contentHash: "archive-good"))
    check(store.save(), "archive fixture must first have a valid history")
    let damaged = Data(("{damaged legacy fixture " + String(repeating: "original bytes ", count: 20_000)).utf8)
    try! damaged.write(to: directory.appendingPathComponent("history.legacy-backup.json"))
    for _ in 0..<4 {
        check(store.save(), "preserving a damaged migration backup must not prevent valid saves")
    }
    let restarted = ClipboardStore(storageDirectory: directory)
    check(restarted.save(), "archive protection must also work after restart")
    let archives = try! fileManager.contentsOfDirectory(
        at: directory.appendingPathComponent("Recovery"), includingPropertiesForKeys: nil
    )
    let identicalCopies = archives.filter { (try? Data(contentsOf: $0)) == damaged }
    check(identicalCopies.count == 1, "repeated saves and restarts must archive identical damaged backup bytes only once")
    check(restarted.items.first?.text == "Good", "archive reuse must preserve the valid current history")
    let permissions = try! fileManager.attributesOfItem(atPath: identicalCopies[0].path)[.posixPermissions] as! NSNumber
    check(permissions.intValue == 0o600, "a reused recovery archive must remain private")
}
