import Foundation

public enum TimelineSelection {
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
