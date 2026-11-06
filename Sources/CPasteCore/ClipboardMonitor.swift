import AppKit
import Foundation

public final class ClipboardMonitor {
    public var isPaused = false {
        didSet {
            if oldValue != isPaused {
                // A pause/resume cycle can fit entirely between timer ticks.
                lastChangeCount = pasteboard.changeCount
                epoch &+= 1
                pendingGeneration = nil
                unavailableAttempts = 0
            }
        }
    }

    private let pasteboard: NSPasteboard
    private let store: ClipboardStore
    private var timer: Timer?
    private var lastChangeCount: Int
    private var suppressedChangeCounts = Set<Int>()
    private let captureQueue = DispatchQueue(label: "local.cpaste.capture", qos: .userInitiated)
    private var epoch: UInt64 = 0
    private var sequence: UInt64 = 0
    private var isRunning = false
    private var isFinishing = false
    private var pendingGeneration: Int?
    private var unavailableGeneration: Int?
    private var unavailableAttempts = 0
    private var inFlight: CaptureJob?
    private var cancelledJobID: UInt64?
    private var finishHandlers: [(Bool) -> Void] = []

    private struct CaptureJob {
        let id: UInt64
        let epoch: UInt64
        let generation: Int
        let capturedAt: Date
        let sourceAppName: String?
        let sourceBundleIdentifier: String?
        var snapshot: ClipboardSnapshot
        var excludedImageTypes: Set<String>
    }

    public init(pasteboard: NSPasteboard = .general, store: ClipboardStore) {
        self.pasteboard = pasteboard
        self.store = store
        self.lastChangeCount = pasteboard.changeCount
    }

    public func start() {
        stop()
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        isFinishing = false
        epoch &+= 1
        pendingGeneration = nil
        finishIfIdle()
    }

    /// Freeze admission and finish only representations already copied into
    /// immutable snapshots. Always complete asynchronously on main, including
    /// an empty pipeline, so application termination never blocks main waiting
    /// for a worker that still needs main-thread model publication.
    public func finishPendingCaptures(completion: @escaping (Bool) -> Void) {
        timer?.invalidate()
        timer = nil
        isRunning = false
        isFinishing = true
        pendingGeneration = nil
        finishHandlers.append(completion)
        finishIfIdle()
    }

    public func suppressCurrentChange() {
        suppressChange(pasteboard.changeCount)
    }

    public func suppressChange(_ changeCount: Int) {
        if let job = inFlight, job.generation == changeCount { cancelledJobID = job.id }
        suppressedChangeCounts.insert(changeCount)
        if suppressedChangeCounts.count > 8 {
            suppressedChangeCounts.remove(suppressedChangeCounts.min() ?? pasteboard.changeCount)
        }
    }

    private func tick() {
        guard isRunning else { return }
        guard !isPaused else {
            lastChangeCount = pasteboard.changeCount
            return
        }
        // A failed stage is now retained by the store for explicit retry. Do
        // not keep accepting large snapshots behind that one unsaved capture.
        guard !store.hasPendingCaptureFailure else { return }

        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else {
            return
        }
        if suppressedChangeCounts.remove(changeCount) != nil {
            lastChangeCount = changeCount
            return
        }
        guard inFlight == nil else {
            // This is only an unread token. Do not advance lastChangeCount;
            // restart/retry must still be able to read the latest board.
            pendingGeneration = changeCount
            return
        }

        let sourceApplication = NSWorkspace.shared.frontmostApplication
        let isExternalSource = sourceApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier
        let sourceAppName = isExternalSource ? sourceApplication?.localizedName : nil
        let sourceBundleIdentifier = isExternalSource ? sourceApplication?.bundleIdentifier : nil

        let snapshot = PasteboardReader.snapshotResult(
            from: pasteboard,
            sourceBundleIdentifier: sourceBundleIdentifier
        )
        guard pasteboard.changeCount == changeCount else {
            pendingGeneration = pasteboard.changeCount
            return
        }
        switch snapshot {
        case .ignored:
            lastChangeCount = changeCount
            unavailableAttempts = 0
        case .unavailable:
            if unavailableGeneration != changeCount {
                unavailableGeneration = changeCount
                unavailableAttempts = 0
            }
            unavailableAttempts += 1
            if unavailableAttempts >= 3 { lastChangeCount = changeCount }
        case let .snapshot(value):
            lastChangeCount = changeCount
            unavailableAttempts = 0
            pendingGeneration = nil
            sequence &+= 1
            let job = CaptureJob(
                id: sequence, epoch: epoch, generation: changeCount,
                capturedAt: Date(), sourceAppName: sourceAppName,
                sourceBundleIdentifier: sourceBundleIdentifier,
                snapshot: value, excludedImageTypes: []
            )
            inFlight = job
            decode(job)
        }
    }

    private func decode(_ job: CaptureJob) {
        let snapshot = job.snapshot
        captureQueue.async {
            let content = PasteboardReader.decode(snapshot)
            DispatchQueue.main.async { [weak self] in self?.didDecode(content, job: job) }
        }
    }

    private func didDecode(_ content: CapturedClipboardContent?, job: CaptureJob) {
        guard isEligible(job) else { finish(job); return }
        guard var content else {
            // Fetch a fallback representation only after a failed decode. In
            // particular, a normal PNG must not force its provider to create a
            // second large TIFF on the main thread. The board must still have
            // the same generation before and after this additional read.
            if let type = job.snapshot.imageType,
               job.excludedImageTypes.count < 32,
               pasteboard.changeCount == job.generation {
                var next = job
                next.excludedImageTypes.insert(type)
                let result = PasteboardReader.snapshotResult(
                    from: pasteboard, sourceBundleIdentifier: job.sourceBundleIdentifier,
                    excludingImageTypes: next.excludedImageTypes
                )
                if pasteboard.changeCount == job.generation, case let .snapshot(snapshot) = result {
                    next.snapshot = snapshot
                    inFlight = next
                    decode(next)
                    return
                }
            }
            finish(job)
            return
        }
        content.sourceAppName = job.sourceAppName
        content.sourceBundleIdentifier = job.sourceBundleIdentifier
        store.insertCapturedAsync(content, capturedAt: job.capturedAt, shouldCommit: { [weak self] in
            self?.isEligible(job) == true
        }, completion: { [weak self] _ in
            self?.finish(job)
        })
    }

    private func isEligible(_ job: CaptureJob) -> Bool {
        inFlight?.id == job.id && cancelledJobID != job.id && job.epoch == epoch && !isPaused &&
        (isRunning || isFinishing) && !suppressedChangeCounts.contains(job.generation)
    }

    private func finish(_ job: CaptureJob) {
        guard inFlight?.id == job.id else { return }
        inFlight = nil
        if cancelledJobID == job.id { cancelledJobID = nil }
        suppressedChangeCounts.remove(job.generation)
        finishIfIdle()
        let hasUnreadGeneration = pendingGeneration != nil
        pendingGeneration = nil
        if isRunning, hasUnreadGeneration || pasteboard.changeCount != lastChangeCount { tick() }
    }

    private func finishIfIdle() {
        guard inFlight == nil, !finishHandlers.isEmpty else { return }
        let handlers = finishHandlers
        finishHandlers.removeAll()
        isFinishing = false
        let succeeded = !store.hasPendingCaptureFailure
        DispatchQueue.main.async { handlers.forEach { $0(succeeded) } }
    }
}
