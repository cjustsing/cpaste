import Darwin
import Foundation

public enum ClipboardStorageIssue: Equatable {
    case recoveredFromBackup
    case damagedHistoryPreserved
    case readOnly
    case saveFailed
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
        let issue: ClipboardStorageIssue?
        let succeeded: Bool
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
    private enum ReadResult {
        case missing
        case valid(Snapshot)
        case invalid(Data?)
    }
    private enum StorageFailure: Error {
        case unsafePath, invalidRecord, invalidText, changedHistory, blocked
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
    private var pending: [ClipboardItem]?
    private var isDraining = false
    private var reservedBlobs = Set<String>()
    private var latestReport = Report(sequence: 0, issue: nil, succeeded: true)
    private var sequence: UInt64 = 0
    private var blocked = false
    private var recoveryIssue: ClipboardStorageIssue?
    private var current: Snapshot?
    private var backup: Snapshot?
    private var legacyBackup: Snapshot?
    private var replaceablePrimaryData: Data?
    private var textCache: [UUID: CachedText] = [:]
    private var indexStamps: [String: FileStamp] = [:]
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
        backup = nil
        legacyBackup = nil
        replaceablePrimaryData = nil
        textCache.removeAll()
        indexStamps.removeAll()
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
            if !blocked {
                do {
                    try writeSecure(recovered.data, to: historyURL)
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

    func enqueue(_ items: [ClipboardItem]) {
        stateLock.lock()
        pending = items
        reservedBlobs.removeAll()
        let shouldStart = !isDraining
        isDraining = true
        if shouldStart { queue.async { self.drain() } }
        stateLock.unlock()
    }

    /// No delayed jobs: this fence follows the drain, which takes the latest
    /// snapshot repeatedly until there is no pending work.
    func flush(_ items: [ClipboardItem]) -> Report {
        enqueue(items)
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
                try commit(snapshot)
                succeeded = true
            } catch {}
            sequence &+= 1
            let report = Report(sequence: sequence,
                                issue: succeeded ? recoveryIssue : (blocked ? .readOnly : .saveFailed),
                                succeeded: succeeded)
            stateLock.lock()
            latestReport = report
            stateLock.unlock()
            onReport?(report)
        }
    }

    func persistBlob(_ data: Data, filename: String) throws {
        guard Self.isFilename(filename) else { throw StorageFailure.unsafePath }
        stateLock.lock()
        reservedBlobs.insert(filename)
        stateLock.unlock()
        do {
            let destination = blobDirectory.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: destination.path) {
                try requireRegularFile(destination)
                guard try Data(contentsOf: destination) == data else { throw StorageFailure.invalidRecord }
                try secureFile(destination)
            } else { try writeSecure(data, to: destination) }
        } catch {
            stateLock.lock()
            reservedBlobs.remove(filename)
            stateLock.unlock()
            throw error
        }
    }

    private func commit(_ items: [ClipboardItem]) throws {
        try prepareDirectories()
        var primaryNeedsRepair = current != nil && !fileManager.fileExists(atPath: historyURL.path)
        // Refuse to overwrite an independently changed history with an older
        // in-memory snapshot, for example from a second app instance.
        if fileManager.fileExists(atPath: historyURL.path) {
            try requireRegularFile(historyURL)
            let bytes = try Data(contentsOf: historyURL)
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
        try writeSecure(data, to: historyURL)
        current = Snapshot(data: data, records: records, items: items)
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
        let fileStamp = try stamp(url)
        if let known {
            let unchanged: Bool
            if indexStamps[url.path] == fileStamp {
                unchanged = true
            } else {
                unchanged = try Data(contentsOf: url) == known.data
            }
            if unchanged {
                do {
                    try repairDependencies(of: known)
                    indexStamps[url.path] = fileStamp
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
            bytes = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let records = try decoder.decode([ClipboardRecord].self, from: bytes!)
            var ids = Set<UUID>()
            var items: [ClipboardItem] = []
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
                    textCache[item.id] = CachedText(text: text, reference: reference, stamp: try stamp(textURL))
                }
                items.append(item)
            }
            items.sort { $0.lastCopiedAt > $1.lastCopiedAt }
            if let value = try? stamp(url) { indexStamps[url.path] = value }
            return .valid(Snapshot(data: bytes!, records: records, items: items))
        } catch { return .invalid(bytes) }
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
        // Failed indices may contain references we cannot interpret. Retain
        // their dependencies until the user explicitly removes Recovery.
        guard !hasRecoveryFiles() else { return }
        let snapshots = [current, backup, legacyBackup].compactMap { $0 }
        var imageNames = Set(snapshots.flatMap { $0.records.compactMap { $0.item.blobFilename } })
        var textNames = Set(snapshots.flatMap { $0.records.compactMap { $0.textStorage?.filename } })
        stateLock.lock()
        defer { stateLock.unlock() }
        let waiting = pending ?? []
        imageNames.formUnion(waiting.compactMap(\.blobFilename))
        imageNames.formUnion(reservedBlobs)
        let retainedIDs = Set(snapshots.flatMap { $0.items.map(\.id) } + waiting.map(\.id))
        textCache = textCache.filter { retainedIDs.contains($0.key) }
        textNames.formUnion(textCache.values.map { $0.reference.filename })
        for (folder, names) in [(blobDirectory, imageNames), (textDirectory, textNames)] {
            // A capture can be creating a hidden atomic staging file while
            // this older snapshot is collecting unused immutable payloads.
            guard let urls = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for url in urls where !names.contains(url.lastPathComponent) {
                guard (try? requireRegularFile(url)) != nil else { continue }
                try? fileManager.removeItem(at: url)
            }
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
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
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
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
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
    private func writeSecure(_ bytes: Data, to url: URL) throws {
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
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if url == historyURL || url == backupURL || url == legacyBackupURL {
            if let value = try? stamp(url) {
                indexStamps[url.path] = value
            } else {
                indexStamps.removeValue(forKey: url.path)
            }
        }
    }
    private static func isFilename(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") &&
        !value.contains("\\") && !value.contains("\0") && URL(fileURLWithPath: value).lastPathComponent == value
    }
}
