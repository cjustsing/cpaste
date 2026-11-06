import CoreGraphics
import Foundation

private final class ImageRequestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private final class ImageRequestOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CGImage?
    func store(_ image: CGImage?) { lock.lock(); self.image = image; lock.unlock() }
    func load() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return image
    }
}

private final class CachedImageRequest: NSObject {
    let image: CGImage?
    let expiresAt: TimeInterval?
    init(image: CGImage?, expiresAt: TimeInterval?) {
        self.image = image
        self.expiresAt = expiresAt
    }
}

/// Coalesces image work without blocking Swift's cooperative executor. Running
/// synchronous decoders retain their operation slot until they actually return.
public actor ImageRequestPipeline {
    private struct Waiter {
        let continuation: CheckedContinuation<CGImage?, Never>
        let cancellation: ImageRequestFlag
    }
    private struct Job {
        let id: UUID
        let operation: BlockOperation
        let cancellation: ImageRequestFlag
        var waiters: [UUID: Waiter]
    }

    private let operations: OperationQueue
    private let cache = NSCache<NSString, CachedImageRequest>()
    private let positiveTimeToLive: TimeInterval?
    private let negativeTimeToLive: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private var jobs: [String: Job] = [:]

    public init(
        maximumConcurrentOperations: Int = 2,
        totalCostLimit: Int = 128 * 1_024 * 1_024,
        countLimit: Int = 256,
        positiveTimeToLive: TimeInterval? = nil,
        negativeTimeToLive: TimeInterval = 0,
        qualityOfService: QualityOfService = .userInitiated,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        let operations = OperationQueue()
        operations.name = "local.cpaste.image-requests"
        operations.maxConcurrentOperationCount = max(1, maximumConcurrentOperations)
        operations.qualityOfService = qualityOfService
        self.operations = operations
        self.positiveTimeToLive = positiveTimeToLive.map { max(0, $0) }
        self.negativeTimeToLive = max(0, negativeTimeToLive)
        self.clock = clock
        cache.totalCostLimit = max(1, totalCostLimit)
        cache.countLimit = max(1, countLimit)
    }

    public func image(for key: String, loader: @escaping @Sendable () -> CGImage?) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if let cached = cache.object(forKey: key as NSString) {
            if cached.expiresAt.map({ $0 > clock() }) ?? true { return cached.image }
            cache.removeObject(forKey: key as NSString)
        }
        let waiterID = UUID()
        let cancellation = ImageRequestFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(key: key, waiterID: waiterID, cancellation: cancellation, continuation: continuation, loader: loader)
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancel(key: key, waiterID: waiterID) }
        }
    }

    private func enqueue(
        key: String,
        waiterID: UUID,
        cancellation: ImageRequestFlag,
        continuation: CheckedContinuation<CGImage?, Never>,
        loader: @escaping @Sendable () -> CGImage?
    ) {
        guard !cancellation.isCancelled else { continuation.resume(returning: nil); return }
        let waiter = Waiter(continuation: continuation, cancellation: cancellation)
        if var job = jobs[key] {
            job.waiters[waiterID] = waiter
            jobs[key] = job
            return
        }
        let jobID = UUID()
        let output = ImageRequestOutput()
        let jobCancellation = ImageRequestFlag()
        let operation = BlockOperation {
            guard !jobCancellation.isCancelled else { return }
            output.store(autoreleasepool(invoking: loader))
        }
        operation.completionBlock = { [weak self] in
            let image = output.load()
            Task { await self?.complete(key: key, jobID: jobID, image: image) }
        }
        jobs[key] = Job(id: jobID, operation: operation, cancellation: jobCancellation, waiters: [waiterID: waiter])
        operations.addOperation(operation)
    }

    private func cancel(key: String, waiterID: UUID) {
        guard var job = jobs[key], let waiter = job.waiters.removeValue(forKey: waiterID) else { return }
        waiter.continuation.resume(returning: nil)
        if job.waiters.isEmpty {
            jobs[key] = nil
            job.cancellation.cancel()
            job.operation.cancel()
        } else {
            jobs[key] = job
        }
    }

    private func complete(key: String, jobID: UUID, image: CGImage?) {
        guard let job = jobs[key], job.id == jobID else { return }
        jobs[key] = nil
        let hasActiveWaiter = job.waiters.values.contains { !$0.cancellation.isCancelled }
        if hasActiveWaiter {
            let ttl = image == nil ? negativeTimeToLive : positiveTimeToLive
            if ttl == nil || ttl! > 0 {
                let record = CachedImageRequest(image: image, expiresAt: ttl.map { clock() + $0 })
                cache.setObject(record, forKey: key as NSString, cost: image.map { $0.bytesPerRow * $0.height } ?? 0)
            }
        }
        for waiter in job.waiters.values {
            waiter.continuation.resume(returning: waiter.cancellation.isCancelled ? nil : image)
        }
    }
}
