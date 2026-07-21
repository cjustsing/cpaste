import CPasteCore
import Foundation

enum CPasteL10n {
    static var usesChinese: Bool {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
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
            let lineCount = text.components(separatedBy: .newlines).count
            if lineCount > 1 {
                return CPasteL10n.text("\(lineCount) 行", "\(lineCount) lines")
            }
            return CPasteL10n.text("\(text.count) 个字符", "\(text.count) characters")
        case .url:
            return CPasteL10n.text("链接", "URL")
        case .file:
            return CPasteL10n.text("\(fileURLs.count) 个文件", fileURLs.count == 1 ? "1 file" : "\(fileURLs.count) files")
        case .image:
            return subtitle.isEmpty ? CPasteL10n.text("图片", "Image") : subtitle
        }
    }
}
