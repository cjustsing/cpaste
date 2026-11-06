import CPasteCore
import Combine
import Foundation

private final class PreparedFaultFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var denied: String?
    private var blocked: String?
    private var didBlock = false
    private var mainWriter = false
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func deny(_ fragment: String?) { lock.lock(); denied = fragment; lock.unlock() }
    func block(_ fragment: String) { lock.lock(); blocked = fragment; didBlock = false; lock.unlock() }
    var writerWasMain: Bool { lock.lock(); defer { lock.unlock() }; return mainWriter }

    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        lock.lock()
        let refuse = denied.map { path.contains($0) } ?? false
        let wait = !didBlock && (blocked.map { path.contains($0) } ?? false)
        if wait { didBlock = true; mainWriter = Thread.isMainThread }
        lock.unlock()
        if wait { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        return refuse ? false : super.createFile(atPath: path, contents: data, attributes: attr)
    }
}

private func waitForPreparedCapture(_ message: String, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
    check(condition(), message)
}

func testPreparedCaptureStagesOffMainAndRequiresMainAdmission() {
    let directory = makeTemporaryDirectory()
    let manager = PreparedFaultFileManager()
    let store = ClipboardStore(storageDirectory: directory, fileManager: manager)
    defer { manager.release.signal(); _ = store.save(); try? FileManager.default.removeItem(at: directory) }
    manager.block(".prepared-image.png-")
    let observed = Date(timeIntervalSince1970: 1_700_000_000)
    let bytes = Data([0, 1, 2, 3, 255])
    var result: String?
    var admissionWasMain = false
    var completionWasMain = false
    store.insertCapturedAsync(
        .init(kind: .image, title: "Prepared", imagePNGData: bytes, contentHash: "prepared-image"),
        capturedAt: observed,
        shouldCommit: { admissionWasMain = Thread.isMainThread; return true },
        completion: { completionWasMain = Thread.isMainThread; result = String(describing: $0) }
    )
    check(manager.entered.wait(timeout: .now() + 2) == .success, "capture staging must reach its controlled worker write")
    check(!manager.writerWasMain && store.items.isEmpty, "attachment staging must neither run nor publish a model on main")
    check(store.hasPendingCaptureWork && !store.save(), "a durability barrier must not claim success while main admission remains pending")
    manager.release.signal()
    waitForPreparedCapture("the prepared result must be admitted on main") { result != nil }
    check(result == "inserted" && admissionWasMain && completionWasMain, "admission and completion must run on main exactly after preparation")
    check(!store.hasPendingCaptureWork && store.items.first?.createdAt == observed, "observed capture time must survive staging")
    check(store.save(), "an admitted capture must be durable after its explicit barrier")
    check((try! Data(contentsOf: store.blobDirectory.appendingPathComponent("prepared-image.png"))) == bytes,
          "preparation must preserve the original attachment bytes")
}

func testCancelledPreparationDoesNotRetainFailureOrOrphan() {
    for shouldFail in [false, true] {
        let directory = makeTemporaryDirectory()
        let manager = PreparedFaultFileManager()
        let store = ClipboardStore(storageDirectory: directory, fileManager: manager)
        defer { manager.deny(nil); _ = store.save(); try? FileManager.default.removeItem(at: directory) }
        if shouldFail { manager.deny(".cancelled-image.png-") }
        var result: String?
        store.insertCapturedAsync(
            .init(kind: .image, title: "Cancelled", imagePNGData: Data([1, 2, 3]), contentHash: "cancelled-image"),
            capturedAt: Date(), shouldCommit: { false },
            completion: { result = String(describing: $0) }
        )
        waitForPreparedCapture("cancelled staging must complete") { result != nil }
        check(result == "discarded" && store.items.isEmpty && !store.hasPendingCaptureFailure,
              "an ineligible success or failure must never enter history or its retry buffer")
        manager.deny(nil)
        check(store.save(), "cancelled work must not prevent later durability")
        check(!FileManager.default.fileExists(atPath: store.blobDirectory.appendingPathComponent("cancelled-image.png").path),
              "the unused cancelled lease must eventually be collected")
    }
}

func testPreparedLeaseSurvivesOlderSnapshotCollection() {
    let directory = makeTemporaryDirectory()
    let store = ClipboardStore(storageDirectory: directory)
    defer { _ = store.save(); try? FileManager.default.removeItem(at: directory) }
    store.insertCaptured(.init(kind: .text, title: "Base", text: "Base", contentHash: "lease-base"))
    check(store.save(), "lease fixture must start from a valid snapshot")
    var result: String?
    store.insertCapturedAsync(
        .init(kind: .image, title: "Slow older image", imagePNGData: Data([7, 8, 9]), contentHash: "leased-image"),
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000), shouldCommit: { true },
        completion: { result = String(describing: $0) }
    )
    // Each synchronous stage follows prior worker work, while main admission
    // for the image is deliberately withheld until we run the main loop.
    store.insertCaptured(.init(kind: .text, title: "First newer", text: "First newer", contentHash: "lease-first"))
    store.insertCaptured(.init(kind: .text, title: "Second newer", text: "Second newer", contentHash: "lease-second"))
    let blob = store.blobDirectory.appendingPathComponent("leased-image.png")
    check(FileManager.default.fileExists(atPath: blob.path), "collection by an older commit must retain the not-yet-admitted lease")
    waitForPreparedCapture("the retained image must be admitted") { result != nil }
    check(result == "inserted" && store.items.last?.contentHash == "leased-image",
          "an older observed capture must be inserted chronologically rather than ahead of later promotions")
    check(store.save() && FileManager.default.fileExists(atPath: blob.path), "enqueue and lease release must publish the new reference atomically")
}

func testOlderPreparedDuplicateCannotRollbackNewerState() {
    let directory = makeTemporaryDirectory()
    let store = ClipboardStore(storageDirectory: directory)
    defer { _ = store.save(); try? FileManager.default.removeItem(at: directory) }
    store.insertCaptured(.init(kind: .text, title: "New title", text: "Complete body", contentHash: "prepared-same", sourceAppName: "New source"))
    let before = store.items
    let revision = store.revision
    var result: String?
    store.insertCapturedAsync(
        .init(kind: .text, title: "Old title", text: "Complete body", contentHash: "prepared-same", sourceAppName: "Old source"),
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000), shouldCommit: { true },
        completion: { result = String(describing: $0) }
    )
    waitForPreparedCapture("an obsolete duplicate must finish") { result != nil }
    check(result == "discarded" && store.items == before && store.revision == revision,
          "an older duplicate may only release its lease, never roll back time, title, source or body")
}

func testAcceptedFailedCaptureReplaysAfterAdmissionEnds() {
    for useExplicitRetry in [false, true] {
        let directory = makeTemporaryDirectory()
        let manager = PreparedFaultFileManager()
        let store = ClipboardStore(storageDirectory: directory, fileManager: manager)
        defer { manager.deny(nil); _ = store.save(); try? FileManager.default.removeItem(at: directory) }
        manager.deny(".retry-image.png-")
        let bytes = Data([10, 11, 12, 255])
        let observed = Date(timeIntervalSince1970: 1_700_000_000)
        var eligible = true
        var decisions = 0
        var result: String?
        store.insertCapturedAsync(
            .init(kind: .image, title: "Pending raw", imagePNGData: bytes, contentHash: "retry-image"),
            capturedAt: observed, shouldCommit: { decisions += 1; return eligible },
            completion: { result = String(describing: $0) }
        )
        waitForPreparedCapture("an accepted preparation failure must complete") { result != nil }
        check(result == "failed" && store.hasPendingCaptureFailure && !store.save(),
              "an accepted failed payload must block false durability success")
        eligible = false
        manager.deny(nil)
        let saved = useExplicitRetry ? store.retrySaving() : store.save()
        check(saved && !store.hasPendingCaptureFailure && decisions == 1,
              "once accepted, retry must replay raw data without rechecking an expired admission closure")
        check(store.items.first?.createdAt == observed && store.items.first?.contentHash == "retry-image",
              "replay must preserve the original capture timestamp and identity")
        check((try! Data(contentsOf: store.blobDirectory.appendingPathComponent("retry-image.png"))) == bytes,
              "successful replay must really restore the entire attachment, not just clear its error")
    }
}

func testReadOnlyPreparationCancellationRetainsUnknownDependencies() {
    let directory = makeTemporaryDirectory()
    let blobs = directory.appendingPathComponent("Blobs", isDirectory: true)
    try! FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: directory.appendingPathComponent("history.json"), withIntermediateDirectories: true)
    let original = blobs.appendingPathComponent("unknown-original.png")
    let bytes = Data([100, 101, 102])
    try! bytes.write(to: original)
    let store = ClipboardStore(storageDirectory: directory)
    defer { _ = store.save(); try? FileManager.default.removeItem(at: directory) }
    var completed = false
    store.insertCapturedAsync(
        .init(kind: .image, title: "Cancelled", imagePNGData: Data([1]), contentHash: "readonly-cancelled"),
        capturedAt: Date(), shouldCommit: { false }, completion: { _ in completed = true }
    )
    waitForPreparedCapture("read-only cancellation must complete") { completed }
    check(!store.save(), "unknown original history must remain protected")
    check((try? Data(contentsOf: original)) == bytes,
          "a cancelled lease must never collect unknown dependencies of an unreadable history")
}

func testPendingCaptureWorkClearsOnlyAfterMainAdmission() {
    for outcome in ["inserted", "discarded", "failed"] {
        let directory = makeTemporaryDirectory()
        let manager = PreparedFaultFileManager()
        let store = ClipboardStore(storageDirectory: directory, fileManager: manager)
        if outcome == "failed" { manager.deny(".pending-order.png-") }
        var admissionDecided = false
        var observedIdle = false
        var completed = false
        let subscription = store.$hasPendingCaptureWork.dropFirst().filter { !$0 }.sink { _ in
            observedIdle = true
            check(admissionDecided, "capture pending must remain true until main admission has made its decision")
            switch outcome {
            case "inserted":
                check(store.items.first?.contentHash == "pending-order" && !store.hasPendingCaptureFailure,
                      "the idle notification must follow insertion of the prepared model")
            case "failed":
                check(store.items.isEmpty && store.hasPendingCaptureFailure && store.storageIssue == .saveFailed,
                      "the idle notification must follow retention and reporting of an accepted failed payload")
            default:
                check(store.items.isEmpty && !store.hasPendingCaptureFailure,
                      "the idle notification must follow an explicit discarded admission")
            }
        }
        defer {
            subscription.cancel()
            manager.deny(nil)
            _ = store.save()
            try? FileManager.default.removeItem(at: directory)
        }
        store.insertCapturedAsync(
            .init(kind: .image, title: "Pending order", imagePNGData: Data([1, 4, 9]), contentHash: "pending-order"),
            capturedAt: Date(),
            shouldCommit: { admissionDecided = true; return outcome != "discarded" },
            completion: { result in
                check(String(describing: result) == outcome && observedIdle && !store.hasPendingCaptureWork,
                      "completion must observe its final decision and a cleared pending flag")
                manager.deny(nil)
                check(store.save(), "a completion callback must be able to persist its admitted or replayed capture")
                completed = true
            }
        )
        waitForPreparedCapture("the decided capture must complete after its idle notification") { completed }
    }
}
