import Combine
import Foundation

public final class ClipboardStore: ObservableObject {
    @Published public private(set) var items: [ClipboardItem] = []
    @Published public private(set) var revision: UInt64 = 0
    @Published public private(set) var storageIssue: ClipboardStorageIssue?

    public let storageDirectory: URL
    public let historyURL: URL
    public let historyBackupURL: URL
    public let blobDirectory: URL
    public let textDirectory: URL
    public var maxItems: Int
    private let persistence: ClipboardPersistence
    private var reportSequence: UInt64 = 0

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

    public func insertCaptured(_ captured: CapturedClipboardContent) {
        let now = Date()
        var resolvedFileURLs = captured.fileURLs
        var blobFilename: String?
        do {
            if let imagePNGData = captured.imagePNGData {
                let filename = "\(captured.contentHash).png"
                try persistence.persistBlob(imagePNGData, filename: filename)
                blobFilename = filename
            } else if let fileData = captured.fileData, let requestedFileName = captured.fileName {
                let filename = URL(fileURLWithPath: requestedFileName).lastPathComponent
                try persistence.persistBlob(fileData, filename: filename)
                blobFilename = filename
                resolvedFileURLs = [blobDirectory.appendingPathComponent(filename).absoluteString]
            }
        } catch {
            storageIssue = .saveFailed
            return
        }
        if let index = items.firstIndex(where: { $0.contentHash == captured.contentHash }) {
            var existing = items.remove(at: index)
            existing.lastCopiedAt = now
            existing.title = captured.title
            existing.subtitle = captured.subtitle
            existing.text = captured.text
            existing.fileURLs = resolvedFileURLs
            existing.blobFilename = blobFilename ?? existing.blobFilename
            existing.sourceAppName = captured.sourceAppName ?? existing.sourceAppName
            existing.sourceBundleIdentifier = captured.sourceBundleIdentifier ?? existing.sourceBundleIdentifier
            items.insert(existing, at: 0)
        } else {
            items.insert(ClipboardItem(
                kind: captured.kind, title: captured.title, subtitle: captured.subtitle,
                text: captured.text, fileURLs: resolvedFileURLs, blobFilename: blobFilename,
                contentHash: captured.contentHash, sourceAppName: captured.sourceAppName,
                sourceBundleIdentifier: captured.sourceBundleIdentifier,
                createdAt: now, lastCopiedAt: now
            ), at: 0)
            trimToLimit()
        }
        didChange()
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
        items.remove(at: index)
        didChange()
    }
    public func clearUnpinned() {
        items.removeAll { !$0.isPinned }
        didChange()
    }
    public func moveToTop(_ itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        var item = items.remove(at: index)
        item.lastCopiedAt = Date()
        items.insert(item, at: 0)
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
    public func reloadFromDisk() {
        guard save() else { return }
        let loaded = persistence.load()
        items = loaded.items
        revision &+= 1
        storageIssue = loaded.issue
        if loaded.needsMigration { requestSave() }
    }
    /// Explicit durability barrier for termination/export/tests. Normal UI
    /// changes enqueue background snapshots instead of calling this method.
    @discardableResult
    public func save() -> Bool {
        let report = persistence.flush(items)
        apply(report)
        return report.succeeded
    }
    private func didChange() {
        revision &+= 1
        requestSave()
    }
    private func requestSave() { persistence.enqueue(items) }
    private func apply(_ report: ClipboardPersistence.Report) {
        guard report.sequence >= reportSequence else { return }
        reportSequence = report.sequence
        storageIssue = report.issue
    }
    private func trimToLimit() {
        while items.count > maxItems, let index = items.lastIndex(where: { !$0.isPinned }) {
            items.remove(at: index)
        }
    }
}
