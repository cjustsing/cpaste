import AppKit
import CPasteCore
import Foundation

func testPauseResumeDoesNotCaptureChangesBetweenTimerTicks() {
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
    monitor.start()
    monitor.isPaused = true
    let beforePausedCopy = pasteboard.changeCount
    pasteboard.clearContents()
    check(pasteboard.setString("private fixture copied while paused", forType: .string), "paused fixture should be writable")
    check(pasteboard.changeCount != beforePausedCopy, "paused fixture must advance the pasteboard generation")
    monitor.isPaused = false
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    check(store.items.isEmpty, "resuming before the next poll must not capture content copied while paused")

    pasteboard.clearContents()
    check(pasteboard.setString("normal fixture copied after resume", forType: .string), "resumed fixture should be writable")
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    check(store.items.count == 1 && store.items[0].text == "normal fixture copied after resume",
          "new copies after resume must still be captured normally")

    monitor.isPaused = false
    pasteboard.clearContents()
    check(pasteboard.setString("new fixture before an unchanged enabled setting", forType: .string), "enabled fixture should be writable")
    monitor.isPaused = false
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    check(store.items.first?.text == "new fixture before an unchanged enabled setting",
          "assigning the same enabled state must not suppress a genuine new copy")
}
