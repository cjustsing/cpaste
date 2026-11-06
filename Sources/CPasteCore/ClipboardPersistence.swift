import Darwin
import Foundation

public enum ClipboardStorageIssue: Equatable {
    case recoveredFromBackup
    case damagedHistoryPreserved
    case readOnly
    case saveFailed
    case historyConflict
    case recoveryCopyFailed
}

/// Keep the legacy flat fields while moving only large text to an immutable body.
/// ClipboardItem itself always contains the complete in-memory text.
private struct ClipboardRecord: Codable {
    struct TextStorage: Codable {
        let filename: String
        let sha256: String
        let byteCount: Int
    }
    var item: ClipboardItem
    var textStorage: TextStorage?
    private enum CodingKeys: String, CodingKey { case textStorage }
    init(item: ClipboardItem, textStorage: TextStorage? = nil) {
        self.item = item
        self.textStorage = textStorage
    }
    init(from decoder: Decoder) throws {
        item = try ClipboardItem(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        textStorage = try container.decodeIfPresent(TextStorage.self, forKey: .textStorage)
    }
    func encode(to encoder: Encoder) throws {
        try item.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(textStorage, forKey: .textStorage)
    }
}

/// Index writes, backup rotation and collection share one serial worker. The
/// lock covers only pending snapshots and reservations, never text encoding.
final class ClipboardPersistence {
    static let externalTextThreshold = 65_536
    struct Report {
        let sequence: UInt64
        let epoch: UInt64
        let issue: ClipboardStorageIssue?
        let succeeded: Bool
    }
    struct RetryOutcome {
        let items: [ClipboardItem]
        let report: Report
        let recoveryCopyURL: URL?
        var shouldAdoptItems = false
    }
    struct Loaded {
        let items: [ClipboardItem]
        let issue: ClipboardStorageIssue?
        let needsMigration: Bool
    }
    private struct Snapshot {
        let data: Data
        let records: [ClipboardRecord]
        let items: [ClipboardItem]
    }
    private struct PendingSnapshot {
        let items: [ClipboardItem]
        let epoch: UInt64
    }
    private enum ReadResult {
        case missing
        case valid(Snapshot)
        case invalid(Data?)
    }
    private enum StorageFailure: Error {
        case unsafePath, invalidRecord, invalidText, changedHistory, blocked
    }
    private enum PrimaryExpectation {
        case missing
        case bytes(Data)
    }
    private struct CachedText {
        let text: String
        let reference: ClipboardRecord.TextStorage
        let stamp: FileStamp
    }
    private struct FileStamp: Equatable {
        let size: UInt64
        let modified: Date
        let inode: UInt64
    }

    let directory: URL
    let historyURL: URL
    let backupURL: URL
    let blobDirectory: URL
    let textDirectory: URL
    private let legacyBackupURL: URL
    private let recoveryDirectory: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "local.cpaste.persistence", qos: .utility)
    private let stateLock = NSLock()
    private var pending: PendingSnapshot?
    private var isDraining = false
    private var leases: [UUID: Set<String>] = [:]
    private var liveBlobNames = Set<String>()
    private var liveItemIDs = Set<UUID>()
    private var latestReport = Report(sequence: 0, epoch: 0, issue: nil, succeeded: true)
    private var sequence: UInt64 = 0
    private var blocked = false
    private var recoveryIssue: ClipboardStorageIssue?
    private var current: Snapshot?
    // A first recovery can verify D, then conflict before publishing D + U.
    // Keep D as the disk comparison/dependency baseline without pretending
    // its rows have already been adopted by the main-thread model.
    private var currentRequiresMemoryMerge = false
    private var loadedBaseline: Snapshot?
    private var backup: Snapshot?
    private var legacyBackup: Snapshot?
    private var replaceablePrimaryData: Data?
    private var textCache: [UUID: CachedText] = [:]
    private var indexStamps: [String: FileStamp] = [:]
    private var indexData: [String: Data] = [:]
    // A foreign writer publishes payloads before publishing its index. Only
    // collect files created here or referenced by a fully validated index.
    private var ownedBlobNames = Set<String>()
    private var ownedTextNames = Set<String>()
    var onReport: ((Report) -> Void)?

    init(directory: URL, fileManager: FileManager) {
        self.directory = directory
        self.fileManager = fileManager
        historyURL = directory.appendingPathComponent("history.json")
        backupURL = directory.appendingPathComponent("history.backup.json")
        blobDirectory = directory.appendingPathComponent("Blobs", isDirectory: true)
        textDirectory = directory.appendingPathComponent("Text", isDirectory: true)
        legacyBackupURL = directory.appendingPathComponent("history.legacy-backup.json")
        recoveryDirectory = directory.appendingPathComponent("Recovery", isDirectory: true)
    }

    func load() -> Loaded { queue.sync { loadOnWorker() } }

    private func loadOnWorker() -> Loaded {
        blocked = false
        recoveryIssue = nil
        current = nil
        currentRequiresMemoryMerge = false
        loadedBaseline = nil
        backup = nil
        legacyBackup = nil
        replaceablePrimaryData = nil
        textCache.removeAll()
        indexStamps.removeAll()
        indexData.removeAll()
        do {
            try prepareDirectories()
            try hardenFiles()
        } catch { blocked = true }

        let primaryResult = read(historyURL)
        let backupResult = read(backupURL)
        if case let .valid(snapshot) = backupResult { backup = snapshot }
        let legacyResult = read(legacyBackupURL)
        if case let .valid(snapshot) = legacyResult { legacyBackup = snapshot }
        if case let .valid(snapshot) = primaryResult {
            do {
                if case let .invalid(bytes) = backupResult {
                    guard let bytes else { throw StorageFailure.blocked }
                    try preserve(bytes, prefix: "backup")
                    recoveryIssue = .damagedHistoryPreserved
                }
                if case let .invalid(bytes) = legacyResult {
                    guard let bytes else { throw StorageFailure.blocked }
                    try preserve(bytes, prefix: "legacy-backup")
                    recoveryIssue = .damagedHistoryPreserved
                }
            } catch { blocked = true }
            current = snapshot
            loadedBaseline = snapshot
            if blocked { recoveryIssue = .readOnly }
            return Loaded(items: snapshot.items, issue: recoveryIssue, needsMigration: !blocked && needsMigration(snapshot))
        }

        // Failed bytes must be archived before replacing either candidate. If
        // reading or archiving is impossible, no disk writes are permitted.
        do {
            if case let .invalid(bytes) = primaryResult {
                guard let bytes else { throw StorageFailure.blocked }
                try preserve(bytes, prefix: "history")
                replaceablePrimaryData = bytes
            }
            if case let .invalid(bytes) = backupResult {
                guard let bytes else { throw StorageFailure.blocked }
                try preserve(bytes, prefix: "backup")
            }
            if case let .invalid(bytes) = legacyResult {
                guard let bytes else { throw StorageFailure.blocked }
                try preserve(bytes, prefix: "legacy-backup")
            }
        } catch { blocked = true }

        if let recovered = backup ?? legacyBackup {
            loadedBaseline = recovered
            if !blocked {
                do {
                    let expectation: PrimaryExpectation
                    if case let .invalid(bytes) = primaryResult, let bytes { expectation = .bytes(bytes) }
                    else { expectation = .missing }
                    try writeSecure(recovered.data, to: historyURL, expecting: expectation)
                    current = recovered
                    recoveryIssue = .recoveredFromBackup
                } catch { blocked = true }
            }
            if blocked { recoveryIssue = .readOnly }
            return Loaded(items: recovered.items, issue: recoveryIssue, needsMigration: !blocked && needsMigration(recovered))
        }
        if blocked {
            recoveryIssue = .readOnly
        } else if case .invalid = primaryResult {
            recoveryIssue = .damagedHistoryPreserved
        } else if case .invalid = backupResult {
            recoveryIssue = .damagedHistoryPreserved
        } else if case .invalid = legacyResult {
            recoveryIssue = .damagedHistoryPreserved
        }
        return Loaded(items: [], issue: recoveryIssue, needsMigration: false)
    }

    func enqueue(_ items: [ClipboardItem], epoch: UInt64, releasing releasedLeases: [UUID] = []) {
        stateLock.lock()
        pending = PendingSnapshot(items: items, epoch: epoch)
        updateLiveReferences(items, releasing: releasedLeases)
        let shouldStart = !isDraining
        isDraining = true
        if shouldStart { queue.async { self.drain() } }
        stateLock.unlock()
    }

    /// No delayed jobs: this fence follows the drain, which takes the latest
    /// snapshot repeatedly until there is no pending work.
    func flush(_ items: [ClipboardItem], epoch: UInt64, releasing releasedLeases: [UUID] = []) -> Report {
        enqueue(items, epoch: epoch, releasing: releasedLeases)
        queue.sync {}
        stateLock.lock()
        defer { stateLock.unlock() }
        return latestReport
    }

    private func drain() {
        while true {
            stateLock.lock()
            guard let snapshot = pending else {
                isDraining = false
                stateLock.unlock()
                return
            }
            pending = nil
            stateLock.unlock()
            var succeeded = false
            do {
                guard !blocked else { throw StorageFailure.blocked }
                try commit(snapshot.items)
                succeeded = true
            } catch {}
            let report = makeReport(epoch: snapshot.epoch,
                                    issue: succeeded ? recoveryIssue : blockedFailureIssue(),
                                    succeeded: succeeded)
            onReport?(report)
        }
    }

    private func makeReport(epoch: UInt64, issue: ClipboardStorageIssue?, succeeded: Bool) -> Report {
        sequence &+= 1
        let report = Report(sequence: sequence, epoch: epoch, issue: issue, succeeded: succeeded)
        stateLock.lock()
        latestReport = report
        stateLock.unlock()
        return report
    }

    private func blockedFailureIssue() -> ClipboardStorageIssue {
        guard blocked else { return .saveFailed }
        if recoveryIssue == .historyConflict { return .historyConflict }
        if recoveryIssue == .recoveryCopyFailed { return .recoveryCopyFailed }
        return .readOnly
    }

    /// Must be called with stateLock held, including lease release and enqueue.
    private func updateLiveReferences(_ items: [ClipboardItem], releasing releasedLeases: [UUID]) {
        liveBlobNames = Set(items.compactMap(\.blobFilename))
        liveItemIDs = Set(items.map(\.id))
        for lease in releasedLeases { leases.removeValue(forKey: lease) }
    }

    func prepareCapturedSync(_ captured: CapturedClipboardContent, capturedAt: Date) throws -> PreparedClipboardCapture {
        try queue.sync { try prepareCapturedOnWorker(captured, capturedAt: capturedAt) }
    }

    func prepareCaptured(
        _ captured: CapturedClipboardContent,
        capturedAt: Date,
        completion: @escaping (Result<PreparedClipboardCapture, Error>) -> Void
    ) {
        queue.async {
            do { completion(.success(try self.prepareCapturedOnWorker(captured, capturedAt: capturedAt))) }
            catch { completion(.failure(error)) }
        }
    }

    private func prepareCapturedOnWorker(_ captured: CapturedClipboardContent, capturedAt: Date) throws -> PreparedClipboardCapture {
        let lease = UUID()
        var filename: String?
        var fileURLs = captured.fileURLs
        if captured.imagePNGData != nil { filename = "\(captured.contentHash).png" }
        else if captured.fileData != nil {
            guard let requested = captured.fileName else { throw StorageFailure.invalidRecord }
            filename = URL(fileURLWithPath: requested).lastPathComponent
        }
        stateLock.lock()
        leases[lease] = Set(filename.map { [$0] } ?? [])
        stateLock.unlock()
        do {
            try prepareDirectories()
            if let image = captured.imagePNGData, let filename {
                try writeBlob(image, filename: filename)
            } else if let data = captured.fileData, let filename {
                try writeBlob(data, filename: filename)
                fileURLs = [blobDirectory.appendingPathComponent(filename).absoluteString]
            }
            return PreparedClipboardCapture(leaseID: lease, content: captured,
                                            capturedAt: capturedAt, fileURLs: fileURLs,
                                            blobFilename: filename)
        } catch {
            stateLock.lock()
            leases.removeValue(forKey: lease)
            stateLock.unlock()
            collectUnusedFiles()
            throw error
        }
    }

    func discard(_ prepared: PreparedClipboardCapture) {
        stateLock.lock()
        leases.removeValue(forKey: prepared.leaseID)
        stateLock.unlock()
        queue.async { self.collectUnusedFiles() }
    }

    private func writeBlob(_ data: Data, filename: String) throws {
        guard Self.isFilename(filename) else { throw StorageFailure.unsafePath }
        let destination = blobDirectory.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: destination.path) {
            try requireRegularFile(destination)
            guard try Data(contentsOf: destination) == data else { throw StorageFailure.invalidRecord }
            try secureFile(destination)
        } else { try writeSecure(data, to: destination) }
    }

    /// Probe without running load's replacement writes. Only adopt a fresh
    /// version after resolving it against the known load/commit baseline.
    func retry(_ items: [ClipboardItem], epoch: UInt64, releasing releasedLeases: [UUID]) -> RetryOutcome {
        queue.sync {
            stateLock.lock()
            updateLiveReferences(items, releasing: releasedLeases)
            stateLock.unlock()
            var recoveredItems = items
            var safeRecoveredItems = false
            do {
                do {
                    try prepareDirectories()
                    try hardenFiles()
                } catch {
                    blocked = true
                    return RetryOutcome(items: items,
                                        report: makeReport(epoch: epoch, issue: .readOnly, succeeded: false),
                                        recoveryCopyURL: nil)
                }

                let baseline = current ?? loadedBaseline
                let primary = read(historyURL)
                var candidate: Snapshot?
                var preservedDamage = false
                switch primary {
                case let .valid(snapshot):
                    if let baseline, snapshot.data != baseline.data {
                        let retained = currentRequiresMemoryMerge
                            ? combinePreviouslyUnreadable(baseline.items, with: items) ?? items
                            : items
                        return conflict(retained, epoch: epoch)
                    }
                    candidate = snapshot
                case let .invalid(bytes):
                    guard let bytes else { throw StorageFailure.blocked }
                    try preserve(bytes, prefix: "history")
                    preservedDamage = true
                    replaceablePrimaryData = bytes
                    candidate = baseline
                case .missing:
                    candidate = baseline
                }
                if candidate == nil {
                    if case let .valid(snapshot) = read(backupURL) {
                        backup = snapshot
                        candidate = snapshot
                    } else if case let .valid(snapshot) = read(legacyBackupURL) {
                        legacyBackup = snapshot
                        candidate = snapshot
                    }
                }
                if baseline == nil || currentRequiresMemoryMerge, let candidate {
                    guard let combined = combinePreviouslyUnreadable(candidate.items, with: items) else {
                        return conflict(items, epoch: epoch)
                    }
                    recoveredItems = combined
                    safeRecoveredItems = true
                }
                current = candidate
                blocked = false
                recoveryIssue = preservedDamage ? .damagedHistoryPreserved : nil
                stateLock.lock()
                updateLiveReferences(recoveredItems, releasing: [])
                stateLock.unlock()
                do { try commit(recoveredItems) }
                catch StorageFailure.changedHistory {
                    currentRequiresMemoryMerge = safeRecoveredItems
                    return conflict(recoveredItems, epoch: epoch)
                }
                currentRequiresMemoryMerge = false
                loadedBaseline = current
                return RetryOutcome(items: recoveredItems,
                                    report: makeReport(epoch: epoch, issue: recoveryIssue, succeeded: true),
                                    recoveryCopyURL: nil)
            } catch {
                // A non-conflict failure returns the verified merge to Store,
                // so subsequent saves already contain those recovered rows.
                if safeRecoveredItems { currentRequiresMemoryMerge = false }
                let issue: ClipboardStorageIssue
                if case StorageFailure.blocked = error {
                    blocked = true
                    issue = .readOnly
                } else { issue = .saveFailed }
                return RetryOutcome(items: safeRecoveredItems ? recoveredItems : items,
                                    report: makeReport(epoch: epoch, issue: issue, succeeded: false),
                                    recoveryCopyURL: nil,
                                    shouldAdoptItems: safeRecoveredItems)
            }
        }
    }

    /// No known readable base means the in-memory rows are newly accepted
    /// captures, not a replacement for an entire previously unreadable history.
    /// Conflicting identities or bodies require preserving both versions.
    private func combinePreviouslyUnreadable(_ disk: [ClipboardItem], with memory: [ClipboardItem]) -> [ClipboardItem]? {
        var combined = disk
        for item in memory {
            if let sameID = combined.first(where: { $0.id == item.id }) {
                guard sameID == item, sameID.text.utf8.elementsEqual(item.text.utf8) else { return nil }
                continue
            }
            let matching = combined.indices.filter { combined[$0].contentHash == item.contentHash }
            if let index = matching.first {
                guard matching.count == 1 else { return nil }
                var existing = combined[index]
                guard existing.kind == item.kind,
                      existing.text.utf8.elementsEqual(item.text.utf8),
                      existing.fileURLs == item.fileURLs,
                      existing.blobFilename == item.blobFilename
                else { return nil }
                if item.lastCopiedAt > existing.lastCopiedAt {
                    existing.title = item.title
                    existing.subtitle = item.subtitle
                    existing.lastCopiedAt = item.lastCopiedAt
                    existing.sourceAppName = item.sourceAppName ?? existing.sourceAppName
                    existing.sourceBundleIdentifier = item.sourceBundleIdentifier ?? existing.sourceBundleIdentifier
                }
                existing.createdAt = min(existing.createdAt, item.createdAt)
                existing.isPinned = existing.isPinned || item.isPinned
                combined[index] = existing
            } else { combined.append(item) }
        }
        return combined.sorted { $0.lastCopiedAt > $1.lastCopiedAt }
    }

    private func conflict(_ items: [ClipboardItem], epoch: UInt64) -> RetryOutcome {
        blocked = true
        do {
            let copy = try preserveMemory(items)
            recoveryIssue = .historyConflict
            return RetryOutcome(items: items,
                                report: makeReport(epoch: epoch, issue: .historyConflict, succeeded: false),
                                recoveryCopyURL: copy)
        } catch {
            recoveryIssue = .recoveryCopyFailed
            return RetryOutcome(items: items,
                                report: makeReport(epoch: epoch, issue: .recoveryCopyFailed, succeeded: false),
                                recoveryCopyURL: nil)
        }
    }

    /// A recovery copy stands alone: full inline text and every managed binary
    /// dependency. Publish its private directory only after verifying all bytes.
    private func preserveMemory(_ items: [ClipboardItem]) throws -> URL {
        try secureDirectory(recoveryDirectory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(items)
        let destination = recoveryDirectory.appendingPathComponent("unsaved-\(ContentHasher.hash(data: data))", isDirectory: true)
        let staging = recoveryDirectory.appendingPathComponent(".unsaved-\(UUID().uuidString)", isDirectory: true)
        let exists = fileManager.fileExists(atPath: destination.path)
        let output = exists ? destination : staging
        defer { if !exists { try? fileManager.removeItem(at: staging) } }
        try secureDirectory(output)
        let outputBlobs = output.appendingPathComponent("Blobs", isDirectory: true)
        try secureDirectory(outputBlobs)
        let outputHistory = output.appendingPathComponent("history.json")
        if exists {
            try requireRegularFile(outputHistory)
            guard try Data(contentsOf: outputHistory) == data else { throw StorageFailure.blocked }
            try secureFile(outputHistory)
        } else { try writeSecure(data, to: outputHistory) }
        for name in Set(items.compactMap(\.blobFilename)) {
            guard Self.isFilename(name) else { throw StorageFailure.unsafePath }
            let source = blobDirectory.appendingPathComponent(name)
            try requireRegularFile(source)
            let bytes = try Data(contentsOf: source)
            let copy = outputBlobs.appendingPathComponent(name)
            if exists {
                try requireRegularFile(copy)
                guard try Data(contentsOf: copy) == bytes else { throw StorageFailure.blocked }
                try secureFile(copy)
            } else { try writeSecure(bytes, to: copy) }
            guard try Data(contentsOf: copy) == bytes else { throw StorageFailure.blocked }
        }
        guard try Data(contentsOf: outputHistory) == data else { throw StorageFailure.blocked }
        if !exists { try fileManager.moveItem(at: staging, to: destination) }
        return destination
    }

    private func commit(_ items: [ClipboardItem]) throws {
        try prepareDirectories()
        var expectation = PrimaryExpectation.missing
        var primaryNeedsRepair = current != nil && !fileManager.fileExists(atPath: historyURL.path)
        // Refuse to overwrite an independently changed history with an older
        // in-memory snapshot, for example from a second app instance.
        if fileManager.fileExists(atPath: historyURL.path) {
            try requireRegularFile(historyURL)
            let bytes = try Data(contentsOf: historyURL)
            expectation = .bytes(bytes)
            if let current {
                if bytes != current.data {
                    if case .invalid = read(historyURL) {
                        try retainDamagedIndex(bytes, prefix: "history")
                        primaryNeedsRepair = true
                    } else {
                        throw StorageFailure.changedHistory
                    }
                }
            } else {
                guard bytes == replaceablePrimaryData, hasRecoveryFiles() else { throw StorageFailure.changedHistory }
            }
        }
        // The candidate for backup rotation includes records deleted from the
        // next snapshot. Repair/verify those old dependencies before dropping
        // them from memory; validating only the new records is insufficient.
        var rotatableCurrent = current
        if let current {
            do {
                try repairDependencies(of: current)
            } catch {
                try retainDamagedIndex(current.data, prefix: "history")
                rotatableCurrent = nil
            }
        }
        backup = try checkedBackup(at: backupURL, known: backup)
        legacyBackup = try checkedBackup(at: legacyBackupURL, known: legacyBackup)

        var records: [ClipboardRecord] = []
        for item in items {
            if let name = item.blobFilename {
                guard Self.isFilename(name) else { throw StorageFailure.unsafePath }
                try requireRegularFile(blobDirectory.appendingPathComponent(name))
            }
            if item.text.utf8.count > Self.externalTextThreshold {
                let reference = try persistText(item)
                var summary = item
                summary.text = ""
                records.append(ClipboardRecord(item: summary, textStorage: reference))
            } else { records.append(ClipboardRecord(item: item)) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)
        if data == current?.data, !primaryNeedsRepair, rotatableCurrent != nil, backup != nil { return }
        if let current = rotatableCurrent {
            if needsMigration(current), !fileManager.fileExists(atPath: legacyBackupURL.path) {
                try writeSecure(current.data, to: legacyBackupURL)
                legacyBackup = current
            }
            try writeSecure(current.data, to: backupURL)
            backup = current
        } else if backup == nil {
            // When the old primary cannot be repaired, retain any existing
            // valid backup rather than rotating an invalid snapshot over it.
            try writeSecure(data, to: backupURL)
            backup = Snapshot(data: data, records: records, items: items)
        }
        try writeSecure(data, to: historyURL, expecting: expectation)
        let published = Snapshot(data: data, records: records, items: items)
        current = published
        ownDependencies(of: published)
        collectUnusedFiles()
    }

    private func repairDependencies(of snapshot: Snapshot) throws {
        let completeItems = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        for record in snapshot.records {
            if let name = record.item.blobFilename {
                guard Self.isFilename(name) else { throw StorageFailure.unsafePath }
                try requireRegularFile(blobDirectory.appendingPathComponent(name))
            }
            if let expected = record.textStorage {
                guard let item = completeItems[record.item.id] else { throw StorageFailure.invalidRecord }
                let actual = try persistText(item)
                guard actual.filename == expected.filename,
                      actual.sha256 == expected.sha256,
                      actual.byteCount == expected.byteCount
                else { throw StorageFailure.invalidText }
            }
        }
    }

    private func checkedBackup(at url: URL, known: Snapshot?) throws -> Snapshot? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        try requireRegularFile(url)
        if let known {
            if try matchesSnapshot(known, at: url) {
                do {
                    try repairDependencies(of: known)
                    return known
                } catch {
                    try retainDamagedIndex(known.data, prefix: url == backupURL ? "backup" : "legacy-backup")
                    return nil
                }
            }
        }
        switch read(url) {
        case let .valid(snapshot):
            // Preserve an externally replaced snapshot before a normal backup
            // rotation could overwrite its otherwise unique history.
            if url == backupURL, known?.data != snapshot.data {
                try retainDamagedIndex(snapshot.data, prefix: "changed-backup")
            }
            return snapshot
        case let .invalid(bytes):
            guard let bytes else { throw StorageFailure.blocked }
            try retainDamagedIndex(bytes, prefix: url == backupURL ? "backup" : "legacy-backup")
            return nil
        case .missing:
            return nil
        }
    }

    private func retainDamagedIndex(_ bytes: Data, prefix: String) throws {
        try preserve(bytes, prefix: prefix)
        if recoveryIssue == nil { recoveryIssue = .damagedHistoryPreserved }
    }

    private func persistText(_ item: ClipboardItem) throws -> ClipboardRecord.TextStorage {
        if let cached = textCache[item.id], cached.text == item.text {
            let url = textDirectory.appendingPathComponent(cached.reference.filename)
            if fileManager.fileExists(atPath: url.path) {
                try requireRegularFile(url)
                if try stamp(url) == cached.stamp { return cached.reference }
            }
        }
        let bytes = Data(item.text.utf8)
        let hash = ContentHasher.hash(data: bytes)
        let reference = ClipboardRecord.TextStorage(filename: "\(hash).txt", sha256: hash, byteCount: bytes.count)
        let url = textDirectory.appendingPathComponent(reference.filename)
        if fileManager.fileExists(atPath: url.path) {
            try requireRegularFile(url)
            if try Data(contentsOf: url) != bytes { try writeSecure(bytes, to: url) }
        } else { try writeSecure(bytes, to: url) }
        textCache[item.id] = CachedText(text: item.text, reference: reference, stamp: try stamp(url))
        return reference
    }

    private func read(_ url: URL) -> ReadResult {
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        var bytes: Data?
        do {
            try requireRegularFile(url)
            let initialStamp = try stamp(url)
            bytes = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let records = try decoder.decode([ClipboardRecord].self, from: bytes!)
            var ids = Set<UUID>()
            var items: [ClipboardItem] = []
            var cachedTexts: [UUID: CachedText] = [:]
            for record in records {
                var item = record.item
                guard ids.insert(item.id).inserted else { throw StorageFailure.invalidRecord }
                if let name = item.blobFilename {
                    guard Self.isFilename(name) else { throw StorageFailure.unsafePath }
                    try requireRegularFile(blobDirectory.appendingPathComponent(name))
                }
                if let reference = record.textStorage {
                    guard Self.isFilename(reference.filename),
                          reference.filename == "\(reference.sha256).txt",
                          reference.sha256.count == 64,
                          reference.sha256.allSatisfy({ $0.isHexDigit }),
                          reference.byteCount > 0, item.text.isEmpty
                    else { throw StorageFailure.invalidText }
                    let textURL = textDirectory.appendingPathComponent(reference.filename)
                    try requireRegularFile(textURL)
                    let body = try Data(contentsOf: textURL)
                    guard body.count == reference.byteCount,
                          ContentHasher.hash(data: body) == reference.sha256,
                          let text = String(data: body, encoding: .utf8)
                    else { throw StorageFailure.invalidText }
                    item.text = text
                    cachedTexts[item.id] = CachedText(text: text, reference: reference, stamp: try stamp(textURL))
                }
                items.append(item)
            }
            items.sort { $0.lastCopiedAt > $1.lastCopiedAt }
            let snapshot = Snapshot(data: bytes!, records: records, items: items)
            textCache.merge(cachedTexts) { _, new in new }
            ownDependencies(of: snapshot)
            if (try? stamp(url)) == initialStamp {
                indexStamps[url.path] = initialStamp
                indexData[url.path] = snapshot.data
            } else {
                indexStamps.removeValue(forKey: url.path)
                indexData.removeValue(forKey: url.path)
            }
            return .valid(snapshot)
        } catch { return .invalid(bytes) }
    }

    private func ownDependencies(of snapshot: Snapshot) {
        ownedBlobNames.formUnion(snapshot.records.compactMap { $0.item.blobFilename })
        ownedTextNames.formUnion(snapshot.records.compactMap { $0.textStorage?.filename })
    }

    /// A cached stamp is meaningful only for the exact bytes it verified.
    /// Probing another valid version must not make an older snapshot appear
    /// unchanged merely because both versions use the same index path.
    private func matchesSnapshot(_ snapshot: Snapshot, at url: URL) throws -> Bool {
        try requireRegularFile(url)
        let before = try stamp(url)
        if indexStamps[url.path] == before, indexData[url.path] == snapshot.data { return true }
        let bytes = try Data(contentsOf: url)
        guard try stamp(url) == before, bytes == snapshot.data else { return false }
        indexStamps[url.path] = before
        indexData[url.path] = snapshot.data
        return true
    }

    private func indexStillMatches(_ snapshot: Snapshot?, at url: URL) -> Bool {
        if let snapshot { return (try? matchesSnapshot(snapshot, at: url)) == true }
        // fileExists follows symlinks and hides unreadable paths. An unknown
        // dangling link or inaccessible index must also stop collection.
        do {
            _ = try fileManager.attributesOfItem(atPath: url.path)
            return false
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return true
        } catch let error as POSIXError where error.code == .ENOENT {
            return true
        } catch { return false }
    }

    private func needsMigration(_ snapshot: Snapshot) -> Bool {
        snapshot.records.contains { $0.textStorage == nil && $0.item.text.utf8.count > Self.externalTextThreshold }
    }

    private func preserve(_ bytes: Data, prefix: String) throws {
        try secureDirectory(recoveryDirectory)
        // A damaged legacy index may remain in place across many commits.
        // Reuse its verified archive instead of adding another full copy.
        let hash = ContentHasher.hash(data: bytes)
        let url = recoveryDirectory.appendingPathComponent("\(prefix)-\(hash).json")
        if fileManager.fileExists(atPath: url.path) {
            try requireRegularFile(url)
            guard try Data(contentsOf: url) == bytes else { throw StorageFailure.blocked }
            try secureFile(url)
            return
        }
        try writeSecure(bytes, to: url)
        guard try Data(contentsOf: url) == bytes else { throw StorageFailure.blocked }
    }

    private func hasRecoveryFiles() -> Bool {
        guard let files = try? fileManager.contentsOfDirectory(atPath: recoveryDirectory.path) else { return false }
        return !files.isEmpty
    }

    private func collectUnusedFiles() {
        // A blocked/unloaded history may reference files we cannot inspect.
        // Preparation failure or cancellation must never collect that data.
        guard !blocked, current != nil else { return }
        // Failed indices may contain references we cannot interpret. Retain
        // their dependencies until the user explicitly removes Recovery.
        guard !hasRecoveryFiles() else { return }
        guard indexStillMatches(current, at: historyURL),
              indexStillMatches(backup, at: backupURL),
              indexStillMatches(legacyBackup, at: legacyBackupURL)
        else { return }
        let snapshots = [current, backup, legacyBackup].compactMap { $0 }
        var imageNames = Set(snapshots.flatMap { $0.records.compactMap { $0.item.blobFilename } })
        var textNames = Set(snapshots.flatMap { $0.records.compactMap { $0.textStorage?.filename } })
        stateLock.lock()
        let waiting = pending?.items ?? []
        imageNames.formUnion(waiting.compactMap(\.blobFilename))
        imageNames.formUnion(liveBlobNames)
        imageNames.formUnion(leases.values.flatMap { $0 })
        let retainedIDs = Set(snapshots.flatMap { $0.items.map(\.id) } + waiting.map(\.id)).union(liveItemIDs)
        stateLock.unlock()
        textCache = textCache.filter { retainedIDs.contains($0.key) }
        textNames.formUnion(textCache.values.map { $0.reference.filename })
        collectOwnedFiles(in: blobDirectory, owned: &ownedBlobNames, retaining: imageNames)
        collectOwnedFiles(in: textDirectory, owned: &ownedTextNames, retaining: textNames)
    }

    private func collectOwnedFiles(in folder: URL, owned: inout Set<String>, retaining names: Set<String>) {
        for name in owned.subtracting(names) {
            let url = folder.appendingPathComponent(name)
            guard (try? requireRegularFile(url)) != nil else { continue }
            do {
                try fileManager.removeItem(at: url)
                owned.remove(name)
            } catch { continue }
        }
    }

    private func prepareDirectories() throws {
        try secureDirectory(directory)
        try secureDirectory(blobDirectory)
        try secureDirectory(textDirectory)
    }
    private func hardenFiles() throws {
        for url in [historyURL, backupURL, legacyBackupURL] where fileManager.fileExists(atPath: url.path) {
            try requireRegularFile(url)
            try secureFile(url)
        }
        for folder in [blobDirectory, textDirectory, recoveryDirectory] where fileManager.fileExists(atPath: folder.path) {
            try secureDirectory(folder)
            for url in try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
                if (try? requireRegularFile(url)) != nil { try secureFile(url) }
            }
        }
    }
    private func secureDirectory(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            let probe = URL(fileURLWithPath: url.path)
            let values = try probe.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw StorageFailure.unsafePath }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    private func secureFile(_ url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func requireRegularFile(_ url: URL) throws {
        // URLs cache resource values; a repaired path can have a different
        // type/inode from the one that caused read-only startup.
        let probe = URL(fileURLWithPath: url.path)
        let values = try probe.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw StorageFailure.unsafePath }
    }
    private func stamp(_ url: URL) throws -> FileStamp {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber
        else { throw StorageFailure.invalidText }
        return FileStamp(size: size.uint64Value, modified: modified, inode: inode.uint64Value)
    }
    private func writeSecure(_ bytes: Data, to url: URL, expecting expectation: PrimaryExpectation? = nil) throws {
        if fileManager.fileExists(atPath: url.path) { try requireRegularFile(url) }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent)-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        guard fileManager.createFile(atPath: temporary.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else {
            throw StorageFailure.blocked
        }
        try secureFile(temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        let stagedStamp = try stamp(temporary)
        // Text materialization and fsync may take time. Recheck after that
        // work so a concurrent valid history is not silently overwritten.
        if let expectation {
            switch expectation {
            case .missing:
                guard !fileManager.fileExists(atPath: url.path) else { throw StorageFailure.changedHistory }
            case let .bytes(expected):
                try requireRegularFile(url)
                guard try Data(contentsOf: url) == expected else { throw StorageFailure.changedHistory }
            }
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if url.deletingLastPathComponent() == blobDirectory { ownedBlobNames.insert(url.lastPathComponent) }
        if url.deletingLastPathComponent() == textDirectory { ownedTextNames.insert(url.lastPathComponent) }
        if url == historyURL || url == backupURL || url == legacyBackupURL {
            if (try? stamp(url)) == stagedStamp {
                indexStamps[url.path] = stagedStamp
                indexData[url.path] = bytes
            } else {
                indexStamps.removeValue(forKey: url.path)
                indexData.removeValue(forKey: url.path)
            }
        }
    }
    private static func isFilename(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") &&
        !value.contains("\\") && !value.contains("\0") && URL(fileURLWithPath: value).lastPathComponent == value
    }
}
