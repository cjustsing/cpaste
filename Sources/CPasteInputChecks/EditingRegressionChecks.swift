import AppKit
import CPasteCore

private final class InputActionResponder: NSResponder, NSMenuItemValidation {
    var calls: [String: Int] = [:]
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }
    override func resignFirstResponder() -> Bool { true }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { true }
    @objc func cut(_ sender: Any?) { calls["cut:", default: 0] += 1 }
    @objc func copy(_ sender: Any?) { calls["copy:", default: 0] += 1 }
    @objc func paste(_ sender: Any?) { calls["paste:", default: 0] += 1 }
    @objc func undo(_ sender: Any?) { calls["undo:", default: 0] += 1 }
    @objc func redo(_ sender: Any?) { calls["redo:", default: 0] += 1 }
    override func selectAll(_ sender: Any?) { calls["selectAll:", default: 0] += 1 }
}

private final class InputMarkedTextView: NSTextView {
    var receivedKeys: [UInt16] = []
    override func keyDown(with event: NSEvent) {
        // Keep the marked text stable while verifying that the real local
        // monitor forwards these events to the composing native text view.
        receivedKeys.append(event.keyCode)
    }
}

private final class InputUndoToken: NSObject {
    var calls = 0
}

private func inputMenuItems(in menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { item in
        [item] + (item.submenu.map { inputMenuItems(in: $0) } ?? [])
    }
}

private func updateInputMenus(_ menu: NSMenu) {
    menu.update()
    for submenu in menu.items.compactMap(\.submenu) { updateInputMenus(submenu) }
}

private func dispatchInputKey(
    app: NSApplication,
    window: NSWindow,
    keyCode: UInt16,
    characters: String,
    flags: NSEvent.ModifierFlags = []
) {
    let event = inputKeyEvent(keyCode: keyCode, characters: characters, flags: flags, window: window)
    app.postEvent(event, atStart: true)
    if let queued = app.nextEvent(matching: .keyDown, until: Date().addingTimeInterval(0.1), inMode: .default, dequeue: true) {
        app.sendEvent(queued)
    }
}

private func testHistoryInputCommandMatrix() {
    func expect(
        _ keyCode: UInt16,
        _ flags: NSEvent.ModifierFlags = [],
        focused: Bool = true,
        empty: Bool = false,
        _ expected: HistoryKeyboardCommand?
    ) {
        inputCheck(
            HistoryKeyboardMonitor.Coordinator.command(
                forKeyCode: keyCode, modifierFlags: flags,
                isSearchFocused: focused, isSearchEmpty: empty
            ) == expected,
            "history keyboard mapping changed for key \(keyCode), modifiers \(flags.rawValue)"
        )
    }
    for key in [UInt16(0), 7, 9, 6] { expect(key, .command, nil) }
    expect(6, [.command, .shift], nil)
    expect(8, .command, nil)
    expect(8, .command, empty: true, .copy)
    expect(8, .command, focused: false, .copy)
    expect(3, .command, .focusSearch)
    expect(34, .command, .toggleInspector)
    expect(35, [.command, .shift], .togglePinned)
    expect(43, .command, .showSettings)
    expect(17, .command, .toggleCapture)
    expect(126, .command, .first)
    expect(125, .command, .last)
    let numberCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    for (offset, code) in numberCodes.enumerated() { expect(code, .command, .quickPaste(offset + 1)) }
    expect(18, .option, .showHistory)
    expect(19, .option, .showPinned)
    expect(48, [], .focusTimeline)
    expect(48, focused: false, .focusSearch)
    expect(53, [], .closeOrClearSearch)
    expect(126, [], .previous)
    expect(125, [], .next)
    expect(123, [], nil)
    expect(124, [], nil)
    expect(123, empty: true, .previous)
    expect(124, empty: true, .next)
    expect(123, focused: false, .previous)
    expect(124, focused: false, .next)
    expect(36, [], .paste)
    expect(36, .shift, .pastePlainText)
    expect(76, .shift, .pastePlainText)
    expect(49, [], nil)
    expect(49, focused: false, .toggleInspector)
    expect(35, [], nil)
    expect(35, focused: false, .togglePinned)
    expect(51, [], nil)
    expect(51, focused: false, .delete)
    expect(0, .control, nil)
}

private func testMenuActionsAndRouting(app: NSApplication, window: NSWindow) {
    let definitions: [(String, String, UInt16, NSEvent.ModifierFlags)] = [
        ("selectAll:", "a", 0, .command),
        ("cut:", "x", 7, .command),
        ("copy:", "c", 8, .command),
        ("paste:", "v", 9, .command),
        ("undo:", "z", 6, .command),
        ("redo:", "z", 6, [.command, .shift])
    ]
    let menu = app.mainMenu!
    let allItems = inputMenuItems(in: menu)
    let responder = InputActionResponder()
    responder.nextResponder = window
    inputCheck(window.makeFirstResponder(responder), "isolated action responder must accept focus")
    updateInputMenus(menu)
    for (action, key, keyCode, flags) in definitions {
        let selector = NSSelectorFromString(action)
        let matches = allItems.filter { $0.action == selector }
        inputCheck(matches.count == 1, "there must be one standard menu action for \(action)")
        let item = matches[0]
        inputCheck(item.target == nil, "\(action) must use the native responder chain")
        let logicalKey = item.keyEquivalent.lowercased()
        var logicalFlags = item.keyEquivalentModifierMask
        if item.keyEquivalent != logicalKey { logicalFlags.insert(.shift) }
        inputCheck(logicalKey == key && logicalFlags == flags, "\(action) must use its standard exact keyboard shortcut")
        inputCheck(item.menu?.autoenablesItems == true, "editing items must use automatic validation")
        inputCheck(
            app.target(forAction: selector, to: nil, from: item) as? InputActionResponder === responder,
            "editing test must resolve to its clipboard-free action responder"
        )
        let characters = flags.contains(.shift) ? key.uppercased() : key
        dispatchInputKey(app: app, window: window, keyCode: keyCode, characters: characters, flags: flags)
        inputCheck(responder.calls[action] == 1, "native event queue must dispatch \(action) exactly once")
    }
    for flags: NSEvent.ModifierFlags in [[.command, .shift], [.command, .option], .control] {
        inputCheck(!menu.performKeyEquivalent(with: inputKeyEvent(keyCode: 9, characters: flags.contains(.shift) ? "V" : "v", flags: flags, window: window)), "ordinary Paste must not capture additional modifier combinations")
    }

    var handledHistory: [HistoryKeyboardCommand] = []
    let monitor = HistoryKeyboardMonitor.Coordinator(isSearchFocused: true, isSearchEmpty: false) {
        handledHistory.append($0)
        return true
    }
    monitor.hostView = window.contentView
    monitor.install()
    defer { monitor.uninstall() }
    let copiedBefore = responder.calls["copy:", default: 0]
    dispatchInputKey(app: app, window: window, keyCode: 8, characters: "c", flags: .command)
    inputCheck(responder.calls["copy:"] == copiedBefore + 1 && handledHistory.isEmpty, "nonempty search Cmd+C must reach the native copy responder through the real event path")
    monitor.isSearchEmpty = true
    dispatchInputKey(app: app, window: window, keyCode: 8, characters: "c", flags: .command)
    inputCheck(handledHistory == [.copy] && responder.calls["copy:"] == copiedBefore + 1, "empty search Cmd+C must copy history without invoking native Copy")
    monitor.isSearchFocused = false
    dispatchInputKey(app: app, window: window, keyCode: 8, characters: "c", flags: .command)
    inputCheck(handledHistory == [.copy, .copy] && responder.calls["copy:"] == copiedBefore + 1, "timeline Cmd+C must retain its history action")

    inputCheck(window.makeFirstResponder(nil), "test must be able to clear its editing responder")
    updateInputMenus(menu)
    for action in ["cut:", "copy:", "paste:", "selectAll:"] {
        let item = allItems.first { $0.action == NSSelectorFromString(action) }!
        inputCheck(!item.isEnabled, "\(action) must be disabled without an editing responder")
    }
}

private func testMarkedTextAndSheetEventPassThrough(app: NSApplication, window: NSWindow) {
    let composing = InputMarkedTextView(frame: NSRect(x: 5, y: 5, width: 240, height: 60))
    window.contentView!.addSubview(composing)
    defer { composing.removeFromSuperview() }
    inputCheck(window.makeFirstResponder(composing), "native composing view must accept focus")
    composing.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    inputCheck(composing.hasMarkedText(), "IME regression fixture must have native marked text")
    var handledHistory: [HistoryKeyboardCommand] = []
    let monitor = HistoryKeyboardMonitor.Coordinator(isSearchFocused: true, isSearchEmpty: false) {
        handledHistory.append($0)
        return true
    }
    monitor.hostView = composing
    monitor.install()
    defer { monitor.uninstall() }
    let composingKeys: [(UInt16, String)] = [
        (36, "\r"), (49, " "), (123, "\u{f702}"), (124, "\u{f703}"),
        (125, "\u{f701}"), (126, "\u{f700}"), (53, "\u{1b}")
    ]
    for (code, characters) in composingKeys {
        let event = inputKeyEvent(keyCode: code, characters: characters, flags: [], window: window)
        inputCheck(app.mainMenu?.performKeyEquivalent(with: event) == false, "Edit menu must not claim an unmodified composition key")
        dispatchInputKey(app: app, window: window, keyCode: code, characters: characters)
    }
    inputCheck(handledHistory.isEmpty, "marked text must keep Return, Space, arrows, and Escape out of history shortcuts")
    inputCheck(composing.receivedKeys == composingKeys.map(\.0), "composing native view must receive every forwarded key")
    composing.unmarkText()
    dispatchInputKey(app: app, window: window, keyCode: 35, characters: "P", flags: [.command, .shift])
    inputCheck(handledHistory == [.togglePinned], "the real monitor must resume history shortcuts after marked text ends")

    let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
    sheet.isReleasedWhenClosed = false
    window.beginSheet(sheet)
    inputCheck(window.attachedSheet === sheet, "sheet pass-through fixture must use an attached native sheet")
    let sheetField = NSTextField(frame: NSRect(x: 5, y: 18, width: 110, height: 24))
    sheetField.stringValue = "弹窗 中文 👨‍👩‍👧‍👦"
    sheet.contentView!.addSubview(sheetField)
    sheet.makeKeyAndOrderFront(nil)
    inputCheck(sheet.makeFirstResponder(sheetField), "native sheet input must accept focus")
    let sheetEditor = sheetField.currentEditor() as! NSTextView
    let sheetLength = (sheetField.stringValue as NSString).length
    sheetEditor.setSelectedRange(NSRange(location: sheetLength, length: 0))
    dispatchInputKey(app: app, window: sheet, keyCode: 0, characters: "a", flags: .command)
    inputCheck(sheetEditor.selectedRange() == NSRange(location: 0, length: sheetLength), "sheet Cmd+A must select text in its own current native field editor")
    dispatchInputKey(app: app, window: window, keyCode: 36, characters: "\r")
    inputCheck(handledHistory == [.togglePinned], "history monitor must not consume input while a native sheet is attached")
    window.endSheet(sheet)
    sheet.orderOut(nil)
    sheet.close()
    window.makeKeyAndOrderFront(nil)
}

private func testMenuLanguageReinstallation(app: NSApplication, window: NSWindow, field: NSTextField) {
    let previousLanguage = CPasteL10n.language
    defer {
        CPasteL10n.language = previousLanguage
        NativeAppMenu.install(in: app)
    }
    field.stringValue = "前缀 中文 👨‍👩‍👧‍👦 cafe\u{301} 后缀"
    inputCheck(window.makeFirstResponder(field), "native field editor must regain focus after menu tests")
    let editor = field.currentEditor() as! NSTextView
    let selectedRange = NSRange(location: 3, length: ("中文 👨‍👩‍👧‍👦 cafe\u{301}" as NSString).length)
    editor.setSelectedRange(selectedRange)
    let undoManager = editor.undoManager
    let undoToken = InputUndoToken()
    if let undoManager {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: undoToken) { $0.calls += 1 }
        undoManager.endUndoGrouping()
    }
    defer { undoManager?.removeAllActions(withTarget: undoToken) }
    let canUndo = undoManager?.canUndo
    for (language, title) in [(AppLanguage.english, "Select All"), (.simplifiedChinese, "全选")] {
        CPasteL10n.language = language
        NativeAppMenu.install(in: app)
        inputCheck(window.firstResponder === editor && field.currentEditor() === editor, "menu localization must retain the same native field editor")
        inputCheck(editor.selectedRange() == selectedRange && editor.string == field.stringValue, "menu localization must preserve the text and UTF-16 selection")
        inputCheck(editor.undoManager === undoManager && editor.undoManager?.canUndo == canUndo, "menu localization must preserve the native undo manager and its pending actions")
        let selectAll = inputMenuItems(in: app.mainMenu!).first { $0.action == NSSelectorFromString("selectAll:") }
        inputCheck(selectAll?.title == title, "editing menu labels must follow the interface language")
    }
}

func runFullNativeInputChecks(app: NSApplication, window: NSWindow, field: NSTextField) {
    testHistoryInputCommandMatrix()
    testMenuActionsAndRouting(app: app, window: window)
    testMarkedTextAndSheetEventPassThrough(app: app, window: window)
    testMenuLanguageReinstallation(app: app, window: window, field: field)
    print("Native menu, event routing, marked text, sheet, and shortcut checks passed")
}
