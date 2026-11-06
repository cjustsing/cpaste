import Foundation

// The runner inserts production lifecycle methods. All effects remain local.
enum ShutdownScheduler {
    static var jobs: [() -> Void] = []
    static let main = Queue()
    struct Queue {
        func async(execute: @escaping () -> Void) { ShutdownScheduler.jobs.append(execute) }
    }
    static func drain() {
        var budget = 20
        while !jobs.isEmpty && budget > 0 { jobs.removeFirst()(); budget -= 1 }
        precondition(jobs.isEmpty)
    }
}
typealias DispatchQueue = ShutdownScheduler
final class NSApplication {
    enum TerminateReply { case terminateNow, terminateCancel, terminateLater }
    var replies: [Bool] = []
    func reply(toApplicationShouldTerminate answer: Bool) { replies.append(answer) }
}
enum CPasteL10n {
    static func text(_ chinese: String, _ english: String) -> String { english }
}
struct ShutdownIssue { var localizedMessage = "Storage fixture failed" }
final class ShutdownStore {
    var saveSucceeds = true
    var saveCalls = 0
    var retryCalls = 0
    var storageIssue: ShutdownIssue?
    func save() -> Bool { saveCalls += 1; return saveSucceeds }
    func retrySaving() -> Bool { retryCalls += 1; return saveSucceeds }
}
final class ShutdownMonitor {
    var callbacks: [() -> Void] = []
    var starts = 0
    func finishPendingCaptures(completion: @escaping (Bool) -> Void) { callbacks.append { completion(true) } }
    func start() { starts += 1 }
    func complete() {
        precondition(!callbacks.isEmpty)
        let callback = callbacks.removeFirst()
        ShutdownScheduler.jobs.append(callback)
    }
}
final class ShutdownState {
    var storageWarning: String?
    var statusMessage = ""
    var isStorageRetrying = false
}
final class ShutdownPasteDelivery { func cancel() {} }
final class ShutdownHarness {
    let store = ShutdownStore()
    let monitor = ShutdownMonitor()
    let appState = ShutdownState()
    let pasteDelivery = ShutdownPasteDelivery()
    var pendingTermination: NSApplication?
    var shownPanels = 0
    func showPanel() { shownPanels += 1 }
    func startRetry() { retryStorage() }
    // {{LIFECYCLE_METHODS}}
}
func shutdownCheck(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("Shutdown check failed: \(message)\n", stderr)
        exit(1)
    }
}
do {
    ShutdownScheduler.jobs = []
    let harness = ShutdownHarness()
    let app = NSApplication()
    let reply = harness.applicationShouldTerminate(app)
    shutdownCheck(reply == .terminateLater, "quit must wait for accepted background captures before saving or exiting")
    shutdownCheck(harness.store.saveCalls == 0 && app.replies.isEmpty, "save must not run before the capture drain publishes its last model update")
    _ = harness.applicationShouldTerminate(app)
    shutdownCheck(harness.monitor.callbacks.count == 1, "repeated quit requests must share one capture drain")
    harness.monitor.complete()
    ShutdownScheduler.drain()
    shutdownCheck(harness.store.saveCalls == 1 && app.replies == [true], "a completed capture drain must save once and approve quit once")
    shutdownCheck(harness.monitor.starts == 0, "successful quit must not restart capture")
}
do {
    ShutdownScheduler.jobs = []
    let harness = ShutdownHarness()
    harness.store.saveSucceeds = false
    let app = NSApplication()
    _ = harness.applicationShouldTerminate(app)
    harness.monitor.complete()
    ShutdownScheduler.drain()
    shutdownCheck(app.replies == [false] && harness.monitor.starts == 1, "failed durability must reject quit and restore capture")
    shutdownCheck(harness.shownPanels == 1 && harness.appState.storageWarning != nil, "failed quit must keep a visible recovery path")
    shutdownCheck(harness.pendingTermination == nil, "failed quit must allow a later retry")
}
do {
    ShutdownScheduler.jobs = []
    let harness = ShutdownHarness()
    let app = NSApplication()
    harness.startRetry()
    shutdownCheck(harness.appState.isStorageRetrying && harness.monitor.callbacks.count == 1, "storage retry must drain accepted captures first")
    _ = harness.applicationShouldTerminate(app)
    shutdownCheck(harness.monitor.callbacks.count == 1, "quit during storage retry must wait for that retry instead of racing its drain")
    harness.monitor.complete()
    ShutdownScheduler.drain()
    shutdownCheck(harness.store.retryCalls == 1 && !harness.appState.isStorageRetrying, "retry must finish against the latest drained history")
    shutdownCheck(harness.monitor.starts == 0 && harness.monitor.callbacks.count == 1, "pending quit must drain without restarting capture between retry and quit")
    harness.monitor.complete()
    ShutdownScheduler.drain()
    shutdownCheck(app.replies == [true] && harness.store.saveCalls == 1, "quit following retry must await its final durability barrier")
}
print("Capture shutdown and retry lifecycle checks passed")
