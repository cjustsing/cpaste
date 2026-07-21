import AppKit
import Foundation

public final class ClipboardMonitor {
    public var isPaused = false

    private let pasteboard: NSPasteboard
    private let store: ClipboardStore
    private var timer: Timer?
    private var lastChangeCount: Int
    private var suppressedChangeCounts = Set<Int>()

    public init(pasteboard: NSPasteboard = .general, store: ClipboardStore) {
        self.pasteboard = pasteboard
        self.store = store
        self.lastChangeCount = pasteboard.changeCount
    }

    public func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func suppressCurrentChange() {
        suppressedChangeCounts.insert(pasteboard.changeCount)
        if suppressedChangeCounts.count > 8 {
            suppressedChangeCounts.remove(suppressedChangeCounts.min() ?? pasteboard.changeCount)
        }
    }

    private func tick() {
        guard !isPaused else {
            lastChangeCount = pasteboard.changeCount
            return
        }

        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else {
            return
        }
        lastChangeCount = changeCount

        if suppressedChangeCounts.remove(changeCount) != nil {
            return
        }

        let sourceApplication = NSWorkspace.shared.frontmostApplication
        let isExternalSource = sourceApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier
        let sourceAppName = isExternalSource ? sourceApplication?.localizedName : nil
        let sourceBundleIdentifier = isExternalSource ? sourceApplication?.bundleIdentifier : nil

        if var captured = PasteboardReader.read(
            from: pasteboard,
            sourceBundleIdentifier: sourceBundleIdentifier
        ) {
            captured.sourceAppName = sourceAppName
            captured.sourceBundleIdentifier = sourceBundleIdentifier
            store.insertCaptured(captured)
        }
    }
}
