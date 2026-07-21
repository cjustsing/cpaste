import Carbon
import Foundation

final class HotKeyCenter {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handler: (() -> Void)?

    @discardableResult
    func registerCommandShiftV(handler: @escaping () -> Void) -> Bool {
        unregister()
        self.handler = handler

        let hotKeyID = EventHotKeyID(signature: "CPST".fourCharCode, id: 1)
        let modifiers = UInt32(cmdKey | shiftKey)
        let keyCode = UInt32(kVK_ANSI_V)
        var nextHotKeyRef: EventHotKeyRef?

        let registrationStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &nextHotKeyRef
        )
        guard registrationStatus == noErr else {
            self.handler = nil
            return false
        }
        hotKeyRef = nextHotKeyRef

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else {
                    return noErr
                }
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    center.handler?()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard installStatus == noErr else {
            unregister()
            return false
        }

        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        hotKeyRef = nil
        eventHandlerRef = nil
    }

    deinit {
        unregister()
    }
}

private extension String {
    var fourCharCode: FourCharCode {
        utf8.reduce(0) { result, byte in
            (result << 8) + FourCharCode(byte)
        }
    }
}
