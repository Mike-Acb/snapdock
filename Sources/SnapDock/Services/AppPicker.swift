import AppKit
import Foundation
import UniformTypeIdentifiers

enum AppPicker {
    @MainActor
    static func pickApplication() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        localize(panel)
        let observer = NotificationCenter.default.addObserver(
            forName: L10n.didChangeNotification, object: nil, queue: .main
        ) { [weak panel] _ in
            Task { @MainActor in
                if let panel { localize(panel) }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }
        return url
    }

    @MainActor
    private static func localize(_ panel: NSOpenPanel) {
        panel.title = L10n.tr("interface.app_picker.title")
        panel.prompt = L10n.tr("interface.app_picker.choose")
        panel.message = L10n.tr("interface.app_picker.message")
    }

    static func makeShortcut(from url: URL) -> AppShortcut {
        let bundle = Bundle(url: url)
        let displayName =
            bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent

        return AppShortcut(
            appPath: url.path,
            bundleIdentifier: bundle?.bundleIdentifier,
            displayName: displayName
        )
    }
}
