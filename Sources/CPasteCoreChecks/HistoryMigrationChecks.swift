import CPasteCore
import Foundation

/// Exercise migration on a disposable copy; never initialize a store on the input directory.
func checkLegacyHistoryMigration(sourceDirectory: URL) {
    let fileManager = FileManager.default
    let directory = makeTemporaryDirectory()
    defer { try? fileManager.removeItem(at: directory) }
    do {
        let originalData = try Data(contentsOf: sourceDirectory.appendingPathComponent("history.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let expected = try decoder.decode([ClipboardItem].self, from: originalData)
        try fileManager.copyItem(at: sourceDirectory, to: directory)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let store = ClipboardStore(storageDirectory: directory)
        checkHistoryItemsEqual(store.items, expected, phase: "legacy load")
        check(store.save(), "legacy migration must complete every pending write")
        let reloaded = ClipboardStore(storageDirectory: directory)
        checkHistoryItemsEqual(reloaded.items, expected, phase: "migrated reload")
        check(reloaded.save(), "a migrated history must remain writable after reloading")

        let names = Set(expected.compactMap(\.blobFilename))
        for name in names {
            check(URL(fileURLWithPath: name).lastPathComponent == name, "fixture blob name must be local")
            let original = try Data(contentsOf: sourceDirectory.appendingPathComponent("Blobs").appendingPathComponent(name))
            let migrated = try Data(contentsOf: store.blobDirectory.appendingPathComponent(name))
            check(original == migrated, "migration must preserve every binary attachment")
        }
        let finalInput = try Data(contentsOf: sourceDirectory.appendingPathComponent("history.json"))
        check(originalData == finalInput, "migration verification must not modify its input history")
        let indexBytes = try Data(contentsOf: store.historyURL).count
        print("Legacy migration verified: \(expected.count) items, \(names.count) attachments; index \(originalData.count) -> \(indexBytes) bytes")
    } catch {
        fputs("Check failed: isolated legacy migration: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

private func checkHistoryItemsEqual(_ actual: [ClipboardItem], _ expected: [ClipboardItem], phase: String) {
    check(actual.count == expected.count, "\(phase) must preserve all history items")
    let byID = Dictionary(uniqueKeysWithValues: actual.map { ($0.id, $0) })
    for item in expected {
        check(byID[item.id] == item, "\(phase) must preserve IDs, full text, metadata, dates, pins, hashes and file references")
        check(byID[item.id]?.text.utf8.elementsEqual(item.text.utf8) == true,
              "\(phase) must preserve text byte-for-byte, including Unicode normalization")
    }
}
