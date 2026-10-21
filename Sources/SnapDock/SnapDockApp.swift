import AppKit
import SwiftUI

@main
@MainActor
enum SnapDockMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Create the status item before becoming accessory on macOS Tahoe.
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum WindowID: String {
        case settings
        case addShortcut
        case importApptivate

        var title: String {
            switch self {
            case .settings: return "SnapDock"
            case .addShortcut: return L10n.tr("interface.window.add_shortcut")
            case .importApptivate: return L10n.tr("interface.window.import_apptivate")
            }
        }
    }

    private var observers: [NSObjectProtocol] = []
    private var windows: [WindowID: NSWindow] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = ShortcutStore.shared
        DockMonitor.shared.start()
        HotkeyManager.shared.start(store: store, dock: .shared)
        StatusItemController.shared.install()
        StatusItemController.shared.setVisible(store.settings.showInStatusBar)
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = AppMenuBuilder.makeMainMenu()

        observe(.snapDockOpenSettings) { [weak self] notification in
            self?.showSettings(tab: notification.userInfo?["tab"] as? String ?? "automatic")
        }
        observe(.snapDockOpenAddShortcut) { [weak self] _ in
            self?.showWindow(id: .addShortcut, size: NSSize(width: 480, height: 300),
                             root: AddShortcutView().environmentObject(store))
        }
        observe(.snapDockOpenImportApptivate) { [weak self] _ in
            self?.showWindow(id: .importApptivate, size: NSSize(width: 560, height: 440),
                             root: ImportApptivateView().environmentObject(store))
        }
        observe(ShortcutStore.didChangeNotification) { _ in
            StatusItemController.shared.setVisible(store.settings.showInStatusBar)
        }
        observe(L10n.didChangeNotification) { [weak self] _ in
            self?.refreshLocalizedInterface()
        }
        observe(NSLocale.currentLocaleDidChangeNotification) { _ in
            L10n.shared.refreshSystemLanguage()
        }

        if !UserDefaults.standard.bool(forKey: "hasOpenedSettings") {
            showSettings()
            UserDefaults.standard.set(true, forKey: "hasOpenedSettings")
        }
        Log.app.notice("已启动，Dock 固定应用 \(DockMonitor.shared.applications.count) 个")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        L10n.shared.refreshSystemLanguage()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.stop()
        DockMonitor.shared.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func observe(_ name: Notification.Name, action: @escaping @MainActor (Notification) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
            notification in Task { @MainActor in action(notification) }
        })
    }

    private func refreshLocalizedInterface() {
        NSApp.mainMenu = AppMenuBuilder.makeMainMenu()
        for (id, window) in windows {
            window.title = id.title
        }
    }

    private func showSettings(tab: String = "automatic") {
        showWindow(id: .settings, size: NSSize(width: 720, height: 560),
                   root: SettingsView(initialTab: tab).environmentObject(ShortcutStore.shared))
    }

    private func showWindow<Content: View>(id: WindowID, size: NSSize, root: Content) {
        let window: NSWindow
        if let existing = windows[id] {
            window = existing
            if !existing.isVisible && !existing.isMiniaturized {
                window.contentViewController = NSHostingController(rootView: root)
            }
        } else {
            window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = id.title
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(size)
            window.minSize = size
            window.center()
            window.isReleasedWhenClosed = false
            windows[id] = window
        }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
