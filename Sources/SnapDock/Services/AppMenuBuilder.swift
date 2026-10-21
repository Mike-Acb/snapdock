import AppKit

@MainActor
enum AppMenuBuilder {
    static func makeMenu() -> NSMenu {
        let store = ShortcutStore.shared
        let dock = DockMonitor.shared
        let hotkeys = HotkeyManager.shared
        let menu = NSMenu()
        menu.autoenablesItems = false

        addHeading(L10n.tr("interface.tab.automatic"), to: menu)
        for (index, app) in dock.applications.prefix(10).enumerated() {
            let combo = HotkeyManager.dockShortcut(at: index, modifiers: store.settings.modifiers)?.description ?? "—"
            let status = hotkeys.automaticStatus[index] ?? L10n.tr("interface.status.waiting")
            let item = actionItem(L10n.tr("interface.menu.shortcut_summary", app.displayName, combo, status), action: #selector(StatusItemActions.activateDockApp(_:)))
            item.representedObject = app.id.uuidString
            item.image = resizedIcon(app.icon)
            menu.addItem(item)
        }
        if dock.applications.isEmpty { addHeading(L10n.tr("interface.menu.no_dock_apps"), to: menu) }
        if let error = dock.lastError { addHeading(error.text, to: menu) }

        menu.addItem(.separator())
        addHeading(L10n.tr("interface.tab.manual"), to: menu)
        for app in store.shortcuts {
            let status = hotkeys.manualStatus[app.id] ?? L10n.tr("interface.status.waiting")
            let item = actionItem(L10n.tr("interface.menu.shortcut_summary", app.displayName, app.shortcutDisplay, status), action: #selector(StatusItemActions.activateShortcut(_:)))
            item.representedObject = app.id.uuidString
            item.image = resizedIcon(app.icon)
            menu.addItem(item)
        }
        if store.shortcuts.isEmpty { addHeading(L10n.tr("interface.menu.no_manual_shortcuts"), to: menu) }
        if let error = store.lastError { addHeading(error.text, to: menu) }

        menu.addItem(.separator())
        for (key, tab) in [("interface.menu.automatic", "automatic"), ("interface.menu.manual", "manual"), ("interface.menu.settings", "settings")] {
            menu.addItem(settingsItem(L10n.tr(key), tab: tab))
        }
        menu.addItem(actionItem(L10n.tr("interface.menu.add_shortcut"), action: #selector(StatusItemActions.openAddShortcut(_:))))
        menu.addItem(actionItem(L10n.tr("interface.action.import_apptivate"), action: #selector(StatusItemActions.openImportApptivate(_:))))
        menu.addItem(.separator())
        menu.addItem(quitItem())
        return menu
    }

    /// An accessory app shows no menu bar, but its main menu still handles key equivalents
    /// while a SnapDock window is active, e.g. ⌘, in the settings window.
    static func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu(title: "SnapDock")
        appMenu.addItem(settingsItem(L10n.tr("interface.menu.settings"), tab: "settings"))
        appMenu.addItem(.separator())
        appMenu.addItem(quitItem())

        let windowMenu = NSMenu(title: L10n.tr("interface.menu.window"))
        windowMenu.addItem(NSMenuItem(title: L10n.tr("interface.menu.close_window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

        let mainMenu = NSMenu()
        for submenu in [appMenu, windowMenu] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }

    private static func settingsItem(_ title: String, tab: String) -> NSMenuItem {
        let item = actionItem(title, action: #selector(StatusItemActions.openSettings(_:)))
        item.representedObject = tab
        if tab == "settings" { item.keyEquivalent = "," }
        return item
    }

    private static func quitItem() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.tr("interface.menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.target = NSApp
        return item
    }

    private static func actionItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = StatusItemActions.shared
        return item
    }

    private static func addHeading(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private static func resizedIcon(_ image: NSImage) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}
