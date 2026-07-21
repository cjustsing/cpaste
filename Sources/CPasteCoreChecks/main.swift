import AppKit
import CPasteCore
import Foundation

@discardableResult
func check(_ condition: @autoclosure () -> Bool, _ message: String) -> Bool {
    if !condition() {
        fputs("Check failed: \(message)\n", stderr)
        exit(1)
    }
    return true
}

func makeStore(maxItems: Int = 500) -> ClipboardStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CPasteChecks-\(UUID().uuidString)", isDirectory: true)
    return ClipboardStore(storageDirectory: url, maxItems: maxItems)
}

func makeTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("CPasteChecks-\(UUID().uuidString)", isDirectory: true)
}

func testInsertDeduplicatesByContentHashAndMovesToTop() {
    let store = makeStore()
    let first = CapturedClipboardContent(
        kind: .text,
        title: "First",
        text: "First",
        contentHash: ContentHasher.hash(string: "text:First")
    )
    let second = CapturedClipboardContent(
        kind: .text,
        title: "Second",
        text: "Second",
        contentHash: ContentHasher.hash(string: "text:Second")
    )

    store.insertCaptured(first)
    store.insertCaptured(second)
    store.insertCaptured(first)

    check(store.items.count == 2, "dedupe should keep two unique items")
    check(store.items.first?.title == "First", "deduped item should move to top")
}

func testClearUnpinnedPreservesPinnedItems() {
    let store = makeStore()
    store.insertCaptured(CapturedClipboardContent(
        kind: .text,
        title: "Keep",
        text: "Keep",
        contentHash: "keep"
    ))
    store.insertCaptured(CapturedClipboardContent(
        kind: .text,
        title: "Remove",
        text: "Remove",
        contentHash: "remove"
    ))

    guard let keepID = store.items.first(where: { $0.title == "Keep" })?.id else {
        fputs("Check failed: pinned candidate should exist\n", stderr)
        exit(1)
    }
    store.togglePinned(keepID)
    store.clearUnpinned()

    check(store.items.map(\.title) == ["Keep"], "clear should preserve pinned item")
    check(store.items[0].isPinned, "preserved item should remain pinned")
}

func testTimelineSelectionUsesPreviousVisibleItemAfterRemoval() {
    let first = UUID()
    let second = UUID()
    let third = UUID()
    let fourth = UUID()
    let ids = [first, second, third, fourth]

    check(
        TimelineSelection.replacementID(afterRemoving: third, from: ids) == second,
        "removing a middle item should select its previous visible item"
    )
    check(
        TimelineSelection.replacementID(afterRemoving: fourth, from: ids) == third,
        "removing the last item should select its previous visible item"
    )
    check(
        TimelineSelection.replacementID(afterRemoving: first, from: ids) == second,
        "removing the first item should select the next visible item"
    )
    check(
        TimelineSelection.replacementID(afterRemoving: first, from: [first]) == nil,
        "removing the only item should clear selection"
    )
    check(
        TimelineSelection.replacementID(afterRemoving: UUID(), from: ids) == nil,
        "removing an unknown item should not invent a replacement selection"
    )
}

func testFilteringMatchesTextAndKind() {
    let store = makeStore()
    store.insertCaptured(CapturedClipboardContent(
        kind: .url,
        title: "https://example.com",
        subtitle: "URL",
        text: "https://example.com",
        contentHash: "url"
    ))
    store.insertCaptured(CapturedClipboardContent(
        kind: .text,
        title: "Meeting notes",
        text: "launch checklist",
        contentHash: "text"
    ))

    let results = store.filteredItems(search: "launch", kind: .text)

    check(results.count == 1, "filter should find one text item")
    check(results[0].title == "Meeting notes", "filter should return matching item")
}

func testPasteboardTextRoundTripUsesNamedPasteboard() {
    let pasteboardName = NSPasteboard.Name("CPasteChecks-\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: pasteboardName)
    pasteboard.clearContents()
    pasteboard.setString("named pasteboard smoke", forType: .string)

    guard let captured = PasteboardReader.read(from: pasteboard) else {
        fputs("Check failed: text should be readable from named pasteboard\n", stderr)
        exit(1)
    }

    check(captured.kind == .text, "named pasteboard text should be captured as text")
    check(captured.text == "named pasteboard smoke", "captured text should match pasteboard text")

    let store = makeStore()
    store.insertCaptured(captured)
    let item = store.items[0]
    pasteboard.clearContents()

    check(
        PasteboardWriter.write(item, blobDirectory: store.blobDirectory, to: pasteboard),
        "text item should write back to named pasteboard"
    )
    check(
        pasteboard.string(forType: .string) == "named pasteboard smoke",
        "written pasteboard text should match source"
    )
}

func testPersistenceReloadsHistory() {
    let directory = makeTemporaryDirectory()
    let store = ClipboardStore(storageDirectory: directory)
    store.insertCaptured(CapturedClipboardContent(
        kind: .text,
        title: "Persistent",
        text: "Persistent body",
        contentHash: "persistent"
    ))
    guard let itemID = store.items.first?.id else {
        fputs("Check failed: persistent item should exist\n", stderr)
        exit(1)
    }
    store.togglePinned(itemID)

    let reloadedStore = ClipboardStore(storageDirectory: directory)
    check(reloadedStore.items.count == 1, "reloaded store should contain saved item")
    check(reloadedStore.items[0].title == "Persistent", "reloaded item title should match")
    check(reloadedStore.items[0].isPinned, "reloaded item should preserve pinned state")
}

func testMaxItemsTrimsOldestUnpinnedItems() {
    let store = makeStore(maxItems: 3)
    for index in 0..<5 {
        store.insertCaptured(CapturedClipboardContent(
            kind: .text,
            title: "Item \(index)",
            text: "Item \(index)",
            contentHash: "item-\(index)"
        ))
    }

    check(store.items.count == 3, "max item limit should trim to three")
    check(store.items.map(\.title) == ["Item 4", "Item 3", "Item 2"], "trim should keep newest unpinned items")
}

func testTrimmingKeepsPinnedItemsInChronologicalOrder() {
    let store = makeStore(maxItems: 3)
    for index in 0..<3 {
        store.insertCaptured(CapturedClipboardContent(
            kind: .text,
            title: "Item \(index)",
            text: "Item \(index)",
            contentHash: "ordered-item-\(index)"
        ))
    }

    guard let oldestID = store.items.last?.id else {
        fputs("Check failed: chronological trim fixture should contain an item\n", stderr)
        exit(1)
    }
    store.togglePinned(oldestID)

    for index in 3..<5 {
        store.insertCaptured(CapturedClipboardContent(
            kind: .text,
            title: "Item \(index)",
            text: "Item \(index)",
            contentHash: "ordered-item-\(index)"
        ))
    }

    check(
        store.items.map(\.title) == ["Item 4", "Item 3", "Item 0"],
        "trimming should retain chronological order when preserving a pinned item"
    )
}

func testCorruptHistoryStartsEmpty() {
    let directory = makeTemporaryDirectory()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let historyURL = directory.appendingPathComponent("history.json", isDirectory: false)
    try? Data("{not json".utf8).write(to: historyURL)

    let store = ClipboardStore(storageDirectory: directory)
    check(store.items.isEmpty, "corrupt history should load as empty instead of crashing")
}

func testURLRoundTripUsesNamedPasteboard() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("CPasteChecks-\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setString("https://example.com/path?q=1", forType: .string)

    guard let captured = PasteboardReader.read(from: pasteboard) else {
        fputs("Check failed: URL should be readable from named pasteboard\n", stderr)
        exit(1)
    }

    check(captured.kind == .url, "URL string should be captured as URL")
    let store = makeStore()
    store.insertCaptured(captured)
    check(PasteboardWriter.write(store.items[0], blobDirectory: store.blobDirectory, to: pasteboard), "URL should write back")
    check(pasteboard.string(forType: .string) == "https://example.com/path?q=1", "URL string should remain available")
}

func testFileRoundTripUsesNamedPasteboard() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("CPasteChecks-\(UUID().uuidString)"))
    let fileURL = URL(fileURLWithPath: "/tmp/cpaste-check.txt")
    pasteboard.clearContents()
    pasteboard.writeObjects([fileURL as NSURL])

    guard let captured = PasteboardReader.read(from: pasteboard) else {
        fputs("Check failed: file URL should be readable from named pasteboard\n", stderr)
        exit(1)
    }

    check(captured.kind == .file, "file URL should be captured as file")
    check(captured.fileURLs == [fileURL.absoluteString], "captured file URL should match")

    let store = makeStore()
    store.insertCaptured(captured)
    check(PasteboardWriter.write(store.items[0], blobDirectory: store.blobDirectory, to: pasteboard), "file URL should write back")
}

func testFinderFileIconDoesNotOverrideFileRepresentation() {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let iconURL = repositoryRoot.appendingPathComponent("Resources/AppIcon/CPaste.icns", isDirectory: false)
    guard let iconData = try? Data(contentsOf: iconURL) else {
        fputs("Check failed: Finder file icon fixture should be readable\n", stderr)
        exit(1)
    }

    let fileURL = URL(fileURLWithPath: "/tmp/cpaste-finder-document.pdf")
    let pasteboardItem = NSPasteboardItem()
    pasteboardItem.setString(fileURL.absoluteString, forType: .fileURL)
    pasteboardItem.setData(iconData, forType: NSPasteboard.PasteboardType("com.apple.icns"))

    let pasteboard = NSPasteboard(name: NSPasteboard.Name("CPasteChecks-\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.writeObjects([pasteboardItem])

    check(NSImage(pasteboard: pasteboard) != nil, "Finder icon fixture should be convertible to an image")
    guard let captured = PasteboardReader.read(
        from: pasteboard,
        sourceBundleIdentifier: "com.apple.finder"
    ) else {
        fputs("Check failed: Finder PDF file should be readable\n", stderr)
        exit(1)
    }

    check(captured.kind == .file, "a Finder file icon should not replace the copied PDF file")
    check(captured.fileURLs == [fileURL.absoluteString], "the Finder PDF file URL should be preserved")
    check(captured.imagePNGData == nil, "the Finder file icon should not be saved as clipboard image content")
}

func testImageRoundTripUsesNamedPasteboard() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("CPasteChecks-\(UUID().uuidString)"))
    let image = NSImage(size: NSSize(width: 12, height: 12))
    image.lockFocus()
    NSColor.systemMint.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 12, height: 12)).fill()
    image.unlockFocus()

    pasteboard.clearContents()
    pasteboard.writeObjects([image])

    guard let captured = PasteboardReader.read(from: pasteboard) else {
        fputs("Check failed: image should be readable from named pasteboard\n", stderr)
        exit(1)
    }

    check(captured.kind == .image, "image should be captured as image")
    check(captured.imagePNGData != nil, "captured image should include PNG data")

    let store = makeStore()
    store.insertCaptured(captured)
    check(store.items[0].blobFilename != nil, "image item should save blob filename")
    check(PasteboardWriter.write(store.items[0], blobDirectory: store.blobDirectory, to: pasteboard), "image should write back")
}

func testImageThumbnailDecoderDownsamplesLargeImages() {
    let directory = makeTemporaryDirectory()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let imageURL = directory.appendingPathComponent("large-image.png", isDirectory: false)

    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 1_200,
        pixelsHigh: 600,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fputs("Check failed: thumbnail fixture should create a bitmap\n", stderr)
        exit(1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.systemMint.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1_200, height: 600)).fill()
    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        fputs("Check failed: thumbnail fixture should encode as PNG\n", stderr)
        exit(1)
    }
    try? pngData.write(to: imageURL, options: .atomic)

    guard let thumbnail = ImageThumbnailDecoder.thumbnail(at: imageURL, maxPixelSize: 240) else {
        fputs("Check failed: large image should produce a thumbnail\n", stderr)
        exit(1)
    }

    check(thumbnail.width == 240, "thumbnail should respect the requested maximum width")
    check(thumbnail.height == 120, "thumbnail should preserve the source aspect ratio")
    check(
        ImageThumbnailDecoder.thumbnail(at: imageURL, maxPixelSize: 0) == nil,
        "non-positive thumbnail size should be rejected"
    )
}

func testImageDataTakesPriorityOverFileRepresentation() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("CPasteChecks-\(UUID().uuidString)"))
    let image = NSImage(size: NSSize(width: 18, height: 14))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 18, height: 14)).fill()
    image.unlockFocus()

    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:])
    else {
        fputs("Check failed: hybrid image fixture should encode as PNG\n", stderr)
        exit(1)
    }

    let pasteboardItem = NSPasteboardItem()
    pasteboardItem.setString(
        URL(fileURLWithPath: "/tmp/chat-image.png").absoluteString,
        forType: .fileURL
    )
    pasteboardItem.setData(pngData, forType: .png)
    pasteboard.clearContents()
    pasteboard.writeObjects([pasteboardItem])

    check(pasteboard.types?.contains(.fileURL) == true, "hybrid chat image should advertise a file URL")
    check(pasteboard.types?.contains(.png) == true, "hybrid chat image should advertise PNG data")

    guard let captured = PasteboardReader.read(from: pasteboard) else {
        fputs("Check failed: hybrid chat image should be readable\n", stderr)
        exit(1)
    }

    check(captured.kind == .image, "direct image data should win over a temporary file representation")
    check(captured.imagePNGData != nil, "hybrid chat image should preserve image data")
    check(captured.fileURLs.isEmpty, "hybrid chat image should not remain a file item")
}

func testPDFFileRepresentationWinsOverImagePreview() {
    let directory = makeTemporaryDirectory()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let pdfURL = directory.appendingPathComponent("document.pdf", isDirectory: false)
    let pdfView = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    let pdfData = pdfView.dataWithPDF(inside: pdfView.bounds)
    try? pdfData.write(to: pdfURL, options: .atomic)

    let preview = NSImage(size: NSSize(width: 24, height: 24))
    preview.lockFocus()
    NSColor.systemOrange.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 24, height: 24)).fill()
    preview.unlockFocus()

    guard let tiffData = preview.tiffRepresentation else {
        fputs("Check failed: PDF preview fixture should encode as TIFF\n", stderr)
        exit(1)
    }

    let pasteboardItem = NSPasteboardItem()
    pasteboardItem.setString(pdfURL.absoluteString, forType: .fileURL)
    pasteboardItem.setData(pdfData, forType: .pdf)
    pasteboardItem.setData(tiffData, forType: .tiff)

    let pasteboard = NSPasteboard(name: NSPasteboard.Name("CPasteChecks-\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.writeObjects([pasteboardItem])

    guard let captured = PasteboardReader.read(
        from: pasteboard,
        sourceBundleIdentifier: "com.electron.lark"
    ) else {
        fputs("Check failed: PDF file with an image preview should be readable\n", stderr)
        exit(1)
    }

    check(captured.kind == .file, "a PDF file should not become an image because it advertises a preview")
    check(captured.fileURLs == [pdfURL.absoluteString], "the original PDF file URL should be preserved")
    check(captured.imagePNGData == nil, "a PDF file preview should not be persisted as PNG")
}

func testPDFDataIsPreservedAsAFile() {
    let pdfView = NSView(frame: NSRect(x: 0, y: 0, width: 32, height: 18))
    let pdfData = pdfView.dataWithPDF(inside: pdfView.bounds)
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("CPasteChecks-\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setData(pdfData, forType: .pdf)

    guard let captured = PasteboardReader.read(
        from: pasteboard,
        sourceBundleIdentifier: "com.apple.Preview"
    ) else {
        fputs("Check failed: PDF pasteboard data should be readable\n", stderr)
        exit(1)
    }

    check(captured.kind == .file, "PDF data should be captured as a file")
    check(captured.imagePNGData == nil, "PDF data should not be rasterized as PNG")
    check(captured.fileData == pdfData, "captured PDF data should remain byte-for-byte intact")
    check(captured.fileName?.hasSuffix(".pdf") == true, "captured PDF data should receive a PDF filename")

    let store = makeStore()
    store.insertCaptured(captured)
    guard let storedItem = store.items.first,
          let storedURLValue = storedItem.fileURLs.first,
          let storedURL = URL(string: storedURLValue)
    else {
        fputs("Check failed: captured PDF should be materialized as a stored file\n", stderr)
        exit(1)
    }

    check(storedItem.kind == .file, "stored PDF should remain a file item")
    check(storedURL.pathExtension.lowercased() == "pdf", "stored PDF should retain its extension")
    check((try? Data(contentsOf: storedURL)) == pdfData, "stored PDF should retain its original bytes")

    let outputPasteboard = NSPasteboard(name: NSPasteboard.Name("CPasteChecks-\(UUID().uuidString)"))
    check(
        PasteboardWriter.write(storedItem, blobDirectory: store.blobDirectory, to: outputPasteboard),
        "stored PDF should write back as a file"
    )
    let writtenURLs = outputPasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]
    ) as? [NSURL]
    check(writtenURLs?.first?.pathExtension?.lowercased() == "pdf", "written PDF should remain a file URL")
}

func testSingleImageFileUsesSourceApplicationIntent() {
    let directory = makeTemporaryDirectory()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let imageURL = directory.appendingPathComponent("chat-image.png", isDirectory: false)
    let image = NSImage(size: NSSize(width: 20, height: 16))
    image.lockFocus()
    NSColor.systemPink.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 20, height: 16)).fill()
    image.unlockFocus()

    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:])
    else {
        fputs("Check failed: image-file fixture should encode as PNG\n", stderr)
        exit(1)
    }
    try? pngData.write(to: imageURL, options: .atomic)

    let pasteboard = NSPasteboard(name: NSPasteboard.Name("CPasteChecks-\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.writeObjects([imageURL as NSURL])

    guard let chatCapture = PasteboardReader.read(
        from: pasteboard,
        sourceBundleIdentifier: "com.electron.lark"
    ) else {
        fputs("Check failed: chat image file should be readable\n", stderr)
        exit(1)
    }
    check(chatCapture.kind == .image, "single chat image file should convert to an image item")
    check(chatCapture.imagePNGData != nil, "converted chat image file should preserve image data")

    guard let finderCapture = PasteboardReader.read(
        from: pasteboard,
        sourceBundleIdentifier: "com.apple.finder"
    ) else {
        fputs("Check failed: Finder image file should be readable\n", stderr)
        exit(1)
    }
    check(finderCapture.kind == .file, "Finder image file should keep file semantics")
    check(finderCapture.fileURLs == [imageURL.absoluteString], "Finder image file URL should remain available")
}

func testSourceApplicationMetadataPersistsAndSearches() {
    let directory = makeTemporaryDirectory()
    let store = ClipboardStore(storageDirectory: directory)
    store.insertCaptured(CapturedClipboardContent(
        kind: .url,
        title: "Apple Developer",
        subtitle: "URL",
        text: "https://developer.apple.com",
        contentHash: "source-app-metadata",
        sourceAppName: "Safari",
        sourceBundleIdentifier: "com.apple.Safari"
    ))

    check(store.filteredItems(search: "Safari").count == 1, "source app name should be searchable")
    check(store.filteredItems(search: "com.apple.Safari").count == 1, "source bundle id should be searchable")

    let reloadedStore = ClipboardStore(storageDirectory: directory)
    check(reloadedStore.items.first?.sourceAppName == "Safari", "source app name should persist")
    check(reloadedStore.items.first?.sourceBundleIdentifier == "com.apple.Safari", "source bundle id should persist")
}

func testLegacyHistoryWithoutSourceMetadataStillLoads() {
    let directory = makeTemporaryDirectory()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let historyURL = directory.appendingPathComponent("history.json", isDirectory: false)
    let id = UUID().uuidString
    let legacyJSON = """
    [
      {
        "id": "\(id)",
        "kind": "text",
        "title": "Legacy item",
        "subtitle": "",
        "text": "Legacy body",
        "fileURLs": [],
        "contentHash": "legacy-item",
        "createdAt": "2026-07-09T00:00:00Z",
        "lastCopiedAt": "2026-07-09T00:00:00Z",
        "isPinned": false
      }
    ]
    """
    try? Data(legacyJSON.utf8).write(to: historyURL, options: .atomic)

    let store = ClipboardStore(storageDirectory: directory)
    check(store.items.count == 1, "legacy history without source metadata should load")
    check(store.items[0].sourceAppName == nil, "legacy source app name should default to nil")
    check(store.items[0].sourceBundleIdentifier == nil, "legacy source bundle id should default to nil")
}

func testUpdatingHistoryLimitTrimsImmediately() {
    let store = makeStore(maxItems: 10)
    for index in 0..<6 {
        store.insertCaptured(CapturedClipboardContent(
            kind: .text,
            title: "Limit item \(index)",
            text: "Limit item \(index)",
            contentHash: "limit-item-\(index)"
        ))
    }

    guard let pinnedID = store.items.last?.id else {
        fputs("Check failed: limit test should contain an item\n", stderr)
        exit(1)
    }
    store.togglePinned(pinnedID)
    store.setMaxItems(3)

    check(store.maxItems == 50, "history limit should clamp to the supported minimum")
    check(store.items.count == 6, "minimum limit should not trim a six item history")

    let largerStore = makeStore(maxItems: 100)
    for index in 0..<60 {
        largerStore.insertCaptured(CapturedClipboardContent(
            kind: .text,
            title: "Large item \(index)",
            text: "Large item \(index)",
            contentHash: "large-item-\(index)"
        ))
    }
    largerStore.setMaxItems(50)
    check(largerStore.items.count == 50, "updating history limit should trim immediately")
}

func testPlainTextWriterUsesTextFallbacks() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("CPasteChecks-\(UUID().uuidString)"))
    let textItem = ClipboardItem(kind: .text, title: "Text", text: "plain value", contentHash: "plain-text")
    check(PasteboardWriter.writePlainText(textItem, to: pasteboard), "text item should write as plain text")
    check(pasteboard.string(forType: .string) == "plain value", "plain text value should match")

    let fileItem = ClipboardItem(
        kind: .file,
        title: "Files",
        fileURLs: ["file:///tmp/one.txt", "file:///tmp/two.txt"],
        contentHash: "plain-files"
    )
    check(PasteboardWriter.writePlainText(fileItem, to: pasteboard), "file item should write paths as plain text")
    check(pasteboard.string(forType: .string) == "/tmp/one.txt\n/tmp/two.txt", "file paths should be newline separated")

    let imageItem = ClipboardItem(kind: .image, title: "Image", contentHash: "plain-image")
    check(!PasteboardWriter.writePlainText(imageItem, to: pasteboard), "image without OCR should not claim a plain text value")
}

func testPanelPlacementFollowsMouseAndUsesFullScreenWidth() {
    let screenFrames = [
        CGRect(x: -1_920, y: -200, width: 1_920, height: 1_080),
        CGRect(x: 0, y: 0, width: 1_440, height: 900),
        CGRect(x: 1_440, y: 120, width: 2_560, height: 1_440)
    ]

    check(
        PanelPlacement.targetScreenIndex(
            for: CGPoint(x: -800, y: 100),
            screenFrames: screenFrames
        ) == 0,
        "mouse on a negative-origin display should select that display"
    )
    check(
        PanelPlacement.targetScreenIndex(
            for: CGPoint(x: 2_000, y: 600),
            screenFrames: screenFrames
        ) == 2,
        "mouse on a secondary display should select that display"
    )
    check(
        PanelPlacement.targetScreenIndex(
            for: CGPoint(x: 9_999, y: 9_999),
            screenFrames: screenFrames,
            fallbackIndex: 1
        ) == 1,
        "an unmatched mouse location should use the requested fallback display"
    )

    let targetFrame = PanelPlacement.panelFrame(on: screenFrames[2], height: 440)
    check(targetFrame.minX == screenFrames[2].minX, "panel should align with the display's left edge")
    check(targetFrame.minY == screenFrames[2].minY, "panel should align with the display's bottom edge")
    check(targetFrame.width == screenFrames[2].width, "panel should use the display's full width")
    check(targetFrame.height == 440, "panel should preserve the requested height")
}

func testHiddenPanelCanBePreparedBeforePresentation() {
    _ = NSApplication.shared
    let panel = NSPanel(
        contentRect: CGRect(x: 0, y: 0, width: 640, height: 320),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    panel.animationBehavior = .none

    let targetFrame = CGRect(x: 1_440, y: -200, width: 1_920, height: 440)
    panel.setFrame(targetFrame, display: false, animate: false)
    panel.contentView?.layoutSubtreeIfNeeded()
    panel.displayIfNeeded()

    check(!panel.isVisible, "preparing a hidden panel should not present it on the previous display")
    check(panel.frame == targetFrame, "hidden panel should commit its target display frame before presentation")
}

func testPanelRecreationTracksDisplayGeometryAndBackingScale() {
    let externalFrame = CGRect(x: 0, y: 982, width: 3_440, height: 1_440)
    let builtInFrame = CGRect(x: 0, y: 0, width: 1_512, height: 982)

    check(
        !PanelPlacement.requiresWindowRecreation(
            currentScreenFrame: externalFrame,
            currentBackingScaleFactor: 1,
            targetScreenFrame: externalFrame,
            targetBackingScaleFactor: 1
        ),
        "same-display presentation should reuse the existing panel"
    )
    check(
        PanelPlacement.requiresWindowRecreation(
            currentScreenFrame: externalFrame,
            currentBackingScaleFactor: 1,
            targetScreenFrame: builtInFrame,
            targetBackingScaleFactor: 2
        ),
        "moving from a 1x external display to a 2x built-in display should recreate the panel"
    )
    check(
        PanelPlacement.requiresWindowRecreation(
            currentScreenFrame: builtInFrame,
            currentBackingScaleFactor: 1,
            targetScreenFrame: builtInFrame,
            targetBackingScaleFactor: 2
        ),
        "a backing-scale change should recreate the panel even when geometry is unchanged"
    )
    check(
        PanelPlacement.requiresWindowRecreation(
            currentScreenFrame: nil,
            currentBackingScaleFactor: nil,
            targetScreenFrame: builtInFrame,
            targetBackingScaleFactor: 2
        ),
        "the first presentation should create a panel for the target display"
    )
}

func testThemeAvailabilityAndDefaultsFollowMacOSVersion() {
    check(
        AppThemeStyle.available(onMacOSMajorVersion: 25) == [.standard],
        "macOS versions below 26 should only expose the standard theme"
    )
    check(
        AppThemeStyle.available(onMacOSMajorVersion: 26) == [.standard, .liquidGlass],
        "macOS 26 should expose both standard and Liquid Glass themes"
    )
    check(
        AppThemeStyle.resolved(savedRawValue: nil, onMacOSMajorVersion: 25) == .standard,
        "macOS versions below 26 should default to the standard theme"
    )
    check(
        AppThemeStyle.resolved(savedRawValue: nil, onMacOSMajorVersion: 26) == .liquidGlass,
        "macOS 26 should default to Liquid Glass"
    )
}

func testThemeResolutionPreservesValidChoicesAndRejectsUnsupportedGlass() {
    check(
        AppThemeStyle.resolved(savedRawValue: AppThemeStyle.standard.rawValue, onMacOSMajorVersion: 26) == .standard,
        "a saved standard-theme choice should be preserved on macOS 26"
    )
    check(
        AppThemeStyle.resolved(savedRawValue: AppThemeStyle.liquidGlass.rawValue, onMacOSMajorVersion: 26) == .liquidGlass,
        "a saved Liquid Glass choice should be preserved on macOS 26"
    )
    check(
        AppThemeStyle.resolved(savedRawValue: AppThemeStyle.liquidGlass.rawValue, onMacOSMajorVersion: 25) == .standard,
        "an unavailable saved Liquid Glass choice should fall back to standard"
    )
    check(
        AppThemeStyle.resolved(savedRawValue: "unknown", onMacOSMajorVersion: 26) == .liquidGlass,
        "an invalid saved choice should use the system-appropriate default"
    )
}

testInsertDeduplicatesByContentHashAndMovesToTop()
testClearUnpinnedPreservesPinnedItems()
testTimelineSelectionUsesPreviousVisibleItemAfterRemoval()
testFilteringMatchesTextAndKind()
testSensitiveAndTransientPasteboardTypesAreIgnored()
testPasteboardTextRoundTripUsesNamedPasteboard()
testPersistenceReloadsHistory()
testClipboardStorageUsesPrivatePermissions()
testMaxItemsTrimsOldestUnpinnedItems()
testTrimmingKeepsPinnedItemsInChronologicalOrder()
testCorruptHistoryStartsEmpty()
testURLRoundTripUsesNamedPasteboard()
testFileRoundTripUsesNamedPasteboard()
testFinderFileIconDoesNotOverrideFileRepresentation()
testImageRoundTripUsesNamedPasteboard()
testImageThumbnailDecoderDownsamplesLargeImages()
testImageDataTakesPriorityOverFileRepresentation()
testPDFFileRepresentationWinsOverImagePreview()
testPDFDataIsPreservedAsAFile()
testSingleImageFileUsesSourceApplicationIntent()
testSourceApplicationMetadataPersistsAndSearches()
testLegacyHistoryWithoutSourceMetadataStillLoads()
testUpdatingHistoryLimitTrimsImmediately()
testPlainTextWriterUsesTextFallbacks()
testPanelPlacementFollowsMouseAndUsesFullScreenWidth()
testHiddenPanelCanBePreparedBeforePresentation()
testPanelRecreationTracksDisplayGeometryAndBackingScale()
testThemeAvailabilityAndDefaultsFollowMacOSVersion()
testThemeResolutionPreservesValidChoicesAndRejectsUnsupportedGlass()

print("CPasteCoreChecks passed")
