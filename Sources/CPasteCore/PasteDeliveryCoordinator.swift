import Foundation

/// Main-thread delivery guard. The caller owns the captured target application;
/// delayed work must never resolve a different target or a newer clipboard.
public final class PasteDeliveryCoordinator {
    public enum Result { case sent, copied, clipboardChanged }
    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void

    private let schedule: Scheduler
    private var generation: UInt64 = 0

    public init(schedule: @escaping Scheduler = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }) {
        self.schedule = schedule
    }

    public func cancel() { generation &+= 1 }

    public func deliver(
        targetProcessID: Int32,
        ownerProcessID: Int32,
        isTargetAvailable: @escaping () -> Bool,
        frontmostProcessID: @escaping () -> Int32?,
        isClipboardCurrent: @escaping () -> Bool,
        isPermitted: @escaping () -> Bool,
        activateTarget: @escaping () -> Bool,
        sendPaste: @escaping () -> Bool,
        completion: @escaping (Result) -> Void
    ) {
        cancel()
        let request = generation
        let isValid = {
            targetProcessID > 0 && targetProcessID != ownerProcessID && isTargetAvailable()
                && isClipboardCurrent() && isPermitted()
        }
        let finishWithoutPaste = {
            completion(isClipboardCurrent() ? .copied : .clipboardChanged)
        }
        guard isValid() else {
            finishWithoutPaste()
            return
        }
        schedule(0.12) { [weak self] in
            guard let self, self.generation == request else { return }
            let frontmost = frontmostProcessID()
            guard isValid(), frontmost == ownerProcessID || frontmost == targetProcessID,
                  activateTarget() else {
                finishWithoutPaste()
                return
            }
            self.schedule(0.08) { [weak self] in
                guard let self, self.generation == request else { return }
                guard isValid(), frontmostProcessID() == targetProcessID, sendPaste() else {
                    finishWithoutPaste()
                    return
                }
                completion(.sent)
            }
        }
    }
}
