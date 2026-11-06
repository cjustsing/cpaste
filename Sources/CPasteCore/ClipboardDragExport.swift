import AppKit
import Foundation

public enum ClipboardDragExport {
    public static func providers(for item: ClipboardItem, imageURL: URL?) -> [NSItemProvider] {
        switch item.kind {
        case .text:
            return [NSItemProvider(object: item.text as NSString)]
        case .url:
            if let url = URL(string: item.text) { return [NSItemProvider(object: url as NSURL)] }
            return [NSItemProvider(object: item.text as NSString)]
        case .file:
            guard let urls = fileURLs(for: item) else { return [] }
            return urls.map { NSItemProvider(contentsOf: $0) ?? NSItemProvider(object: $0 as NSURL) }
        case .image:
            guard let imageURL, let provider = NSItemProvider(contentsOf: imageURL) else { return [] }
            return [provider]
        }
    }

    public static func fileURLs(for item: ClipboardItem) -> [URL]? {
        guard item.kind == .file, !item.fileURLs.isEmpty else { return nil }
        var urls: [URL] = []
        for value in item.fileURLs {
            guard let url = URL(string: value), url.isFileURL,
                  FileManager.default.fileExists(atPath: url.path)
            else { return nil }
            urls.append(url)
        }
        return urls
    }

    public static func draggingItems(for item: ClipboardItem) -> [NSDraggingItem] {
        (fileURLs(for: item) ?? []).map { NSDraggingItem(pasteboardWriter: $0 as NSURL) }
    }
}
