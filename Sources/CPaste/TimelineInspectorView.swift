import AppKit
import CPasteCore
import SwiftUI

struct TimelineInspectorView: View {
    let item: ClipboardItem
    let imageURL: URL?
    let ageText: String
    let hasAccessibilityPermission: Bool
    var paste: () -> Void
    var pastePlainText: () -> Void
    var copy: () -> Void
    var togglePinned: () -> Void
    var open: () -> Void
    var openAccessibility: () -> Void
    var delete: () -> Void

    @Environment(\.cpasteThemeStyle) private var themeStyle

    var body: some View {
        HStack(spacing: 0) {
            metadata
                .frame(width: 230, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)

            Divider()
                .overlay(CPasteTheme.separator)

            contentPreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .overlay(CPasteTheme.separator)

            actions
                .frame(width: 136)
        }
        .background {
            if !usesLiquidGlassLayout {
                CPasteGlassBackground(
                    radius: 0,
                    material: .hudWindow,
                    tint: CPasteTheme.backgroundLift,
                    tintOpacity: 0.58,
                    stroke: Color.clear,
                    shadowOpacity: 0
                )
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var usesLiquidGlassLayout: Bool {
        if #available(macOS 26.0, *) {
            return themeStyle == .liquidGlass
        }
        return false
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SourceApplicationIcon(
                    name: item.sourceAppName,
                    bundleIdentifier: item.sourceBundleIdentifier,
                    size: 36
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.sourceAppName ?? CPasteL10n.text("未知来源", "Unknown source"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CPasteTheme.textPrimary)
                        .lineLimit(1)
                    Text(ageText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(CPasteTheme.textMuted)
                        .lineLimit(1)
                }
            }

            Text(ClipboardText.excerpt(item.title, limit: ClipboardText.cardLimit).text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CPasteTheme.textPrimary)
                .lineLimit(2)

            HStack(spacing: 6) {
                inspectorChip(item.kind.localizedDisplayName, color: CPasteTheme.kindColor(item.kind))
                if item.isPinned {
                    inspectorChip(CPasteL10n.text("已收藏", "Pinned"), color: CPasteTheme.amber)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func inspectorChip(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 21)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(color.opacity(0.26), lineWidth: 1)
            )
    }

    @ViewBuilder
    private var contentPreview: some View {
        switch item.kind {
        case .image:
            if let imageURL {
                TimelineThumbnailView(
                    imageURL: imageURL,
                    maxPixelSize: TimelineThumbnailCache.inspectorMaxPixelSize,
                    contentMode: .fit
                ) {
                    missingPreview
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(10)
            } else {
                missingPreview
            }
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(item.fileURLs, id: \.self) { value in
                        HStack(spacing: 8) {
                            Image(systemName: "doc")
                                .foregroundStyle(CPasteTheme.kindColor(.file))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(fileName(for: value))
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .lineLimit(1)
                                Text(filePath(for: value))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(CPasteTheme.textMuted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        case .text, .url:
            let excerpt = ClipboardText.excerpt(item.text, limit: ClipboardText.inspectorLimit)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if excerpt.isTruncated {
                        Text(CPasteL10n.text("长文本仅显示部分预览，复制和粘贴会使用完整内容。", "Showing a preview of this long text. Copy and Paste use the full content."))
                            .font(.system(size: 11))
                            .foregroundStyle(CPasteTheme.textSecondary)
                    }
                    Text(excerpt.text)
                        .font(.system(size: 11.5, design: item.kind == .url ? .monospaced : .default))
                        .foregroundStyle(CPasteTheme.textPrimary)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(12)
            }
        }
    }

    private var missingPreview: some View {
        VStack(spacing: 7) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 24))
            Text(CPasteL10n.text("预览不可用", "Preview unavailable"))
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(CPasteTheme.textMuted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actions: some View {
        LazyVGrid(columns: actionColumns, alignment: .leading, spacing: 7) {
            inspectorAction("doc.on.doc", label: CPasteL10n.text("复制", "Copy"), action: copy)
            inspectorAction("arrow.down.doc.fill", label: CPasteL10n.text("粘贴", "Paste"), prominent: true, action: paste)
            inspectorAction(
                item.isPinned ? "pin.slash" : "pin",
                label: item.isPinned ? CPasteL10n.text("取消收藏", "Unpin") : CPasteL10n.text("收藏", "Pin"),
                active: item.isPinned,
                action: togglePinned
            )
            if item.kind != .image {
                inspectorAction("textformat", label: CPasteL10n.text("纯文本粘贴", "Paste Plain Text"), action: pastePlainText)
            }
            if item.kind == .url || item.kind == .file {
                inspectorAction(
                    item.kind == .url ? "safari" : "folder",
                    label: item.kind == .url ? CPasteL10n.text("打开链接", "Open Link") : CPasteL10n.text("在访达中显示", "Show in Finder"),
                    action: open
                )
            }
            if !hasAccessibilityPermission {
                inspectorAction("lock.open", label: CPasteL10n.text("辅助功能权限", "Accessibility"), action: openAccessibility)
            }
            inspectorAction("trash", label: CPasteL10n.text("删除", "Delete"), destructive: true, action: delete)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var actionColumns: [GridItem] {
        Array(repeating: GridItem(.fixed(30), spacing: 7), count: 3)
    }

    private func inspectorAction(
        _ systemImage: String,
        label: String,
        active: Bool = false,
        prominent: Bool = false,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(CPasteIconButtonStyle(size: 30, isActive: active, isDestructive: destructive, isProminent: prominent))
        .help(label)
        .accessibilityLabel(label)
    }

    private func filePath(for value: String) -> String {
        URL(string: value)?.path ?? value
    }

    private func fileName(for value: String) -> String {
        let path = filePath(for: value)
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }
}
