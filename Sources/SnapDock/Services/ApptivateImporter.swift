import AppKit
import Foundation
import KeyboardShortcuts

enum ApptivateImporter {
    struct ImportedEntry: Identifiable, Hashable {
        let id = UUID()
        let appURL: URL
        let keyCode: Int
        let carbonModifiers: Int
        let displayName: String

        var shortcut: KeyboardShortcuts.Shortcut {
            KeyboardShortcuts.Shortcut(carbonKeyCode: keyCode, carbonModifiers: carbonModifiers)
        }

        @MainActor
        var shortcutDisplay: String {
            shortcut.description
        }

        var icon: NSImage {
            NSWorkspace.shared.icon(forFile: appURL.path)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        static func == (lhs: ImportedEntry, rhs: ImportedEntry) -> Bool {
            lhs.id == rhs.id
        }
    }

    struct Skip {
        let label: LocalizedMessage
        let reason: LocalizedMessage
    }

    struct Result {
        var imported: [ImportedEntry] = []
        var skipped: [Skip] = []
        var notes: [LocalizedMessage] = []
        var errorMessage: LocalizedMessage?
    }

    static var defaultHotkeysURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Apptivate/hotkeys")
    }

    static func importAvailable(at url: URL = defaultHotkeysURL) -> Bool {
        FileManager.default.isReadableFile(atPath: url.path)
    }

    static func loadEntries(from url: URL = defaultHotkeysURL) -> Result {
        var result = Result()

        guard FileManager.default.isReadableFile(atPath: url.path) else {
            result.errorMessage = LocalizedMessage("imports.apptivate.config_missing", url.path)
            return result
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            result.errorMessage = LocalizedMessage(render: {
                L10n.tr("imports.apptivate.file_unreadable", error.localizedDescription)
            })
            return result
        }

        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              root["$archiver"] as? String == "NSKeyedArchiver",
              let objects = root["$objects"] as? [Any],
              let top = root["$top"] as? [String: Any]
        else {
            result.errorMessage = LocalizedMessage("imports.apptivate.archive_unrecognized")
            return result
        }

        let resolver = KeyedArchiveResolver(objects: objects)
        guard let items = resolver.resolve(top["items"]) as? [Any] else {
            result.errorMessage = LocalizedMessage("imports.apptivate.items_missing")
            return result
        }

        for (index, item) in items.enumerated() {
            guard let dict = item as? [String: Any] else { continue }
            let className = dict["$class"] as? String ?? ""
            let label = LocalizedMessage("imports.apptivate.item_number", index + 1)

            guard className == "TAApplicationItem" || className.contains("Application") else {
                result.skipped.append(Skip(label: label, reason: LocalizedMessage("imports.apptivate.not_application")))
                continue
            }

            guard let alias = dict["fileAlias"] as? [String: Any],
                  let aliasData = aliasData(from: alias),
                  let relativePath = pathFromAliasData(aliasData)
            else {
                result.skipped.append(Skip(label: label, reason: LocalizedMessage("imports.apptivate.alias_unreadable")))
                continue
            }

            guard let appURL = resolveApplicationURL(relativePath: relativePath) else {
                result.skipped.append(Skip(label: LocalizedMessage(render: { relativePath }), reason: LocalizedMessage("imports.apptivate.application_missing")))
                continue
            }

            let displayName = AppPicker.makeShortcut(from: appURL).displayName

            guard let hotkeys = dict["hotkeys"] as? [Any] else {
                result.skipped.append(Skip(label: LocalizedMessage(render: { displayName }), reason: LocalizedMessage("imports.apptivate.hotkeys_missing")))
                continue
            }

            let combos = hotkeys.compactMap { hotkey -> (Int, Int)? in
                guard let hotkey = hotkey as? [String: Any],
                      let combo = hotkey["keyCombo"] as? [String: Any]
                else { return nil }
                let keyCode = intValue(combo["keyCode"]) ?? -1
                let mods = intValue(combo["mods"]) ?? 0
                guard keyCode >= 0 else { return nil }
                return (keyCode, mods)
            }

            guard let first = combos.first else {
                result.skipped.append(Skip(label: LocalizedMessage(render: { displayName }), reason: LocalizedMessage("imports.apptivate.shortcut_unset")))
                continue
            }

            if combos.count > 1 {
                // Apptivate sequences aren't fully supported — keep the first chord.
                result.notes.append(LocalizedMessage("imports.apptivate.sequence_reduced", displayName))
            }

            result.imported.append(
                ImportedEntry(
                    appURL: appURL,
                    keyCode: first.0,
                    carbonModifiers: first.1,
                    displayName: displayName
                )
            )
        }

        return result
    }

    /// Imports selected entries into the store. Skips apps that already have a shortcut with the same bundle id.
    @MainActor
    static func apply(entries: [ImportedEntry], to store: ShortcutStore, notes: [LocalizedMessage] = [], skipped: [Skip] = []) -> (added: Int, skipped: Int, message: LocalizedMessage) {
        var added = 0
        var skippedNotes = skipped.map { skip in
            LocalizedMessage(render: { L10n.tr("imports.labeled_reason", skip.label.text, skip.reason.text) })
        }
        skippedNotes.append(contentsOf: notes)

        for entry in entries {
            let draft = AppPicker.makeShortcut(from: entry.appURL)

            if store.hasDuplicate(bundleIdentifier: draft.bundleIdentifier) {
                skippedNotes.append(LocalizedMessage("imports.apptivate.duplicate_skipped", entry.displayName))
                continue
            }

            KeyboardShortcuts.setShortcut(entry.shortcut, for: draft.hotkeyName)
            if store.add(draft) {
                added += 1
            } else {
                KeyboardShortcuts.setShortcut(nil, for: draft.hotkeyName)
                let name = entry.displayName
                let reason = store.lastError ?? LocalizedMessage("imports.apptivate.add_failed")
                skippedNotes.append(LocalizedMessage(render: { L10n.tr("imports.labeled_reason", name, reason.text) }))
            }
        }

        let message = LocalizedMessage(render: { [added, skippedNotes] in
            var lines = [L10n.tr(added == 1 ? "imports.apptivate.imported_one" : "imports.apptivate.imported_many", added)]
            if !skippedNotes.isEmpty {
                lines.append("")
                lines.append(L10n.tr("imports.skipped_notes"))
                lines.append(contentsOf: skippedNotes.map { L10n.tr("imports.bullet", $0.text) })
            }
            return lines.joined(separator: "\n")
        })
        return (added, skippedNotes.count, message)
    }

    @MainActor
    static func apply(to store: ShortcutStore, at url: URL = defaultHotkeysURL) -> (added: Int, skipped: Int, message: LocalizedMessage) {
        let loaded = loadEntries(from: url)
        if let errorMessage = loaded.errorMessage {
            return (0, 0, errorMessage)
        }
        return apply(entries: loaded.imported, to: store, notes: loaded.notes, skipped: loaded.skipped)
    }

    /// Rows ready for the preview UI.
    @MainActor
    static func previewRows(from result: Result, store: ShortcutStore) -> [PreviewRow] {
        result.imported.map { entry in
            let draft = AppPicker.makeShortcut(from: entry.appURL)
            let duplicate = store.hasDuplicate(bundleIdentifier: draft.bundleIdentifier)
            return PreviewRow(entry: entry, isDuplicate: duplicate)
        }
    }

    struct PreviewRow: Identifiable {
        let entry: ImportedEntry
        let isDuplicate: Bool
        var id: UUID { entry.id }
    }

    // MARK: - Parsing helpers

    private static func aliasData(from alias: [String: Any]) -> Data? {
        if let data = alias["$0"] as? Data { return data }
        if let data = alias["NS.data"] as? Data { return data }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let i as Int: return i
        case let n as NSNumber: return n.intValue
        default: return nil
        }
    }

    /// Pulls a path like `Applications/iTerm.app` out of classic Mac alias record bytes.
    static func pathFromAliasData(_ data: Data) -> String? {
        // Prefer ASCII / MacRoman embedded POSIX-ish paths.
        if let latin = String(data: data, encoding: .isoLatin1),
           let path = firstAppPath(in: latin) {
            return path
        }

        // UTF-16 paths also appear in alias records.
        if data.count >= 2 {
            let utf16 = data.withUnsafeBytes { buffer -> String? in
                guard let base = buffer.bindMemory(to: UInt16.self).baseAddress else { return nil }
                let count = data.count / 2
                return String(utf16CodeUnits: base, count: count)
            }
            if let utf16, let path = firstAppPath(in: utf16) {
                return path
            }
        }

        return nil
    }

    private static func firstAppPath(in text: String) -> String? {
        // Alias records embed paths like `Applications/Foo.app` and HFS `/:Applications:Foo.app/`.
        // Note: do not use \0 in NSRegularExpression patterns — Swift turns it into a NUL and ICU rejects it.
        let patterns = [
            #"(?i)((?:System/)?Applications)/([^/:]+?\.app)"#,
            #"(?i):((?:System/)?Applications):([^:]+?\.app)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let folderRange = Range(match.range(at: 1), in: text),
                  let nameRange = Range(match.range(at: 2), in: text)
            else { continue }
            return "\(text[folderRange])/\(text[nameRange])"
        }
        return nil
    }

    static func resolveApplicationURL(relativePath: String) -> URL? {
        let trimmed = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
        let candidates = [
            URL(fileURLWithPath: "/\(trimmed)"),
            URL(fileURLWithPath: "/\(trimmed)".replacingOccurrences(of: "Applications/", with: "System/Applications/")),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(trimmed)
        ]

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        let name = URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: guessBundleId(forDisplayName: name)) {
            return url
        }

        // Last resort: search by localized name under /Applications
        let appName = URL(fileURLWithPath: relativePath).lastPathComponent
        let apps = URL(fileURLWithPath: "/Applications").appendingPathComponent(appName)
        if FileManager.default.fileExists(atPath: apps.path) {
            return apps
        }

        return nil
    }

    private static func guessBundleId(forDisplayName name: String) -> String {
        // Only used as a weak fallback; usually path resolution succeeds.
        name
    }
}

/// Minimal NSKeyedArchiver object-graph resolver (UID → value).
private final class KeyedArchiveResolver {
    private let objects: [Any]
    private var cache: [Int: Any] = [:]

    init(objects: [Any]) {
        self.objects = objects
    }

    func resolve(_ value: Any?) -> Any? {
        guard let value else { return nil }

        if let uid = uidIndex(value) {
            if let cached = cache[uid] { return cached }
            guard uid < objects.count else { return nil }
            let resolved = materialize(objects[uid], uid: uid)
            cache[uid] = resolved as Any
            return resolved
        }

        return materialize(value, uid: nil)
    }

    private func materialize(_ value: Any, uid: Int?) -> Any? {
        if value is NSNull { return nil }

        if let string = value as? String {
            return string == "$null" ? nil : string
        }

        if let data = value as? Data { return data }
        if let number = value as? NSNumber { return number }
        if let bool = value as? Bool { return bool }

        if let array = value as? [Any] {
            return array.map { resolve($0) as Any }
        }

        guard let dict = value as? [String: Any] else {
            return value
        }

        // Class metadata
        var className: String?
        if let classUID = dict["$class"], let classIdx = uidIndex(classUID), classIdx < objects.count,
           let classDict = objects[classIdx] as? [String: Any] {
            className = classDict["$classname"] as? String
        }

        // NSArray / NSMutableArray
        if dict["NS.keys"] == nil, let nsObjectsRaw = dict["NS.objects"] {
            let nsObjects = (nsObjectsRaw as? [Any])
                ?? (nsObjectsRaw as? NSArray as? [Any])
                ?? []
            return nsObjects.compactMap { resolve($0) }
        }

        // NSDictionary
        if let nsKeysRaw = dict["NS.keys"], let nsObjectsRaw = dict["NS.objects"] {
            let nsKeys = (nsKeysRaw as? [Any]) ?? (nsKeysRaw as? NSArray as? [Any]) ?? []
            let nsObjects = (nsObjectsRaw as? [Any]) ?? (nsObjectsRaw as? NSArray as? [Any]) ?? []
            var out: [String: Any] = [:]
            for (keyAny, valAny) in zip(nsKeys, nsObjects) {
                guard let key = resolve(keyAny) as? String else { continue }
                if let val = resolve(valAny) {
                    out[key] = val
                }
            }
            return out
        }

        // Custom object: resolve fields
        var out: [String: Any] = [:]
        if let className {
            out["$class"] = className
        }
        for (key, raw) in dict where key != "$class" {
            if let resolved = resolve(raw) {
                out[key] = resolved
            }
        }

        // NDAlias often stores data under "$0"
        if className == "NDAlias", out["$0"] == nil, let data = dict.values.compactMap({ $0 as? Data }).first {
            out["$0"] = data
        }

        return out
    }

    private func uidIndex(_ value: Any) -> Int? {
        // XML-style UID
        if let dict = value as? [String: Any] {
            if let n = dict["CF$UID"] as? Int { return n }
            if let n = dict["CF$UID"] as? NSNumber { return n.intValue }
            return nil
        }

        // Binary plist: CFKeyedArchiverUID
        let description = String(describing: value)
        guard description.contains("CFKeyedArchiverUID") else { return nil }

        let object = value as AnyObject
        let intValueSelector = Selector(("intValue"))
        if object.responds(to: intValueSelector),
           let number = object.perform(intValueSelector)?.takeUnretainedValue() as? NSNumber {
            return number.intValue
        }

        guard let regex = try? NSRegularExpression(pattern: #"value\s*=\s*(\d+)"#) else { return nil }
        let range = NSRange(description.startIndex..<description.endIndex, in: description)
        guard let match = regex.firstMatch(in: description, range: range),
              let valueRange = Range(match.range(at: 1), in: description)
        else { return nil }
        return Int(description[valueRange])
    }
}
