import AppKit
import KeyboardShortcuts
import XCTest
@testable import SnapDock

@MainActor
final class SnapImporterTests: XCTestCase {
    func testInstalledSnapArchivePreservesFinderCommandShortcut() throws {
        let data = try XCTUnwrap(Data(base64Encoded: installedArchive, options: .ignoreUnknownCharacters))
        let preview = try SnapImporter.preview(preferences: ["apps": data], defaults: [:])

        XCTAssertEqual(preview.bindings.count, 1)
        XCTAssertEqual(preview.bindings.first?.app.bundleIdentifier, "com.apple.finder")
        XCTAssertEqual(preview.bindings.first?.shortcut, KeyboardShortcuts.Shortcut(.backtick, modifiers: .command))
        XCTAssertEqual(preview.skipped.count, 3)
    }

    func testUnassignedShortcutIsSkipped() throws {
        let preview = try SnapImporter.preview(preferences: ["apps": archive(keyCode: -1)], defaults: [:])
        XCTAssertTrue(preview.bindings.isEmpty)
        XCTAssertEqual(preview.skipped.count, 1)
    }

    func testMalformedRootReferenceThrows() throws {
        let data = try archive(root: ["CF$UID": 999])
        XCTAssertThrowsError(try SnapImporter.preview(preferences: ["apps": data], defaults: [:]))
    }
    func testInvalidShortcutFieldsAreSkipped() throws {
        let malformedFields: [[String: Any]] = [
            ["keyFlags": ["CF$UID": 999]],
            ["keyFlags": 0],
            ["keyCode": "50"],
            ["keyCode": true]
        ]
        for fields in malformedFields {
            let preview = try SnapImporter.preview(preferences: ["apps": archive(fields: fields)], defaults: [:])
            XCTAssertTrue(preview.bindings.isEmpty)
            XCTAssertEqual(preview.skipped.count, 1)
        }
    }

    func testUserSettingsOverrideOnlyPresentDefaults() throws {
        let preview = try SnapImporter.preview(
            preferences: ["apps": archive(), "option": true, "shift": false, "showInStatusBar": false],
            defaults: ["command": true, "shift": true, "showInStatusBar": true]
        )
        XCTAssertEqual(preview.settings.modifiers, [.command, .option])
        XCTAssertFalse(preview.settings.showInStatusBar)
    }

    func testMissingApplicationResolvesByArchivedBundleIdentifier() throws {
        let preview = try SnapImporter.preview(
            preferences: ["apps": archive(fields: ["bundleIdentifier": "com.apple.finder"], path: "file:///missing/Finder.app")],
            defaults: [:]
        )
        XCTAssertEqual(preview.bindings.first?.app.bundleIdentifier, "com.apple.finder")
        XCTAssertTrue(preview.skipped.isEmpty)
    }

    func testMissingArchiveDoesNotProduceSuccessfulPreview() {
        XCTAssertThrowsError(try SnapImporter.preview(preferences: [:], defaults: ["command": true]))
    }

    private func archive(
        keyCode: Int = 50,
        fields: [String: Any] = [:],
        path: String = "file:///System/Library/CoreServices/Finder.app/",
        root: [String: Int] = ["CF$UID": 1]
    ) throws -> Data {
        var record: [String: Any] = [
            "$class": ["CF$UID": 4], "appURL": ["CF$UID": 3],
            "keyCode": keyCode, "keyFlags": 1048576
        ]
        record.merge(fields) { _, new in new }
        return try PropertyListSerialization.data(fromPropertyList: [
            "$archiver": "NSKeyedArchiver", "$version": 100000,
            "$top": ["root": root],
            "$objects": [
                "$null",
                ["$class": ["CF$UID": 5], "NS.objects": [["CF$UID": 2]]],
                record,
                ["$class": ["CF$UID": 6], "NS.base": ["CF$UID": 0], "NS.relative": path],
                ["$classname": "Application"],
                ["$classname": "NSMutableArray"],
                ["$classname": "NSURL"]
            ]
        ], format: .xml, options: 0)
    }

    // A binary archive written by Snap 1.5, including its NSURL and NSNumber references.
    private let installedArchive = """
    YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMS
    AAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGvEBMLDBUdIyQrLDA1OTo7P0NE
    SExNVSRudWxs0g0ODxRaTlMub2JqZWN0c1YkY2xhc3OkEBESE4ACgAiADIAPgBLUFhcY
    DhkaGxxWYXBwVVJMV2tleUNvZGVYa2V5RmxhZ3OAAxP//////////4AGgAfTHg4fICEi
    V05TLmJhc2VbTlMucmVsYXRpdmWAAIAFgARfECdmaWxlOi8vL0FwcGxpY2F0aW9ucy9B
    eHVyZSUyMFJQJTIwOS5hcHDSJSYnKFokY2xhc3NuYW1lWCRjbGFzc2VzVU5TVVJM
    oikqVU5TVVJMWE5TT2JqZWN0EADSJSYtLltBcHBsaWNhdGlvbqItL1hOU09iamVjdNQW
    FxgOMTIzHIAJEDKAC4AH0x4OHyAhOIAAgAWACl8QOGZpbGU6Ly9sb2NhbGhvc3QvU3lz
    dGVtL0xpYnJhcnkvQ29yZVNlcnZpY2VzL0ZpbmRlci5hcHAvEgAQAADUFhcYDjwaGxyA
    DYAGgAfTHg4fICFCgACABYAOXxAkZmlsZTovLy9TeXN0ZW0vQXBwbGljYXRpb25zL01h
    aWwuYXBw1BYXGA5FGhscgBCABoAH0x4OHyAhS4AAgAWAEV8QJ2ZpbGU6Ly8vQXBwbGlj
    YXRpb25zL1N1YmxpbWUlMjBUZXh0LmFwcNIlJk5PXk5TTXV0YWJsZUFycmF5o05QUVdO
    U0FycmF5WE5TT2JqZWN0AAgAEQAaACQAKQAyADcASQBMAFEAUwBpAG8AdAB/AIYAiwCN
    AI8AkQCTAJUAngClAK0AtgC4AMEAwwDFAMwA1ADgAOIA5ADmARABFQEgASkBLwEyATgB
    QQFDAUgBVAFXAWABaQFrAW0BbwFxAXgBegF8AX4BuQG+AccByQHLAc0B1AHWAdgB2gIB
    AgoCDAIOAhACFwIZAhsCHQJHAkwCWwJfAmcAAAAAAAACAQAAAAAAAABSAAAAAAAAAAAAAAAA
    AAACcA==
    """
}
