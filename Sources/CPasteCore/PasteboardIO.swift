import AppKit
import Foundation
import UniformTypeIdentifiers

public enum PasteboardReader {
    private static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    private static let fileIconType = NSPasteboard.PasteboardType("com.apple.icns")

    public static func read(
        from pasteboard: NSPasteboard = .general,
        sourceBundleIdentifier: String? = nil
    ) -> CapturedClipboardContent? {
        guard !ClipboardPrivacy.shouldIgnore(pasteboard) else {
            return nil
        }

        if hasPDFRepresentation(in: pasteboard),
           let fileContent = readFiles(from: pasteboard) {
            return fileContent
        }

        if hasDirectImageRepresentation(in: pasteboard),
           let imageContent = readImage(from: pasteboard) {
            return imageContent
        }

        if let fileContent = readFiles(from: pasteboard) {
            if let imageContent = readSingleImageFile(
                from: fileContent,
                sourceBundleIdentifier: sourceBundleIdentifier
            ) {
                return imageContent
            }
            return fileContent
        }

        if let pdfContent = readPDF(from: pasteboard) {
            return pdfContent
        }

        if let imageContent = readImage(from: pasteboard) {
            return imageContent
        }

        if let urlContent = readURL(from: pasteboard) {
            return urlContent
        }

        return readText(from: pasteboard)
    }

    private static func hasDirectImageRepresentation(in pasteboard: NSPasteboard) -> Bool {
        guard let declaredTypes = pasteboard.pasteboardItems?.flatMap(\.types) else {
            return false
        }

        return declaredTypes.contains { pasteboardType in
            guard pasteboardType != fileIconType,
                  let contentType = UTType(pasteboardType.rawValue)
            else {
                return false
            }
            return contentType.conforms(to: .image) && !contentType.conforms(to: .pdf)
        }
    }

    private static func hasPDFRepresentation(in pasteboard: NSPasteboard) -> Bool {
        (pasteboard.types ?? []).contains { pasteboardType in
            pasteboardType == .pdf || UTType(pasteboardType.rawValue)?.conforms(to: .pdf) == true
        }
    }

    private static func readFiles(from pasteboard: NSPasteboard) -> CapturedClipboardContent? {
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String], !paths.isEmpty {
            return contentForFilePaths(paths)
        }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL], !objects.isEmpty {
            let urls = objects.map { $0 as URL }
            return contentForFilePaths(urls.map(\.path))
        }

        return nil
    }

    private static func contentForFilePaths(_ paths: [String]) -> CapturedClipboardContent {
        let urls = paths.map { URL(fileURLWithPath: $0).absoluteString }
        let first = paths.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Files"
        let title = paths.count == 1 ? first : "\(first) + \(paths.count - 1)"
        let subtitle = paths.count == 1 ? "1 file" : "\(paths.count) files"

        return CapturedClipboardContent(
            kind: .file,
            title: title,
            subtitle: subtitle,
            text: paths.joined(separator: "\n"),
            fileURLs: urls,
            contentHash: ContentHasher.hash(strings: urls)
        )
    }

    private static func readImage(from pasteboard: NSPasteboard) -> CapturedClipboardContent? {
        guard let image = NSImage(pasteboard: pasteboard),
              let content = contentForImage(image) else {
            return nil
        }
        return content
    }

    private static func readPDF(from pasteboard: NSPasteboard) -> CapturedClipboardContent? {
        guard let pdfData = pasteboard.data(forType: .pdf), !pdfData.isEmpty else {
            return nil
        }

        let contentHash = ContentHasher.hash(data: pdfData)
        let fileName = "Clipboard-\(contentHash.prefix(12)).pdf"
        return CapturedClipboardContent(
            kind: .file,
            title: fileName,
            subtitle: "1 file",
            fileData: pdfData,
            fileName: fileName,
            contentHash: contentHash
        )
    }

    private static func readSingleImageFile(
        from fileContent: CapturedClipboardContent,
        sourceBundleIdentifier: String?
    ) -> CapturedClipboardContent? {
        guard sourceBundleIdentifier != nil,
              sourceBundleIdentifier != "com.apple.finder",
              fileContent.fileURLs.count == 1,
              let value = fileContent.fileURLs.first,
              let url = URL(string: value),
              url.isFileURL,
              let contentType = UTType(filenameExtension: url.pathExtension),
              contentType.conforms(to: .image),
              !contentType.conforms(to: .pdf),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }

        return contentForImage(image)
    }

    private static func contentForImage(_ image: NSImage) -> CapturedClipboardContent? {
        guard let pngData = image.pngData() else {
            return nil
        }
        let size = image.pixelSizeDescription
        return CapturedClipboardContent(
            kind: .image,
            title: "Image",
            subtitle: size,
            imagePNGData: pngData,
            contentHash: ContentHasher.hash(data: pngData)
        )
    }

    private static func readURL(from pasteboard: NSPasteboard) -> CapturedClipboardContent? {
        if pasteboard.types?.contains(.URL) == true,
           let url = NSURL(from: pasteboard) as URL? {
            return urlContent(url.absoluteString)
        }

        if let string = pasteboard.string(forType: .string),
           string.utf8.count <= 8_192,
           let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme != nil,
           url.host != nil {
            return urlContent(url.absoluteString)
        }

        return nil
    }

    private static func urlContent(_ value: String) -> CapturedClipboardContent {
        CapturedClipboardContent(
            kind: .url,
            title: value,
            subtitle: "URL",
            text: value,
            contentHash: ContentHasher.hash(string: "url:\(value)")
        )
    }

    private static func readText(from pasteboard: NSPasteboard) -> CapturedClipboardContent? {
        guard let string = pasteboard.string(forType: .string) else {
            return nil
        }

        let title = ClipboardText.title(for: string)
        guard !title.isEmpty else {
            return nil
        }

        let subtitle = ClipboardText.summary(for: string)

        return CapturedClipboardContent(
            kind: .text,
            title: title,
            subtitle: subtitle,
            text: string,
            contentHash: ContentHasher.hash(string: "text:\(string)")
        )
    }
}

public enum PasteboardWriter {
    public static func write(_ item: ClipboardItem, blobDirectory: URL, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()

        switch item.kind {
        case .text:
            pasteboard.setString(item.text, forType: .string)
            return true
        case .url:
            pasteboard.setString(item.text, forType: .string)
            if let url = URL(string: item.text) {
                pasteboard.writeObjects([url as NSURL])
            }
            return true
        case .file:
            let urls = item.fileURLs.compactMap(URL.init(string:))
            guard !urls.isEmpty else {
                return false
            }
            pasteboard.writeObjects(urls.map { $0 as NSURL })
            return true
        case .image:
            guard let filename = item.blobFilename else {
                return false
            }
            let url = blobDirectory.appendingPathComponent(filename, isDirectory: false)
            guard let image = NSImage(contentsOf: url) else {
                return false
            }
            pasteboard.writeObjects([image])
            return true
        }
    }

    public static func writePlainText(_ item: ClipboardItem, to pasteboard: NSPasteboard = .general) -> Bool {
        let value: String

        switch item.kind {
        case .text, .url:
            value = item.text
        case .file:
            value = item.fileURLs
                .compactMap(URL.init(string:))
                .map(\.path)
                .joined(separator: "\n")
        case .image:
            return false
        }

        guard !value.isEmpty else {
            return false
        }

        pasteboard.clearContents()
        return pasteboard.setString(value, forType: .string)
    }
}

private extension NSImage {
    func pngData() -> Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    var pixelSizeDescription: String {
        guard let representation = representations.first else {
            return "\(Int(size.width)) x \(Int(size.height))"
        }
        return "\(representation.pixelsWide) x \(representation.pixelsHigh)"
    }
}
