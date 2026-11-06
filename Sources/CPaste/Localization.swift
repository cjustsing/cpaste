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

extension ClipboardStorageIssue {
    var localizedMessage: String {
        switch self {
        case .recoveredFromBackup:
            return CPasteL10n.text("历史已从备份恢复", "History recovered from backup")
        case .damagedHistoryPreserved:
            return CPasteL10n.text("历史文件异常，原件已保留", "Damaged history preserved for recovery")
        case .readOnly:
            return CPasteL10n.text("历史存储不可用，已停止覆盖写入", "Storage unavailable; replacement writes blocked")
        case .saveFailed:
            return CPasteL10n.text("有内容尚未保存，请重试保存", "Some content is unsaved; retry saving")
        case .historyConflict:
            return CPasteL10n.text("磁盘历史有更新，本地已保留恢复副本", "History changed on disk; local recovery copy saved")
        case .recoveryCopyFailed:
            return CPasteL10n.text("恢复副本保存失败，记录仍在内存中", "Recovery copy failed; unsaved records remain in memory")
        }
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
