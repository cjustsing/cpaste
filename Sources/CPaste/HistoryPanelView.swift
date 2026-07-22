import AppKit
import CPasteCore
import SwiftUI

struct HistoryPanelActions {
    var paste: (ClipboardItem) -> Void
    var pastePlainText: (ClipboardItem) -> Void
    var copy: (ClipboardItem) -> Void
    var togglePinned: (ClipboardItem) -> Void
    var delete: (ClipboardItem) -> Void
    var clearUnpinned: () -> Void
    var close: () -> Void
    var openAccessibility: () -> Void
    var hasAccessibilityPermission: () -> Bool
    var toggleCapture: () -> Void
    var setHistoryLimit: (Int) -> Void
    var openItem: (ClipboardItem) -> Void
    var setInspectorPresented: (Bool) -> Void
}

struct HistoryPanelView: View {
    private enum TimelineMetrics {
        static let verticalInset: CGFloat = 12
        static let minimumCardHeight: CGFloat = 190
        static let maximumCardHeight: CGFloat = 320
        static let minimumCardWidth: CGFloat = 174
        static let widthToHeightRatio: CGFloat = 0.75
    }

    @ObservedObject var store: ClipboardStore
    @ObservedObject var appState: AppState
    let actions: HistoryPanelActions

    @State private var searchText = ""
    @State private var selectedKind: ClipboardKind?
    @State private var scope: HistoryScope = .history
    @State private var selectedID: UUID?
    @State private var isInspectorPresented: Bool
    @State private var presentationState = HistoryPanelPresentationState()
    @State private var animateNextSelectionScroll = false
    @State private var thumbnailPrefetchTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        store: ClipboardStore,
        appState: AppState,
        actions: HistoryPanelActions,
        initialInspectorPresented: Bool = false
    ) {
        self.store = store
        self.appState = appState
        self.actions = actions
        _isInspectorPresented = State(initialValue: initialInspectorPresented)
    }

    private var visibleItems: [ClipboardItem] {
        store.filteredItems(
            search: searchText,
            kind: selectedKind,
            pinnedOnly: scope == .pinned
        )
    }

    private func selectedItem(in items: [ClipboardItem]) -> ClipboardItem? {
        if let selectedID,
           let item = items.first(where: { $0.id == selectedID }) {
            return item
        }
        return items.first
    }

    private var hasActiveFilter: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedKind != nil || scope == .pinned
    }

    private var canClearUnpinned: Bool {
        store.items.contains { !$0.isPinned }
    }

    var body: some View {
        let items = visibleItems
        let selectedItem = selectedItem(in: items)

        Group {
            if usesLiquidGlassLayout {
                ZStack {
                    panelBackground
                    panelContent(items: items, selectedItem: selectedItem)
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.36), radius: 28, x: 0, y: 14)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 10)
            } else {
                ZStack {
                    panelBackground
                    panelContent(items: items, selectedItem: selectedItem)
                }
            }
        }
        .foregroundStyle(CPasteTheme.textPrimary)
        .background {
            HistoryKeyboardMonitor(isSearchFocused: isSearchFocused, handle: handleKeyboardCommand)
                .frame(width: 0, height: 0)
        }
        .onAppear {
            setSelection(items.first?.id, animateScroll: false)
            isSearchFocused = false
        }
        .onChange(of: appState.panelPresentationID) { _ in
            prepareForPresentation()
        }
        .onChange(of: items.map(\.id)) { ids in
            if let selectedID, ids.contains(selectedID) {
                return
            }
            setSelection(ids.first, animateScroll: false)
        }
        .onDisappear {
            thumbnailPrefetchTask?.cancel()
        }
        .sheet(isPresented: $presentationState.isSettingsPresented) {
            CPasteSettingsView(store: store, appState: appState, actions: actions)
        }
        .confirmationDialog(CPasteL10n.text("清空未收藏的历史记录？", "Clear unpinned history?"), isPresented: $presentationState.isConfirmingClear) {
            Button(CPasteL10n.text("清空", "Clear"), role: .destructive) {
                actions.clearUnpinned()
            }
            Button(CPasteL10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(CPasteL10n.text("已收藏的内容会保留。", "Pinned items will stay in CPaste."))
        }
        .environment(\.cpasteThemeStyle, appState.themeStyle)
    }

    @ViewBuilder
    private func panelContent(items: [ClipboardItem], selectedItem: ClipboardItem?) -> some View {
        VStack(spacing: 0) {
            toolbar

            if !usesLiquidGlassLayout {
                Divider().overlay(CPasteTheme.separator)
            }

            timeline(items)

            if isInspectorPresented, let selectedItem {
                if !usesLiquidGlassLayout {
                    Divider().overlay(CPasteTheme.separator)
                }
                inspectorPanel(selectedItem)
            }

            if !usesLiquidGlassLayout {
                Divider().overlay(CPasteTheme.separator)
            }
            footer(items: items, selectedItem: selectedItem)
        }
    }

    @ViewBuilder
    private func inspectorPanel(_ selectedItem: ClipboardItem) -> some View {
        let inspector = TimelineInspectorView(
            item: selectedItem,
            imageURL: store.blobURL(for: selectedItem),
            ageText: relativeDescription(for: selectedItem.lastCopiedAt),
            hasAccessibilityPermission: actions.hasAccessibilityPermission(),
            paste: { actions.paste(selectedItem) },
            pastePlainText: { actions.pastePlainText(selectedItem) },
            copy: { actions.copy(selectedItem) },
            togglePinned: { togglePinned(selectedItem, in: visibleItems) },
            open: { actions.openItem(selectedItem) },
            openAccessibility: actions.openAccessibility,
            delete: { delete(selectedItem, from: visibleItems) }
        )
        .frame(height: 142)

        if usesLiquidGlassLayout {
            inspector
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .cpasteGlass(radius: 18, shadowOpacity: 0.20)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
        } else {
            inspector
        }
    }

    private var usesLiquidGlassLayout: Bool {
        if #available(macOS 26.0, *) {
            return appState.themeStyle == .liquidGlass
        }
        return false
    }

    @ViewBuilder
    private var panelBackground: some View {
        if usesLiquidGlassLayout {
            CPasteLiquidCanvas()
        } else {
            ZStack {
                VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                    .ignoresSafeArea()
                CPasteTheme.background.opacity(0.76)
                    .ignoresSafeArea()
                CPasteTheme.canvas.opacity(0.18)
                    .ignoresSafeArea()
            }
        }
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            fullToolbar
            compactToolbar
        }
        .padding(.horizontal, usesLiquidGlassLayout ? 10 : 14)
        .frame(height: usesLiquidGlassLayout ? 64 : 60)
        .background {
            if !usesLiquidGlassLayout {
                CPasteGlassBackground(
                    radius: 0,
                    material: .headerView,
                    tint: CPasteTheme.backgroundLift,
                    tintOpacity: 0.58,
                    stroke: Color.clear,
                    shadowOpacity: 0.10
                )
            }
        }
    }

    private var fullToolbar: some View {
        CPasteGlassGroup(spacing: 10) {
            HStack(spacing: usesLiquidGlassLayout ? 10 : 9) {
                brand(showName: true)
                scopePicker
                searchField
                filterMenu
                inspectorButton
                captureButton
                settingsButton
                closeButton
            }
        }
    }

    private var compactToolbar: some View {
        CPasteGlassGroup(spacing: 9) {
            HStack(spacing: 8) {
                brand(showName: false)
                searchField
                compactScopeMenu
                filterMenu
                moreMenu
                closeButton
            }
        }
    }

    @ViewBuilder
    private func brand(showName: Bool) -> some View {
        let content = HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            if showName {
                Text("CPaste")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CPasteTheme.textPrimary)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("CPaste")

        if usesLiquidGlassLayout {
            content
                .padding(.horizontal, showName ? 11 : 4)
                .frame(height: 36)
                .cpasteGlass(radius: 18, isInteractive: true)
        } else {
            content
        }
    }

    private var scopePicker: some View {
        Picker("", selection: $scope) {
            Text(CPasteL10n.text("历史", "History"))
                .tag(HistoryScope.history)
            Text(CPasteL10n.text("收藏", "Pinned"))
                .tag(HistoryScope.pinned)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 142)
        .controlSize(usesLiquidGlassLayout ? .large : .regular)
        .help(CPasteL10n.text("⌥1 历史 · ⌥2 收藏", "⌥1 History · ⌥2 Pinned"))
        .accessibilityLabel(CPasteL10n.text("浏览范围", "Browse scope"))
    }

    private var compactScopeMenu: some View {
        Menu {
            Button {
                scope = .history
            } label: {
                Label(CPasteL10n.text("历史", "History"), systemImage: scope == .history ? "checkmark" : "clock.arrow.circlepath")
            }
            Button {
                scope = .pinned
            } label: {
                Label(CPasteL10n.text("收藏", "Pinned"), systemImage: scope == .pinned ? "checkmark" : "pin.fill")
            }
        } label: {
            Image(systemName: scope == .pinned ? "pin.fill" : "clock.arrow.circlepath")
                .foregroundStyle(scope == .pinned ? CPasteTheme.amber : CPasteTheme.textSecondary)
                .frame(width: 32, height: 32)
                .cpasteGlass(
                    radius: usesLiquidGlassLayout ? 16 : 7,
                    material: .menu,
                    tintOpacity: 0.44,
                    shadowOpacity: 0.02,
                    isInteractive: true,
                    liquidTint: scope == .pinned ? CPasteTheme.amber.opacity(0.26) : nil
                )
        }
        .menuStyle(.borderlessButton)
        .frame(width: 32, height: 32)
        .help(CPasteL10n.text("⌥1 历史 · ⌥2 收藏", "⌥1 History · ⌥2 Pinned"))
        .accessibilityLabel(CPasteL10n.text("浏览范围", "Browse scope"))
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CPasteTheme.textMuted)
                .frame(width: 14)

            if let selectedKind {
                HStack(spacing: 4) {
                    Image(systemName: selectedKind.systemImageName)
                    Text(selectedKind.localizedDisplayName)
                        .lineLimit(1)
                    Button {
                        self.selectedKind = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help(CPasteL10n.text("移除类型筛选", "Remove type filter"))
                    .accessibilityLabel(CPasteL10n.text("移除类型筛选", "Remove type filter"))
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CPasteTheme.kindColor(selectedKind))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(CPasteTheme.kindColor(selectedKind).opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .fixedSize()
            }

            TextField(CPasteL10n.text("搜索复制内容", "Search copied content"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFocused)
                .onSubmit {
                    pasteSelected()
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(CPasteTheme.textMuted)
                }
                .buttonStyle(.plain)
                .help(CPasteL10n.text("清空搜索", "Clear search"))
                .accessibilityLabel(CPasteL10n.text("清空搜索", "Clear search"))
                .frame(width: 20, height: 20)
            }
        }
        .padding(.horizontal, 11)
        .frame(
            minWidth: 180,
            maxWidth: .infinity,
            minHeight: usesLiquidGlassLayout ? 38 : 34,
            maxHeight: usesLiquidGlassLayout ? 38 : 34
        )
        .cpasteGlass(
            radius: usesLiquidGlassLayout ? 19 : 8,
            material: .menu,
            tint: CPasteTheme.surface,
            tintOpacity: 0.54,
            stroke: isSearchFocused ? CPasteTheme.accent.opacity(0.70) : CPasteTheme.glassStroke,
            shadowOpacity: isSearchFocused ? 0.13 : 0.02,
            liquidTint: isSearchFocused ? CPasteTheme.accent.opacity(0.22) : nil
        )
        .layoutPriority(1)
    }

    private var filterMenu: some View {
        Menu {
            Button {
                selectedKind = nil
            } label: {
                Label(CPasteL10n.text("全部类型", "All Types"), systemImage: selectedKind == nil ? "checkmark" : "square.grid.2x2")
            }

            Divider()

            ForEach(ClipboardKind.allCases) { kind in
                Button {
                    selectedKind = kind
                } label: {
                    Label(kind.localizedDisplayName, systemImage: selectedKind == kind ? "checkmark" : kind.systemImageName)
                }
            }
        } label: {
            Image(systemName: selectedKind?.systemImageName ?? "line.3.horizontal.decrease")
                .foregroundStyle(selectedKind.map(CPasteTheme.kindColor) ?? CPasteTheme.textSecondary)
                .frame(width: 32, height: 32)
                .cpasteGlass(
                    radius: usesLiquidGlassLayout ? 16 : 7,
                    material: .menu,
                    tint: selectedKind.map(CPasteTheme.kindColor) ?? CPasteTheme.surface,
                    tintOpacity: selectedKind == nil ? 0.44 : 0.17,
                    stroke: selectedKind.map { CPasteTheme.kindColor($0).opacity(0.44) } ?? CPasteTheme.glassStroke,
                    shadowOpacity: 0.02,
                    isInteractive: true,
                    liquidTint: selectedKind.map { CPasteTheme.kindColor($0).opacity(0.24) }
                )
        }
        .menuStyle(.borderlessButton)
        .frame(width: 32, height: 32)
        .help(CPasteL10n.text("内容类型", "Content Type"))
        .accessibilityLabel(CPasteL10n.text("内容类型筛选", "Content type filter"))
    }

    private var inspectorButton: some View {
        Button {
            toggleInspector()
        } label: {
            Image(systemName: isInspectorPresented ? "rectangle.bottomhalf.inset.filled" : "rectangle.bottomhalf.inset.filled")
        }
        .buttonStyle(CPasteIconButtonStyle(isActive: isInspectorPresented))
        .help(CPasteL10n.text("详情", "Inspector"))
        .accessibilityLabel(isInspectorPresented ? CPasteL10n.text("收起详情", "Hide inspector") : CPasteL10n.text("显示详情", "Show inspector"))
        .disabled(selectedID == nil)
    }

    private var captureButton: some View {
        Button {
            actions.toggleCapture()
        } label: {
            Image(systemName: appState.isCapturePaused ? "play.fill" : "pause.fill")
        }
        .buttonStyle(CPasteIconButtonStyle(isActive: appState.isCapturePaused))
        .help(appState.isCapturePaused ? CPasteL10n.text("继续捕获", "Resume capture") : CPasteL10n.text("暂停捕获", "Pause capture"))
        .accessibilityLabel(appState.isCapturePaused ? CPasteL10n.text("继续捕获", "Resume capture") : CPasteL10n.text("暂停捕获", "Pause capture"))
    }

    private var settingsButton: some View {
        Button {
            presentationState.isSettingsPresented = true
        } label: {
            Image(systemName: "gearshape")
        }
        .buttonStyle(CPasteIconButtonStyle())
        .help(CPasteL10n.text("设置", "Settings"))
        .accessibilityLabel(CPasteL10n.text("设置", "Settings"))
    }

    private var closeButton: some View {
        Button {
            closePanel()
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(CPasteIconButtonStyle())
        .help(CPasteL10n.text("关闭", "Close"))
        .accessibilityLabel(CPasteL10n.text("关闭 CPaste", "Close CPaste"))
    }

    private var moreMenu: some View {
        Menu {
            Button {
                toggleInspector()
            } label: {
                Label(
                    isInspectorPresented ? CPasteL10n.text("收起详情", "Hide Inspector") : CPasteL10n.text("显示详情", "Show Inspector"),
                    systemImage: "rectangle.bottomhalf.inset.filled"
                )
            }
            .disabled(selectedID == nil)

            Button {
                actions.toggleCapture()
            } label: {
                Label(
                    appState.isCapturePaused ? CPasteL10n.text("继续捕获", "Resume Capture") : CPasteL10n.text("暂停捕获", "Pause Capture"),
                    systemImage: appState.isCapturePaused ? "play.fill" : "pause.fill"
                )
            }

            Button {
                presentationState.isSettingsPresented = true
            } label: {
                Label(CPasteL10n.text("设置", "Settings"), systemImage: "gearshape")
            }

            Divider()

            Button(role: .destructive) {
                presentationState.isConfirmingClear = true
            } label: {
                Label(CPasteL10n.text("清空未收藏历史", "Clear Unpinned History"), systemImage: "trash")
            }
            .disabled(!canClearUnpinned)
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(CPasteTheme.textSecondary)
                .frame(width: 32, height: 32)
                .cpasteGlass(
                    radius: usesLiquidGlassLayout ? 16 : 7,
                    material: .menu,
                    tintOpacity: 0.44,
                    shadowOpacity: 0.02,
                    isInteractive: true
                )
        }
        .menuStyle(.borderlessButton)
        .frame(width: 32, height: 32)
        .help(CPasteL10n.text("更多", "More"))
        .accessibilityLabel(CPasteL10n.text("更多操作", "More actions"))
    }

    private func timeline(_ items: [ClipboardItem]) -> some View {
        GeometryReader { proxy in
            let cardHeight = min(
                max(proxy.size.height - TimelineMetrics.verticalInset * 2, TimelineMetrics.minimumCardHeight),
                TimelineMetrics.maximumCardHeight
            )
            let cardWidth = max(
                cardHeight * TimelineMetrics.widthToHeightRatio,
                TimelineMetrics.minimumCardWidth
            )
            let cardSize = CGSize(width: cardWidth, height: cardHeight)

            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            TimelineCardView(
                                item: item,
                                position: index + 1,
                                isSelected: item.id == selectedID,
                                size: cardSize,
                                imageURL: store.blobURL(for: item),
                                ageText: relativeDescription(for: item.lastCopiedAt),
                                select: {
                                    select(item, animateScroll: true)
                                },
                                paste: {
                                    select(item, animateScroll: true)
                                    actions.paste(item)
                                },
                                pastePlainText: {
                                    select(item, animateScroll: true)
                                    actions.pastePlainText(item)
                                },
                                copy: {
                                    select(item, animateScroll: true)
                                    actions.copy(item)
                                },
                                togglePinned: {
                                    togglePinned(item, in: items)
                                },
                                open: {
                                    select(item, animateScroll: true)
                                    actions.openItem(item)
                                },
                                delete: {
                                    delete(item, from: items)
                                }
                            )
                            .equatable()
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, TimelineMetrics.verticalInset)
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .leading)
                }
                .id(appState.panelPresentationID)
                .background(usesLiquidGlassLayout ? Color.clear : CPasteTheme.canvas.opacity(0.25))
                .overlay {
                    if items.isEmpty {
                        EmptyTimelineView(
                            hasActiveFilter: hasActiveFilter,
                            clearFilters: resetFilters
                        )
                    }
                }
                .onChange(of: selectedID) { id in
                    guard let id else {
                        return
                    }
                    let shouldAnimate = animateNextSelectionScroll && !reduceMotion
                    animateNextSelectionScroll = false
                    if shouldAnimate {
                        withAnimation(.easeOut(duration: 0.12)) {
                            scrollProxy.scrollTo(id, anchor: .center)
                        }
                    } else {
                        scrollProxy.scrollTo(id, anchor: .center)
                    }
                    prefetchThumbnails(around: id, in: items)
                }
            }
        }
        .frame(minHeight: 190)
    }

    @ViewBuilder
    private func footer(items: [ClipboardItem], selectedItem: ClipboardItem?) -> some View {
        let content = HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            Text(appState.statusMessage)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(CPasteTheme.textSecondary)
                .lineLimit(1)

            if hasActiveFilter {
                Button {
                    resetFilters()
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(CPasteTheme.textMuted)
                .help(CPasteL10n.text("清除筛选", "Clear filters"))
                .accessibilityLabel(CPasteL10n.text("清除筛选", "Clear filters"))
            }

            Spacer(minLength: 10)

            if let selectedItem {
                HStack(spacing: 5) {
                    SourceApplicationIcon(
                        name: selectedItem.sourceAppName,
                        bundleIdentifier: selectedItem.sourceBundleIdentifier,
                        size: 17
                    )
                    Text(selectedItem.sourceAppName ?? CPasteL10n.text("未知来源", "Unknown source"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(CPasteTheme.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 10)

            Text("\(items.count) / \(store.items.count)")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(CPasteTheme.textMuted)
                .lineLimit(1)

            if !actions.hasAccessibilityPermission() {
                Button {
                    actions.openAccessibility()
                } label: {
                    Image(systemName: "lock.open")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(CPasteTheme.amber)
                .help(CPasteL10n.text("自动粘贴需要辅助功能权限", "Direct paste needs Accessibility access"))
                .accessibilityLabel(CPasteL10n.text("打开辅助功能设置", "Open Accessibility settings"))
            }
        }

        if usesLiquidGlassLayout {
            content
                .padding(.horizontal, 14)
                .frame(height: 34)
                .cpasteGlass(radius: 17, shadowOpacity: 0.16)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
        } else {
            content
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background {
                    CPasteGlassBackground(
                        radius: 0,
                        material: .menu,
                        tint: CPasteTheme.backgroundLift,
                        tintOpacity: 0.50,
                        stroke: Color.clear,
                        shadowOpacity: 0
                    )
                }
        }
    }

    private var statusColor: Color {
        if appState.isCapturePaused || !appState.isHotKeyRegistered {
            return CPasteTheme.amber
        }
        return CPasteTheme.accent
    }

    private func handleKeyboardCommand(_ command: HistoryKeyboardCommand) -> Bool {
        let items = visibleItems
        let selectedItem = selectedItem(in: items)

        switch command {
        case .previous:
            moveSelection(by: -1, in: items)
        case .next:
            moveSelection(by: 1, in: items)
        case .first:
            selectIndex(0, in: items)
        case .last:
            selectIndex(items.count - 1, in: items)
        case .paste:
            if let selectedItem {
                actions.paste(selectedItem)
            }
        case .pastePlainText:
            if let selectedItem {
                actions.pastePlainText(selectedItem)
            }
        case .copy:
            if let selectedItem {
                actions.copy(selectedItem)
            }
        case .togglePinned:
            if let selectedItem {
                togglePinned(selectedItem, in: items)
            }
        case .delete:
            if let selectedItem {
                delete(selectedItem, from: items)
            }
        case .closeOrClearSearch:
            if !searchText.isEmpty {
                searchText = ""
            } else {
                closePanel()
            }
        case .toggleInspector:
            toggleInspector()
        case .focusSearch:
            isSearchFocused = true
        case .focusTimeline:
            isSearchFocused = false
            if selectedID == nil {
                setSelection(items.first?.id, animateScroll: false)
            }
        case .quickPaste(let position):
            let index = position - 1
            guard items.indices.contains(index) else {
                return false
            }
            let item = items[index]
            setSelection(item.id, animateScroll: false)
            actions.paste(item)
        case .showHistory:
            selectScope(.history)
        case .showPinned:
            selectScope(.pinned)
        case .showSettings:
            presentationState.isSettingsPresented = true
        case .toggleCapture:
            actions.toggleCapture()
        }
        return true
    }

    private func select(_ item: ClipboardItem, animateScroll: Bool) {
        setSelection(item.id, animateScroll: animateScroll)
        isSearchFocused = false
    }

    private func togglePinned(_ item: ClipboardItem, in items: [ClipboardItem]) {
        if scope == .pinned, item.isPinned {
            selectReplacement(afterRemoving: item.id, from: items)
        } else {
            select(item, animateScroll: true)
        }
        actions.togglePinned(item)
    }

    private func delete(_ item: ClipboardItem, from items: [ClipboardItem]) {
        selectReplacement(afterRemoving: item.id, from: items)
        actions.delete(item)
    }

    private func selectReplacement(afterRemoving itemID: UUID, from items: [ClipboardItem]) {
        let replacementID = TimelineSelection.replacementID(
            afterRemoving: itemID,
            from: items.map(\.id)
        )
        setSelection(replacementID, animateScroll: false)
        isSearchFocused = false
    }

    private func selectScope(_ nextScope: HistoryScope) {
        scope = nextScope
        let items = store.filteredItems(
            search: searchText,
            kind: selectedKind,
            pinnedOnly: nextScope == .pinned
        )
        setSelection(items.first?.id, animateScroll: false)
        isSearchFocused = false
    }

    private func moveSelection(by offset: Int, in items: [ClipboardItem]) {
        guard !items.isEmpty else {
            setSelection(nil, animateScroll: false)
            return
        }

        isSearchFocused = false
        let currentIndex = selectedID.flatMap { id in items.firstIndex(where: { $0.id == id }) } ?? 0
        selectIndex(currentIndex + offset, in: items)
    }

    private func selectIndex(_ index: Int, in items: [ClipboardItem]) {
        guard !items.isEmpty else {
            setSelection(nil, animateScroll: false)
            return
        }

        let clampedIndex = min(max(index, 0), items.count - 1)
        setSelection(items[clampedIndex].id, animateScroll: false)
        isSearchFocused = false
    }

    private func setSelection(_ id: UUID?, animateScroll: Bool) {
        animateNextSelectionScroll = selectedID != id && animateScroll
        selectedID = id
    }

    private func pasteSelected() {
        let items = visibleItems
        if let selectedItem = selectedItem(in: items) {
            actions.paste(selectedItem)
        }
    }

    private func toggleInspector() {
        let items = visibleItems
        guard selectedItem(in: items) != nil else {
            return
        }
        let nextValue = !isInspectorPresented
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isInspectorPresented = nextValue
        }
        actions.setInspectorPresented(nextValue)
    }

    private func resetFilters() {
        searchText = ""
        selectedKind = nil
        scope = .history
        setSelection(store.filteredItems(search: "").first?.id, animateScroll: false)
        isSearchFocused = true
    }

    private func prepareForPresentation() {
        presentationState.resetTransientUI()
        searchText = ""
        let items = store.filteredItems(
            search: "",
            kind: selectedKind,
            pinnedOnly: scope == .pinned
        )
        setSelection(items.first?.id, animateScroll: false)
        isSearchFocused = false
    }

    private func closePanel() {
        presentationState.resetTransientUI()
        actions.close()
    }

    private func prefetchThumbnails(around selectedID: UUID, in items: [ClipboardItem]) {
        thumbnailPrefetchTask?.cancel()

        guard let selectedIndex = items.firstIndex(where: { $0.id == selectedID }) else {
            return
        }

        let lowerBound = max(0, selectedIndex - 2)
        let upperBound = min(items.count - 1, selectedIndex + 2)
        let imageURLs = items[lowerBound...upperBound].compactMap { item in
            item.kind == .image ? store.blobURL(for: item) : nil
        }
        guard !imageURLs.isEmpty else {
            return
        }

        thumbnailPrefetchTask = Task(priority: .utility) {
            await TimelineThumbnailCache.shared.prefetch(
                urls: imageURLs,
                maxPixelSize: TimelineThumbnailCache.cardMaxPixelSize
            )
        }
    }

    private func relativeDescription(for date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 60 {
            return CPasteL10n.text("刚刚", "Just now")
        }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = CPasteL10n.usesChinese ? Locale(identifier: "zh_Hans") : Locale.current
        return formatter
    }()
}

private enum HistoryScope: String, CaseIterable, Identifiable {
    case history
    case pinned

    var id: String { rawValue }
}

private struct EmptyTimelineView: View {
    let hasActiveFilter: Bool
    var clearFilters: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: hasActiveFilter ? "magnifyingglass" : "tray")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(CPasteTheme.textMuted)

            Text(hasActiveFilter ? CPasteL10n.text("没有匹配内容", "No Matches") : CPasteL10n.text("暂无记录", "No Clipboard Items"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CPasteTheme.textSecondary)

            if hasActiveFilter {
                Button {
                    clearFilters()
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(CPasteIconButtonStyle())
                .help(CPasteL10n.text("清除筛选", "Clear filters"))
                .accessibilityLabel(CPasteL10n.text("清除筛选", "Clear filters"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
