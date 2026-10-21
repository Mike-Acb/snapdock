import AppKit
import Carbon.HIToolbox
import Combine
import KeyboardShortcuts

struct HotkeyPressState<Key: Hashable> {
    private var held: Set<Key> = []

    mutating func press(_ key: Key) -> Bool { held.insert(key).inserted }
    mutating func release(_ key: Key) { held.remove(key) }
    mutating func reset() { held.removeAll(keepingCapacity: true) }
}

@MainActor
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    @Published private(set) var manualStatus: [UUID: String] = [:]
    @Published private(set) var automaticStatus: [Int: String] = [:]

    private enum Target: Hashable {
        case manual(UUID)
        case automatic(Int)

        var name: KeyboardShortcuts.Name {
            switch self {
            case .manual(let id): return .init("SnapDock.runtime.manual.\(id.uuidString)")
            case .automatic(let index): return .init("SnapDock.runtime.dock.\(index)")
            }
        }

        var logName: String {
            switch self {
            case .manual: return "手动快捷键"
            case .automatic(let index): return "Dock 第 \(index + 1) 个"
            }
        }
    }

    private enum PauseReason: Hashable { case recording, menu, sleep, session }

    private weak var store: ShortcutStore?
    private weak var dock: DockMonitor?
    private var registrations: [Target: KeyboardShortcuts.Shortcut] = [:]
    private var held = HotkeyPressState<Target>()
    private var pauses: Set<PauseReason> = []
    private var openMenus: Set<ObjectIdentifier> = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var dockSubscription: AnyCancellable?
    private var refreshScheduled = false
    private var isRefreshing = false
    private static let numberKeyCodes = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
    private static let supportedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    private init() {}

    static func dockShortcut(at index: Int, modifiers: NSEvent.ModifierFlags) -> KeyboardShortcuts.Shortcut? {
        guard numberKeyCodes.indices.contains(index), validModifiers(modifiers) else { return nil }
        let key = KeyboardShortcuts.Key(rawValue: numberKeyCodes[index])
        return .init(key, modifiers: modifiers)
    }

    private static func validModifiers(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers.isEmpty && modifiers.subtracting(supportedModifiers).isEmpty
    }

    private static func isSupported(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        let carbonMask = Int(cmdKey | optionKey | controlKey | shiftKey)
        return (0...127).contains(shortcut.carbonKeyCode) && validModifiers(shortcut.modifiers)
            && shortcut.carbonModifiers & ~carbonMask == 0
    }

    func start(store: ShortcutStore, dock: DockMonitor) {
        if self.store === store, self.dock === dock {
            refresh()
            return
        }
        stop()
        self.store = store
        self.dock = dock
        _ = Target.automatic(0).name

        observe(.default, ShortcutStore.didChangeNotification) { [weak self] _ in self?.scheduleRefresh() }
        observe(.default, L10n.didChangeNotification) { [weak self] _ in self?.scheduleRefresh() }
        observe(.default, .init("KeyboardShortcuts_shortcutByNameDidChange")) { [weak self] _ in
            self?.scheduleRefresh()
        }
        observe(.default, .init("KeyboardShortcuts_recorderActiveStatusDidChange")) { [weak self] note in
            self?.setPaused(.recording, note.userInfo?["isActive"] as? Bool == true)
        }
        observe(.default, NSMenu.didBeginTrackingNotification) { [weak self] note in
            guard let self, let menu = note.object as? NSMenu else { return }
            openMenus.insert(ObjectIdentifier(menu))
            setPaused(.menu, true)
        }
        observe(.default, NSMenu.didEndTrackingNotification) { [weak self] note in
            guard let self, let menu = note.object as? NSMenu else { return }
            openMenus.remove(ObjectIdentifier(menu))
            setPaused(.menu, !openMenus.isEmpty)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] _ in self?.setPaused(.sleep, true) }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] _ in self?.setPaused(.sleep, false) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] _ in
            self?.setPaused(.session, true)
        }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] _ in
            self?.setPaused(.session, false)
        }
        dockSubscription = dock.$applications.sink { [weak self] _ in self?.scheduleRefresh() }
        refresh()
    }

    func stop() {
        store = nil
        dock = nil
        dockSubscription = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        for target in Array(registrations.keys) { remove(target) }
        pauses.removeAll()
        openMenus.removeAll()
        held.reset()
        KeyboardShortcuts.isEnabled = true
        manualStatus = [:]
        automaticStatus = [:]
    }

    func refresh() {
        guard let store, let dock, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var desired: [Target: KeyboardShortcuts.Shortcut] = [:]
        var manual: [UUID: String] = [:]
        var automatic: [Int: String] = [:]
        var manualClaims: [KeyboardShortcuts.Shortcut: String] = [:]

        for app in store.shortcuts {
            // A switched-off entry keeps its combination on file but claims nothing, so a Dock slot
            // may use the same keys while it is off.
            guard store.isEnabled(app.manualKey) else {
                manual[app.id] = L10n.tr("runtime.hotkey.switchedOff")
                continue
            }
            guard let shortcut = KeyboardShortcuts.getShortcut(for: app.hotkeyName) else {
                manual[app.id] = L10n.tr("runtime.hotkey.unset")
                continue
            }
            guard Self.isSupported(shortcut) else {
                manual[app.id] = L10n.tr("runtime.hotkey.invalid")
                continue
            }
            if let owner = manualClaims[shortcut] {
                manual[app.id] = L10n.tr("runtime.hotkey.manualConflict", owner)
                continue
            }
            manualClaims[shortcut] = app.displayName
            guard AppActivator.resolveApplicationURL(for: app) != nil else {
                manual[app.id] = L10n.tr("runtime.hotkey.manualAppMissing")
                continue
            }
            desired[.manual(app.id)] = shortcut
        }

        for index in 0..<10 {
            guard store.settings.automaticEnabled else {
                automatic[index] = L10n.tr("runtime.hotkey.automaticDisabled")
                continue
            }
            guard dock.applications.indices.contains(index) else {
                automatic[index] = L10n.tr("runtime.hotkey.emptyDockSlot")
                continue
            }
            guard store.isEnabled(dock.applications[index].automaticKey) else {
                automatic[index] = L10n.tr("runtime.hotkey.switchedOff")
                continue
            }
            guard let shortcut = Self.dockShortcut(at: index, modifiers: store.settings.modifiers) else {
                automatic[index] = L10n.tr("runtime.hotkey.invalidModifiers")
                continue
            }
            if let owner = manualClaims[shortcut] {
                automatic[index] = L10n.tr("runtime.hotkey.automaticConflict", owner)
                continue
            }
            guard AppActivator.resolveApplicationURL(for: dock.applications[index]) != nil else {
                automatic[index] = L10n.tr("runtime.hotkey.dockAppMissing")
                continue
            }
            desired[.automatic(index)] = shortcut
        }

        for (target, shortcut) in registrations where desired[target] != shortcut {
            remove(target)
        }
        for (target, shortcut) in desired {
            if registrations[target] == nil {
                let name = target.name
                KeyboardShortcuts.removeHandler(for: name)
                KeyboardShortcuts.setTemporaryShortcut(shortcut, for: name)
                KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
                    MainActor.assumeIsolated { self?.keyDown(target) }
                }
                KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
                    MainActor.assumeIsolated { self?.held.release(target) }
                }
                registrations[target] = shortcut
            } else if pauses.isEmpty, !KeyboardShortcuts.isEnabled(for: target.name) {
                KeyboardShortcuts.enable(target.name)
            }
            let status = status(for: target)
            switch target {
            case .manual(let id): manual[id] = status
            case .automatic(let index): automatic[index] = status
            }
        }
        if manualStatus != manual || automaticStatus != automatic {
            logStatus(manual: manual, automatic: automatic)
        }
        if manualStatus != manual { manualStatus = manual }
        if automaticStatus != automatic { automaticStatus = automatic }
    }

    private func logStatus(manual: [UUID: String], automatic: [Int: String]) {
        let enabledText = L10n.tr("runtime.hotkey.enabled")
        let enabled = manual.values.lazy.filter { $0 == enabledText }.count
            + automatic.values.lazy.filter { $0 == enabledText }.count
        Log.hotkey.notice("快捷键状态更新：已启用 \(enabled) 个，暂停原因 \(String(describing: self.pauses), privacy: .public)")
        let quiet: Set<String> = [enabledText, L10n.tr("runtime.hotkey.automaticDisabled"),
                                  L10n.tr("runtime.hotkey.switchedOff"), L10n.tr("runtime.hotkey.paused"),
                                  L10n.tr("runtime.hotkey.recordingPaused"), L10n.tr("runtime.hotkey.unset"),
                                  L10n.tr("runtime.hotkey.emptyDockSlot")]
        for (index, status) in automatic.sorted(by: { $0.key < $1.key }) where !quiet.contains(status) {
            Log.hotkey.error("Dock 第 \(index + 1) 个：\(status, privacy: .public)")
        }
        for app in store?.shortcuts ?? [] {
            guard let status = manual[app.id], !quiet.contains(status) else { continue }
            Log.hotkey.error("手动「\(app.displayName, privacy: .public)」：\(status, privacy: .public)")
        }
    }

    private func keyDown(_ target: Target) {
        guard pauses.isEmpty else {
            Log.hotkey.notice("忽略 \(target.logName, privacy: .public)：已暂停 \(String(describing: self.pauses), privacy: .public)")
            return
        }
        guard let store, let shortcut = registrations[target],
              KeyboardShortcuts.isEnabled(for: target.name) else {
            Log.hotkey.notice("忽略 \(target.logName, privacy: .public)：快捷键未启用")
            return
        }
        guard held.press(target) else {
            Log.hotkey.notice("忽略 \(target.logName, privacy: .public)：上一次按键尚未松开")
            return
        }
        switch target {
        case .manual(let id):
            guard let app = store.shortcut(id: id), store.isEnabled(app.manualKey),
                  KeyboardShortcuts.getShortcut(for: app.hotkeyName) == shortcut else {
                Log.hotkey.notice("忽略手动快捷键：绑定已变化")
                return
            }
            Log.hotkey.notice("按下手动快捷键 → \(app.displayName, privacy: .public)")
            store.perform(app)
        case .automatic(let index):
            guard store.settings.automaticEnabled, let dock,
                  dock.applications.indices.contains(index),
                  store.isEnabled(dock.applications[index].automaticKey),
                  Self.dockShortcut(at: index, modifiers: store.settings.modifiers) == shortcut else {
                Log.hotkey.notice("忽略 \(target.logName, privacy: .public)：Dock 映射已变化")
                return
            }
            let app = dock.applications[index]
            Log.hotkey.notice("按下 \(target.logName, privacy: .public) → \(app.displayName, privacy: .public)")
            store.perform(app)
        }
    }

    private func remove(_ target: Target) {
        KeyboardShortcuts.removeHandler(for: target.name)
        KeyboardShortcuts.setTemporaryShortcut(nil, for: target.name)
        registrations[target] = nil
        held.release(target)
    }

    private func status(for target: Target) -> String {
        if pauses.contains(.recording) { return L10n.tr("runtime.hotkey.recordingPaused") }
        if !pauses.isEmpty { return L10n.tr("runtime.hotkey.paused") }
        if KeyboardShortcuts.isEnabled(for: target.name) { return L10n.tr("runtime.hotkey.enabled") }
        if let error = KeyboardShortcuts.registrationError(for: target.name) {
            if error == Int32(eventHotKeyExistsErr) {
                return L10n.tr("runtime.hotkey.occupied")
            }
            return L10n.tr("runtime.hotkey.registrationFailed", error)
        }
        return L10n.tr("runtime.hotkey.notEnabled")
    }

    private func setPaused(_ reason: PauseReason, _ paused: Bool) {
        if paused { pauses.insert(reason) } else { pauses.remove(reason) }
        Log.hotkey.info("暂停原因 \(String(describing: reason), privacy: .public) = \(paused)")
        held.reset()
        KeyboardShortcuts.isEnabled = pauses.isEmpty
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard store != nil, !isRefreshing, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            refreshScheduled = false
            refresh()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (Notification) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { action(note) }
        }
        observers.append((center, observer))
    }
}
