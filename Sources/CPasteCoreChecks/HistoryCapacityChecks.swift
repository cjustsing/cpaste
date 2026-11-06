import CPasteCore
import Foundation

func testHistoryCapacityChangeProtectsPinnedItemsAndPredictsRemoval() {
    let items = (0..<60).map { index in
        ClipboardItem(kind: .text, title: "Capacity \(index)", text: "Fixture \(index)", contentHash: "capacity-\(index)", isPinned: index < 3)
    }
    let original = items
    let reduction = HistoryCapacityChange(requestedLimit: 50, items: items)
    check(reduction.limit == 50 && reduction.removalCount == 10 && reduction.pinnedCount == 3, "capacity prediction must match trimming while preserving pinned items")
    check(reduction.requiresConfirmation, "a reduction that removes history must require confirmation")
    check(!HistoryCapacityChange(requestedLimit: 100, items: items).requiresConfirmation, "a capacity change without removal must apply without a destructive confirmation")
    check(!HistoryCapacityChange(requestedLimit: 50, items: []).requiresConfirmation, "empty history must not require a destructive confirmation")
    check(items == original, "predicting a capacity change must not mutate any item or metadata")

    let allPinned = items.map { item in
        var copy = item
        copy.isPinned = true
        return copy
    }
    let pinnedOnly = HistoryCapacityChange(requestedLimit: 50, items: allPinned)
    check(pinnedOnly.removalCount == 0 && !pinnedOnly.requiresConfirmation, "pinned history may exceed capacity and must not be predicted for removal")
    let mostlyPinned = allPinned.enumerated().map { index, item in
        var copy = item
        copy.isPinned = index < 55
        return copy
    }
    let pinnedExcess = HistoryCapacityChange(requestedLimit: 50, items: mostlyPinned)
    check(pinnedExcess.removalCount == 5 && pinnedExcess.pinnedCount == 55, "removal counts must stop when only pinned items remain")

    check(HistoryCapacityChange(requestedLimit: Int.min, items: items).limit == 50, "capacity prediction must honor the store's minimum")
    check(HistoryCapacityChange(requestedLimit: Int.max, items: items).limit == 5_000, "capacity prediction must honor the store's maximum")
    let capturedDuringConfirmation = items + (60..<65).map { index in
        ClipboardItem(kind: .text, title: "Later \(index)", contentHash: "later-\(index)")
    }
    check(HistoryCapacityChange(requestedLimit: 50, items: capturedDuringConfirmation).removalCount == 15, "pending confirmation must be able to describe the current history after new captures")
}
