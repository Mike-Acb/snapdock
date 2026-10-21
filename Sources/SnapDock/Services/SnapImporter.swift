import AppKit
import CoreFoundation
import Foundation
import KeyboardShortcuts

struct SnapImportPreview {
    let settings: SnapSettings
    let bindings: [ShortcutBinding]
    let skipped: [LocalizedMessage]
}

@MainActor
enum SnapImporter {
    static func loadPreview() throws -> SnapImportPreview {
        let domain = "com.iktm.snap" as CFString
        guard let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
              CFArrayGetCount(keys) > 0,
              let preferences = CFPreferencesCopyMultiple(keys, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any],
              !preferences.isEmpty
        else {
            throw LocalizedMessage("imports.snap.config_missing")
        }

        let defaultsURL = URL(fileURLWithPath: "/Applications/Snap.app/Contents/Resources/Defaults.plist")
        var defaults: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: defaultsURL.path) {
            guard let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: defaultsURL), options: [], format: nil) as? [String: Any] else {
                throw LocalizedMessage("imports.snap.defaults_invalid")
            }
            defaults = values
        }
        return try preview(preferences: preferences, defaults: defaults)
    }

    static func preview(preferences: [String: Any], defaults: [String: Any]) throws -> SnapImportPreview {
        guard let data = preferences["apps"] as? Data else {
            throw LocalizedMessage("imports.snap.archive_missing")
        }
        let archive = try SnapApplicationArchive(data: data)
        let records = try archive.records()
        var values: [String: Any] = ["command": true, "showInStatusBar": true]
        values.merge(defaults) { _, new in new }
        values.merge(preferences) { _, new in new }

        var settings = SnapSettings()
        var modifiers: NSEvent.ModifierFlags = []
        let modifierKeys: [(String, NSEvent.ModifierFlags)] = [
            ("command", .command), ("option", .option), ("control", .control), ("shift", .shift)
        ]
        for (name, flag) in modifierKeys {
            if try boolean(values[name], key: name) { modifiers.insert(flag) }
        }
        settings.modifierFlagsRawValue = modifiers.rawValue
        settings.showInStatusBar = try boolean(values["showInStatusBar"], key: "showInStatusBar")

        var bindings: [ShortcutBinding] = []
        var skipped: [LocalizedMessage] = []
        for (index, record) in records.enumerated() {
            var label = LocalizedMessage("imports.snap.application_number", index + 1)
            do {
                let fields = try archive.application(record)
                let originalURL = try archive.url(fields["appURL"])
                let name = originalURL.deletingPathExtension().lastPathComponent
                label = LocalizedMessage(render: { name })
                let keyCode = try archive.integer(fields["keyCode"])
                guard keyCode != -1 else {
                    skipped.append(LocalizedMessage("imports.snap.shortcut_unset", name))
                    continue
                }
                guard (0...127).contains(keyCode) else {
                    throw LocalizedMessage("imports.snap.key_code_unsupported")
                }
                let rawFlags = try archive.integer(fields["keyFlags"])
                let supported: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
                guard rawFlags >= 0, UInt(rawFlags) & ~supported.rawValue == 0 else {
                    throw LocalizedMessage("imports.snap.modifiers_unsupported")
                }
                let flags = NSEvent.ModifierFlags(rawValue: UInt(rawFlags))
                guard !flags.isEmpty else {
                    throw LocalizedMessage("imports.snap.modifiers_missing")
                }
                let bundleIdentifier = try archive.string(fields["bundleIdentifier"] ?? fields["bundleID"])
                let resolvedURL: URL
                if isApplication(originalURL) {
                    resolvedURL = originalURL
                } else if let bundleIdentifier,
                          let locatedURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
                          isApplication(locatedURL) {
                    resolvedURL = locatedURL
                } else {
                    throw LocalizedMessage("imports.snap.application_missing", originalURL.path)
                }
                var app = AppPicker.makeShortcut(from: resolvedURL)
                if app.bundleIdentifier == nil { app.bundleIdentifier = bundleIdentifier }
                bindings.append(ShortcutBinding(
                    app: app,
                    shortcut: KeyboardShortcuts.Shortcut(KeyboardShortcuts.Key(rawValue: keyCode), modifiers: flags)
                ))
            } catch {
                let failedLabel = label
                skipped.append(LocalizedMessage(render: {
                    L10n.tr("imports.labeled_reason", failedLabel.text, error.localizedDescription)
                }))
            }
        }
        return SnapImportPreview(settings: settings, bindings: bindings, skipped: skipped)
    }

    private static func boolean(_ value: Any?, key: String) throws -> Bool {
        guard let value else { return false }
        guard let number = value as? NSNumber,
              number == 0 || number == 1 else {
            throw LocalizedMessage("imports.snap.setting_invalid", key)
        }
        return number.boolValue
    }

    private static func isApplication(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return url.isFileURL && url.pathExtension.lowercased() == "app"
            && FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue
    }
}


private struct SnapApplicationArchive {
    private let objects: [Any]
    private let root: Any

    init(data: Data) throws {
        guard data.count <= 4 * 1024 * 1024 else {
            throw LocalizedMessage("imports.snap.archive_too_large")
        }
        do {
            let binary = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            let xml = try PropertyListSerialization.data(fromPropertyList: binary, format: .xml, options: 0)
            // Foundation otherwise converts CF$UID back into opaque objects when reading XML.
            let normalizedXML = String(decoding: xml, as: UTF8.self)
                .replacingOccurrences(of: "<key>CF$UID</key>", with: "<key>SnapDockArchiveUID</key>")
            let normalizedData = Data(normalizedXML.utf8)
            guard let archive = try PropertyListSerialization.propertyList(from: normalizedData, options: [], format: nil) as? [String: Any],
                  archive["$archiver"] as? String == "NSKeyedArchiver",
                  let objects = archive["$objects"] as? [Any],
                  !objects.isEmpty, objects.count <= 10_000,
                  let top = archive["$top"] as? [String: Any],
                  let root = top["root"] else {
                throw LocalizedMessage("imports.snap.archive_structure_invalid")
            }
            self.objects = objects
            self.root = root
        } catch let error as LocalizedMessage {
            throw error
        } catch {
            throw LocalizedMessage("imports.snap.archive_unreadable")
        }
    }

    func records() throws -> [Any] {
        guard let array = try value(root) as? [String: Any],
              ["NSArray", "NSMutableArray"].contains(try className(array)),
              let records = array["NS.objects"] as? [Any], records.count <= 10_000 else {
            throw LocalizedMessage("imports.snap.application_list_invalid")
        }
        return records
    }

    func application(_ raw: Any) throws -> [String: Any] {
        guard let fields = try value(raw) as? [String: Any],
              try className(fields) == "Application" else {
            throw LocalizedMessage("imports.snap.application_record_unsupported")
        }
        return fields
    }

    func integer(_ raw: Any?) throws -> Int {
        guard let result = try value(raw), let number = integerValue(result) else {
            throw LocalizedMessage("imports.snap.shortcut_number_invalid")
        }
        return number
    }

    func string(_ raw: Any?) throws -> String? {
        guard let result = try value(raw) else { return nil }
        guard let string = result as? String else {
            throw LocalizedMessage("imports.snap.application_info_invalid")
        }
        return string
    }

    func url(_ raw: Any?, depth: Int = 0) throws -> URL {
        guard depth < 16,
              let fields = try value(raw) as? [String: Any],
              try className(fields) == "NSURL",
              let relative = try string(fields["NS.relative"]) else {
            throw LocalizedMessage("imports.snap.application_path_invalid")
        }
        let base = try value(fields["NS.base"])
        let baseURL = try base.map { try url($0, depth: depth + 1) }
        guard let url = URL(string: relative, relativeTo: baseURL)?.absoluteURL,
              url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.path.hasPrefix("/"), url.pathExtension.lowercased() == "app" else {
            throw LocalizedMessage("imports.snap.application_path_not_local")
        }
        return url.standardizedFileURL
    }

    private func className(_ fields: [String: Any]) throws -> String {
        guard let metadata = try value(fields["$class"]) as? [String: Any],
              let name = metadata["$classname"] as? String else {
            throw LocalizedMessage("imports.snap.archive_type_invalid")
        }
        return name
    }

    private func value(_ raw: Any?, depth: Int = 0) throws -> Any? {
        guard depth < 16 else { throw LocalizedMessage("imports.snap.archive_reference_depth") }
        guard let raw else { return nil }
        if let reference = raw as? [String: Any], let indexValue = reference["SnapDockArchiveUID"] {
            guard reference.count == 1, let index = integerValue(indexValue), objects.indices.contains(index) else {
                throw LocalizedMessage("imports.snap.archive_reference_invalid")
            }
            if index == 0 { return nil }
            return try value(objects[index], depth: depth + 1)
        }
        return raw
    }

    private func integerValue(_ raw: Any) -> Int? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
        return Int(number.stringValue)
    }
}
