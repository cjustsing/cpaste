import AppKit
import CPasteCore
import SwiftUI

struct TimelineCardView: View, Equatable {
    private enum Metrics {
        static let headerHeight: CGFloat = 48
        static let footerHeight: CGFloat = 34
    }

    let item: ClipboardItem
    let position: Int
    let isSelected: Bool
    let size: CGSize
    let imageURL: URL?
    let ageText: String
    var select: () -> Void
    var paste: () -> Void
    var pastePlainText: () -> Void
    var copy: () -> Void
    var togglePinned: () -> Void
    var open: () -> Void
    var delete: () -> Void

    @State private var isHovering = false
    @Environment(\.cpasteThemeStyle) private var themeStyle

    static func == (lhs: TimelineCardView, rhs: TimelineCardView) -> Bool {
        lhs.item == rhs.item
            && lhs.position == rhs.position
            && lhs.isSelected == rhs.isSelected
            && lhs.size == rhs.size
            && lhs.imageURL == rhs.imageURL
            && lhs.ageText == rhs.ageText
    }

    private var accent: Color {
        CPasteTheme.kindColor(item.kind)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            preview
                .frame(width: size.width, height: previewHeight)
                .clipped()
            footer
        }
        .frame(width: size.width, height: size.height)
        .background(cardBackground)
        .clipShape(cardShape)
        .overlay(cardShape.stroke(borderColor, lineWidth: isSelected ? 2 : 1))
        .overlay(alignment: .bottom) {
            if isHovering {
                hoverActions
                    .padding(.bottom, 38)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .shadow(
            color: cardShadowColor,
            radius: isSelected ? (usesLiquidGlassLayout ? 26 : 22) : 10,
            x: 0,
            y: isSelected ? 12 : 6
        )
        .contentShape(cardShape)
        .onTapGesture(count: 2, perform: paste)
        // Keep selection independent from double-click recognition so the first
        // click updates immediately instead of waiting for the double-click timeout.
        .simultaneousGesture(
            TapGesture(count: 1)
                .onEnded(select)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
        .onDrag { dragProvider() }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction(.default, select)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: usesLiquidGlassLayout ? 16 : 9, style: .continuous)
    }

    private var previewHeight: CGFloat {
        max(0, size.height - Metrics.headerHeight - Metrics.footerHeight)
    }

    @ViewBuilder
    private var cardBackground: some View {
        if usesLiquidGlassLayout {
            ZStack {
                VisualEffectView(material: .contentBackground, blendingMode: .withinWindow)
                CPasteTheme.surface.opacity(0.58)
                LinearGradient(
                    colors: [Color.white.opacity(0.09), Color.clear],
                    startPoint: .top,
                    endPoint: .center
                )
            }
        } else {
            ZStack {
                VisualEffectView(material: .contentBackground, blendingMode: .withinWindow)
                CPasteTheme.surface.opacity(0.90)
            }
        }
    }

    private var borderColor: Color {
        if isSelected {
            return CPasteTheme.accent
        }
        if isHovering {
            return accent.opacity(0.52)
        }
        return usesLiquidGlassLayout ? Color.white.opacity(0.18) : CPasteTheme.separator
    }

    private var cardShadowColor: Color {
        if usesLiquidGlassLayout, isSelected {
            return accent.opacity(0.30)
        }
        return Color.black.opacity(isSelected ? 0.28 : 0.14)
    }

    private var header: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.kind.localizedDisplayName)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                Text(ageText)
                    .font(.system(size: 10, weight: .medium))
                    .opacity(0.78)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .bold))
                    .accessibilityLabel(CPasteL10n.text("已收藏", "Pinned"))
            }

            SourceApplicationIcon(
                name: item.sourceAppName,
                bundleIdentifier: item.sourceBundleIdentifier,
                size: 28
            )
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 11)
        .frame(height: Metrics.headerHeight)
        .background {
            if usesLiquidGlassLayout {
                LinearGradient(
                    colors: [accent.opacity(0.96), accent.opacity(0.68)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                accent
            }
        }
        .overlay(alignment: .top) {
            if usesLiquidGlassLayout {
                Rectangle()
                    .fill(Color.white.opacity(0.24))
                    .frame(height: 1)
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .image:
            imagePreview
        case .file:
            filePreview
        case .url:
            urlPreview
        case .text:
            textPreview
        }
    }

    private var textPreview: some View {
        Text(ClipboardText.excerpt(item.text.isEmpty ? item.title : item.text, limit: ClipboardText.cardLimit).text)
            .font(.system(size: 12.5))
            .foregroundStyle(CPasteTheme.textPrimary)
            .lineSpacing(3)
            .lineLimit(11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .background(CPasteTheme.previewSurface.opacity(previewSurfaceOpacity))
    }

    private var urlPreview: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "link")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                Text(urlHost)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CPasteTheme.textPrimary)
                    .lineLimit(1)
            }

            Text(ClipboardText.excerpt(item.text, limit: ClipboardText.cardLimit).text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(CPasteTheme.textSecondary)
                .lineSpacing(2)
                .lineLimit(9)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(CPasteTheme.previewSurface.opacity(previewSurfaceOpacity))
    }

    private var filePreview: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(item.fileURLs.prefix(4).enumerated()), id: \.offset) { _, value in
                HStack(spacing: 8) {
                    Image(systemName: "doc")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 18)
                    Text(fileName(for: value))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CPasteTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if item.fileURLs.count > 4 {
                Text(CPasteL10n.text("另有 \(item.fileURLs.count - 4) 个文件", "\(item.fileURLs.count - 4) more files"))
                    .font(.system(size: 11))
                    .foregroundStyle(CPasteTheme.textMuted)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(CPasteTheme.previewSurface.opacity(previewSurfaceOpacity))
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let imageURL {
            TimelineThumbnailView(
                imageURL: imageURL,
                maxPixelSize: TimelineThumbnailCache.cardMaxPixelSize,
                contentMode: .fit
            ) {
                missingImagePreview
            }
                .frame(width: size.width, height: previewHeight)
                .clipped()
                .background(CPasteTheme.previewSurface.opacity(usesLiquidGlassLayout ? 0.70 : 1))
        } else {
            missingImagePreview
        }
    }

    private var missingImagePreview: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 28))
            Text(CPasteL10n.text("预览不可用", "Preview unavailable"))
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(CPasteTheme.textMuted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CPasteTheme.previewSurface.opacity(previewSurfaceOpacity))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(position)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(position <= 9 ? CPasteTheme.textPrimary : CPasteTheme.textMuted)
                .frame(minWidth: 20, minHeight: 20)
                .background(
                    Circle()
                        .fill(position <= 9 ? accent.opacity(0.18) : Color.clear)
                )

            Text(item.sourceAppName ?? CPasteL10n.text("未知来源", "Unknown source"))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(CPasteTheme.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(item.localizedSubtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(CPasteTheme.textMuted)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: Metrics.footerHeight)
        .background(CPasteTheme.surface.opacity(usesLiquidGlassLayout ? 0.64 : 1))
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            compactAction("doc.on.doc", label: CPasteL10n.text("复制", "Copy"), action: copy)
            compactAction(
                item.isPinned ? "pin.slash" : "pin",
                label: item.isPinned ? CPasteL10n.text("取消收藏", "Unpin") : CPasteL10n.text("收藏", "Pin"),
                action: togglePinned
            )
            compactAction("trash", label: CPasteL10n.text("删除", "Delete"), isDestructive: true, action: delete)
        }
        .padding(4)
        .cpasteGlass(
            radius: usesLiquidGlassLayout ? 15 : 8,
            material: .menu,
            tint: CPasteTheme.background,
            tintOpacity: 0.76,
            shadowOpacity: 0.18,
            isInteractive: true
        )
    }

    private var previewSurfaceOpacity: Double {
        usesLiquidGlassLayout ? 0.54 : 0.72
    }

    private var usesLiquidGlassLayout: Bool {
        if #available(macOS 26.0, *) {
            return themeStyle == .liquidGlass
        }
        return false
    }

    private func compactAction(
        _ systemImage: String,
        label: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isDestructive ? CPasteTheme.rose : CPasteTheme.textPrimary)
                .frame(width: 27, height: 25)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button(CPasteL10n.text("粘贴", "Paste"), action: paste)
        if item.kind != .image {
            Button(CPasteL10n.text("粘贴为纯文本", "Paste as Plain Text"), action: pastePlainText)
        }
        Button(CPasteL10n.text("复制", "Copy"), action: copy)

        if item.kind == .url || item.kind == .file {
            Divider()
            Button(item.kind == .url ? CPasteL10n.text("打开链接", "Open Link") : CPasteL10n.text("在访达中显示", "Show in Finder"), action: open)
        }

        Divider()
        Button(
            item.isPinned ? CPasteL10n.text("取消收藏", "Unpin") : CPasteL10n.text("收藏", "Pin"),
            action: togglePinned
        )
        Divider()
        Button(CPasteL10n.text("删除", "Delete"), role: .destructive, action: delete)
    }

    private var urlHost: String {
        URL(string: ClipboardText.excerpt(item.text, limit: ClipboardText.cardLimit).text)?.host
            ?? CPasteL10n.text("链接", "Link")
    }

    private func fileName(for value: String) -> String {
        let path = URL(string: value)?.path ?? value
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func dragProvider() -> NSItemProvider {
        switch item.kind {
        case .text:
            return NSItemProvider(object: item.text as NSString)
        case .url:
            if let url = URL(string: item.text) {
                return NSItemProvider(object: url as NSURL)
            }
            return NSItemProvider(object: item.text as NSString)
        case .file:
            if let first = item.fileURLs.first.flatMap(URL.init(string:)),
               let provider = NSItemProvider(contentsOf: first) {
                return provider
            }
            return NSItemProvider(object: item.text as NSString)
        case .image:
            if let imageURL,
               let provider = NSItemProvider(contentsOf: imageURL) {
                return provider
            }
            return NSItemProvider(object: item.title as NSString)
        }
    }

    private var accessibilityLabel: String {
        [
            item.kind.localizedDisplayName,
            item.title,
            item.sourceAppName,
            ageText
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

struct SourceApplicationIcon: View {
    let name: String?
    let bundleIdentifier: String?
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let icon = SourceApplicationIconCache.shared.icon(bundleIdentifier: bundleIdentifier) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .fill(Color.black.opacity(0.20))
                    Text(initials)
                        .font(.system(size: max(8, size * 0.34), weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.94))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityLabel(name ?? CPasteL10n.text("来源应用", "Source application"))
    }

    private var initials: String {
        let words = (name ?? "App")
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        let value = words.prefix(2).compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "A" : value.uppercased()
    }
}

private final class SourceApplicationIconCache {
    static let shared = SourceApplicationIconCache()

    private let cache = NSCache<NSString, NSImage>()

    func icon(bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return nil
        }

        let key = bundleIdentifier as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        guard let applicationURL = applicationURL(for: bundleIdentifier) else {
            return nil
        }

        let workspaceIcon = iconImage(for: applicationURL) ?? NSWorkspace.shared.icon(forFile: applicationURL.path)
        let size = NSSize(width: 64, height: 64)
        let rasterizedIcon = NSImage(size: size)
        rasterizedIcon.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        workspaceIcon.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: workspaceIcon.size),
            operation: .sourceOver,
            fraction: 1
        )
        rasterizedIcon.unlockFocus()
        rasterizedIcon.isTemplate = false
        cache.setObject(rasterizedIcon, forKey: key)
        return rasterizedIcon
    }

    private func applicationURL(for bundleIdentifier: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }

        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]

        for root in roots {
            guard let children = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            if let match = children.first(where: { url in
                url.pathExtension == "app" && Bundle(url: url)?.bundleIdentifier == bundleIdentifier
            }) {
                return match
            }
        }

        return nil
    }

    private func iconImage(for applicationURL: URL) -> NSImage? {
        guard let bundle = Bundle(url: applicationURL),
              let resourcesURL = bundle.resourceURL,
              let rawName = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              !rawName.isEmpty
        else {
            return nil
        }

        let filename = (rawName as NSString).pathExtension.isEmpty ? "\(rawName).icns" : rawName
        return NSImage(contentsOf: resourcesURL.appendingPathComponent(filename, isDirectory: false))
    }
}
