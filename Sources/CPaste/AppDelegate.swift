import AppKit
import ApplicationServices
import CPasteCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum PanelMetrics {
        static let idealWidth: CGFloat = 1_180
        static let collapsedHeight: CGFloat = 440
        static let maximumExpandedHeight: CGFloat = 583
        static let inspectorHeightDelta: CGFloat = 143
    }

    private let appState = AppState()
    private lazy var store = ClipboardStore(
        storageDirectory: AppEnvironment.storageDirectory,
        maxItems: AppEnvironment.historyLimit
    )
    private lazy var monitor = ClipboardMonitor(store: store)
    private let hotKeyCenter = HotKeyCenter()

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var panelScreenFrame: NSRect?
    private var panelBackingScaleFactor: CGFloat?
    private var pendingPanelPresentationID: UUID?
    private var previousApplication: NSRunningApplication?
    private var isInspectorPresented = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        seedDemoDataIfNeeded()
        setupStatusItem()
        setupHotKey()
        monitor.start()
        if AppEnvironment.isDemoMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.showPanel()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        hotKeyCenter.unregister()
        store.save()
    }

    func applicationDidResignActive(_ notification: Notification) {
        hidePanel()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = StatusItemIcon.make()
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let showItem = NSMenuItem(
            title: CPasteL10n.text("显示 CPaste", "Show CPaste"),
            action: #selector(showPanelFromMenu),
            keyEquivalent: "v"
        )
        showItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(showItem)

        let captureItem = NSMenuItem(
            title: monitor.isPaused ? CPasteL10n.text("继续捕获", "Resume Capture") : CPasteL10n.text("暂停捕获", "Pause Capture"),
            action: #selector(toggleCapture),
            keyEquivalent: "t"
        )
        captureItem.keyEquivalentModifierMask = [.command]
        menu.addItem(captureItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: CPasteL10n.text("清空未收藏历史", "Clear Unpinned"), action: #selector(confirmClearUnpinned), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: CPasteL10n.text("辅助功能设置", "Accessibility Settings"), action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: CPasteL10n.text("退出 CPaste", "Quit CPaste"), action: #selector(quit), keyEquivalent: "q"))
        return menu
    }

    private func setupHotKey() {
        let registered = hotKeyCenter.registerCommandShiftV { [weak self] in
            self?.togglePanel()
        }
        appState.isHotKeyRegistered = registered
        if !registered {
            appState.statusMessage = CPasteL10n.text("快捷键不可用", "Hotkey unavailable")
        }
    }

    @objc private func showPanelFromMenu() {
        showPanel()
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            togglePanel()
        }
    }

    @objc private func togglePanel() {
        if pendingPanelPresentationID != nil || (panel?.isVisible == true && panel?.isKeyWindow == true) {
            hidePanel()
        } else {
            showPanel()
        }
    }

    @objc private func toggleCapture() {
        monitor.isPaused.toggle()
        appState.isCapturePaused = monitor.isPaused
        appState.statusMessage = monitor.isPaused ? CPasteL10n.text("已暂停", "Paused") : CPasteL10n.text("就绪", "Ready")
    }

    @objc private func openAccessibilitySettings() {
        PermissionHelper.openAccessibilitySettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showPanel() {
        capturePreviousApplication()
        let presentationID = UUID()
        pendingPanelPresentationID = presentationID
        appState.panelPresentationID = presentationID

        let targetScreen = targetScreen()
        let panel = ensurePanel(for: targetScreen)
        panel.orderOut(nil)
        position(panel, on: targetScreen)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()

        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self,
                  let panel,
                  self.pendingPanelPresentationID == presentationID,
                  let currentPanel = self.panel,
                  currentPanel === panel
            else {
                return
            }

            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            self.pendingPanelPresentationID = nil
        }
    }

    private func hidePanel() {
        pendingPanelPresentationID = nil
        panel?.orderOut(nil)
    }

    private func showStatusMenu() {
        guard let button = statusItem?.button else {
            return
        }

        let menu = makeStatusMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func capturePreviousApplication() {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            return
        }

        previousApplication = application
    }

    private func ensurePanel(for targetScreen: NSScreen?) -> NSPanel {
        let screenFrame = targetScreen?.frame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let backingScaleFactor = targetScreen?.backingScaleFactor ?? 1
        if let panel,
           !PanelPlacement.requiresWindowRecreation(
               currentScreenFrame: panelScreenFrame,
               currentBackingScaleFactor: panelBackingScaleFactor,
               targetScreenFrame: screenFrame,
               targetBackingScaleFactor: backingScaleFactor
           ) {
            return panel
        }

        if let panel {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }

        let actions = HistoryPanelActions(
            paste: { [weak self] item in self?.paste(item) },
            pastePlainText: { [weak self] item in self?.pastePlainText(item) },
            copy: { [weak self] item in self?.copyOnly(item) },
            togglePinned: { [weak self] item in self?.togglePinned(item) },
            delete: { [weak self] item in self?.delete(item) },
            clearUnpinned: { [weak self] in self?.performClearUnpinned() },
            close: { [weak self] in self?.hidePanel() },
            openAccessibility: { PermissionHelper.openAccessibilitySettings() },
            hasAccessibilityPermission: { PermissionHelper.isAccessibilityTrusted },
            toggleCapture: { [weak self] in self?.toggleCapture() },
            setHistoryLimit: { [weak self] limit in self?.setHistoryLimit(limit) },
            openItem: { [weak self] item in self?.open(item) },
            setInspectorPresented: { [weak self] isPresented in
                self?.setInspectorPresented(isPresented)
            }
        )

        let rootView = HistoryPanelView(
            store: store,
            appState: appState,
            actions: actions,
            initialInspectorPresented: isInspectorPresented
        )
            .frame(
                minWidth: 640,
                idealWidth: PanelMetrics.idealWidth,
                minHeight: 320,
                idealHeight: PanelMetrics.collapsedHeight
            )

        let panel = CPastePanel(
            contentRect: panelFrame(for: screenFrame),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.title = "CPaste"
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: rootView)
        self.panel = panel
        panelScreenFrame = screenFrame
        panelBackingScaleFactor = backingScaleFactor
        return panel
    }

    private func setInspectorPresented(_ isPresented: Bool) {
        guard isInspectorPresented != isPresented else {
            return
        }
        isInspectorPresented = isPresented
        guard let panel else {
            return
        }
        position(panel, on: panel.screen ?? targetScreen())
    }

    private func position(_ panel: NSPanel, on targetScreen: NSScreen?, animated: Bool = false) {
        let screenFrame = targetScreen?.frame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let shouldDisplay = panel.isVisible
        panel.setFrame(
            panelFrame(for: screenFrame),
            display: shouldDisplay,
            animate: animated && shouldDisplay
        )
    }

    private func panelFrame(for screenFrame: NSRect) -> NSRect {
        let maximumHeight = max(420, min(PanelMetrics.maximumExpandedHeight, screenFrame.height - 52))
        let expandedHeight = min(max(520, screenFrame.height * 0.58), maximumHeight)
        let height = isInspectorPresented
            ? expandedHeight
            : max(320, expandedHeight - PanelMetrics.inspectorHeightDelta)
        return PanelPlacement.panelFrame(on: screenFrame, height: height)
    }

    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let fallbackScreen = panel?.screen ?? NSScreen.main
        let fallbackIndex = fallbackScreen.flatMap { candidate in
            screens.firstIndex { $0 === candidate }
        } ?? 0
        guard let targetIndex = PanelPlacement.targetScreenIndex(
            for: NSEvent.mouseLocation,
            screenFrames: screens.map(\.frame),
            fallbackIndex: fallbackIndex
        ) else {
            return fallbackScreen
        }
        return screens[targetIndex]
    }

    private func paste(_ item: ClipboardItem) {
        guard PasteboardWriter.write(item, blobDirectory: store.blobDirectory) else {
            appState.statusMessage = CPasteL10n.text("复制失败", "Copy failed")
            return
        }

        completePaste(item, status: CPasteL10n.text("已粘贴", "Pasted"))
    }

    private func pastePlainText(_ item: ClipboardItem) {
        guard PasteboardWriter.writePlainText(item) else {
            appState.statusMessage = CPasteL10n.text("没有可用的纯文本", "No plain text available")
            return
        }

        completePaste(item, status: CPasteL10n.text("已粘贴纯文本", "Pasted plain text"))
    }

    private func completePaste(_ item: ClipboardItem, status: String) {
        store.moveToTop(item.id)
        monitor.suppressCurrentChange()

        let canPasteDirectly = PermissionHelper.isAccessibilityTrusted
        appState.statusMessage = canPasteDirectly ? status : CPasteL10n.text("已复制", "Copied")
        hidePanel()

        guard canPasteDirectly else {
            previousApplication?.activate(options: [.activateIgnoringOtherApps])
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.previousApplication?.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                KeyboardPaster.sendPasteCommand()
            }
        }
    }

    private func copyOnly(_ item: ClipboardItem) {
        guard PasteboardWriter.write(item, blobDirectory: store.blobDirectory) else {
            appState.statusMessage = CPasteL10n.text("复制失败", "Copy failed")
            return
        }

        store.moveToTop(item.id)
        monitor.suppressCurrentChange()
        appState.statusMessage = CPasteL10n.text("已复制", "Copied")
    }

    private func togglePinned(_ item: ClipboardItem) {
        store.togglePinned(item.id)
        appState.statusMessage = item.isPinned ? CPasteL10n.text("已取消收藏", "Unpinned") : CPasteL10n.text("已收藏", "Pinned")
    }

    private func delete(_ item: ClipboardItem) {
        store.delete(item.id)
        appState.statusMessage = CPasteL10n.text("已删除", "Deleted")
    }

    private func setHistoryLimit(_ limit: Int) {
        store.setMaxItems(limit)
        AppEnvironment.saveHistoryLimit(limit)
        appState.statusMessage = CPasteL10n.text("历史容量已更新", "History limit updated")
    }

    private func open(_ item: ClipboardItem) {
        switch item.kind {
        case .url:
            guard let url = URL(string: item.text), NSWorkspace.shared.open(url) else {
                appState.statusMessage = CPasteL10n.text("无法打开链接", "Could not open link")
                return
            }
            appState.statusMessage = CPasteL10n.text("已打开链接", "Opened link")
            hidePanel()
        case .file:
            let urls = item.fileURLs.compactMap(URL.init(string:))
            guard !urls.isEmpty else {
                appState.statusMessage = CPasteL10n.text("文件不存在", "File unavailable")
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            appState.statusMessage = CPasteL10n.text("已在访达中显示", "Shown in Finder")
            hidePanel()
        case .text, .image:
            appState.statusMessage = CPasteL10n.text("此内容无法直接打开", "This item cannot be opened")
        }
    }

    @objc private func confirmClearUnpinned() {
        guard store.items.contains(where: { !$0.isPinned }) else {
            appState.statusMessage = CPasteL10n.text("没有可清理的记录", "Nothing to clear")
            return
        }

        let alert = NSAlert()
        alert.messageText = CPasteL10n.text("清空未收藏的历史记录？", "Clear unpinned history?")
        alert.informativeText = CPasteL10n.text("已收藏的内容会保留。", "Pinned items will stay in CPaste.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: CPasteL10n.text("清空", "Clear"))
        alert.addButton(withTitle: CPasteL10n.text("取消", "Cancel"))

        if alert.runModal() == .alertFirstButtonReturn {
            performClearUnpinned()
        }
    }

    private func performClearUnpinned() {
        guard store.items.contains(where: { !$0.isPinned }) else {
            appState.statusMessage = CPasteL10n.text("没有可清理的记录", "Nothing to clear")
            return
        }

        store.clearUnpinned()
        appState.statusMessage = CPasteL10n.text("已清空", "Cleared")
    }

    private func seedDemoDataIfNeeded() {
        guard AppEnvironment.isDemoMode, store.items.isEmpty else {
            return
        }

        store.insertCaptured(CapturedClipboardContent(
            kind: .text,
            title: "Release checklist",
            subtitle: "4 lines",
            text: "Build arm64\nRun checks\nVerify signing\nOpen the app",
            contentHash: "demo-text-release-checklist",
            sourceAppName: "Xcode",
            sourceBundleIdentifier: "com.apple.dt.Xcode"
        ))
        store.insertCaptured(CapturedClipboardContent(
            kind: .url,
            title: "https://developer.apple.com/documentation/appkit/nspasteboard",
            subtitle: "URL",
            text: "https://developer.apple.com/documentation/appkit/nspasteboard",
            contentHash: "demo-url-nspasteboard",
            sourceAppName: "Safari",
            sourceBundleIdentifier: "com.apple.Safari"
        ))
        store.insertCaptured(CapturedClipboardContent(
            kind: .file,
            title: "CPaste.app",
            subtitle: "1 file",
            text: "/Applications/CPaste.app",
            fileURLs: ["file:///Applications/CPaste.app"],
            contentHash: "demo-file-cpaste",
            sourceAppName: "Finder",
            sourceBundleIdentifier: "com.apple.finder"
        ))
        if let pngData = NSImage.cpasteDemoImageData() {
            store.insertCaptured(CapturedClipboardContent(
                kind: .image,
                title: "Demo Image",
                subtitle: "160 x 100",
                imagePNGData: pngData,
                contentHash: ContentHasher.hash(data: pngData),
                sourceAppName: "Preview",
                sourceBundleIdentifier: "com.apple.Preview"
            ))
        }

        if let firstID = store.items.first?.id {
            store.togglePinned(firstID)
        }
    }
}

private final class CPastePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private extension NSImage {
    static func cpasteDemoImageData() -> Data? {
        let size = NSSize(width: 160, height: 100)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.04, green: 0.12, blue: 0.13, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor.systemMint.setFill()
        NSBezierPath(roundedRect: NSRect(x: 22, y: 24, width: 116, height: 52), xRadius: 10, yRadius: 10).fill()
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 76, height: 8), xRadius: 4, yRadius: 4).fill()
        NSBezierPath(roundedRect: NSRect(x: 42, y: 28, width: 46, height: 8), xRadius: 4, yRadius: 4).fill()
        image.unlockFocus()

        guard let tiffRepresentation = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation)
        else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }
}
