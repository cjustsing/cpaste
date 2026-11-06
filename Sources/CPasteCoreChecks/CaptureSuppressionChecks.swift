import AppKit
import CPasteCore
import Foundation

func testCaptureSuppressionDoesNotConsumeANewerExternalCopy() {
    let directory = makeTemporaryDirectory()
    let pasteboard = NSPasteboard.withUniqueName()
    let store = ClipboardStore(storageDirectory: directory)
    let monitor = ClipboardMonitor(pasteboard: pasteboard, store: store)
    defer {
        monitor.stop()
        pasteboard.releaseGlobally()
        _ = store.save()
        try? FileManager.default.removeItem(at: directory)
    }
    pasteboard.clearContents()
    check(pasteboard.setString("our copy", forType: .string), "own copy fixture must be writable")
    let copiedVersion = pasteboard.changeCount
    pasteboard.clearContents()
    check(pasteboard.setString("later external copy", forType: .string), "external copy fixture must be writable")
    check(pasteboard.changeCount != copiedVersion, "external copy must have a newer generation")
    monitor.suppressChange(copiedVersion)
    monitor.start()
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    check(store.items.count == 1 && store.items[0].text == "later external copy",
          "suppressing our published generation must not discard a later external copy")
}
