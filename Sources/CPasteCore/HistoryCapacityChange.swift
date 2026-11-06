import Foundation

/// Describes the existing store's trimming rules without mutating history.
public struct HistoryCapacityChange: Equatable {
    public let limit: Int
    public let pinnedCount: Int
    public let removalCount: Int

    public var requiresConfirmation: Bool { removalCount > 0 }

    public init(requestedLimit: Int, items: [ClipboardItem]) {
        limit = min(max(requestedLimit, 50), 5_000)
        pinnedCount = items.reduce(0) { $0 + ($1.isPinned ? 1 : 0) }
        removalCount = min(items.count - pinnedCount, max(0, items.count - limit))
    }
}
