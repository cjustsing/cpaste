import AppKit
import CPasteCore
import Foundation

private struct WriteCheckItemSnapshot: Equatable {
    let types: [String]
    let bytes: [Data?]
}

private struct WriteCheckSnapshot: Equatable {
    let changeCount: Int
    let types: [String]
    let items: [WriteCheckItemSnapshot]

    init(_ pasteboard: NSPasteboard) {
        changeCount = pasteboard.changeCount
        types = (pasteboard.types ?? []).map(\.rawValue)
        items = (pasteboard.pasteboardItems ?? []).map { item in
            WriteCheckItemSnapshot(types: item.types.map(\.rawValue), bytes: item.types.map { item.data(forType: $0) })
        }
    }
}

private func writeCheckPasteboard() -> NSPasteboard {
    let pasteboard = NSPasteboard(name: .init("CPasteWriterChecks-\(UUID().uuidString)"))
    let first = NSPasteboardItem()
    first.setString("existing clipboard 👨‍👩‍👧‍👦\n", forType: .string)
    first.setData(Data([0, 255, 16, 128, 0]), forType: .init("local.cpaste.writer-check.binary"))
    let second = NSPasteboardItem()
    second.setData(Data([1, 2, 0, 3, 254]), forType: .init("local.cpaste.writer-check.second"))
    check(pasteboard.writeObjects([first, second]), "the named sentinel pasteboard must initialize")
    return pasteboard
}

private func writeCheckPNG() -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32
    )!
    for offset in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) {
        bitmap.bitmapData![offset] = UInt8([48, 128, 192, 255][offset % 4])
    }
    return bitmap.representation(using: .png, properties: [:])!
}

func testImageWritePreflightPreservesPasteboard() {
    let directory = makeTemporaryDirectory()
    let blobs = directory.appendingPathComponent("Blobs", isDirectory: true)
    try! FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try! Data("invalid image bytes".utf8).write(to: blobs.appendingPathComponent("invalid.png"))
    try! writeCheckPNG().write(to: directory.appendingPathComponent("outside.png"))
    let filenames: [String?] = [nil, "", "missing.png", "invalid.png", ".", "../outside.png"]
    for filename in filenames {
        let pasteboard = writeCheckPasteboard()
        defer { pasteboard.releaseGlobally() }
        let before = WriteCheckSnapshot(pasteboard)
        let item = ClipboardItem(kind: .image, title: "Invalid image fixture", blobFilename: filename, contentHash: "invalid-image")
        check(!PasteboardWriter.write(item, blobDirectory: blobs, to: pasteboard),
              "an absent, invalid or escaping image must fail preflight")
        check(WriteCheckSnapshot(pasteboard) == before,
              "failed image preflight must preserve changeCount, all types, every item and every byte")
    }
}

func testFileWritePreflightPreservesPasteboard() {
    let directory = makeTemporaryDirectory()
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let valid = directory.appendingPathComponent("valid.txt")
    try! Data("valid file".utf8).write(to: valid)
    let missing = directory.appendingPathComponent("missing.txt").absoluteString
    let remote = "https://example.com/not-a-local-file.txt"
    let invalidLists = [
        [], [missing], [remote], ["relative/file.txt"], ["http://["],
        [valid.absoluteString, missing], [valid.absoluteString, remote],
        [valid.absoluteString, "http://["]
    ]
    for urls in invalidLists {
        let pasteboard = writeCheckPasteboard()
        defer { pasteboard.releaseGlobally() }
        let before = WriteCheckSnapshot(pasteboard)
        let item = ClipboardItem(kind: .file, title: "Invalid file fixture", fileURLs: urls, contentHash: "invalid-files")
        check(!PasteboardWriter.write(item, blobDirectory: directory, to: pasteboard),
              "invalid file lists must fail as a whole, including mixed valid and invalid entries")
        check(WriteCheckSnapshot(pasteboard) == before,
              "failed file preflight must preserve changeCount, all types, every item and every byte")
    }
}

func testPasteboardWriterNormalRoundTrips() {
    let directory = makeTemporaryDirectory()
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pasteboard = writeCheckPasteboard()
    defer { pasteboard.releaseGlobally() }
    let text = "Full text 👨‍👩‍👧‍👦 e\u{301}\r\n第二行"
    let textItem = ClipboardItem(kind: .text, title: "Text", text: text, contentHash: "text")
    check(PasteboardWriter.write(textItem, blobDirectory: directory, to: pasteboard), "valid text must write")
    check(pasteboard.string(forType: .string) == text, "text must round-trip without losing Unicode or line endings")

    let address = "https://example.com/path?q=hello%20world#part"
    let urlItem = ClipboardItem(kind: .url, title: address, text: address, contentHash: "url")
    check(PasteboardWriter.write(urlItem, blobDirectory: directory, to: pasteboard), "valid URL must write")
    check((NSURL(from: pasteboard) as URL?)?.absoluteString == address, "URL representation must remain usable by AppKit readers")
    check(pasteboard.string(forType: .string) == address, "URL must also expose its complete plain text once")

    let file = directory.appendingPathComponent("file.txt")
    let folder = directory.appendingPathComponent("folder", isDirectory: true)
    try! Data("file contents".utf8).write(to: file)
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let fileItem = ClipboardItem(kind: .file, title: "Files", fileURLs: [file.absoluteString, folder.absoluteString], contentHash: "files")
    check(PasteboardWriter.write(fileItem, blobDirectory: directory, to: pasteboard), "valid file and directory URLs must write")
    let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL]
    check(urls?.map { ($0 as URL).standardizedFileURL.path } == [file.path, folder.path],
          "all valid file URLs must preserve order and full paths")

    let imageURL = directory.appendingPathComponent("valid.png")
    try! writeCheckPNG().write(to: imageURL)
    let imageItem = ClipboardItem(kind: .image, title: "Image", blobFilename: "valid.png", contentHash: "image")
    check(PasteboardWriter.write(imageItem, blobDirectory: directory, to: pasteboard), "valid image must write")
    check(NSImage.canInit(with: pasteboard), "image publication must remain compatible with AppKit image readers")
    let image = NSImage(pasteboard: pasteboard)
    let bitmap = image?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
    check(bitmap?.pixelsWide == 4 && bitmap?.pixelsHigh == 3, "image publication must preserve full pixel dimensions")

    for (item, expected) in [(textItem, text), (urlItem, address), (fileItem, [file.path, folder.path].joined(separator: "\n"))] {
        check(PasteboardWriter.writePlainText(item, to: pasteboard), "plain text publication must support text, URL and file paths")
        check(pasteboard.string(forType: .string) == expected, "plain text publication must preserve the complete value")
    }
    let beforeUnsupported = WriteCheckSnapshot(pasteboard)
    check(!PasteboardWriter.writePlainText(imageItem, to: pasteboard), "an image must not claim to have a plain text representation")
    check(WriteCheckSnapshot(pasteboard) == beforeUnsupported, "unsupported plain text copy must preserve prior clipboard contents")
}
