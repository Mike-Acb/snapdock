import AppKit
import KeyboardShortcuts
import XCTest
@testable import SnapDock

final class ShortcutStoreTests: XCTestCase {
    @MainActor
    func testConflictingImportLeavesExistingConfigurationUntouched() async throws {
        let domain = "SnapDockTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let store = ShortcutStore(defaults: defaults)
        let first = AppPicker.makeShortcut(from: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        let second = AppPicker.makeShortcut(from: URL(fileURLWithPath: "/System/Applications/TextEdit.app"))
        let combination = KeyboardShortcuts.Shortcut(.one, modifiers: [.control, .option, .command])
        defer {
            KeyboardShortcuts.setShortcut(nil, for: first.hotkeyName)
            KeyboardShortcuts.setShortcut(nil, for: second.hotkeyName)
            defaults.removePersistentDomain(forName: domain)
        }
        KeyboardShortcuts.setShortcut(combination, for: first.hotkeyName)
        XCTAssertTrue(store.add(first))
        var importedSettings = store.settings
        importedSettings.automaticEnabled = false
        let preview = SnapImportPreview(settings: importedSettings,
                                        bindings: [ShortcutBinding(app: second, shortcut: combination)], skipped: [])

        XCTAssertThrowsError(try store.importSnap(preview))
        let reloaded = ShortcutStore(defaults: defaults)
        XCTAssertEqual(reloaded.shortcuts.map(\.id), [first.id])
        XCTAssertTrue(reloaded.settings.automaticEnabled)
        XCTAssertFalse(reloaded.canRestoreImport)
    }

    @MainActor
    func testImportRollbackSurvivesRestartAndRestoresOriginalBinding() async throws {
        let domain = "SnapDockTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let store = ShortcutStore(defaults: defaults)
        let first = AppPicker.makeShortcut(from: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        let second = AppPicker.makeShortcut(from: URL(fileURLWithPath: "/System/Applications/TextEdit.app"))
        let original = KeyboardShortcuts.Shortcut(.one, modifiers: [.control, .option, .command])
        let imported = KeyboardShortcuts.Shortcut(.two, modifiers: [.control, .option, .command])
        defer {
            KeyboardShortcuts.setShortcut(nil, for: first.hotkeyName)
            KeyboardShortcuts.setShortcut(nil, for: second.hotkeyName)
            defaults.removePersistentDomain(forName: domain)
        }
        KeyboardShortcuts.setShortcut(original, for: first.hotkeyName)
        XCTAssertTrue(store.add(first))
        var importedSettings = store.settings
        importedSettings.hideOnRepeat = false
        // Snap has no per-app switches, so the imported settings carry none.
        store.setEnabled(false, key: first.manualKey)
        try store.importSnap(SnapImportPreview(settings: importedSettings,
                                               bindings: [ShortcutBinding(app: second, shortcut: imported)], skipped: []))
        XCTAssertFalse(store.isEnabled(first.manualKey))
        KeyboardShortcuts.setShortcut(nil, for: first.hotkeyName)

        let restarted = ShortcutStore(defaults: defaults)
        try restarted.restoreBeforeImport()
        let restored = ShortcutStore(defaults: defaults)
        XCTAssertEqual(restored.shortcuts.map(\.id), [first.id])
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: first.hotkeyName), original)
        XCTAssertNil(KeyboardShortcuts.getShortcut(for: second.hotkeyName))
        XCTAssertTrue(restored.settings.hideOnRepeat)
        XCTAssertFalse(restored.isEnabled(first.manualKey))
        XCTAssertFalse(restored.canRestoreImport)
    }

    @MainActor
    func testSwitchedOffEntrySurvivesRestartAndOnlyItsOwnRemoval() throws {
        let domain = "SnapDockTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let store = ShortcutStore(defaults: defaults)
        let app = AppPicker.makeShortcut(from: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        let combination = KeyboardShortcuts.Shortcut(.one, modifiers: [.control, .option, .command])
        defer {
            KeyboardShortcuts.setShortcut(nil, for: app.hotkeyName)
            defaults.removePersistentDomain(forName: domain)
        }
        KeyboardShortcuts.setShortcut(combination, for: app.hotkeyName)
        XCTAssertTrue(store.add(app))

        store.setEnabled(false, key: app.manualKey)
        store.setEnabled(false, key: "com.example.dock")

        let reloaded = ShortcutStore(defaults: defaults)
        XCTAssertFalse(reloaded.isEnabled(app.manualKey))
        XCTAssertFalse(reloaded.isEnabled("com.example.dock"))
        // Switching off keeps the entry and the combination it recorded.
        XCTAssertEqual(reloaded.shortcuts.map(\.id), [app.id])
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: app.hotkeyName), combination)

        reloaded.remove(app)
        let afterRemoval = ShortcutStore(defaults: defaults)
        XCTAssertTrue(afterRemoval.isEnabled(app.manualKey))
        XCTAssertFalse(afterRemoval.isEnabled("com.example.dock"))
    }

    @MainActor
    func testSettingsSavedBeforePerAppSwitchesKeepEveryChoice() throws {
        let domain = "SnapDockTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let modifiers = NSEvent.ModifierFlags([.option, .command])
        let saved: [String: Any] = [
            "automaticEnabled": true,
            "modifierFlagsRawValue": modifiers.rawValue,
            "hideOnRepeat": false,
            "showInStatusBar": false
        ]
        // The key ShortcutStore persists settings under, as written by a build without `disabledKeys`.
        defaults.set(try JSONSerialization.data(withJSONObject: saved), forKey: "snapDockSettings")

        let store = ShortcutStore(defaults: defaults)

        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.settings.modifiers, modifiers)
        XCTAssertFalse(store.settings.hideOnRepeat)
        XCTAssertFalse(store.settings.showInStatusBar)
        XCTAssertTrue(store.isEnabled("com.example.dock"))
        XCTAssertEqual(store.settings.language, .simplifiedChinese)
    }

    @MainActor
    func testLanguageSurvivesRestartImportAndRestore() throws {
        let domain = "SnapDockTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let previousLanguage = L10n.shared.language
        defer {
            defaults.removePersistentDomain(forName: domain)
            L10n.shared.apply(language: previousLanguage)
        }
        let store = ShortcutStore(defaults: defaults)
        store.settings.language = .english
        let restarted = ShortcutStore(defaults: defaults)
        XCTAssertEqual(restarted.settings.language, .english)

        var importedSettings = SnapSettings()
        importedSettings.hideOnRepeat = false
        try restarted.importSnap(SnapImportPreview(settings: importedSettings, bindings: [], skipped: []))
        XCTAssertEqual(restarted.settings.language, .english)
        XCTAssertFalse(restarted.settings.hideOnRepeat)

        restarted.settings.language = .simplifiedChinese
        try restarted.restoreBeforeImport()
        let restored = ShortcutStore(defaults: defaults)
        XCTAssertEqual(restored.settings.language, .simplifiedChinese)
        XCTAssertTrue(restored.settings.hideOnRepeat)
    }

    func testUnknownLanguageKeepsOtherSavedSettings() throws {
        let saved: [String: Any] = [
            "language": "future-language",
            "hideOnRepeat": false,
            "showInStatusBar": false,
            "disabledKeys": ["com.example.dock"]
        ]
        let settings = try JSONDecoder().decode(SnapSettings.self, from: JSONSerialization.data(withJSONObject: saved))
        XCTAssertEqual(settings.language, .system)
        XCTAssertFalse(settings.hideOnRepeat)
        XCTAssertFalse(settings.showInStatusBar)
        XCTAssertEqual(settings.disabledKeys, ["com.example.dock"])
    }

    func testSystemLanguageUsesPreferenceOrderAndEnglishFallback() {
        XCTAssertEqual(AppLanguage.system.resolvedIdentifier(preferredLanguages: ["zh-Hans-CN", "en-US"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.system.resolvedIdentifier(preferredLanguages: ["en-GB", "zh-Hans"]), "en")
        XCTAssertEqual(AppLanguage.system.resolvedIdentifier(preferredLanguages: ["fr-FR", "zh-Hans"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.system.resolvedIdentifier(preferredLanguages: ["fr-FR"]), "en")
        XCTAssertEqual(AppLanguage.system.resolvedIdentifier(preferredLanguages: []), "en")
        XCTAssertEqual(AppLanguage.english.resolvedIdentifier(preferredLanguages: ["zh-Hans"]), "en")
        XCTAssertEqual(AppLanguage.simplifiedChinese.resolvedIdentifier(preferredLanguages: ["en"]), "zh-Hans")
    }
}
