import CPasteCore
import Foundation

enum CPasteL10n {
    static var language = AppEnvironment.language

    static var usesChinese: Bool {
        language.usesChinese(preferredLanguages: Locale.preferredLanguages)
    }

    static var locale: Locale {
        Locale(identifier: usesChinese ? "zh-Hans" : "en")
    }

    static func text(_ chinese: String, _ english: String) -> String {
        usesChinese ? chinese : english
    }
}

extension ClipboardKind {
    var localizedDisplayName: String {
        switch self {
        case .text:
            return CPasteL10n.text("文本", "Text")
        case .url:
            return CPasteL10n.text("链接", "Links")
        case .file:
            return CPasteL10n.text("文件", "Files")
        case .image:
            return CPasteL10n.text("图片", "Images")
        }
    }
}

extension ClipboardItem {
    var localizedSubtitle: String {
        switch kind {
        case .text:
            let summary = subtitle.isEmpty ? ClipboardText.summary(for: text) : subtitle
            let parts = summary.split(separator: " ")
            if parts.count == 2, let count = Int(parts[0]) {
                switch parts[1] {
                case "lines":
                    return CPasteL10n.text("\(count) 行", "\(count) lines")
                case "characters":
                    return CPasteL10n.text("\(count) 个字符", count == 1 ? "1 character" : "\(count) characters")
                case "bytes":
                    return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
                default: break
                }
            }
            return summary
        case .url:
            return CPasteL10n.text("链接", "URL")
        case .file:
            return CPasteL10n.text("\(fileURLs.count) 个文件", fileURLs.count == 1 ? "1 file" : "\(fileURLs.count) files")
        case .image:
            return subtitle.isEmpty ? CPasteL10n.text("图片", "Image") : subtitle
        }
    }
}
