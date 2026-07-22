import AppKit

let app = NSApplication.shared

if let snapshotDirectory = SnapshotRenderer.snapshotDirectoryArgument() {
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        do {
            try await SnapshotRenderer.renderAll(to: snapshotDirectory)
            exit(0)
        } catch {
            fputs("Snapshot rendering failed: \(error)\n", stderr)
            exit(1)
        }
    }
    app.run()
}

if let snapshotPreview = SnapshotRenderer.snapshotPreviewArgument() {
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        do {
            try SnapshotRenderer.showPreview(named: snapshotPreview)
        } catch {
            fputs("Snapshot preview failed: \(error)\n", stderr)
            exit(1)
        }
    }
    app.run()
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
