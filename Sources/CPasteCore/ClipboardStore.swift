import AppKit
import Combine
import Foundation

public final class ClipboardStore: ObservableObject {
    private static let directoryPermissions = 0o700
    private static let filePermissions = 0o600

    @Published public private(set) var items: [ClipboardItem] = []

    public let storageDirectory: URL
    public let historyURL: URL
    public let blobDirectory: URL
    public var maxItems: Int

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        storageDirectory: URL = ClipboardStore.defaultStorageDirectory(),
        maxItems: Int = 500,
        fileManager: FileManager = .default
    ) {
        self.storageDirectory = storageDirectory
        self.historyURL = storageDirectory.appendingPathComponent("history.json", isDirectory: false)
        self.blobDirectory = storageDirectory.appendingPathComponent("Blobs", isDirectory: true)
        self.maxItems = maxItems
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        prepareStorage()
        load()
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

        if let imagePNGData = captured.imagePNGData {
            let filename = "\(captured.contentHash).png"
            guard persistBlob(imagePNGData, filename: filename) else {
                return
            }
            blobFilename = filename
        } else if let fileData = captured.fileData,
                  let requestedFileName = captured.fileName {
            let filename = URL(fileURLWithPath: requestedFileName).lastPathComponent
            guard !filename.isEmpty,
                  filename != ".",
                  filename != "..",
                  persistBlob(fileData, filename: filename)
            else {
                return
            }
            blobFilename = filename
            resolvedFileURLs = [blobDirectory.appendingPathComponent(filename, isDirectory: false).absoluteString]
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
            save()
            return
        }

        let item = ClipboardItem(
            kind: captured.kind,
            title: captured.title,
            subtitle: captured.subtitle,
            text: captured.text,
            fileURLs: resolvedFileURLs,
            blobFilename: blobFilename,
            contentHash: captured.contentHash,
            sourceAppName: captured.sourceAppName,
            sourceBundleIdentifier: captured.sourceBundleIdentifier,
            createdAt: now,
            lastCopiedAt: now
        )

        items.insert(item, at: 0)
        trimToLimit()
        save()
    }

    private func persistBlob(_ data: Data, filename: String) -> Bool {
        let destination = blobDirectory.appendingPathComponent(filename, isDirectory: false)
        do {
            try ensureSecureDirectories()
            if !fileManager.fileExists(atPath: destination.path) {
                try data.write(to: destination, options: .atomic)
            }
            try applySecureFilePermissions(to: destination)
            return true
        } catch {
            return false
        }
    }

    public func filteredItems(search: String, kind: ClipboardKind? = nil, pinnedOnly: Bool = false) -> [ClipboardItem] {
        items.filter { item in
            let kindMatches = kind == nil || item.kind == kind
            let pinMatches = !pinnedOnly || item.isPinned
            return kindMatches && pinMatches && item.matches(search)
        }
    }

    public func togglePinned(_ itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        items[index].isPinned.toggle()
        save()
    }

    public func delete(_ itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        let removed = items.remove(at: index)
        cleanupBlobIfUnused(from: removed)
        save()
    }

    public func clearUnpinned() {
        let removed = items.filter { !$0.isPinned }
        items.removeAll { !$0.isPinned }
        for item in removed {
            cleanupBlobIfUnused(from: item)
        }
        save()
    }

    public func moveToTop(_ itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        var item = items.remove(at: index)
        item.lastCopiedAt = Date()
        items.insert(item, at: 0)
        save()
    }

    public func setMaxItems(_ limit: Int) {
        maxItems = min(max(limit, 50), 5_000)
        trimToLimit()
        save()
    }

    public func blobURL(for item: ClipboardItem) -> URL? {
        guard let blobFilename = item.blobFilename else {
            return nil
        }
        return blobDirectory.appendingPathComponent(blobFilename, isDirectory: false)
    }

    public func reloadFromDisk() {
        load()
    }

    private func prepareStorage() {
        do {
            try ensureSecureDirectories()
            try hardenExistingStorageFiles()
        } catch {
            NSSound.beep()
        }
    }

    private func ensureSecureDirectories() throws {
        let attributes: [FileAttributeKey: Any] = [
            .posixPermissions: Self.directoryPermissions
        ]
        try fileManager.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true,
            attributes: attributes
        )
        try fileManager.createDirectory(
            at: blobDirectory,
            withIntermediateDirectories: true,
            attributes: attributes
        )
        try applySecureDirectoryPermissions(to: storageDirectory)
        try applySecureDirectoryPermissions(to: blobDirectory)
    }

    private func hardenExistingStorageFiles() throws {
        if fileManager.fileExists(atPath: historyURL.path) {
            try applySecureFilePermissions(to: historyURL)
        }

        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let blobURLs = try fileManager.contentsOfDirectory(
            at: blobDirectory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )
        for blobURL in blobURLs {
            let values = try blobURL.resourceValues(forKeys: resourceKeys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                continue
            }
            try applySecureFilePermissions(to: blobURL)
        }
    }

    private func applySecureDirectoryPermissions(to url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: Self.directoryPermissions],
            ofItemAtPath: url.path
        )
    }

    private func applySecureFilePermissions(to url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: Self.filePermissions],
            ofItemAtPath: url.path
        )
    }

    private func load() {
        guard fileManager.fileExists(atPath: historyURL.path) else {
            items = []
            return
        }

        do {
            let data = try Data(contentsOf: historyURL)
            items = sorted(try decoder.decode([ClipboardItem].self, from: data))
        } catch {
            items = []
        }
    }

    public func save() {
        do {
            try ensureSecureDirectories()
            let data = try encoder.encode(items)
            try data.write(to: historyURL, options: .atomic)
            try applySecureFilePermissions(to: historyURL)
        } catch {
            NSSound.beep()
        }
    }

    private func sorted(_ source: [ClipboardItem]) -> [ClipboardItem] {
        source.sorted { $0.lastCopiedAt > $1.lastCopiedAt }
    }

    private func trimToLimit() {
        while items.count > maxItems,
              let removalIndex = items.lastIndex(where: { !$0.isPinned }) {
            let removed = items.remove(at: removalIndex)
            cleanupBlobIfUnused(from: removed)
        }
    }

    private func cleanupBlobIfUnused(from item: ClipboardItem) {
        guard let filename = item.blobFilename else {
            return
        }

        let stillUsed = items.contains { $0.blobFilename == filename }
        guard !stillUsed else {
            return
        }

        try? fileManager.removeItem(at: blobDirectory.appendingPathComponent(filename, isDirectory: false))
    }
}
