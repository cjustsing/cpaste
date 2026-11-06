import CPasteCore
import Foundation

private final class RemovalFaultFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var deniedWrite: String?
    private var deniedAttributes: String?
    private var blockedWrite: String?
    private var blockedAttributes: String?
    private var didBlock = false
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func denyWrite(_ fragment: String?) { lock.lock(); deniedWrite = fragment; lock.unlock() }
    func denyAttributes(_ path: String?) { lock.lock(); deniedAttributes = path; lock.unlock() }
    func blockWrite(_ fragment: String) { lock.lock(); blockedWrite = fragment; didBlock = false; lock.unlock() }
    func blockAttributes(_ path: String) { lock.lock(); blockedAttributes = path; didBlock = false; lock.unlock() }

    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        lock.lock()
        let denied = deniedWrite.map { path.contains($0) } ?? false
        let wait = !didBlock && (blockedWrite.map { path.contains($0) } ?? false)
        if wait { didBlock = true }
        lock.unlock()
        if wait { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        return denied ? false : super.createFile(atPath: path, contents: data, attributes: attr)
    }
    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        lock.lock()
        let denied = deniedAttributes == path
        let wait = !didBlock && blockedAttributes == path
        if wait { didBlock = true }
        lock.unlock()
        if wait { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        if denied { throw CocoaError(.fileWriteNoPermission) }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}

private func awaitRemovalCapture(_ message: String, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
    check(condition(), message)
}

func testExplicitClearRemovesOnlyUnpinnedFailedRaw() {
    for pinned in [false, true] {
        let directory = makeTemporaryDirectory()
        let manager = RemovalFaultFileManager()
        let store = ClipboardStore(storageDirectory: directory, fileManager: manager)
        defer { manager.denyWrite(nil); manager.denyAttributes(nil); _ = store.save(); try? FileManager.default.removeItem(at: directory) }
        let raw = CapturedClipboardContent(kind: .image, title: "Failed raw", imagePNGData: Data([1, 2, 3]), contentHash: "removal-raw")
        if pinned {
            store.insertCaptured(raw)
            store.togglePinned(store.items[0].id)
            check(store.save(), "pinned removal fixture must save")
            manager.denyAttributes(store.blobDirectory.appendingPathComponent("removal-raw.png").path)
        } else { manager.denyWrite(".removal-raw.png-") }
        store.insertCaptured(raw)
        check(store.hasPendingCaptureFailure && store.hasUnpinnedHistory == !pinned,
              "clear availability must include failed raw, excluding content whose visible row is pinned")
        store.clearUnpinned()
        check(store.hasPendingCaptureFailure == pinned && !store.hasUnpinnedHistory,
              "confirmed clear must remove unpinned raw but preserve a failed payload for pinned content")
        manager.denyWrite(nil)
        manager.denyAttributes(nil)
        check(store.retrySaving() && store.items.count == (pinned ? 1 : 0),
              "retry must not resurrect explicitly cleared raw or lose pinned raw")
        if pinned { check(store.items[0].isPinned, "pinned retry must retain the pin") }
    }
}

func testExplicitDeleteRemovesMatchingFailedRaw() {
    let directory = makeTemporaryDirectory()
    let manager = RemovalFaultFileManager()
    let store = ClipboardStore(storageDirectory: directory, fileManager: manager)
    defer { manager.denyAttributes(nil); _ = store.save(); try? FileManager.default.removeItem(at: directory) }
    let raw = CapturedClipboardContent(kind: .image, title: "Delete fixture", imagePNGData: Data([1, 2, 3]), contentHash: "delete-raw")
    store.insertCaptured(raw)
    check(store.save(), "delete fixture must first save")
    let id = store.items[0].id
    manager.denyAttributes(store.blobDirectory.appendingPathComponent("delete-raw.png").path)
    store.insertCaptured(raw)
    check(store.hasPendingCaptureFailure, "duplicate failure must retain its raw data")
    store.delete(id)
    manager.denyAttributes(nil)
    check(!store.hasPendingCaptureFailure && store.retrySaving() && store.items.isEmpty,
          "deleting a row must invalidate its older failed raw instead of resurrecting it on retry")
}

func testClearBoundaryDiscardsInFlightOldCaptureAndAllowsNewCopy() {
    let directory = makeTemporaryDirectory()
    let manager = RemovalFaultFileManager()
    let store = ClipboardStore(storageDirectory: directory, fileManager: manager)
    defer { manager.release.signal(); _ = store.save(); try? FileManager.default.removeItem(at: directory) }
    store.insertCaptured(.init(kind: .text, title: "Visible", text: "Visible", contentHash: "clear-visible"))
    check(store.save(), "clear boundary fixture must start from visible history")
    let raw = CapturedClipboardContent(kind: .image, title: "In flight", imagePNGData: Data([5, 6, 7]), contentHash: "clear-inflight")
    manager.blockWrite(".clear-inflight.png-")
    var result: String?
    store.insertCapturedAsync(raw, capturedAt: Date(), shouldCommit: { true }, completion: { result = String(describing: $0) })
    check(manager.entered.wait(timeout: .now() + 2) == .success, "old capture must be in flight before clear")
    store.clearUnpinned()
    manager.release.signal()
    awaitRemovalCapture("cleared in-flight result must settle") { result != nil }
    check(result == "discarded" && store.items.isEmpty && store.save(), "clearing history must invalidate already observed unpinned work")
    result = nil
    let later = Date()
    store.insertCapturedAsync(raw, capturedAt: later, shouldCommit: { true }, completion: { result = String(describing: $0) })
    awaitRemovalCapture("new copy after clear must settle") { result != nil }
    check(result == "inserted" && store.items.first?.createdAt == later,
          "the same content genuinely copied after clear must remain eligible")
}

func testDeleteBoundaryDiscardsOldDuplicateAdmission() {
    let directory = makeTemporaryDirectory()
    let manager = RemovalFaultFileManager()
    let store = ClipboardStore(storageDirectory: directory, fileManager: manager)
    defer { manager.release.signal(); _ = store.save(); try? FileManager.default.removeItem(at: directory) }
    let raw = CapturedClipboardContent(kind: .image, title: "Duplicate", imagePNGData: Data([9, 8, 7]), contentHash: "delete-inflight")
    store.insertCaptured(raw)
    check(store.save(), "delete boundary fixture must save")
    let id = store.items[0].id
    manager.blockAttributes(store.blobDirectory.appendingPathComponent("delete-inflight.png").path)
    var result: String?
    store.insertCapturedAsync(raw, capturedAt: Date(), shouldCommit: { true }, completion: { result = String(describing: $0) })
    check(manager.entered.wait(timeout: .now() + 2) == .success, "duplicate must be preparing before deletion")
    store.delete(id)
    manager.release.signal()
    awaitRemovalCapture("deleted duplicate must settle") { result != nil }
    check(result == "discarded" && store.items.isEmpty && store.save(), "a delayed duplicate must not recreate an explicitly deleted row")
}

func testAutomaticTrimmingRetainsAcceptedFailedRaw() {
    let directory = makeTemporaryDirectory()
    let manager = RemovalFaultFileManager()
    let store = ClipboardStore(storageDirectory: directory, maxItems: 1, fileManager: manager)
    defer { manager.denyAttributes(nil); _ = store.save(); try? FileManager.default.removeItem(at: directory) }
    let raw = CapturedClipboardContent(kind: .image, title: "Accepted", imagePNGData: Data([1, 3, 5]), contentHash: "trim-raw")
    store.insertCaptured(raw)
    check(store.save(), "automatic trim fixture must save")
    manager.denyAttributes(store.blobDirectory.appendingPathComponent("trim-raw.png").path)
    store.insertCaptured(raw)
    check(store.hasPendingCaptureFailure, "the accepted duplicate failure must be buffered")
    store.insertCaptured(.init(kind: .text, title: "Newer", text: "Newer", contentHash: "trim-newer"))
    check(store.items.count == 1 && store.items[0].contentHash == "trim-newer" && store.hasPendingCaptureFailure,
          "normal capacity trimming must not discard an accepted failed capture")
    manager.denyAttributes(nil)
    check(store.save() && store.items.count == 2 && store.items.contains { $0.contentHash == "trim-raw" },
          "failure replay must preserve both accepted items without another implicit capacity trim")
}
