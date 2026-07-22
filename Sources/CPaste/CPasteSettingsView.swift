import AppKit
import CPasteCore
import SwiftUI

struct CPasteSettingsView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var appState: AppState
    let actions: HistoryPanelActions

    @Environment(\.dismiss) private var dismiss
    @State private var section: SettingsSection
    @State private var hasAccessibilityPermission = false
    @State private var isConfirmingClear = false
    @State private var presentationState: SettingsPresentationState

    init(
        store: ClipboardStore,
        appState: AppState,
        actions: HistoryPanelActions,
        initialSection: SettingsSection = .general,
        initialSupportPresented: Bool = false
    ) {
        self.store = store
        self.appState = appState
        self.actions = actions
        _section = State(initialValue: initialSection)
        _presentationState = State(initialValue: SettingsPresentationState(isSupportPresented: initialSupportPresented))
    }

    var body: some View {
        Group {
            if presentationState.isSupportPresented {
                CPasteSupportView {
                    requestClose()
                }
            } else {
                settingsContent
            }
        }
        .frame(width: 560, height: usesLiquidGlassLayout ? 420 : 390)
        .background {
            if usesLiquidGlassLayout {
                CPasteLiquidCanvas()
            } else {
                ZStack {
                    VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                    CPasteTheme.background.opacity(0.82)
                }
                .ignoresSafeArea()
            }
        }
        .onExitCommand {
            requestClose()
        }
        .onAppear {
            hasAccessibilityPermission = actions.hasAccessibilityPermission()
        }
        .onDisappear {
            presentationState.reset()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasAccessibilityPermission = actions.hasAccessibilityPermission()
        }
        .confirmationDialog(CPasteL10n.text("清空未收藏的历史记录？", "Clear unpinned history?"), isPresented: $isConfirmingClear) {
            Button(CPasteL10n.text("清空", "Clear"), role: .destructive) {
                actions.clearUnpinned()
            }
            Button(CPasteL10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(CPasteL10n.text("已收藏的内容会保留。", "Pinned items will stay in CPaste."))
        }
        .environment(\.cpasteThemeStyle, appState.themeStyle)
    }

    private var settingsContent: some View {
        VStack(spacing: 0) {
            header
            if !usesLiquidGlassLayout {
                Divider().overlay(CPasteTheme.separator)
            }

            Group {
                switch section {
                case .general:
                    generalSettings
                case .privacy:
                    privacySettings
                case .shortcuts:
                    shortcutSettings
                case .about:
                    aboutSettings
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var header: some View {
        let content = HStack(spacing: 12) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(CPasteTheme.accent)
                .frame(width: 30, height: 30)
                .cpasteGlass(radius: 7, tint: CPasteTheme.accentSoft, tintOpacity: 0.42, stroke: CPasteTheme.accent.opacity(0.34), shadowOpacity: 0.02)

            Text(CPasteL10n.text("设置", "Settings"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(CPasteTheme.textPrimary)
                .fixedSize(horizontal: true, vertical: false)

            Spacer()

            Picker("", selection: $section) {
                Label(CPasteL10n.text("通用", "General"), systemImage: "switch.2")
                    .tag(SettingsSection.general)
                Label(CPasteL10n.text("隐私", "Privacy"), systemImage: "hand.raised.fill")
                    .tag(SettingsSection.privacy)
                Label(CPasteL10n.text("快捷键", "Shortcuts"), systemImage: "keyboard")
                    .tag(SettingsSection.shortcuts)
                Label(CPasteL10n.text("关于", "About"), systemImage: "info.circle.fill")
                    .tag(SettingsSection.about)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)

            Button(action: requestClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(CPasteIconButtonStyle())
            .help(CPasteL10n.text("关闭", "Close"))
            .accessibilityLabel(CPasteL10n.text("关闭设置", "Close settings"))
        }

        if usesLiquidGlassLayout {
            CPasteGlassGroup(spacing: 10) {
                content
                    .padding(.horizontal, 16)
                    .frame(height: 58)
                    .cpasteGlass(radius: 20, shadowOpacity: 0.18)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
        } else {
            content
                .padding(.horizontal, 16)
                .frame(height: 58)
                .background {
                    CPasteGlassBackground(
                        radius: 0,
                        material: .headerView,
                        tint: CPasteTheme.backgroundLift,
                        tintOpacity: 0.54,
                        stroke: Color.clear,
                        shadowOpacity: 0.06
                    )
                }
        }
    }

    private var usesLiquidGlassLayout: Bool {
        if #available(macOS 26.0, *) {
            return appState.themeStyle == .liquidGlass
        }
        return false
    }

    private var generalSettings: some View {
        VStack(spacing: 0) {
            settingsRow(
                icon: appState.isCapturePaused ? "pause.circle.fill" : "record.circle",
                title: CPasteL10n.text("剪贴板捕获", "Clipboard Capture"),
                subtitle: appState.isCapturePaused ? CPasteL10n.text("已暂停", "Paused") : CPasteL10n.text("正在记录", "Recording"),
                minHeight: 52
            ) {
                Toggle("", isOn: captureBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel(CPasteL10n.text("剪贴板捕获", "Clipboard Capture"))
            }

            Divider().padding(.leading, 56)

            settingsRow(
                icon: "clock.arrow.circlepath",
                title: CPasteL10n.text("历史容量", "History Capacity"),
                subtitle: CPasteL10n.text("收藏内容不受容量限制", "Pinned items are always preserved"),
                minHeight: 52
            ) {
                Picker("", selection: historyLimitBinding) {
                    Text("50").tag(50)
                    Text("100").tag(100)
                    Text("500").tag(500)
                    Text("1000").tag(1_000)
                }
                .labelsHidden()
                .frame(width: 112)
            }

            Divider().padding(.leading, 56)

            settingsRow(
                icon: "paintpalette.fill",
                title: CPasteL10n.text("外观主题", "Appearance Theme"),
                subtitle: themeSubtitle,
                minHeight: 52
            ) {
                Picker("", selection: themeStyleBinding) {
                    ForEach(AppEnvironment.availableThemeStyles, id: \.self) { style in
                        Text(themeName(style)).tag(style)
                    }
                }
                .labelsHidden()
                .frame(width: 132)
                .accessibilityLabel(CPasteL10n.text("外观主题", "Appearance Theme"))
            }

            Divider().padding(.leading, 56)

            settingsRow(
                icon: "globe",
                title: CPasteL10n.text("界面语言", "Interface Language"),
                subtitle: languageSubtitle,
                minHeight: 52
            ) {
                Picker("", selection: languageBinding) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(languageName(language)).tag(language)
                    }
                }
                .labelsHidden()
                .frame(width: 132)
                .accessibilityLabel(CPasteL10n.text("界面语言", "Interface Language"))
            }

            Divider().padding(.leading, 56)

            settingsRow(
                icon: "keyboard",
                title: CPasteL10n.text("呼出快捷键", "Activation Shortcut"),
                subtitle: appState.isHotKeyRegistered ? CPasteL10n.text("全局快捷键可用", "Global shortcut is available") : CPasteL10n.text("快捷键已被其他应用占用", "Shortcut is used by another app"),
                minHeight: 52
            ) {
                Text("⇧⌘V")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(appState.isHotKeyRegistered ? CPasteTheme.textPrimary : CPasteTheme.rose)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .cpasteGlass(radius: 7, material: .menu, tintOpacity: 0.46, shadowOpacity: 0.02)
            }

            Divider().padding(.leading, 56)

            settingsRow(
                icon: hasAccessibilityPermission ? "checkmark.shield.fill" : "lock.open.fill",
                title: CPasteL10n.text("直接粘贴", "Direct Paste"),
                subtitle: hasAccessibilityPermission ? CPasteL10n.text("辅助功能权限已开启", "Accessibility access is enabled") : CPasteL10n.text("当前会复制到系统剪贴板", "Currently copies back to the clipboard"),
                minHeight: 52
            ) {
                if hasAccessibilityPermission {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(CPasteTheme.accent)
                        .font(.system(size: 17))
                        .accessibilityLabel(CPasteL10n.text("已授权", "Allowed"))
                } else {
                    Button(CPasteL10n.text("打开设置", "Open Settings")) {
                        actions.openAccessibility()
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    private var privacySettings: some View {
        VStack(spacing: 0) {
            settingsRow(
                icon: "externaldrive.fill.badge.checkmark",
                title: CPasteL10n.text("仅本地保存", "Stored Locally"),
                subtitle: CPasteL10n.text("无网络上传；历史文件未加密", "No network upload; history files are not encrypted")
            ) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(CPasteTheme.accent)
                    .font(.system(size: 17))
                    .accessibilityLabel(CPasteL10n.text("本地保存", "Stored locally"))
            }

            Divider().padding(.leading, 56)

            settingsRow(
                icon: "hand.raised.slash.fill",
                title: CPasteL10n.text("敏感内容保护", "Sensitive Content Protection"),
                subtitle: CPasteL10n.text("跳过密码管理器标记和临时剪贴板内容", "Ignores password-manager markers and transient content")
            ) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(CPasteTheme.accent)
                    .font(.system(size: 17))
                    .accessibilityLabel(CPasteL10n.text("已启用敏感内容保护", "Sensitive content protection enabled"))
            }

            Divider().padding(.leading, 56)

            VStack(alignment: .leading, spacing: 8) {
                Label(CPasteL10n.text("数据位置", "Data Location"), systemImage: "folder")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CPasteTheme.textPrimary)

                Text(store.storageDirectory.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(CPasteTheme.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(CPasteTheme.previewSurface.opacity(0.72), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(CPasteTheme.separator, lineWidth: 1)
                    )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)

            Divider().padding(.leading, 56)

            settingsRow(
                icon: "trash",
                title: CPasteL10n.text("清理历史", "Clear History"),
                subtitle: CPasteL10n.text("只删除未收藏的内容", "Only unpinned items are removed")
            ) {
                Button(CPasteL10n.text("清空", "Clear"), role: .destructive) {
                    isConfirmingClear = true
                }
                .controlSize(.small)
                .disabled(!store.items.contains(where: { !$0.isPinned }))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    private var shortcutSettings: some View {
        HStack(alignment: .top, spacing: 14) {
            shortcutGroup(
                title: CPasteL10n.text("浏览", "Navigation"),
                systemImage: "rectangle.and.hand.point.up.left",
                shortcuts: navigationShortcuts
            )

            Divider()
                .overlay(CPasteTheme.separator)
                .padding(.vertical, 2)

            shortcutGroup(
                title: CPasteL10n.text("操作", "Actions"),
                systemImage: "command",
                shortcuts: actionShortcuts
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var aboutSettings: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if let icon = NSApplication.shared.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 58, height: 58)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("CPaste")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(CPasteTheme.textPrimary)
                    Text(versionSummary)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(CPasteTheme.textSecondary)
                    Text(CPasteL10n.text(
                        "本地优先的 macOS 剪贴板历史工具",
                        "A local-first clipboard history app for macOS"
                    ))
                    .font(.system(size: 10.5))
                    .foregroundStyle(CPasteTheme.textMuted)
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 98)

            Divider().padding(.leading, 56)

            settingsRow(
                icon: "heart.fill",
                title: CPasteL10n.text("支持 CPaste", "Support CPaste"),
                subtitle: CPasteL10n.text("完全自愿，不影响任何功能", "Entirely optional; no features are affected")
            ) {
                Button(CPasteL10n.text("查看收款码", "View Codes")) {
                    presentationState.presentSupport()
                }
                .controlSize(.small)
            }

            Divider().padding(.leading, 56)

            settingsRowContent(
                title: CPasteL10n.text("GitHub 项目", "GitHub Project"),
                subtitle: "github.com/cjustsing/cpaste",
                icon: {
                    GitHubMark()
                        .foregroundStyle(CPasteTheme.accent)
                        .frame(width: 18, height: 18)
                        .frame(width: 26, height: 26)
                },
                accessory: {
                    Button(CPasteL10n.text("打开", "Open")) {
                        guard let url = URL(string: "https://github.com/cjustsing/cpaste") else { return }
                        NSWorkspace.shared.open(url)
                    }
                    .controlSize(.small)
                    .accessibilityLabel(CPasteL10n.text("打开 CPaste GitHub 项目", "Open the CPaste GitHub project"))
                }
            )

            Divider().padding(.leading, 56)

            settingsRow(
                icon: "doc.text.fill",
                title: CPasteL10n.text("开源许可", "Open Source License"),
                subtitle: CPasteL10n.text("独立开发的个人项目", "An independently developed personal project")
            ) {
                Text("Apache-2.0")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(CPasteTheme.textSecondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    private func shortcutGroup(
        title: String,
        systemImage: String,
        shortcuts: [SettingsShortcut]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CPasteTheme.textPrimary)
                .frame(height: 28)

            ForEach(shortcuts) { shortcut in
                HStack(spacing: 8) {
                    Text(shortcut.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(CPasteTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Spacer(minLength: 4)

                    Text(shortcut.keys)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(CPasteTheme.textPrimary)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 34, minHeight: 22)
                        .background(
                            CPasteTheme.previewSurface.opacity(0.72),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(CPasteTheme.separator, lineWidth: 1)
                        )
                        .fixedSize()
                }
                .frame(height: 28)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var navigationShortcuts: [SettingsShortcut] {
        [
            SettingsShortcut(CPasteL10n.text("显示或隐藏 CPaste", "Show or hide CPaste"), "⇧⌘V"),
            SettingsShortcut(CPasteL10n.text("切换到历史", "Show history"), "⌥1"),
            SettingsShortcut(CPasteL10n.text("切换到收藏", "Show pinned"), "⌥2"),
            SettingsShortcut(CPasteL10n.text("聚焦搜索", "Focus search"), "⌘F"),
            SettingsShortcut(CPasteL10n.text("切换搜索与时间轴", "Switch search and timeline"), "⇥"),
            SettingsShortcut(CPasteL10n.text("上一张卡片", "Previous card"), "← / ↑"),
            SettingsShortcut(CPasteL10n.text("下一张卡片", "Next card"), "→ / ↓"),
            SettingsShortcut(CPasteL10n.text("第一张卡片", "First card"), "⌘↑"),
            SettingsShortcut(CPasteL10n.text("最后一张卡片", "Last card"), "⌘↓")
        ]
    }

    private var actionShortcuts: [SettingsShortcut] {
        [
            SettingsShortcut(CPasteL10n.text("粘贴", "Paste"), "↩"),
            SettingsShortcut(CPasteL10n.text("纯文本粘贴", "Paste as plain text"), "⇧↩"),
            SettingsShortcut(CPasteL10n.text("快速粘贴第 1–9 项", "Quick paste items 1–9"), "⌘1…⌘9"),
            SettingsShortcut(CPasteL10n.text("复制", "Copy"), "⌘C"),
            SettingsShortcut(CPasteL10n.text("收藏或取消收藏", "Pin or unpin"), "P"),
            SettingsShortcut(CPasteL10n.text("展开或收起详情", "Show or hide details"), "Space"),
            SettingsShortcut(CPasteL10n.text("删除", "Delete"), "⌫"),
            SettingsShortcut(CPasteL10n.text("暂停或继续捕获", "Pause or resume capture"), "⌘T"),
            SettingsShortcut(CPasteL10n.text("打开设置", "Open settings"), "⌘,"),
            SettingsShortcut(CPasteL10n.text("清空搜索或关闭", "Clear search or close"), "Esc")
        ]
    }

    private func settingsRow<Accessory: View>(
        icon: String,
        title: String,
        subtitle: String,
        minHeight: CGFloat = 62,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        settingsRowContent(
            title: title,
            subtitle: subtitle,
            minHeight: minHeight,
            icon: {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CPasteTheme.accent)
                    .frame(width: 26, height: 26)
            },
            accessory: accessory
        )
    }

    private func settingsRowContent<Icon: View, Accessory: View>(
        title: String,
        subtitle: String,
        minHeight: CGFloat = 62,
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 12) {
            icon()

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(CPasteTheme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(CPasteTheme.textMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)
            accessory()
        }
        .frame(minHeight: minHeight)
        .padding(.horizontal, 14)
    }

    private func requestClose() {
        if presentationState.handleCloseRequest() {
            dismiss()
        }
    }

    private var captureBinding: Binding<Bool> {
        Binding(
            get: { !appState.isCapturePaused },
            set: { enabled in
                if enabled == appState.isCapturePaused {
                    actions.toggleCapture()
                }
            }
        )
    }

    private var historyLimitBinding: Binding<Int> {
        Binding(
            get: { store.maxItems },
            set: actions.setHistoryLimit
        )
    }

    private var themeStyleBinding: Binding<AppThemeStyle> {
        Binding(
            get: { appState.themeStyle },
            set: appState.setThemeStyle
        )
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { appState.language },
            set: appState.setLanguage
        )
    }

    private var languageSubtitle: String {
        if appState.language == .system {
            return CPasteL10n.text("根据 macOS 语言自动选择", "Automatically follows macOS")
        }
        return CPasteL10n.text("更改会立即生效", "Changes apply immediately")
    }

    private func languageName(_ language: AppLanguage) -> String {
        switch language {
        case .system:
            return CPasteL10n.text("跟随系统", "System")
        case .simplifiedChinese:
            return "简体中文"
        case .english:
            return "English"
        }
    }

    private var themeSubtitle: String {
        if AppEnvironment.availableThemeStyles.contains(.liquidGlass) {
            return CPasteL10n.text("切换界面材质风格", "Choose the interface material")
        }
        return CPasteL10n.text("当前系统仅支持标准主题", "Only the standard theme is available")
    }

    private func themeName(_ style: AppThemeStyle) -> String {
        switch style {
        case .standard:
            return CPasteL10n.text("标准", "Standard")
        case .liquidGlass:
            return CPasteL10n.text("液态玻璃", "Liquid Glass")
        }
    }

    private var versionSummary: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String

        if let version, let build {
            return CPasteL10n.text("版本 \(version)（\(build)）", "Version \(version) (\(build))")
        }
        return CPasteL10n.text("开发版本", "Development build")
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case privacy
    case shortcuts
    case about

    var id: String { rawValue }
}

private struct GitHubMark: View {
    var body: some View {
        Group {
            if let image = GitHubMarkAssetLoader.image {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            } else {
                Image(systemName: "link")
                    .font(.system(size: 15, weight: .semibold))
            }
        }
        .accessibilityHidden(true)
    }
}

private enum GitHubMarkAssetLoader {
    static let image: NSImage? = {
        if let bundledURL = Bundle.main.url(
            forResource: "github-mark",
            withExtension: "svg",
            subdirectory: "Brand"
        ), let image = NSImage(contentsOf: bundledURL) {
            return image
        }

        let developmentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Resources/Brand/github-mark.svg", isDirectory: false)
        return NSImage(contentsOf: developmentURL)
    }()
}

private struct SettingsShortcut: Identifiable {
    let title: String
    let keys: String

    var id: String { title }

    init(_ title: String, _ keys: String) {
        self.title = title
        self.keys = keys
    }
}
