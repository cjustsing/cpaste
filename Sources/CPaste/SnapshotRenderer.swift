import AppKit
import CPasteCore
import SwiftUI

enum SnapshotRenderer {
    static func snapshotDirectoryArgument() -> URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--snapshot-dir"),
              arguments.indices.contains(index + 1)
        else {
            return nil
        }

        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    static func renderAll(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try renderPanel(
            name: "01-timeline-overview.png",
            size: NSSize(width: 1_180, height: 440),
            store: makeDemoStore(name: "full"),
            appState: makeReadyState(),
            inspectorPresented: false,
            to: directory
        )

        try renderPanel(
            name: "02-timeline-inspector.png",
            size: NSSize(width: 1_180, height: 583),
            store: makeDemoStore(name: "inspector"),
            appState: makeReadyState(),
            inspectorPresented: true,
            to: directory
        )

        try renderPanel(
            name: "03-compact-timeline.png",
            size: NSSize(width: 680, height: 440),
            store: makeDemoStore(name: "compact"),
            appState: makeReadyState(),
            inspectorPresented: false,
            to: directory
        )

        let emptyState = AppState(themeStyle: .standard)
        emptyState.statusMessage = CPasteL10n.text("就绪", "Ready")
        try renderPanel(
            name: "04-empty-timeline.png",
            size: NSSize(width: 680, height: 420),
            store: ClipboardStore(storageDirectory: temporaryStoreDirectory(name: "empty")),
            appState: emptyState,
            inspectorPresented: false,
            to: directory
        )

        try renderSettings(
            name: "05-settings.png",
            store: makeDemoStore(name: "settings"),
            appState: makeReadyState(),
            to: directory
        )

        try renderSettings(
            name: "07-settings-about.png",
            store: makeDemoStore(name: "settings-about"),
            appState: makeReadyState(),
            initialSection: .about,
            to: directory
        )

        try renderSupport(
            name: "06-support.png",
            appState: makeReadyState(),
            to: directory
        )
    }

    private static func renderPanel(
        name: String,
        size: NSSize,
        store: ClipboardStore,
        appState: AppState,
        inspectorPresented: Bool,
        to directory: URL
    ) throws {
        let actions = makeActions(store: store, appState: appState)
        let view = HistoryPanelView(
            store: store,
            appState: appState,
            actions: actions,
            initialInspectorPresented: inspectorPresented
        )
        .frame(width: size.width, height: size.height)
        .preferredColorScheme(.dark)

        try render(view, size: size, to: directory.appendingPathComponent(name, isDirectory: false))
    }

    private static func renderSettings(
        name: String,
        store: ClipboardStore,
        appState: AppState,
        initialSection: SettingsSection = .general,
        to directory: URL
    ) throws {
        let size = NSSize(width: 560, height: 390)
        let view = CPasteSettingsView(
            store: store,
            appState: appState,
            actions: makeActions(store: store, appState: appState),
            initialSection: initialSection
        )
        .preferredColorScheme(.dark)

        try render(view, size: size, to: directory.appendingPathComponent(name, isDirectory: false))
    }

    private static func renderSupport(
        name: String,
        appState: AppState,
        to directory: URL
    ) throws {
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

        try render(view, size: size, to: directory.appendingPathComponent(name, isDirectory: false))
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

    private static func render<V: View>(_ view: V, size: NSSize, to url: URL) throws {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hostingView
        window.setFrame(NSRect(origin: .zero, size: size), display: true)
        hostingView.layoutSubtreeIfNeeded()

        // Let asynchronous thumbnail decoding publish before capturing the view.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw SnapshotError.bitmapCreationFailed
        }

        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.pngEncodingFailed
        }

        try data.write(to: url, options: .atomic)
        window.close()
    }

    private static func makeReadyState() -> AppState {
        // Native Liquid Glass relies on an onscreen compositor and renders as an
        // opaque layer in NSView.cacheDisplay. Keep documentation snapshots stable.
        let state = AppState(themeStyle: .standard)
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
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CPasteSnapshots-\(name)-\(UUID().uuidString)", isDirectory: true)
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
    case bitmapCreationFailed
    case pngEncodingFailed
}
