import AppKit
import CPasteCore
import ScreenCaptureKit
import SwiftUI

@MainActor
enum SnapshotRenderer {
    private static var previewWindow: NSWindow?

    nonisolated static func snapshotDirectoryArgument() -> URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--snapshot-dir"),
              arguments.indices.contains(index + 1)
        else {
            return nil
        }

        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    nonisolated static func snapshotPreviewArgument() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--snapshot-preview"),
              arguments.indices.contains(index + 1)
        else {
            return nil
        }

        return arguments[index + 1]
    }

    static func showPreview(named rawName: String) throws {
        guard #available(macOS 26.0, *) else {
            throw SnapshotError.liquidGlassUnavailable
        }

        let name = (rawName as NSString).deletingPathExtension
        switch name {
        case "01-timeline-overview":
            showPanelPreview(
                size: NSSize(width: 1_180, height: 440),
                store: makeDemoStore(name: "preview-full"),
                appState: makeReadyState(),
                inspectorPresented: false
            )
        case "02-timeline-inspector":
            showPanelPreview(
                size: NSSize(width: 1_180, height: 583),
                store: makeDemoStore(name: "preview-inspector"),
                appState: makeReadyState(),
                inspectorPresented: true
            )
        case "03-compact-timeline":
            showPanelPreview(
                size: NSSize(width: 680, height: 440),
                store: makeDemoStore(name: "preview-compact"),
                appState: makeReadyState(),
                inspectorPresented: false
            )
        case "04-empty-timeline":
            let state = AppState(themeStyle: .liquidGlass)
            state.statusMessage = CPasteL10n.text("就绪", "Ready")
            showPanelPreview(
                size: NSSize(width: 680, height: 420),
                store: ClipboardStore(storageDirectory: temporaryStoreDirectory(name: "preview-empty")),
                appState: state,
                inspectorPresented: false
            )
        case "05-settings":
            showSettingsPreview(initialSection: .general)
        case "06-support":
            showSettingsPreview(initialSection: .about, supportPresented: true)
        case "07-settings-about":
            showSettingsPreview(initialSection: .about)
        case "08-settings-privacy":
            showSettingsPreview(initialSection: .privacy)
        case "09-large-text":
            let store = makeDemoStore(name: "preview-large-text")
            let text = "Large text preview\n" + String(repeating: "长文性能测试 abcdefg 1234567890。\n", count: 200_000) + "CPasteTailNeedle"
            store.insertCaptured(CapturedClipboardContent(
                kind: .text,
                title: "8 MB text fixture",
                subtitle: ClipboardText.summary(for: text),
                text: text,
                contentHash: ContentHasher.hash(string: text),
                sourceAppName: "Performance Fixture"
            ))
            showPanelPreview(
                size: NSSize(width: 1_180, height: 583),
                store: store,
                appState: makeReadyState(),
                inspectorPresented: true
            )
        default:
            throw SnapshotError.unknownScene(rawName)
        }
    }

    static func renderAll(to directory: URL) async throws {
        guard #available(macOS 26.0, *) else {
            throw SnapshotError.liquidGlassUnavailable
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try await renderPanel(
            name: "01-timeline-overview.png",
            size: NSSize(width: 1_180, height: 440),
            store: makeDemoStore(name: "full"),
            appState: makeReadyState(),
            inspectorPresented: false,
            to: directory
        )

        try await renderPanel(
            name: "02-timeline-inspector.png",
            size: NSSize(width: 1_180, height: 583),
            store: makeDemoStore(name: "inspector"),
            appState: makeReadyState(),
            inspectorPresented: true,
            to: directory
        )

        try await renderPanel(
            name: "03-compact-timeline.png",
            size: NSSize(width: 680, height: 440),
            store: makeDemoStore(name: "compact"),
            appState: makeReadyState(),
            inspectorPresented: false,
            to: directory
        )

        let emptyState = AppState(themeStyle: .liquidGlass)
        emptyState.statusMessage = CPasteL10n.text("就绪", "Ready")
        try await renderPanel(
            name: "04-empty-timeline.png",
            size: NSSize(width: 680, height: 420),
            store: ClipboardStore(storageDirectory: temporaryStoreDirectory(name: "empty")),
            appState: emptyState,
            inspectorPresented: false,
            to: directory
        )

        try await renderSettings(
            name: "05-settings.png",
            store: makeDemoStore(name: "settings"),
            appState: makeReadyState(),
            to: directory
        )

        try await renderSettings(
            name: "07-settings-about.png",
            store: makeDemoStore(name: "settings-about"),
            appState: makeReadyState(),
            initialSection: .about,
            to: directory
        )

        try await renderSettings(
            name: "08-settings-privacy.png",
            store: makeDemoStore(name: "settings-privacy"),
            appState: makeReadyState(),
            initialSection: .privacy,
            to: directory
        )

        try await renderSupport(
            name: "06-support.png",
            appState: makeReadyState(),
            to: directory
        )
    }

    @available(macOS 26.0, *)
    private static func renderPanel(
        name: String,
        size: NSSize,
        store: ClipboardStore,
        appState: AppState,
        inspectorPresented: Bool,
        to directory: URL
    ) async throws {
        let actions = makeActions(store: store, appState: appState)
        let view = HistoryPanelView(
            store: store,
            appState: appState,
            actions: actions,
            initialInspectorPresented: inspectorPresented
        )
        .frame(width: size.width, height: size.height)
        .preferredColorScheme(.dark)

        try await render(view, size: size, to: directory.appendingPathComponent(name, isDirectory: false))
    }

    @available(macOS 26.0, *)
    private static func renderSettings(
        name: String,
        store: ClipboardStore,
        appState: AppState,
        initialSection: SettingsSection = .general,
        to directory: URL
    ) async throws {
        let size = NSSize(width: 560, height: 390)
        let view = CPasteSettingsView(
            store: store,
            appState: appState,
            actions: makeActions(store: store, appState: appState),
            initialSection: initialSection
        )
        .preferredColorScheme(.dark)

        try await render(view, size: size, to: directory.appendingPathComponent(name, isDirectory: false))
    }

    @available(macOS 26.0, *)
    private static func renderSupport(
        name: String,
        appState: AppState,
        to directory: URL
    ) async throws {
        let size = NSSize(width: 560, height: 390)
        let store = makeDemoStore(name: "support")
        let view = CPasteSettingsView(
            store: store,
            appState: appState,
            actions: makeActions(store: store, appState: appState),
            initialSection: .about,
            initialSupportPresented: true
        )
            .preferredColorScheme(.dark)

        try await render(view, size: size, to: directory.appendingPathComponent(name, isDirectory: false))
    }

    private static func makeActions(store: ClipboardStore, appState: AppState) -> HistoryPanelActions {
        HistoryPanelActions(
            paste: { _ in },
            pastePlainText: { _ in },
            copy: { _ in },
            togglePinned: { item in store.togglePinned(item.id) },
            delete: { item in store.delete(item.id) },
            clearUnpinned: { store.clearUnpinned() },
            close: {},
            openAccessibility: {},
            hasAccessibilityPermission: { false },
            toggleCapture: {
                appState.isCapturePaused.toggle()
            },
            setHistoryLimit: { limit in store.setMaxItems(limit) },
            openItem: { _ in },
            setInspectorPresented: { _ in }
        )
    }

    @available(macOS 26.0, *)
    private static func showPanelPreview(
        size: NSSize,
        store: ClipboardStore,
        appState: AppState,
        inspectorPresented: Bool
    ) {
        let view = HistoryPanelView(
            store: store,
            appState: appState,
            actions: makeActions(store: store, appState: appState),
            initialInspectorPresented: inspectorPresented
        )
        .frame(width: size.width, height: size.height)
        .preferredColorScheme(.dark)

        showPreview(view, size: size)
    }

    @available(macOS 26.0, *)
    private static func showSettingsPreview(
        initialSection: SettingsSection,
        supportPresented: Bool = false
    ) {
        let size = NSSize(width: 560, height: 390)
        let store = makeDemoStore(name: supportPresented ? "preview-support" : "preview-settings")
        let appState = makeReadyState()
        let view = CPasteSettingsView(
            store: store,
            appState: appState,
            actions: makeActions(store: store, appState: appState),
            initialSection: initialSection,
            initialSupportPresented: supportPresented
        )
        .preferredColorScheme(.dark)

        showPreview(view, size: size)
    }

    @available(macOS 26.0, *)
    private static func showPreview<V: View>(_ view: V, size: NSSize) {
        let (window, hostingView) = makeWindow(for: view, size: size)
        previewWindow = window
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
    }

    @available(macOS 26.0, *)
    private static func render<V: View>(_ view: V, size: NSSize, to url: URL) async throws {
        let (window, hostingView) = makeWindow(for: view, size: size)
        defer { window.close() }
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
        hostingView.layoutSubtreeIfNeeded()

        // Native Liquid Glass is produced by WindowServer. Give the onscreen
        // compositor and asynchronous thumbnails time to publish before capture.
        try await Task.sleep(nanoseconds: 500_000_000)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let content = try await SCShareableContent.currentProcess
        guard let shareableWindow = content.windows.first(where: {
            $0.windowID == CGWindowID(window.windowNumber)
        }) else {
            throw SnapshotError.windowNotFound
        }

        let scale = window.backingScaleFactor
        let configuration = SCScreenshotConfiguration()
        configuration.width = Int(size.width * scale)
        configuration.height = Int(size.height * scale)
        configuration.showsCursor = false
        configuration.ignoreShadows = true
        configuration.displayIntent = .local
        configuration.dynamicRange = .sdr

        let filter = SCContentFilter(desktopIndependentWindow: shareableWindow)
        let output = try await SCScreenshotManager.captureScreenshot(
            contentFilter: filter,
            configuration: configuration
        )
        guard let image = output.sdrImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else {
            throw SnapshotError.pngEncodingFailed
        }

        try data.write(to: url, options: .atomic)
    }

    private static func makeWindow<V: View>(for view: V, size: NSSize) -> (NSWindow, NSHostingView<V>) {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)

        let window = SnapshotWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Swift owns the window through capture/preview teardown.
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.sharingType = .readOnly
        window.contentView = hostingView
        window.setFrame(NSRect(origin: .zero, size: size), display: true)
        window.center()
        return (window, hostingView)
    }

    private static func makeReadyState() -> AppState {
        let state = AppState(themeStyle: .liquidGlass)
        state.statusMessage = CPasteL10n.text("已复制", "Copied")
        return state
    }

    private static func makeDemoStore(name: String) -> ClipboardStore {
        let store = ClipboardStore(storageDirectory: temporaryStoreDirectory(name: name))
        store.insertCaptured(CapturedClipboardContent(
            kind: .text,
            title: "Launch notes",
            subtitle: "5 lines",
            text: "Timeline UI\nKeyboard navigation\nSource app icons\nNative materials\nApple Silicon",
            contentHash: "snapshot-\(name)-launch-notes",
            sourceAppName: "Notes",
            sourceBundleIdentifier: "com.apple.Notes"
        ))
        store.insertCaptured(CapturedClipboardContent(
            kind: .url,
            title: "https://developer.apple.com/documentation/appkit/nspasteboard",
            subtitle: "URL",
            text: "https://developer.apple.com/documentation/appkit/nspasteboard",
            contentHash: "snapshot-\(name)-url-docs",
            sourceAppName: "Safari",
            sourceBundleIdentifier: "com.apple.Safari"
        ))
        store.insertCaptured(CapturedClipboardContent(
            kind: .file,
            title: "CPaste.app",
            subtitle: "1 file",
            text: "/Applications/CPaste.app",
            fileURLs: ["file:///Applications/CPaste.app"],
            contentHash: "snapshot-\(name)-file-app",
            sourceAppName: "Finder",
            sourceBundleIdentifier: "com.apple.finder"
        ))
        store.insertCaptured(CapturedClipboardContent(
            kind: .text,
            title: "Release checklist",
            subtitle: "4 lines",
            text: "Build arm64\nRun checks\nVerify signing\nOpen the app",
            contentHash: "snapshot-\(name)-release-checklist",
            sourceAppName: "Xcode",
            sourceBundleIdentifier: "com.apple.dt.Xcode"
        ))
        store.insertCaptured(CapturedClipboardContent(
            kind: .url,
            title: "Swift documentation",
            subtitle: "URL",
            text: "https://www.swift.org/documentation/",
            contentHash: "snapshot-\(name)-url-swift-docs",
            sourceAppName: "Safari",
            sourceBundleIdentifier: "com.apple.Safari"
        ))
        store.insertCaptured(CapturedClipboardContent(
            kind: .file,
            title: "UI reference files",
            subtitle: "2 files",
            text: "/Users/demo/CPaste/UI-reference.png\n/Users/demo/CPaste/Design-notes.md",
            fileURLs: [
                "file:///Users/demo/CPaste/UI-reference.png",
                "file:///Users/demo/CPaste/Design-notes.md"
            ],
            contentHash: "snapshot-\(name)-file-reference",
            sourceAppName: "Finder",
            sourceBundleIdentifier: "com.apple.finder"
        ))

        if let pngData = demoImageData() {
            store.insertCaptured(CapturedClipboardContent(
                kind: .image,
                title: "Demo Image",
                subtitle: "160 x 100",
                imagePNGData: pngData,
                contentHash: "snapshot-\(name)-image-\(ContentHasher.hash(data: pngData))",
                sourceAppName: "Preview",
                sourceBundleIdentifier: "com.apple.Preview"
            ))
        }

        if let imageID = store.items.first?.id {
            store.togglePinned(imageID)
        }

        return store
    }

    private static func temporaryStoreDirectory(name: String) -> URL {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("CPasteSnapshots-\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        return directory
    }

    private static func demoImageData() -> Data? {
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

private enum SnapshotError: Error {
    case liquidGlassUnavailable
    case unknownScene(String)
    case windowNotFound
    case pngEncodingFailed
}

private final class SnapshotWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
