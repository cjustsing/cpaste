import Combine
import Foundation

public final class ClipboardStore: ObservableObject {
    @Published public private(set) var items: [ClipboardItem] = []
    @Published public private(set) var revision: UInt64 = 0
    @Published public private(set) var storageIssue: ClipboardStorageIssue?
    @Published public private(set) var hasPendingCaptureFailure = false
    @Published public private(set) var hasPendingCaptureWork = false
    @Published public private(set) var recoveryCopyURL: URL?

    public let storageDirectory: URL
    public let historyURL: URL
    public let historyBackupURL: URL
    public let blobDirectory: URL
    public let textDirectory: URL
    public var maxItems: Int
    private let persistence: ClipboardPersistence
    private var reportSequence: UInt64 = 0
    private var reportEpoch: UInt64 = 0
    private var activeCaptureCount = 0
    private struct FailedCapture {
        let content: CapturedClipboardContent
        let capturedAt: Date
    }
    private var failedCaptures: [FailedCapture] = []
    private var deletedThrough: [String: Date] = [:]
    private struct ClearBoundary {
        let date: Date
        let pinnedHashes: Set<String>
    }
    private var clearBoundaries: [ClearBoundary] = []

    public var hasUnpinnedHistory: Bool {
        let pinned = Set(items.filter(\.isPinned).map(\.contentHash))
        return items.contains { !$0.isPinned } || failedCaptures.contains {
            !pinned.contains($0.content.contentHash) && !wasRemoved($0.content.contentHash, capturedAt: $0.capturedAt)
        }
    }

    public init(
        storageDirectory: URL = ClipboardStore.defaultStorageDirectory(),
        maxItems: Int = 500,
        fileManager: FileManager = .default
    ) {
        self.storageDirectory = storageDirectory
        self.maxItems = maxItems
        let persistence = ClipboardPersistence(directory: storageDirectory, fileManager: fileManager)
        self.persistence = persistence
        historyURL = persistence.historyURL
        historyBackupURL = persistence.backupURL
        blobDirectory = persistence.blobDirectory
        textDirectory = persistence.textDirectory
        let loaded = persistence.load()
        items = loaded.items
        storageIssue = loaded.issue
        revision &+= 1
        persistence.onReport = { [weak self] report in
            DispatchQueue.main.async { self?.apply(report) }
        }
        if loaded.needsMigration { requestSave() }
    }

    public static func defaultStorageDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("CPaste", isDirectory: true)
    }

    /// Compatibility entry point; attachment I/O shares the serial worker.
    public func insertCaptured(_ captured: CapturedClipboardContent) {
        let capturedAt = Date()
        do {
            let prepared = try persistence.prepareCapturedSync(captured, capturedAt: capturedAt)
            accept(prepared, trim: true)
        } catch {
            retainFailedCapture(captured, capturedAt: capturedAt)
        }
    }

    /// Admission, completion and model publication execute only on main.
    public func insertCapturedAsync(
        _ captured: CapturedClipboardContent,
        capturedAt: Date,
        shouldCommit: @escaping () -> Bool,
        completion: @escaping (CaptureInsertionResult) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !wasRemoved(captured.contentHash, capturedAt: capturedAt) else {
            completion(.discarded)
            return
        }
        activeCaptureCount += 1
        hasPendingCaptureWork = true
        let persistence = persistence
        persistence.prepareCaptured(captured, capturedAt: capturedAt) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    if case let .success(prepared) = result { persistence.discard(prepared) }
                    completion(.discarded)
                    return
                }
                let insertionResult: CaptureInsertionResult
                if shouldCommit(), !self.wasRemoved(captured.contentHash, capturedAt: capturedAt) {
                    switch result {
                    case let .success(prepared):
                        insertionResult = self.accept(prepared, trim: true) ? .inserted : .discarded
                    case .failure:
                        self.retainFailedCapture(captured, capturedAt: capturedAt)
                        insertionResult = .failed
                    }
                } else {
                    if case let .success(prepared) = result { persistence.discard(prepared) }
                    insertionResult = .discarded
                }
                self.activeCaptureCount -= 1
                self.hasPendingCaptureWork = self.activeCaptureCount > 0
                completion(insertionResult)
            }
        }
    }

    @discardableResult
    private func accept(_ prepared: PreparedClipboardCapture, trim: Bool) -> Bool {
        guard insertPrepared(prepared, trim: trim) else {
            persistence.discard(prepared)
            return false
        }
        revision &+= 1
        requestSave(releasing: [prepared.leaseID])
        return true
    }

    private func insertPrepared(_ prepared: PreparedClipboardCapture, trim: Bool) -> Bool {
        let captured = prepared.content
        guard !wasRemoved(captured.contentHash, capturedAt: prepared.capturedAt) else { return false }
        if let index = items.firstIndex(where: { $0.contentHash == captured.contentHash }) {
            // A slow attachment must not roll back a newer copy or promotion.
            guard items[index].lastCopiedAt <= prepared.capturedAt else { return false }
            var existing = items.remove(at: index)
            existing.lastCopiedAt = prepared.capturedAt
            existing.title = captured.title
            existing.subtitle = captured.subtitle
            existing.text = captured.text
            existing.fileURLs = prepared.fileURLs
            existing.blobFilename = prepared.blobFilename ?? existing.blobFilename
            existing.sourceAppName = captured.sourceAppName ?? existing.sourceAppName
            existing.sourceBundleIdentifier = captured.sourceBundleIdentifier ?? existing.sourceBundleIdentifier
            insertInOrder(existing)
        } else {
            insertInOrder(ClipboardItem(
                kind: captured.kind, title: captured.title, subtitle: captured.subtitle,
                text: captured.text, fileURLs: prepared.fileURLs, blobFilename: prepared.blobFilename,
                contentHash: captured.contentHash, sourceAppName: captured.sourceAppName,
                sourceBundleIdentifier: captured.sourceBundleIdentifier,
                createdAt: prepared.capturedAt, lastCopiedAt: prepared.capturedAt
            ))
            if trim { trimToLimit() }
        }
        return true
    }

    private func insertInOrder(_ item: ClipboardItem) {
        let index = items.firstIndex { $0.lastCopiedAt < item.lastCopiedAt } ?? items.endIndex
        items.insert(item, at: index)
    }

    private func retainFailedCapture(_ captured: CapturedClipboardContent, capturedAt: Date) {
        failedCaptures.append(FailedCapture(content: captured, capturedAt: capturedAt))
        hasPendingCaptureFailure = true
        reportEpoch &+= 1
        storageIssue = .saveFailed
    }

    public func filteredItems(search: String, kind: ClipboardKind? = nil, pinnedOnly: Bool = false) -> [ClipboardItem] {
        items.filter { item in
            (kind == nil || item.kind == kind) && (!pinnedOnly || item.isPinned) && item.matches(search)
        }
    }
    public func togglePinned(_ itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].isPinned.toggle()
        didChange()
    }
    public func delete(_ itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        let date = Date()
        let hash = items[index].contentHash
        deletedThrough[hash] = date
        failedCaptures.removeAll { $0.content.contentHash == hash && $0.capturedAt <= date }
        hasPendingCaptureFailure = !failedCaptures.isEmpty
        reportEpoch &+= 1
        items.remove(at: index)
        didChange()
    }
    public func clearUnpinned() {
        let boundary = ClearBoundary(date: Date(), pinnedHashes: Set(items.filter(\.isPinned).map(\.contentHash)))
        clearBoundaries.append(boundary)
        failedCaptures.removeAll {
            $0.capturedAt <= boundary.date && !boundary.pinnedHashes.contains($0.content.contentHash)
        }
        hasPendingCaptureFailure = !failedCaptures.isEmpty
        reportEpoch &+= 1
        items.removeAll { !$0.isPinned }
        didChange()
    }

    private func wasRemoved(_ hash: String, capturedAt: Date) -> Bool {
        if let date = deletedThrough[hash], capturedAt <= date { return true }
        return clearBoundaries.contains { capturedAt <= $0.date && !$0.pinnedHashes.contains(hash) }
    }
    public func moveToTop(_ itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        var item = items.remove(at: index)
        item.lastCopiedAt = Date()
        insertInOrder(item)
        didChange()
    }
    public func setMaxItems(_ limit: Int) {
        maxItems = min(max(limit, 50), 5_000)
        trimToLimit()
        didChange()
    }
    public func blobURL(for item: ClipboardItem) -> URL? {
        item.blobFilename.map { blobDirectory.appendingPathComponent($0) }
    }

    public func reloadFromDisk() { _ = retrySaving() }

    /// Explicit recovery transaction after admitted capture work has finished.
    @discardableResult
    public func retrySaving() -> Bool {
        guard !hasPendingCaptureWork else { return false }
        reportEpoch &+= 1
        let replay = replayFailedCaptures()
        guard !hasPendingCaptureFailure else {
            requestSave(releasing: replay)
            storageIssue = .saveFailed
            return false
        }
        let result = persistence.retry(items, epoch: reportEpoch, releasing: replay)
        recoveryCopyURL = result.recoveryCopyURL
        if result.report.succeeded || result.shouldAdoptItems {
            items = result.items
            revision &+= 1
        }
        apply(result.report)
        return result.report.succeeded
    }

    /// Never block main waiting for a capture callback that itself needs main.
    /// A successful barrier also replays every accepted failed raw payload.
    @discardableResult
    public func save() -> Bool {
        guard !hasPendingCaptureWork else { return false }
        reportEpoch &+= 1
        let replay = replayFailedCaptures()
        let report = persistence.flush(items, epoch: reportEpoch, releasing: replay)
        apply(report)
        return report.succeeded && !hasPendingCaptureFailure
    }

    private func replayFailedCaptures() -> [UUID] {
        let waiting = failedCaptures
        failedCaptures.removeAll()
        var leases: [UUID] = []
        var changed = false
        for failure in waiting {
            guard !wasRemoved(failure.content.contentHash, capturedAt: failure.capturedAt) else { continue }
            do {
                let prepared = try persistence.prepareCapturedSync(failure.content, capturedAt: failure.capturedAt)
                if insertPrepared(prepared, trim: false) {
                    leases.append(prepared.leaseID)
                    changed = true
                } else { persistence.discard(prepared) }
            } catch { failedCaptures.append(failure) }
        }
        hasPendingCaptureFailure = !failedCaptures.isEmpty
        if changed { revision &+= 1 }
        return leases
    }

    private func didChange() {
        revision &+= 1
        requestSave()
    }
    private func requestSave(releasing leases: [UUID] = []) {
        persistence.enqueue(items, epoch: reportEpoch, releasing: leases)
    }
    private func apply(_ report: ClipboardPersistence.Report) {
        guard report.epoch == reportEpoch, report.sequence > reportSequence else { return }
        reportSequence = report.sequence
        storageIssue = hasPendingCaptureFailure ? .saveFailed : report.issue
    }
    private func trimToLimit() {
        while items.count > maxItems, let index = items.lastIndex(where: { !$0.isPinned }) {
            items.remove(at: index)
        }
    }
}
