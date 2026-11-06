import Foundation

public enum TimelineSelection {
    public enum Change: Equatable {
        case unchanged
        case select(UUID?)
    }

    public enum Navigation {
        case offset(Int)
        case index(Int)
    }

    public static func reconcile(
        selectedID: UUID?,
        visibleIDs: [UUID],
        isSearching: Bool
    ) -> Change {
        guard !isSearching else { return .unchanged }
        if let selectedID, visibleIDs.contains(selectedID) { return .unchanged }
        let replacement = visibleIDs.first
        return selectedID == replacement ? .unchanged : .select(replacement)
    }

    public static func navigate(
        _ navigation: Navigation,
        selectedID: UUID?,
        visibleIDs: [UUID],
        isSearching: Bool
    ) -> Change {
        guard !isSearching else { return .unchanged }
        guard !visibleIDs.isEmpty else { return .select(nil) }
        let requestedIndex: Int
        switch navigation {
        case .offset(let offset):
            let currentIndex = selectedID.flatMap { visibleIDs.firstIndex(of: $0) } ?? 0
            requestedIndex = currentIndex + offset
        case .index(let index):
            requestedIndex = index
        }
        let index = min(max(requestedIndex, 0), visibleIDs.count - 1)
        return .select(visibleIDs[index])
    }

    public static func scrollTarget(
        selectedID: UUID?,
        visibleIDs: [UUID],
        isSearching: Bool,
        shouldScroll: Bool
    ) -> UUID? {
        guard !isSearching, shouldScroll,
              let selectedID, visibleIDs.contains(selectedID)
        else { return nil }
        return selectedID
    }

    public static func replacementID(
        afterRemoving removedID: UUID,
        from orderedIDs: [UUID]
    ) -> UUID? {
        guard let removedIndex = orderedIDs.firstIndex(of: removedID) else {
            return nil
        }
        if removedIndex > 0 {
            return orderedIDs[removedIndex - 1]
        }
        return orderedIDs.dropFirst().first
    }
}
