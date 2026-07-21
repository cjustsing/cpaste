import AppKit

let app = NSApplication.shared

if let snapshotDirectory = SnapshotRenderer.snapshotDirectoryArgument() {
    app.setActivationPolicy(.accessory)
    do {
        try SnapshotRenderer.renderAll(to: snapshotDirectory)
        exit(0)
    } catch {
        fputs("Snapshot rendering failed: \(error)\n", stderr)
        exit(1)
    }
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
