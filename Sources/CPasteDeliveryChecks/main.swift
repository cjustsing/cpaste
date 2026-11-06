import Foundation
import CPasteCore

// The runner inserts the actual AppDelegate method, with only OS effects
// replaced by local spies. No system pasteboard or keyboard events are used.
enum DeliveryScheduler {
    static var work: [() -> Void] = []
    static let main = Queue()
    struct Queue {
        func asyncAfter(deadline: DispatchTime, execute: @escaping () -> Void) {
            DeliveryScheduler.work.append(execute)
        }
    }
    static func next() {
        if !work.isEmpty { work.removeFirst()() }
    }
    static func drain() {
        var remaining = 20
        while !work.isEmpty && remaining > 0 { next(); remaining -= 1 }
        precondition(work.isEmpty, "Delivery scheduler did not settle")
    }
}
typealias DispatchQueue = DeliveryScheduler

final class NSRunningApplication {
    struct ActivationOptions: OptionSet {
        let rawValue: Int
        static let activateIgnoringOtherApps = Self(rawValue: 1)
    }
    let processIdentifier: Int32
    var isTerminated = false
    var activationSucceeds = true
    var activationChangesFrontmost = true
    var activations = 0
    init(_ pid: Int32) { processIdentifier = pid }
    func activate(options: ActivationOptions = []) -> Bool {
        activations += 1
        guard !isTerminated, activationSucceeds else { return false }
        if activationChangesFrontmost { NSWorkspace.shared.frontmostApplication = self }
        return true
    }
}
final class NSWorkspace {
    static let shared = NSWorkspace()
    var frontmostApplication: NSRunningApplication?
}
final class NSPasteboard {
    static let general = NSPasteboard()
    var changeCount = 17
}
enum PermissionHelper { static var isAccessibilityTrusted = true }
enum KeyboardPaster {
    static var recipients: [Int32?] = []
    static var succeeds = true
    static func sendPasteCommand() {
        recipients.append(NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }
    static func sendPasteCommand(to pid: Int32) -> Bool {
        guard succeeds else { return false }
        recipients.append(pid)
        return true
    }
}
enum CPasteL10n {
    static func text(_ chinese: String, _ english: String) -> String { english }
}
final class DeliveryStore {
    var moved: [UUID] = []
    var onMove: (() -> Void)?
    func moveToTop(_ id: UUID) { moved.append(id); onMove?() }
}
final class DeliveryMonitor {
    var suppressions = 0
    var suppressedVersions: [Int] = []
    func suppressCurrentChange() { suppressChange(NSPasteboard.general.changeCount) }
    func suppressChange(_ version: Int) { suppressions += 1; suppressedVersions.append(version) }
}
final class DeliveryState { var statusMessage = "" }
final class PasteDelegateHarness {
    let store = DeliveryStore()
    let monitor = DeliveryMonitor()
    let appState = DeliveryState()
    var previousApplication: NSRunningApplication?
    // {{PASTE_COORDINATOR_PROPERTY}}
    func hidePanel() {}
    func paste(_ item: ClipboardItem) { completePaste(item, status: "Pasted") }
    func reopenPanel() {
        // {{PASTE_COORDINATOR_CANCEL}}
    }
    // {{PASTE_DELEGATE_METHOD}}
}

let ownerPID = ProcessInfo.processInfo.processIdentifier
let fixture = ClipboardItem(kind: .text, title: "delivery fixture", text: "fixture", contentHash: "delivery-fixture")
var failures: [String] = []
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
}
func setup() -> (PasteDelegateHarness, NSRunningApplication) {
    DeliveryScheduler.work = []
    KeyboardPaster.recipients = []
    KeyboardPaster.succeeds = true
    NSPasteboard.general.changeCount = 17
    PermissionHelper.isAccessibilityTrusted = true
    NSWorkspace.shared.frontmostApplication = NSRunningApplication(ownerPID)
    let delegate = PasteDelegateHarness()
    let target = NSRunningApplication(100_001)
    delegate.previousApplication = target
    return (delegate, target)
}

do {
    let (delegate, _) = setup()
    delegate.previousApplication = nil
    delegate.paste(fixture)
    DeliveryScheduler.drain()
    require(KeyboardPaster.recipients.isEmpty, "Missing target must never send a paste command")
}
do {
    let (delegate, target) = setup()
    delegate.paste(fixture)
    NSWorkspace.shared.frontmostApplication = NSRunningApplication(100_002)
    DeliveryScheduler.drain()
    require(KeyboardPaster.recipients.isEmpty && target.activations == 0,
            "User focus change must neither activate the old target nor paste")
}
for reason in ["terminated", "activation failed", "activation did not focus"] {
    let (delegate, target) = setup()
    delegate.paste(fixture)
    if reason == "terminated" { target.isTerminated = true }
    if reason == "activation failed" { target.activationSucceeds = false }
    if reason == "activation did not focus" { target.activationChangesFrontmost = false }
    DeliveryScheduler.drain()
    require(KeyboardPaster.recipients.isEmpty, "\(reason) must retain copy without sending paste")
}
for reason in ["clipboard changed", "permission revoked", "focus changed", "target exited"] {
    let (delegate, target) = setup()
    delegate.paste(fixture)
    DeliveryScheduler.next()
    if reason == "clipboard changed" { NSPasteboard.general.changeCount += 1 }
    if reason == "permission revoked" { PermissionHelper.isAccessibilityTrusted = false }
    if reason == "focus changed" { NSWorkspace.shared.frontmostApplication = NSRunningApplication(100_002) }
    if reason == "target exited" { target.isTerminated = true }
    DeliveryScheduler.drain()
    require(KeyboardPaster.recipients.isEmpty, "\(reason) between delivery stages must cancel paste")
}
do {
    let (delegate, target) = setup()
    delegate.paste(fixture)
    delegate.previousApplication = NSRunningApplication(100_002)
    DeliveryScheduler.drain()
    require(KeyboardPaster.recipients == [target.processIdentifier],
            "Delivery must freeze the original application instead of reading a mutable target later")
}
do {
    let (delegate, _) = setup()
    delegate.paste(fixture)
    delegate.reopenPanel()
    DeliveryScheduler.drain()
    require(KeyboardPaster.recipients.isEmpty, "Reopening CPaste must invalidate an outstanding paste")
}
do {
    let (delegate, _) = setup()
    delegate.paste(fixture)
    NSPasteboard.general.changeCount += 1
    let secondTarget = NSRunningApplication(100_003)
    delegate.previousApplication = secondTarget
    delegate.paste(fixture)
    DeliveryScheduler.drain()
    require(KeyboardPaster.recipients == [secondTarget.processIdentifier],
            "Only the newest paste request may send one command")
}
do {
    let (delegate, target) = setup()
    PermissionHelper.isAccessibilityTrusted = false
    delegate.paste(fixture)
    DeliveryScheduler.drain()
    require(KeyboardPaster.recipients.isEmpty, "Copy fallback without Accessibility must not synthesize keys")
    require(delegate.store.moved == [fixture.id] && delegate.monitor.suppressions == 1,
            "Copy fallback must preserve normal history promotion and capture suppression")
    require(target.activations == 1 && NSWorkspace.shared.frontmostApplication === target,
            "Copy fallback without Accessibility must return focus to the original app")
}
do {
    let (delegate, target) = setup()
    delegate.paste(fixture)
    DeliveryScheduler.drain()
    require(KeyboardPaster.recipients == [target.processIdentifier], "Unchanged valid target must receive exactly one paste")
    require(delegate.store.moved == [fixture.id] && delegate.monitor.suppressions == 1,
            "Successful paste must preserve history promotion and capture suppression")
}
do {
    let (delegate, _) = setup()
    delegate.store.onMove = { NSPasteboard.general.changeCount += 1 }
    delegate.paste(fixture)
    DeliveryScheduler.drain()
    require(KeyboardPaster.recipients.isEmpty && NSPasteboard.general.changeCount == 18,
            "Clipboard version must be frozen before history or window side effects")
    require(delegate.monitor.suppressedVersions == [17],
            "Capture suppression must bind the copied version instead of a later external change")
}
do {
    let (delegate, _) = setup()
    KeyboardPaster.succeeds = false
    delegate.paste(fixture)
    DeliveryScheduler.drain()
    require(KeyboardPaster.recipients.isEmpty, "Event construction failure must keep copy fallback")
}
if !failures.isEmpty {
    for failure in failures { fputs("Check failed: \(failure)\n", stderr) }
    exit(1)
}
print("Automatic paste target and cancellation checks passed")
