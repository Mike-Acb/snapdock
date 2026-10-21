import AppKit
import Combine

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let shared = StatusItemController()
    private(set) var currentItem: NSStatusItem?
    private let menu = NSMenu()
    private var observations: Set<AnyCancellable> = []

    private override init() { super.init() }

    func install() {
        if currentItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "SnapDockStatusItem"
            item.button?.image = Self.makeStatusImage()
            item.button?.imagePosition = .imageOnly
            item.button?.toolTip = "SnapDock"
            menu.autoenablesItems = false
            menu.delegate = self
            menuNeedsUpdate(menu)
            item.menu = menu
            currentItem = item
        }
        currentItem?.isVisible = ShortcutStore.shared.settings.showInStatusBar
        guard observations.isEmpty else { return }
        NotificationCenter.default.publisher(for: ShortcutStore.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.setVisible(ShortcutStore.shared.settings.showInStatusBar) }
            }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: L10n.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.menuNeedsUpdate(self.menu)
                }
            }
            .store(in: &observations)
    }

    /// Builds items when the menu opens or the app language changes. Ordinary store, Dock
    /// and hotkey updates do not reload every app icon in the background.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let fresh = AppMenuBuilder.makeMenu()
        let items = fresh.items
        fresh.removeAllItems()
        menu.items = items
    }

    /// Monochrome version of the app icon (see App/MenuBarIcon.svg): a ⌥ sticker with its top-right
    /// corner peeled back. Drawn in code so it stays crisp at every scale; template so it follows
    /// the menu bar appearance.
    private static func makeStatusImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            NSColor.black.set()

            // Sticker body, cut along the fold line x - y = 11.
            NSGraphicsContext.saveGraphicsState()
            polygon([(0, 0), (11, 0), (18, 7), (18, 18), (0, 18)]).addClip()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 16, height: 16), xRadius: 3.5, yRadius: 3.5).fill()
            NSGraphicsContext.restoreGraphicsState()

            // Punch out the ⌥ glyph and a gap around the folded flap.
            let option = NSBezierPath()
            option.move(to: NSPoint(x: 3.6, y: 9))
            option.line(to: NSPoint(x: 6.2, y: 9))
            option.line(to: NSPoint(x: 9.6, y: 13.6))
            option.line(to: NSPoint(x: 14.4, y: 13.6))
            option.move(to: NSPoint(x: 10.4, y: 9))
            option.line(to: NSPoint(x: 14.4, y: 9))
            option.lineWidth = 1.7
            option.lineCapStyle = .round
            option.lineJoinStyle = .round
            let flap = polygon([(12, 1), (12, 6), (17, 6)])
            flap.lineWidth = 2
            flap.lineJoinStyle = .round
            context.compositingOperation = .clear
            option.stroke()
            flap.stroke()
            context.compositingOperation = .sourceOver

            flap.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SnapDock"
        return image
    }

    private static func polygon(_ points: [(CGFloat, CGFloat)]) -> NSBezierPath {
        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            let p = NSPoint(x: point.0, y: point.1)
            if index == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.close()
        return path
    }

    func setVisible(_ visible: Bool) {
        if currentItem == nil { install() }
        currentItem?.isVisible = visible
    }
}

@MainActor
final class StatusItemActions: NSObject {
    static let shared = StatusItemActions()

    @objc func activateShortcut(_ sender: NSMenuItem) {
        guard let id = uuid(from: sender), let app = ShortcutStore.shared.shortcut(id: id) else { return }
        ShortcutStore.shared.perform(app)
    }

    @objc func activateDockApp(_ sender: NSMenuItem) {
        guard let id = uuid(from: sender),
              let app = DockMonitor.shared.applications.first(where: { $0.id == id }) else { return }
        ShortcutStore.shared.perform(app)
    }

    @objc func openSettings(_ sender: NSMenuItem) {
        NotificationCenter.default.post(
            name: .snapDockOpenSettings,
            object: nil,
            userInfo: ["tab": sender.representedObject as? String ?? "automatic"]
        )
    }

    @objc func openAddShortcut(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: .snapDockOpenAddShortcut, object: nil)
    }

    @objc func openImportApptivate(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: .snapDockOpenImportApptivate, object: nil)
    }

    private func uuid(from sender: NSMenuItem) -> UUID? {
        guard let string = sender.representedObject as? String else { return nil }
        return UUID(uuidString: string)
    }
}

extension Notification.Name {
    static let snapDockOpenSettings = Notification.Name("snapDockOpenSettings")
    static let snapDockOpenAddShortcut = Notification.Name("snapDockOpenAddShortcut")
    static let snapDockOpenImportApptivate = Notification.Name("snapDockOpenImportApptivate")
}
