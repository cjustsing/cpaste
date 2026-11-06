import AppKit
import ApplicationServices
import Carbon

enum PermissionHelper {
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        promptForAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum KeyboardPaster {
    /// Reports event construction/submission, not acknowledgement by the app.
    static func sendPasteCommand(to processIdentifier: pid_t) -> Bool {
        guard processIdentifier > 0 else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let source,
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return false }
        keyDown.flags = CGEventFlags.maskCommand
        keyUp.flags = CGEventFlags.maskCommand
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
        return true
    }
}
