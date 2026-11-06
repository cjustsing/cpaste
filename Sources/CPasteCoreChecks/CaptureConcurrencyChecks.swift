import AppKit
import CPasteCore
import Foundation

private final class CaptureStageGate: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let blocking: Bool
    private var entered = false
    private var released = false
    private var denied = false
    private var observedMainThread = false

    init(blocking: Bool = true) {
        self.blocking = blocking
        super.init()
    }

    var hasEntered: Bool {
        lock.lock(); defer { lock.unlock() }
        return entered
    }
    var wasMainThread: Bool {
        lock.lock(); defer { lock.unlock() }
        return observedMainThread
    }
    func denyImages(_ value: Bool) {
        lock.lock(); denied = value; lock.unlock()
    }
    func release() {
        lock.lock()
        let shouldRelease = !released
        released = true
        lock.unlock()
        if shouldRelease { semaphore.signal() }
    }

    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        if path.contains(".png-") {
            lock.lock()
            let first = !entered
            entered = true
            observedMainThread = observedMainThread || Thread.isMainThread
            let shouldDeny = denied
            lock.unlock()
            if first && blocking { _ = semaphore.wait(timeout: .now() + 6) }
            if shouldDeny { return false }
        }
        return super.createFile(atPath: path, contents: data, attributes: attr)
    }
}

private func captureConcurrencyPNG(width: Int = 8) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 6, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
    )!
    for offset in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) {
        bitmap.bitmapData![offset] = UInt8([64, 128, 160, 255][offset % 4])
    }
    return bitmap.representation(using: .png, properties: [:])!
}

@discardableResult
private func awaitCapture(_ condition: () -> Bool, timeout: TimeInterval = 2.5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
}

private final class CaptureFixture {
    let directory = makeTemporaryDirectory()
    let pasteboard = NSPasteboard.withUniqueName()
    let gate: CaptureStageGate
    let store: ClipboardStore
    let monitor: ClipboardMonitor

    init(blocking: Bool = true) {
        gate = CaptureStageGate(blocking: blocking)
        store = ClipboardStore(storageDirectory: directory, fileManager: gate)
        monitor = ClipboardMonitor(pasteboard: pasteboard, store: store)
        monitor.start()
    }
    func publishPNG() {
        pasteboard.clearContents()
        check(pasteboard.setData(captureConcurrencyPNG(), forType: .png), "the isolated PNG fixture must publish")
    }
    func publishText(_ text: String) {
        pasteboard.clearContents()
        check(pasteboard.setString(text, forType: .string), "the isolated text fixture must publish")
    }
    func close() {
        monitor.stop()
        gate.release()
        var finished = false
        monitor.finishPendingCaptures { _ in finished = true }
        _ = awaitCapture({ finished }, timeout: 6)
        _ = store.save()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }
}

func testCaptureFinishIsAlwaysAsyncAndDrainsAcceptedStage() {
    let empty = CaptureFixture()
    var emptyFinished = false
    var emptyWasMain = false
    empty.monitor.finishPendingCaptures { result in emptyWasMain = Thread.isMainThread; emptyFinished = result }
    let wasSynchronous = emptyFinished
    let emptyCompleted = awaitCapture { emptyFinished }
    empty.close()
    check(!wasSynchronous && emptyCompleted && emptyWasMain, "even empty finish must complete asynchronously on main")

    let fixture = CaptureFixture()
    fixture.publishPNG()
    let entered = awaitCapture { fixture.gate.hasEntered }
    var finished = false
    var succeeded = false
    fixture.monitor.finishPendingCaptures { result in succeeded = result; finished = true }
    var heartbeat = false
    DispatchQueue.main.async { heartbeat = true }
    let responsive = awaitCapture({ heartbeat }, timeout: 0.2)
    let finishedWhileBlocked = finished
    fixture.gate.release()
    let completed = awaitCapture { finished }
    let count = fixture.store.items.count
    let wroteOnMain = fixture.gate.wasMainThread
    fixture.close()
    check(entered && responsive && !wroteOnMain, "a blocked image stage must leave the main queue responsive")
    check(!finishedWhileBlocked && completed && succeeded && count == 1, "finish must await the accepted stage and its main model publication")
}

func testCaptureEpochAndSuppressionDiscardInFlightStages() {
    for action in ["pause", "stop", "restart", "suppress"] {
        let fixture = CaptureFixture()
        fixture.publishPNG()
        let entered = awaitCapture { fixture.gate.hasEntered }
        switch action {
        case "pause": fixture.monitor.isPaused = true
        case "stop": fixture.monitor.stop()
        case "restart": fixture.monitor.start()
        default:
            fixture.monitor.suppressChange(fixture.pasteboard.changeCount)
            // Evicting the old generation from the small suppression cache
            // must not reinstate an already cancelled in-flight capture.
            for offset in 1...10 { fixture.monitor.suppressChange(fixture.pasteboard.changeCount + offset) }
        }
        var finished = false
        fixture.monitor.finishPendingCaptures { _ in finished = true }
        fixture.gate.release()
        let completed = awaitCapture { finished }
        let empty = fixture.store.items.isEmpty
        let noFailure = !fixture.store.hasPendingCaptureFailure
        let saved = fixture.store.save()
        let blobs = (try? FileManager.default.contentsOfDirectory(atPath: fixture.store.blobDirectory.path)) ?? []
        fixture.close()
        check(entered && completed && empty && noFailure, "pause/stop/restart/suppression must discard in-flight stage decisions")
        check(saved && blobs.isEmpty, "discarded stage leases must be released and collected without becoming retry failures")
    }
}

func testStableSnapshotSurvivesNewerClipboardAndRestartsUnreadVersion() {
    let fixture = CaptureFixture()
    fixture.publishPNG()
    let entered = awaitCapture { fixture.gate.hasEntered }
    fixture.publishText("newer clipboard while image A is staging")
    var finished = false
    var succeeded = false
    fixture.monitor.finishPendingCaptures { result in succeeded = result; finished = true }
    fixture.gate.release()
    let completed = awaitCapture { finished }
    let retainedA = fixture.store.items.count == 1 && fixture.store.items[0].kind == .image
    fixture.monitor.start()
    let readB = awaitCapture { fixture.store.items.count == 2 }
    var restartedFinished = false
    fixture.monitor.finishPendingCaptures { _ in restartedFinished = true }
    let restartedCompleted = awaitCapture { restartedFinished }
    let ordered = fixture.store.items.first?.text == "newer clipboard while image A is staging" && fixture.store.items.last?.kind == .image
    fixture.close()
    check(entered && completed && succeeded && retainedA, "a stable accepted A must not be revoked by a later clipboard B")
    check(readB && restartedCompleted && ordered, "finish/restart must not acknowledge an unread B or reorder accepted copies")
}

private final class CountedCaptureProvider: NSObject, NSPasteboardItemDataProvider {
    let data = captureConcurrencyPNG(width: 12)
    private(set) var requests = 0

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        requests += 1
        item.setData(data, forType: type)
    }
}

func testCaptureBackpressureDoesNotReadAnotherLargeSnapshot() {
    let fixture = CaptureFixture()
    fixture.publishPNG()
    let entered = awaitCapture { fixture.gate.hasEntered }
    let provider = CountedCaptureProvider()
    let item = NSPasteboardItem()
    check(item.setDataProvider(provider, forTypes: [.png]), "the deferred named image provider must initialize")
    fixture.pasteboard.clearContents()
    check(fixture.pasteboard.writeObjects([item]), "the deferred named image must publish")
    let initiallyDeferred = provider.requests == 0
    RunLoop.current.run(until: Date().addingTimeInterval(0.75))
    let deferredWhileBusy = provider.requests == 0
    fixture.gate.release()
    let bothCaptured = awaitCapture { fixture.store.items.count == 2 }
    var finished = false
    fixture.monitor.finishPendingCaptures { _ in finished = true }
    let completed = awaitCapture { finished }
    let readAfterCapacityReturned = provider.requests > 0
    fixture.close()
    check(entered && initiallyDeferred, "the second image must be a genuine deferred fixture")
    check(deferredWhileBusy, "a busy pipeline must retain only an unread version token, not another large Data snapshot")
    check(bothCaptured && completed && readAfterCapacityReturned, "the latest unread generation must be read when capacity returns")
}

func testCaptureFailureRetryPreservesAcceptedAndUnreadCopies() {
    let fixture = CaptureFixture(blocking: false)
    fixture.gate.denyImages(true)
    fixture.publishPNG()
    let failed = awaitCapture { fixture.store.hasPendingCaptureFailure }
    fixture.publishText("unread B while A awaits storage retry")
    RunLoop.current.run(until: Date().addingTimeInterval(0.75))
    let heldAdmission = fixture.store.items.isEmpty
    var finished: Bool?
    fixture.monitor.finishPendingCaptures { finished = $0 }
    let completed = awaitCapture { finished != nil }
    fixture.gate.denyImages(false)
    let retried = fixture.store.retrySaving()
    let retainedA = fixture.store.items.count == 1 && fixture.store.items[0].kind == .image
    fixture.monitor.start()
    let readB = awaitCapture { fixture.store.items.count == 2 }
    var restartedFinished = false
    fixture.monitor.finishPendingCaptures { _ in restartedFinished = true }
    let restartedCompleted = awaitCapture { restartedFinished }
    fixture.close()
    check(failed && heldAdmission && completed && finished == false, "storage failure must stop new admission and finish without waiting on an unread copy")
    check(retried && retainedA && readB && restartedCompleted, "retry must preserve accepted A and allow the unread B after restart")
}

func runCaptureConcurrencyChecks() {
    testCaptureFinishIsAlwaysAsyncAndDrainsAcceptedStage()
    testCaptureEpochAndSuppressionDiscardInFlightStages()
    testStableSnapshotSurvivesNewerClipboardAndRestartsUnreadVersion()
    testCaptureBackpressureDoesNotReadAnotherLargeSnapshot()
    testCaptureFailureRetryPreservesAcceptedAndUnreadCopies()
    print("Capture pipeline concurrency checks passed")
}
