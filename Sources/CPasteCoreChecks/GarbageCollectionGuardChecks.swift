import AppKit
import CPasteCore
import Foundation

private func collectionGuardPNG(width: Int) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 3, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
    )!
    for offset in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) {
        bitmap.bitmapData![offset] = UInt8([48, 112, 176, 255][offset % 4])
    }
    return bitmap.representation(using: .png, properties: [:])!
}

private struct ForeignCollectionPayloads {
    let imageData = collectionGuardPNG(width: 4)
    let text = String(repeating: "External complete body 中文 👨‍👩‍👧‍👦 e\u{301}\r\n", count: 4_000)
    let image: ClipboardItem
    let textItem: ClipboardItem
    let imageURL: URL
    let textURL: URL

    init(store: ClipboardStore) {
        let imageHash = ContentHasher.hash(data: imageData)
        let textData = Data(text.utf8)
        imageURL = store.blobDirectory.appendingPathComponent("\(imageHash).png")
        textURL = store.textDirectory.appendingPathComponent("\(ContentHasher.hash(data: textData)).txt")
        image = ClipboardItem(
            kind: .image, title: "External image fixture", blobFilename: imageURL.lastPathComponent,
            contentHash: imageHash, sourceAppName: "External Fixture", sourceBundleIdentifier: "local.cpaste.fixture",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), lastCopiedAt: Date(timeIntervalSince1970: 1_700_000_005)
        )
        textItem = ClipboardItem(
            kind: .text, title: "External long text fixture", text: text,
            contentHash: ContentHasher.hash(string: "text:\(text)"),
            sourceAppName: "External Fixture", sourceBundleIdentifier: "local.cpaste.fixture",
            createdAt: Date(timeIntervalSince1970: 1_700_000_010), lastCopiedAt: Date(timeIntervalSince1970: 1_700_000_015),
            isPinned: true
        )
        try! imageData.write(to: imageURL)
        try! textData.write(to: textURL)
        for url in [imageURL, textURL] {
            try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func indexData(base: [ClipboardItem]) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var records = try! JSONSerialization.jsonObject(with: encoder.encode(base + [image, textItem])) as! [[String: Any]]
        let index = records.firstIndex { $0["contentHash"] as? String == textItem.contentHash }!
        let textData = Data(text.utf8)
        records[index]["text"] = ""
        records[index]["textStorage"] = [
            "filename": textURL.lastPathComponent,
            "sha256": ContentHasher.hash(data: textData),
            "byteCount": textData.count
        ] as [String: Any]
        return try! JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
    }

    var bytesAreIntact: Bool {
        (try? Data(contentsOf: imageURL)) == imageData && (try? Data(contentsOf: textURL)) == Data(text.utf8)
    }

    func rowsAreIntact(in store: ClipboardStore, base: [ClipboardItem]) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let expected = try! decoder.decode([ClipboardItem].self, from: encoder.encode(base + [image, textItem]))
        let actual = Dictionary(uniqueKeysWithValues: store.items.map { ($0.id, $0) })
        return actual.count == expected.count && expected.allSatisfy { actual[$0.id] == $0 } &&
            actual[textItem.id]?.text.utf8.elementsEqual(text.utf8) == true
    }
}

private func cancelCollectionGuardCapture(in store: ClipboardStore) -> (completed: Bool, discarded: Bool, ownBlob: URL) {
    let data = collectionGuardPNG(width: 5)
    let hash = ContentHasher.hash(data: data)
    var completed = false
    var discarded = false
    store.insertCapturedAsync(
        .init(kind: .image, title: "Cancelled local fixture", imagePNGData: data, contentHash: hash),
        capturedAt: Date(), shouldCommit: { false },
        completion: { result in
            if case .discarded = result { discarded = true }
            completed = true
        }
    )
    let deadline = Date().addingTimeInterval(5)
    while !completed, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.002))
    }
    return (completed, discarded, store.blobDirectory.appendingPathComponent("\(hash).png"))
}

func testCancelledStagePreservesPublishedForeignDependencies() {
    let directory = makeTemporaryDirectory()
    let store = ClipboardStore(storageDirectory: directory)
    store.insertCaptured(.init(kind: .text, title: "Known base", text: "Known base", contentHash: "known-base"))
    check(store.save(), "the collection guard base must initialize")
    let base = store.items
    let foreign = ForeignCollectionPayloads(store: store)
    let published = foreign.indexData(base: base)
    try! published.write(to: store.historyURL, options: .atomic)

    let cancelled = cancelCollectionGuardCapture(in: store)
    let saved = store.save()
    let sameIndex = (try? Data(contentsOf: store.historyURL)) == published
    let payloadsIntact = foreign.bytesAreIntact
    let restored = sameIndex && payloadsIntact && foreign.rowsAreIntact(in: ClipboardStore(storageDirectory: directory), base: base)
    try? FileManager.default.removeItem(at: directory)

    check(cancelled.completed && cancelled.discarded, "the local asynchronous preparation must really be cancelled")
    check(payloadsIntact, "cancelled preparation GC must preserve a published foreign index's PNG and full text dependencies")
    check(!saved && sameIndex, "the save barrier must refuse to replace independently published valid history")
    check(restored, "the intact foreign history must still load every full body and metadata field")
}

func testCollectionRetainsUnpublishedForeignPayloads() {
    let directory = makeTemporaryDirectory()
    let store = ClipboardStore(storageDirectory: directory)
    store.insertCaptured(.init(kind: .text, title: "Known base", text: "Known base", contentHash: "known-base"))
    check(store.save(), "the unpublished payload fixture must initialize")
    let baseID = store.items[0].id
    // Another writer has materialized its dependencies but has not published
    // its index yet. The current history is still byte-for-byte unchanged.
    let foreign = ForeignCollectionPayloads(store: store)
    let cancelled = cancelCollectionGuardCapture(in: store)
    store.togglePinned(baseID)
    let saved = store.save()
    let unknownPayloadsIntact = foreign.bytesAreIntact
    let ownCancelledBlobCollected = !FileManager.default.fileExists(atPath: cancelled.ownBlob.path)
    let base = store.items
    var restored = false
    if unknownPayloadsIntact {
        try! foreign.indexData(base: base).write(to: store.historyURL, options: .atomic)
        restored = foreign.rowsAreIntact(in: ClipboardStore(storageDirectory: directory), base: base)
    }
    try? FileManager.default.removeItem(at: directory)

    check(cancelled.completed && cancelled.discarded && saved, "cancellation and an ordinary metadata save must complete")
    check(unknownPayloadsIntact, "GC must retain unknown PNG/text files even before an external writer publishes its index")
    check(ownCancelledBlobCollected, "this process's explicitly created cancelled orphan must remain collectible")
    check(restored, "the external writer must later be able to publish and load its complete prepared history")
}
