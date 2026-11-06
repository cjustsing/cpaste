import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PasteboardReader {
    private static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    private static let fileIconType = NSPasteboard.PasteboardType("com.apple.icns")

    public static func read(
        from pasteboard: NSPasteboard = .general,
        sourceBundleIdentifier: String? = nil
    ) -> CapturedClipboardContent? {
        dispatchPrecondition(condition: .onQueue(.main))
        let generation = pasteboard.changeCount
        var excludedImages = Set<String>()
        while excludedImages.count < 32 {
            guard pasteboard.changeCount == generation,
                  case let .snapshot(snapshot) = snapshotResult(
                    from: pasteboard,
                    sourceBundleIdentifier: sourceBundleIdentifier,
                    excludingImageTypes: excludedImages
                  ),
                  pasteboard.changeCount == generation
            else { return nil }
            if let content = decode(snapshot) { return content }
            guard let type = snapshot.imageType, excludedImages.insert(type).inserted else { return nil }
        }
        return nil
    }

    /// Pasteboard IPC stays on the calling (normally main) thread. This only
    /// copies representations; it does not decode, transcode, hash or read files.
    public static func snapshot(
        from pasteboard: NSPasteboard = .general,
        sourceBundleIdentifier: String? = nil
    ) -> ClipboardSnapshot? {
        dispatchPrecondition(condition: .onQueue(.main))
        let generation = pasteboard.changeCount
        guard case let .snapshot(value) = snapshotResult(from: pasteboard, sourceBundleIdentifier: sourceBundleIdentifier),
              pasteboard.changeCount == generation
        else { return nil }
        return value
    }

    static func snapshotResult(
        from pasteboard: NSPasteboard,
        sourceBundleIdentifier: String?,
        excludingImageTypes: Set<String> = []
    ) -> ClipboardSnapshotResult {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !ClipboardPrivacy.shouldIgnore(pasteboard) else { return .ignored }
        let declared = pasteboard.pasteboardItems?.flatMap(\.types) ?? pasteboard.types ?? []
        var unique = Set<String>()
        let types = declared.filter { unique.insert($0.rawValue).inserted }
        let hasPDF = types.contains { $0 == .pdf || UTType($0.rawValue)?.conforms(to: .pdf) == true }
        if hasPDF, let paths = readFilePaths(from: pasteboard) {
            return .snapshot(ClipboardSnapshot(payload: .files(paths, sourceBundleIdentifier: nil)))
        }
        let supportedImageTypes = Set(NSImage.imageTypes)
        let imageTypes = types.filter { type in
            guard !excludingImageTypes.contains(type.rawValue),
                  UTType(type.rawValue)?.conforms(to: .pdf) != true
            else { return false }
            return UTType(type.rawValue)?.conforms(to: .image) == true || supportedImageTypes.contains(type.rawValue)
        }
        let orderedImages = imageTypes.filter { $0 == .png } + imageTypes.filter { $0 != .png }
        var unavailable = false
        func imageSnapshot(includeIcons: Bool) -> ClipboardSnapshot? {
            for type in orderedImages where includeIcons || type != fileIconType {
                if let data = pasteboard.data(forType: type), !data.isEmpty {
                    return ClipboardSnapshot(payload: .image(data, type: type.rawValue))
                }
                unavailable = true
            }
            return nil
        }
        if let image = imageSnapshot(includeIcons: false) { return .snapshot(image) }
        if let paths = readFilePaths(from: pasteboard) {
            return .snapshot(ClipboardSnapshot(payload: .files(paths, sourceBundleIdentifier: sourceBundleIdentifier)))
        }
        if hasPDF {
            if let data = pasteboard.data(forType: .pdf), !data.isEmpty {
                return .snapshot(ClipboardSnapshot(payload: .pdf(data)))
            }
            unavailable = true
        }
        if let image = imageSnapshot(includeIcons: true) { return .snapshot(image) }
        if types.contains(.URL) {
            if let string = pasteboard.string(forType: .URL) {
                return .snapshot(ClipboardSnapshot(payload: .url(string)))
            }
            unavailable = true
        }
        if let string = pasteboard.string(forType: .string) {
            return .snapshot(ClipboardSnapshot(payload: .text(string)))
        }
        if types.contains(.string) { unavailable = true }
        return unavailable ? .unavailable : .ignored
    }

    public static func decode(_ snapshot: ClipboardSnapshot) -> CapturedClipboardContent? {
        autoreleasepool {
            switch snapshot.payload {
            case let .files(paths, sourceBundleIdentifier):
                let files = contentForFilePaths(paths)
                return readSingleImageFile(from: files, sourceBundleIdentifier: sourceBundleIdentifier) ?? files
            case let .image(data, _):
                if let png = contentForPNG(data) { return png }
                guard let image = NSImage(data: data) else { return nil }
                return contentForImage(image)
            case let .pdf(data):
                return contentForPDF(data)
            case let .url(string):
                guard let url = URL(string: string), url.scheme != nil else { return contentForText(string) }
                return urlContent(url.absoluteString)
            case let .text(string):
                if string.utf8.count <= 8_192,
                   let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
                   url.scheme != nil, url.host != nil {
                    return urlContent(url.absoluteString)
                }
                return contentForText(string)
            }
        }
    }

    private static func readFilePaths(from pasteboard: NSPasteboard) -> [String]? {
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String], !paths.isEmpty {
            return paths
        }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL], !objects.isEmpty {
            let urls = objects.map { $0 as URL }
            return urls.map(\.path)
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

    private static func contentForPDF(_ pdfData: Data) -> CapturedClipboardContent {
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
              !contentType.conforms(to: .pdf)
        else {
            return nil
        }

        if contentType.conforms(to: .png), let data = try? Data(contentsOf: url), let png = contentForPNG(data) { return png }
        guard let image = NSImage(contentsOf: url) else { return nil }
        return contentForImage(image)
    }

    private static func contentForPNG(_ data: Data) -> CapturedClipboardContent? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              (CGImageSourceGetType(source) as String?) == UTType.png.identifier,
              CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              image.width > 0, image.height > 0
        else { return nil }
        return CapturedClipboardContent(
            kind: .image, title: "Image", subtitle: "\(image.width) x \(image.height)",
            imagePNGData: data, contentHash: ContentHasher.hash(data: data)
        )
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

    private static func urlContent(_ value: String) -> CapturedClipboardContent {
        CapturedClipboardContent(
            kind: .url,
            title: value,
            subtitle: "URL",
            text: value,
            contentHash: ContentHasher.hash(string: "url:\(value)")
        )
    }

    private static func contentForText(_ string: String) -> CapturedClipboardContent? {
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
        guard let objects = preparedObjects(for: item, blobDirectory: blobDirectory) else {
            return false
        }

        // Validate every representation before taking ownership. A failed
        // preflight must leave the previous clipboard untouched. AppKit's
        // publication itself is not transactional; return its actual result.
        pasteboard.clearContents()
        return pasteboard.writeObjects(objects)
    }

    private static func preparedObjects(for item: ClipboardItem, blobDirectory: URL) -> [NSPasteboardWriting]? {
        switch item.kind {
        case .text:
            return [item.text as NSString]
        case .url:
            guard let url = URL(string: item.text), url.scheme != nil else { return nil }
            let object = NSPasteboardItem()
            guard object.setString(item.text, forType: .string),
                  object.setString(url.absoluteString, forType: .URL)
            else { return nil }
            return [object]
        case .file:
            guard let urls = localFileURLs(item.fileURLs, requireExistingFiles: true) else { return nil }
            return urls.map { $0 as NSURL }
        case .image:
            guard let filename = item.blobFilename,
                  !filename.isEmpty, filename != ".", filename != "..",
                  !filename.contains("/"), !filename.contains("\\"), !filename.contains("\0"),
                  URL(fileURLWithPath: filename).lastPathComponent == filename
            else { return nil }
            let url = blobDirectory.appendingPathComponent(filename, isDirectory: false)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  FileManager.default.isReadableFile(atPath: url.path),
                  let image = NSImage(contentsOf: url), image.isValid
            else { return nil }
            // Keep NSImage's existing AppKit pasteboard representations for
            // compatibility with destinations that request formats besides PNG.
            return [image]
        }
    }

    private static func localFileURLs(_ values: [String], requireExistingFiles: Bool) -> [URL]? {
        guard !values.isEmpty else { return nil }
        var urls: [URL] = []
        for value in values {
            guard let url = URL(string: value), url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"),
                  url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
                  url.query == nil, url.fragment == nil
            else { return nil }
            if requireExistingFiles, !FileManager.default.fileExists(atPath: url.path) { return nil }
            urls.append(url)
        }
        return urls
    }

    public static func writePlainText(_ item: ClipboardItem, to pasteboard: NSPasteboard = .general) -> Bool {
        let value: String

        switch item.kind {
        case .text, .url:
            value = item.text
        case .file:
            // Copying a path as text does not require its original file to
            // remain on disk, but malformed/mixed URL lists must not silently
            // turn into a partial selection.
            guard let urls = localFileURLs(item.fileURLs, requireExistingFiles: false) else { return false }
            value = urls.map(\.path).joined(separator: "\n")
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
