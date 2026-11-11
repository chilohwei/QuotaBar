import AppKit

public enum QuotaBarApplication {
    @MainActor
    public static func run() -> Never {
        let app = NSApplication.shared
        configureEditingMenu(for: app)
        let appDelegate = AppDelegate()
        app.delegate = appDelegate
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
        fatalError("NSApplicationMain returned unexpectedly")
    }

    @MainActor
    static func configureEditingMenu(for app: NSApplication) {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a")
        ] {
            // A nil target routes the shortcut to the focused field editor.
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        app.mainMenu = mainMenu
    }
}
