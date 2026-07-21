import Foundation

public enum ClipboardKind: String, Codable, CaseIterable, Identifiable {
    case text
    case url
    case file
    case image

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .text:
            return "Text"
        case .url:
            return "URL"
        case .file:
            return "Files"
        case .image:
            return "Images"
        }
    }

    public var systemImageName: String {
        switch self {
        case .text:
            return "text.alignleft"
        case .url:
            return "link"
        case .file:
            return "doc.on.doc"
        case .image:
            return "photo"
        }
    }
}

public struct ClipboardItem: Codable, Identifiable, Equatable {
    public var id: UUID
    public var kind: ClipboardKind
    public var title: String
    public var subtitle: String
    public var text: String
    public var fileURLs: [String]
    public var blobFilename: String?
    public var contentHash: String
    public var sourceAppName: String?
    public var sourceBundleIdentifier: String?
    public var createdAt: Date
    public var lastCopiedAt: Date
    public var isPinned: Bool

    public init(
        id: UUID = UUID(),
        kind: ClipboardKind,
        title: String,
        subtitle: String = "",
        text: String = "",
        fileURLs: [String] = [],
        blobFilename: String? = nil,
        contentHash: String,
        sourceAppName: String? = nil,
        sourceBundleIdentifier: String? = nil,
        createdAt: Date = Date(),
        lastCopiedAt: Date = Date(),
        isPinned: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.text = text
        self.fileURLs = fileURLs
        self.blobFilename = blobFilename
        self.contentHash = contentHash
        self.sourceAppName = sourceAppName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.createdAt = createdAt
        self.lastCopiedAt = lastCopiedAt
        self.isPinned = isPinned
    }

    public func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return true
        }

        let haystack = [
            kind.displayName,
            title,
            subtitle,
            text,
            sourceAppName ?? "",
            sourceBundleIdentifier ?? "",
            fileURLs.joined(separator: " ")
        ]
        .joined(separator: " ")
        .localizedLowercase

        return haystack.contains(trimmed.localizedLowercase)
    }
}

public struct CapturedClipboardContent: Equatable {
    public var kind: ClipboardKind
    public var title: String
    public var subtitle: String
    public var text: String
    public var fileURLs: [String]
    public var imagePNGData: Data?
    public var fileData: Data?
    public var fileName: String?
    public var contentHash: String
    public var sourceAppName: String?
    public var sourceBundleIdentifier: String?

    public init(
        kind: ClipboardKind,
        title: String,
        subtitle: String = "",
        text: String = "",
        fileURLs: [String] = [],
        imagePNGData: Data? = nil,
        fileData: Data? = nil,
        fileName: String? = nil,
        contentHash: String,
        sourceAppName: String? = nil,
        sourceBundleIdentifier: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.text = text
        self.fileURLs = fileURLs
        self.imagePNGData = imagePNGData
        self.fileData = fileData
        self.fileName = fileName
        self.contentHash = contentHash
        self.sourceAppName = sourceAppName
        self.sourceBundleIdentifier = sourceBundleIdentifier
    }
}
