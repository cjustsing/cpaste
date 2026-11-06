import AppKit

/// Let the current native editor handle standard text commands through the
/// responder chain. History-specific shortcuts remain in the local monitor.
enum NativeAppMenu {
    static func install(in app: NSApplication) {
        let mainMenu = NSMenu(title: "CPaste")
        let applicationItem = NSMenuItem(title: "CPaste", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "CPaste")
        applicationMenu.addItem(command(
            CPasteL10n.text("退出 CPaste", "Quit CPaste"),
            action: #selector(NSApplication.terminate(_:)), key: "q"
        ))
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editTitle = CPasteL10n.text("编辑", "Edit")
        let editItem = NSMenuItem(title: editTitle, action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: editTitle)
        editMenu.autoenablesItems = true
        editMenu.addItem(command(CPasteL10n.text("撤销", "Undo"), action: Selector(("undo:")), key: "z"))
        // Uppercase supplies Shift in AppKit's native key-equivalent matching.
        editMenu.addItem(command(
            CPasteL10n.text("重做", "Redo"), action: Selector(("redo:")), key: "Z"
        ))
        editMenu.addItem(.separator())
        editMenu.addItem(command(CPasteL10n.text("剪切", "Cut"), action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(command(CPasteL10n.text("复制", "Copy"), action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(command(CPasteL10n.text("粘贴", "Paste"), action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(command(CPasteL10n.text("全选", "Select All"), action: #selector(NSText.selectAll(_:)), key: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        app.mainMenu = mainMenu
    }

    private static func command(
        _ title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = nil
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
