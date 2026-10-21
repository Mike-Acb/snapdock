import AppKit
import XCTest
@testable import SnapDock

final class AppMenuBuilderTests: XCTestCase {
    @MainActor
    func testMainMenuHandlesStandardShortcuts() throws {
        let items = AppMenuBuilder.makeMainMenu().items.flatMap { $0.submenu?.items ?? [] }
        func command(_ key: String) throws -> NSMenuItem {
            try XCTUnwrap(items.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == .command }, "⌘\(key)")
        }

        let settings = try command(",")
        XCTAssertEqual(settings.action, #selector(StatusItemActions.openSettings(_:)))
        XCTAssertTrue(settings.target === StatusItemActions.shared)
        XCTAssertEqual(settings.representedObject as? String, "settings")
        XCTAssertEqual(try command("w").action, #selector(NSWindow.performClose(_:)))
        XCTAssertEqual(try command("q").action, #selector(NSApplication.terminate(_:)))
    }
}
