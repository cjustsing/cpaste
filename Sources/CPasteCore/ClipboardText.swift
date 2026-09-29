import Foundation

/// Display-only excerpts. The stored text remains the source for search and paste.
public enum ClipboardText {
    public static let cardLimit = 2_048
    public static let inspectorLimit = 16_384

    public struct Excerpt {
        public let text: String
        public let isTruncated: Bool
    }

    public static func excerpt<S: StringProtocol>(_ text: S, limit: Int) -> Excerpt {
        let scalars = text.unicodeScalars
        let end = scalars.index(scalars.startIndex, offsetBy: max(0, limit), limitedBy: scalars.endIndex)
            ?? scalars.endIndex
        return Excerpt(text: String(text[..<end]), isTruncated: end != scalars.endIndex)
    }

    public static func title(for text: String) -> String {
        guard let start = text.unicodeScalars.firstIndex(where: {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }) else { return "" }

        let preview = excerpt(text[start...], limit: 512)
        let flattened = preview.text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let prefix = String(flattened.prefix(90))
        return prefix + (preview.isTruncated || flattened.count > 90 ? "..." : "")
    }

    public static func summary(for text: String) -> String {
        // Avoid splitting or counting every character of a multi-megabyte item.
        let bytes = text.utf8.count
        if bytes > 65_536 { return "\(bytes) bytes" }
        let lines = text.components(separatedBy: .newlines).count
        return lines > 1 ? "\(lines) lines" : "\(text.count) characters"
    }
}
