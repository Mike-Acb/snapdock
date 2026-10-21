import AppKit
import KeyboardShortcuts
import SwiftUI

@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()
    static let didChangeNotification = Notification.Name("ShortcutStoreDidChange")

    @Published private(set) var shortcuts: [AppShortcut] = []
    @Published private(set) var canRestoreImport = false
    @Published var lastError: LocalizedMessage?
    @Published var settings: SnapSettings {
        didSet {
            guard settings != oldValue else { return }
            guard !settings.modifiers.isEmpty else {
                settings = oldValue
                lastError = LocalizedMessage("core.modifierRequired")
                return
            }
            do {
                defaults.set(try JSONEncoder().encode(settings), forKey: Self.settingsKey)
                L10n.shared.apply(language: settings.language)
                notifyChange()
            } catch {
                settings = oldValue
                lastError = LocalizedMessage(error: error)
            }
        }
    }

    private static let shortcutsKey = "appShortcuts"
    private static let settingsKey = "snapDockSettings"
    private static let backupKey = "beforeSnapImport"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = SnapSettings()
        do {
            if let data = defaults.data(forKey: Self.shortcutsKey) {
                shortcuts = try JSONDecoder().decode([AppShortcut].self, from: data)
            }
            if let data = defaults.data(forKey: Self.settingsKey) {
                settings = try JSONDecoder().decode(SnapSettings.self, from: data)
                if settings.modifiers.isEmpty { settings.modifiers = .option }
            }
            canRestoreImport = defaults.data(forKey: Self.backupKey) != nil
        } catch {
            lastError = LocalizedMessage(render: { L10n.tr("core.readSettingsFailed", error.localizedDescription) })
        }
        L10n.shared.apply(language: settings.language)
    }

    func shortcut(id: UUID) -> AppShortcut? {
        shortcuts.first { $0.id == id }
    }

    /// Whether the entry still triggers its shortcut. Switching it off keeps the entry and its
    /// recorded combination; only the registration goes away.
    func isEnabled(_ key: String) -> Bool {
        !settings.disabledKeys.contains(key)
    }

    func setEnabled(_ enabled: Bool, key: String) {
        guard isEnabled(key) != enabled else { return }
        if enabled {
            settings.disabledKeys.remove(key)
        } else {
            settings.disabledKeys.insert(key)
        }
    }

    func hasDuplicate(bundleIdentifier: String?, excluding id: UUID? = nil) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        return shortcuts.contains { $0.bundleIdentifier == bundleIdentifier && $0.id != id }
    }

    func conflict(for combination: KeyboardShortcuts.Shortcut, excluding id: UUID? = nil) -> LocalizedMessage? {
        guard let existing = shortcuts.first(where: {
            $0.id != id && KeyboardShortcuts.getShortcut(for: $0.hotkeyName) == combination
        }) else { return nil }
        return LocalizedMessage("core.shortcutAssigned", existing.displayName)
    }

    @discardableResult
    func add(_ shortcut: AppShortcut) -> Bool {
        guard !shortcuts.contains(where: { $0.id == shortcut.id }), validate(shortcut) else { return false }
        return save(shortcuts + [shortcut])
    }

    func remove(_ shortcut: AppShortcut) {
        guard save(shortcuts.filter { $0.id != shortcut.id }) else { return }
        KeyboardShortcuts.setShortcut(nil, for: shortcut.hotkeyName)
        setEnabled(true, key: shortcut.manualKey)
    }

    func remove(id: UUID) {
        guard let shortcut = shortcut(id: id) else { return }
        remove(shortcut)
    }

    @discardableResult
    func update(_ shortcut: AppShortcut) -> Bool {
        guard let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }), validate(shortcut) else {
            return false
        }
        var updated = shortcuts
        updated[index] = shortcut
        return save(updated)
    }

    func perform(_ app: AppShortcut) {
        AppActivator.activateOrLaunch(app, hideIfFrontmost: settings.hideOnRepeat) { [weak self] result in
            switch result {
            case .success:
                if self?.lastError != nil { self?.lastError = nil }
            case .failure(let error):
                self?.lastError = LocalizedMessage(render: {
                    L10n.tr("core.appError", app.displayName, error.localizedDescription)
                })
            }
        }
    }

    func importSnap(_ preview: SnapImportPreview) throws {
        guard !preview.settings.modifiers.isEmpty else {
            throw LocalizedMessage("core.importModifiersInvalid")
        }
        var combinations = Set(shortcuts.compactMap { KeyboardShortcuts.getShortcut(for: $0.hotkeyName) })
        var ids = Set(shortcuts.map(\.id))
        for binding in preview.bindings {
            guard ids.insert(binding.app.id).inserted,
                  combinations.insert(binding.shortcut).inserted else {
                throw LocalizedMessage("core.importConflict", binding.app.displayName)
            }
        }

        let backup = ConfigurationSnapshot(
            settings: settings,
            entries: shortcuts.map {
                SavedShortcut(app: $0, shortcut: KeyboardShortcuts.getShortcut(for: $0.hotkeyName))
            }
        )
        // Per-app switches have no counterpart in Snap's preferences, so an import must not
        // silently switch those entries back on.
        var imported = preview.settings
        imported.disabledKeys = settings.disabledKeys
        imported.language = settings.language
        let encoder = JSONEncoder()
        let backupData = try encoder.encode(backup)
        let merged = shortcuts + preview.bindings.map(\.app)
        let mergedData = try encoder.encode(merged)
        let settingsData = try encoder.encode(imported)

        defaults.set(backupData, forKey: Self.backupKey)
        for binding in preview.bindings {
            KeyboardShortcuts.setShortcut(binding.shortcut, for: binding.app.hotkeyName)
        }
        defaults.set(mergedData, forKey: Self.shortcutsKey)
        defaults.set(settingsData, forKey: Self.settingsKey)
        shortcuts = merged
        settings = imported
        canRestoreImport = true
        lastError = nil
        notifyChange()
    }

    func restoreBeforeImport() throws {
        guard let data = defaults.data(forKey: Self.backupKey) else {
            throw LocalizedMessage("core.noImportBackup")
        }
        let backup = try JSONDecoder().decode(ConfigurationSnapshot.self, from: data)
        var restoredSettings = backup.settings
        restoredSettings.language = settings.language
        let restored = backup.entries.map(\.app)
        let restoredData = try JSONEncoder().encode(restored)
        let settingsData = try JSONEncoder().encode(restoredSettings)

        for app in shortcuts { KeyboardShortcuts.setShortcut(nil, for: app.hotkeyName) }
        for entry in backup.entries {
            KeyboardShortcuts.setShortcut(entry.shortcut, for: entry.app.hotkeyName)
        }
        defaults.set(restoredData, forKey: Self.shortcutsKey)
        defaults.set(settingsData, forKey: Self.settingsKey)
        shortcuts = restored
        settings = restoredSettings
        defaults.removeObject(forKey: Self.backupKey)
        canRestoreImport = false
        lastError = nil
        notifyChange()
    }

    private func validate(_ app: AppShortcut) -> Bool {
        guard let combination = KeyboardShortcuts.getShortcut(for: app.hotkeyName) else {
            lastError = LocalizedMessage("core.recordShortcutFirst")
            return false
        }
        if let message = conflict(for: combination, excluding: app.id) {
            lastError = message
            return false
        }
        lastError = nil
        return true
    }

    private func save(_ updated: [AppShortcut]) -> Bool {
        do {
            let data = try JSONEncoder().encode(updated)
            defaults.set(data, forKey: Self.shortcutsKey)
            shortcuts = updated
            notifyChange()
            return true
        } catch {
            lastError = LocalizedMessage(render: { L10n.tr("core.saveSettingsFailed", error.localizedDescription) })
            return false
        }
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

private struct SavedShortcut: Codable {
    let app: AppShortcut
    let shortcut: KeyboardShortcuts.Shortcut?
}

private struct ConfigurationSnapshot: Codable {
    let settings: SnapSettings
    let entries: [SavedShortcut]
}

