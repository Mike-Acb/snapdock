import AppKit
import Foundation
import KeyboardShortcuts

struct AppShortcut: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var appPath: String
    var bundleIdentifier: String?
    var displayName: String

    init(
        id: UUID = UUID(),
        appPath: String,
        bundleIdentifier: String?,
        displayName: String
    ) {
        self.id = id
        self.appPath = appPath
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }

    var hotkeyName: KeyboardShortcuts.Name {
        KeyboardShortcuts.Name(id.uuidString)
    }

    /// Key of the per-app switch for a Dock slot. Dock entries are rebuilt from the Dock
    /// preferences on every launch and get a fresh `id`, so the bundle identifier is what survives
    /// reordering and restarts.
    var automaticKey: String {
        bundleIdentifier ?? appPath
    }

    /// Key of the per-app switch for a manual shortcut, which keeps its `id` across edits.
    var manualKey: String {
        id.uuidString
    }

    var appURL: URL {
        URL(fileURLWithPath: appPath)
    }

    var existsAtPath: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: appPath, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && appPath.hasSuffix(".app")
    }

    var icon: NSImage {
        if existsAtPath {
            return NSWorkspace.shared.icon(forFile: appPath)
        }
        if let bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 32, height: 32))
    }

    @MainActor
    var shortcutDisplay: String {
        KeyboardShortcuts.getShortcut(for: hotkeyName)?.description ?? "—"
    }
}
