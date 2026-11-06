import AppKit

var inputCheckCleanup: (() -> Void)?

func inputCheck(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("Input check failed: \(message)\n", stderr)
        inputCheckCleanup?()
        exit(1)
    }
}

func inputKeyEvent(
    keyCode: UInt16,
    characters: String,
    flags: NSEvent.ModifierFlags,
    window: NSWindow
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    )!
}

// A process-local, offscreen window exercises the real AppKit field editor.
// AppKit requires a key window for nil-target responder-chain actions, so the
// test briefly activates itself and restores the previously active app.
let inputPreviousApplication = NSWorkspace.shared.frontmostApplication
app.setActivationPolicy(.accessory)
app.finishLaunching()
let inputWindow = NSWindow(
    contentRect: NSRect(x: -10_000, y: -10_000, width: 260, height: 80),
    styleMask: [.titled],
    backing: .buffered,
    defer: false
)
inputWindow.isReleasedWhenClosed = false
inputCheckCleanup = {
    inputWindow.orderOut(nil)
    inputWindow.close()
    app.deactivate()
    inputPreviousApplication?.activate(options: [])
}
let inputField = NSTextField(frame: NSRect(x: 10, y: 26, width: 240, height: 24))
inputWindow.contentView!.addSubview(inputField)
app.activate(ignoringOtherApps: true)
inputWindow.makeKeyAndOrderFront(nil)
let inputActivationDeadline = Date().addingTimeInterval(2)
while app.keyWindow !== inputWindow, Date() < inputActivationDeadline {
    if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
        app.sendEvent(event)
    }
}
inputCheck(app.keyWindow === inputWindow, "isolated window must be the process-local key window")

for text in ["selectallprobe", "中文搜索 👨‍👩‍👧‍👦 cafe\u{301} 尾部"] {
    inputField.stringValue = text
    inputCheck(inputWindow.makeFirstResponder(inputField), "native input field must accept focus")
    guard let editor = inputField.currentEditor() as? NSTextView else {
        fputs("Input check setup failed: native field editor unavailable\n", stderr)
        inputCheckCleanup?()
        exit(1)
    }
    inputCheck(editor.isFieldEditor && inputWindow.firstResponder === editor, "test must use the native field editor")
    let expectedLength = (text as NSString).length
    editor.setSelectedRange(NSRange(location: expectedLength, length: 0))
    let event = inputKeyEvent(keyCode: 0, characters: "a", flags: [.command], window: inputWindow)
    let handled = app.mainMenu?.performKeyEquivalent(with: event) ?? false
    inputCheck(
        editor.selectedRange() == NSRange(location: 0, length: expectedLength),
        "Cmd+A must select the complete native field-editor text through the shared application menu"
    )
    inputCheck(handled, "the application menu must handle Cmd+A")
    editor.deleteBackward(nil)
    inputCheck(editor.string.isEmpty, "Backspace after Cmd+A must remove the full Unicode input")
    inputWindow.endEditing(for: inputField)
}
inputCheckCleanup?()
inputCheckCleanup = nil
print("Native Cmd+A field-editor checks passed")
