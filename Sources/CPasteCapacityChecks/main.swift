import CPasteCore
import Foundation
import SwiftUI

private final class CapacityStateBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@propertyWrapper
private struct CapacityReferenceState<Value> {
    private let box: CapacityStateBox<Value>
    init(wrappedValue: Value) { box = CapacityStateBox(wrappedValue) }
    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }
}

private struct CapacityCheckActions {
    var setHistoryLimit: (Int) -> Void
}

private struct CapacityBindingHarness {
    let store: ClipboardStore
    let actions: CapacityCheckActions
    // SwiftUI installs State in its view graph. A reference-backed substitute
    // lets the unmodified production Binding/setter run without a real window.
    @CapacityReferenceState var pendingHistoryLimit: Int? = nil

    // __PRODUCTION_CAPACITY_BINDING__

    func request(_ limit: Int) { historyLimitBinding.wrappedValue = limit }
    func confirm() { confirmHistoryLimitChange() }
    func cancel() { cancelHistoryLimitChange() }
}

private var capacityCheckCleanup: (() -> Void)?
private func capacityCheck(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("Capacity check failed: \(message)\n", stderr)
        capacityCheckCleanup?()
        exit(1)
    }
}

let capacityDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("CPasteCapacityChecks-\(UUID().uuidString)", isDirectory: true)
let capacityStore = ClipboardStore(storageDirectory: capacityDirectory, maxItems: 500)
capacityCheckCleanup = {
    capacityStore.save()
    try? FileManager.default.removeItem(at: capacityDirectory)
}
for index in 0..<60 {
    capacityStore.insertCaptured(.init(kind: .text, title: "Synthetic \(index)", text: "Synthetic body \(index)", contentHash: "capacity-\(index)"))
}
for item in capacityStore.items.suffix(3) { capacityStore.togglePinned(item.id) }
let capacityOriginalItems = capacityStore.items
let capacityPinnedIDs = Set(capacityOriginalItems.filter(\.isPinned).map(\.id))
var capacityAppliedCalls = 0
private let capacityHarness = CapacityBindingHarness(store: capacityStore, actions: CapacityCheckActions {
    capacityAppliedCalls += 1
    capacityStore.setMaxItems($0)
})

capacityHarness.request(50)
print("Capacity fixture after request: applied=\(capacityAppliedCalls), capacity=\(capacityStore.maxItems), items=\(capacityStore.items.count)")
capacityCheck(capacityAppliedCalls == 0, "a capacity reduction that removes history must wait for confirmation before applying")
capacityCheck(capacityStore.maxItems == 500 && capacityStore.items == capacityOriginalItems, "requesting a destructive reduction must preserve the old capacity and every item")
capacityCheck(capacityHarness.pendingHistoryLimit == 50, "destructive reduction must record a pending target")

capacityHarness.cancel()
capacityCheck(capacityHarness.pendingHistoryLimit == nil && capacityAppliedCalls == 0, "cancel must discard only the pending capacity change")
capacityCheck(capacityStore.maxItems == 500 && capacityStore.items == capacityOriginalItems, "cancel or dismissal must preserve all history and the capacity")
capacityHarness.request(50)
capacityHarness.confirm()
capacityCheck(capacityAppliedCalls == 1 && capacityStore.maxItems == 50 && capacityStore.items.count == 50, "confirmation must apply the reduction exactly once")
capacityCheck(Set(capacityStore.items.filter(\.isPinned).map(\.id)) == capacityPinnedIDs, "confirmed reduction must retain every pinned item")
capacityCheck(capacityHarness.pendingHistoryLimit == nil, "confirmation must clear its pending target")
capacityHarness.confirm()
capacityCheck(capacityAppliedCalls == 1, "a repeated confirmation must not apply the capacity again")

let capacityRemainingItems = capacityStore.items
capacityHarness.request(1_000)
capacityCheck(capacityAppliedCalls == 2 && capacityStore.maxItems == 1_000 && capacityHarness.pendingHistoryLimit == nil, "increasing capacity must apply immediately")
capacityHarness.request(100)
capacityCheck(capacityAppliedCalls == 3 && capacityStore.maxItems == 100 && capacityStore.items == capacityRemainingItems, "a reduction that removes no items must apply immediately")
capacityHarness.request(100)
capacityCheck(capacityAppliedCalls == 3, "requesting the current capacity must not write again")

capacityCheckCleanup?()
capacityCheckCleanup = nil
print("History capacity confirmation binding checks passed")
