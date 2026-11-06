import CPasteCore
import Foundation

func testChangedClipboardReportsCancellationInsteadOfManualPaste() {
    for changeAfterActivation in [false, true] {
        var scheduled: [() -> Void] = []
        var clipboardVersion = 17
        var frontmost: Int32 = 100
        var sends = 0
        var resultName: String?
        let delivery = PasteDeliveryCoordinator { _, work in scheduled.append(work) }
        delivery.deliver(
            targetProcessID: 200,
            ownerProcessID: 100,
            isTargetAvailable: { true },
            frontmostProcessID: { frontmost },
            isClipboardCurrent: { clipboardVersion == 17 },
            isPermitted: { true },
            activateTarget: { frontmost = 200; return true },
            sendPaste: { sends += 1; return true },
            completion: { resultName = String(describing: $0) }
        )
        if changeAfterActivation { scheduled.removeFirst()() }
        clipboardVersion = 18
        while !scheduled.isEmpty { scheduled.removeFirst()() }
        check(sends == 0 && clipboardVersion == 18, "clipboard change must cancel delivery and preserve the new clipboard generation")
        check(resultName == "clipboardChanged", "changed clipboard must report cancellation rather than asking the user to paste an outdated copy")
    }
}
