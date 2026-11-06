import AppKit
import CPasteCore
import Foundation

private final class InitialRecoveryConflictManager: FileManager, @unchecked Sendable {
    var beforePrimaryPublication: (() -> Void)?

    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        let created = super.createFile(atPath: path, contents: data, attributes: attr)
        if created && path.contains("/.history.json-"), let action = beforePrimaryPublication {
            beforePrimaryPublication = nil
            action()
        }
        return created
    }
}

private func initialConflictPNG() -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32
    )!
    for offset in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) {
        bitmap.bitmapData![offset] = UInt8([40, 96, 160, 255][offset % 4])
    }
    return bitmap.representation(using: .png, properties: [:])!
}

private func initialConflictEncode(_ items: [ClipboardItem]) -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try! encoder.encode(items)
}

private func initialConflictDecode(_ data: Data) -> [ClipboardItem] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try! decoder.decode([ClipboardItem].self, from: data)
}

private func initialConflictContains(_ expected: [ClipboardItem], in actual: [ClipboardItem]) -> Bool {
    let expected = initialConflictDecode(initialConflictEncode(expected))
    let actual = initialConflictDecode(initialConflictEncode(actual))
    let byID = Dictionary(uniqueKeysWithValues: actual.map { ($0.id, $0) })
    return expected.allSatisfy { item in
        byID[item.id] == item && byID[item.id]?.text.utf8.elementsEqual(item.text.utf8) == true
    }
}

func testInitialRecoveryPublicationConflictKeepsUnadoptedRowsForNextRetry() {
    let directory = makeTemporaryDirectory()
    let history = directory.appendingPathComponent("history.json")
    try! FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
    let manager = InitialRecoveryConflictManager()
    let store = ClipboardStore(storageDirectory: directory, fileManager: manager)
    check(store.storageIssue == .readOnly, "the initial conflict fixture must start with unreadable protected history")
    store.insertCaptured(.init(
        kind: .text, title: "Pending capture", subtitle: "Pending metadata", text: "Complete pending body 中文 e\u{301}",
        contentHash: "initial-conflict-pending", sourceAppName: "Pending App", sourceBundleIdentifier: "local.cpaste.pending"
    ))
    check(!store.save() && store.items.count == 1, "the unreadable history must keep the pending capture in memory")
    let pending = store.items[0]
    try! FileManager.default.removeItem(at: history)

    let png = initialConflictPNG()
    let pdf = Data("%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF\n".utf8)
    let imageName = "\(ContentHasher.hash(data: png)).png"
    let fileName = "\(ContentHasher.hash(data: pdf)).pdf"
    let attachments = [imageName: png, fileName: pdf]
    for (name, bytes) in attachments {
        try! bytes.write(to: store.blobDirectory.appendingPathComponent(name))
    }
    let fullText = String(repeating: "Recovered full UTF-8 body 中文 👨‍👩‍👧‍👦 e\u{301}\r\n", count: 4_000)
    let disk = [
        ClipboardItem(
            kind: .text, title: "Recovered text", subtitle: "Recovered long-text metadata", text: fullText,
            contentHash: ContentHasher.hash(string: "text:\(fullText)"),
            sourceAppName: "Text App", sourceBundleIdentifier: "local.cpaste.text",
            createdAt: Date(timeIntervalSince1970: 1_700_000_001), lastCopiedAt: Date(timeIntervalSince1970: 1_700_000_101), isPinned: true
        ),
        ClipboardItem(
            kind: .image, title: "Recovered image", subtitle: "4 × 3", blobFilename: imageName,
            contentHash: ContentHasher.hash(data: png), sourceAppName: "Image App", sourceBundleIdentifier: "local.cpaste.image",
            createdAt: Date(timeIntervalSince1970: 1_700_000_002), lastCopiedAt: Date(timeIntervalSince1970: 1_700_000_102)
        ),
        ClipboardItem(
            kind: .file, title: "Recovered document", subtitle: "Recovered file metadata",
            fileURLs: [store.blobDirectory.appendingPathComponent(fileName).absoluteString], blobFilename: fileName,
            contentHash: ContentHasher.hash(data: pdf), sourceAppName: "File App", sourceBundleIdentifier: "local.cpaste.file",
            createdAt: Date(timeIntervalSince1970: 1_700_000_003), lastCopiedAt: Date(timeIntervalSince1970: 1_700_000_103), isPinned: true
        )
    ]
    let diskData = initialConflictEncode(disk)
    try! diskData.write(to: history)
    let external = ClipboardItem(
        kind: .url, title: "External replacement", subtitle: "Independent metadata", text: "https://example.invalid/external",
        contentHash: "initial-conflict-external", sourceAppName: "External App", sourceBundleIdentifier: "local.cpaste.external",
        createdAt: Date(timeIntervalSince1970: 1_700_000_004), lastCopiedAt: Date(timeIntervalSince1970: 1_700_000_104)
    )
    let externalData = initialConflictEncode(disk + [external])
    var replacedAtPublication = false
    manager.beforePrimaryPublication = {
        replacedAtPublication = true
        try! externalData.write(to: history, options: .atomic)
    }
    check(!store.retrySaving() && replacedAtPublication && store.storageIssue == .historyConflict,
          "the first repair must reach final publication and report the injected concurrent replacement")
    check((try! Data(contentsOf: history)) == externalData,
          "a first-repair publication conflict must preserve the exact complete external primary")
    check(store.items.count == 1 && store.items[0] == pending,
          "a conflicted first repair must not silently adopt its candidate into the live model")
    guard let recovery = store.recoveryCopyURL else {
        check(false, "a first-repair publication conflict must expose a complete recovery copy")
        return
    }
    let recoveryRows = initialConflictDecode(try! Data(contentsOf: recovery.appendingPathComponent("history.json")))
    check(recoveryRows.count == 4 && initialConflictContains(disk + [pending], in: recoveryRows),
          "the recovery copy must preserve all unadopted disk rows and pending full text and metadata")
    check(attachments.allSatisfy { name, bytes in
        (try? Data(contentsOf: recovery.appendingPathComponent("Blobs").appendingPathComponent(name))) == bytes
    }, "the first-repair recovery copy must include every complete attachment")

    // Restoring the probed disk version must still merge it with the pending
    // capture: the conflicted candidate was never adopted by the live model.
    try! diskData.write(to: history, options: .atomic)
    let secondSucceeded = store.retrySaving()
    let secondRows = store.items
    store.togglePinned(pending.id)
    let pinSaved = store.save()
    store.insertCaptured(.init(kind: .text, title: "Later capture", text: "Later full body", contentHash: "initial-conflict-later"))
    let laterSaved = store.save()
    let finalRows = ClipboardStore(storageDirectory: directory).items
    let liveAttachmentsIntact = attachments.allSatisfy { name, bytes in
        (try? Data(contentsOf: store.blobDirectory.appendingPathComponent(name))) == bytes
    }

    let backupDirectory = makeTemporaryDirectory()
    try! FileManager.default.copyItem(at: directory, to: backupDirectory)
    let backupData = try! Data(contentsOf: store.historyBackupURL)
    try! backupData.write(to: backupDirectory.appendingPathComponent("history.json"), options: .atomic)
    let backupRows = ClipboardStore(storageDirectory: backupDirectory).items
    let backupAttachmentsIntact = attachments.allSatisfy { name, bytes in
        (try? Data(contentsOf: backupDirectory.appendingPathComponent("Blobs").appendingPathComponent(name))) == bytes
    }
    try? FileManager.default.removeItem(at: directory)
    try? FileManager.default.removeItem(at: backupDirectory)

    check(secondSucceeded && secondRows.count == 4 && initialConflictContains(disk + [pending], in: secondRows),
          "retry after a first-repair publication conflict must merge every unadopted disk row, not silently publish only pending memory")
    check(pinSaved && laterSaved && finalRows.count == 5 && initialConflictContains(disk, in: finalRows),
          "normal pin/save and new capture rotation must preserve every recovered ID, full UTF-8 body and metadata field")
    check(finalRows.first { $0.id == pending.id }?.isPinned == true && liveAttachmentsIntact,
          "later saves must retain the pending mutation and every original attachment byte")
    check(backupRows.count == 4 && initialConflictContains(disk, in: backupRows) && backupAttachmentsIntact,
          "the rotated backup must independently reload every recovered full body, metadata field and attachment")
}
