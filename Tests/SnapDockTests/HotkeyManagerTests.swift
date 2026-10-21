import AppKit
import KeyboardShortcuts
import XCTest
@testable import SnapDock

final class HotkeyManagerTests: XCTestCase {
    @MainActor
    func testDockSlotsUsePhysicalNumberRowInDockOrder() {
        let codes = (0..<10).compactMap {
            HotkeyManager.dockShortcut(at: $0, modifiers: [.control, .option])?.carbonKeyCode
        }
        XCTAssertEqual(codes, [18, 19, 20, 21, 23, 22, 26, 28, 25, 29])
        XCTAssertNil(HotkeyManager.dockShortcut(at: -1, modifiers: .option))
        XCTAssertNil(HotkeyManager.dockShortcut(at: 10, modifiers: .option))
    }

    @MainActor
    func testUnsupportedModifiersCannotBecomeUnmodifiedOrDifferentShortcuts() {
        XCTAssertNil(HotkeyManager.dockShortcut(at: 0, modifiers: []))
        XCTAssertNil(HotkeyManager.dockShortcut(at: 0, modifiers: .function))
        XCTAssertNil(HotkeyManager.dockShortcut(at: 0, modifiers: [.option, .capsLock]))
        let shortcut = HotkeyManager.dockShortcut(at: 0, modifiers: [.command, .shift])
        XCTAssertEqual(shortcut?.modifiers, [.command, .shift])
    }

    @MainActor
    func testSwitchedOffEntriesStopRegisteringAndReleaseTheirCombination() throws {
        let domain = "SnapDockTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dockURL = directory.appendingPathComponent("com.apple.dock.plist")
        try writeDock([("/System/Applications/Calculator.app", "com.apple.calculator"),
                       ("/System/Applications/Dictionary.app", "com.apple.Dictionary")], to: dockURL)
        let dock = DockMonitor(preferencesURL: dockURL)
        dock.refresh()
        let store = ShortcutStore(defaults: defaults)
        let manual = AppPicker.makeShortcut(from: URL(fileURLWithPath: "/System/Applications/TextEdit.app"))
        // Rare modifiers, so the test never competes with a running SnapDock for a registration.
        let modifiers = NSEvent.ModifierFlags([.control, .shift, .command])
        KeyboardShortcuts.setShortcut(.init(.one, modifiers: modifiers), for: manual.hotkeyName)
        XCTAssertTrue(store.add(manual))
        store.settings.modifiers = modifiers
        let manager = HotkeyManager.shared
        manager.start(store: store, dock: dock)
        defer {
            manager.stop()
            KeyboardShortcuts.setShortcut(nil, for: manual.hotkeyName)
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        let conflict = try XCTUnwrap(manager.automaticStatus[0])
        XCTAssertTrue(conflict.contains(manual.displayName))
        let registeredStatus = try XCTUnwrap(manager.manualStatus[manual.id])

        store.setEnabled(false, key: manual.manualKey)
        manager.refresh()
        let disabledStatus = try XCTUnwrap(manager.manualStatus[manual.id])
        XCTAssertNotEqual(disabledStatus, registeredStatus)
        XCTAssertFalse(store.isEnabled(manual.manualKey))
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: manual.hotkeyName),
                       .init(.one, modifiers: modifiers))
        XCTAssertNotEqual(manager.automaticStatus[0], conflict)

        store.setEnabled(false, key: try XCTUnwrap(dock.applications.first).automaticKey)
        manager.refresh()
        XCTAssertEqual(manager.automaticStatus[0], disabledStatus)
        XCTAssertNotEqual(manager.automaticStatus[1], disabledStatus)
    }

    func testHoldFiresOnlyOnceUntilReleaseOrPauseReset() {
        var gate = HotkeyPressState<String>()
        XCTAssertTrue(gate.press("first"))
        XCTAssertFalse(gate.press("first"))
        XCTAssertTrue(gate.press("second"))
        gate.release("first")
        XCTAssertTrue(gate.press("first"))
        XCTAssertFalse(gate.press("second"))
        gate.reset()
        XCTAssertTrue(gate.press("second"))
    }

    private func writeDock(_ applications: [(path: String, bundleIdentifier: String)], to url: URL) throws {
        let tiles = applications.map { application in
            ["tile-type": "file-tile",
             "tile-data": ["file-type": 41,
                           "bundle-identifier": application.bundleIdentifier,
                           "file-data": ["_CFURLString": "file://\(application.path)/", "_CFURLStringType": 15]]]
        }
        let data = try PropertyListSerialization.data(fromPropertyList: ["persistent-apps": tiles],
                                                      format: .binary, options: 0)
        try data.write(to: url, options: .atomic)
    }
}
