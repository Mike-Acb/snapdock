import AppKit
import KeyboardShortcuts

struct SnapSettings: Codable, Equatable {
    var automaticEnabled = true
    var modifierFlagsRawValue = NSEvent.ModifierFlags.option.rawValue
    var hideOnRepeat = true
    var showInStatusBar = true
    var language: AppLanguage = .simplifiedChinese
    /// Entries the user switched off but kept, see `AppShortcut.automaticKey` / `manualKey`.
    var disabledKeys: Set<String> = []

    var modifiers: NSEvent.ModifierFlags {
        get { NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue) }
        set { modifierFlagsRawValue = newValue.intersection([.command, .option, .control, .shift]).rawValue }
    }

    init() {}

    /// Settings written by an older build lack the newer keys, and synthesized decoding would throw
    /// on the first missing one and reset every choice the user made. Each key keeps its default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SnapSettings()
        automaticEnabled = try container.decodeIfPresent(Bool.self, forKey: .automaticEnabled)
            ?? defaults.automaticEnabled
        modifierFlagsRawValue = try container.decodeIfPresent(NSEvent.ModifierFlags.RawValue.self,
                                                              forKey: .modifierFlagsRawValue)
            ?? defaults.modifierFlagsRawValue
        hideOnRepeat = try container.decodeIfPresent(Bool.self, forKey: .hideOnRepeat) ?? defaults.hideOnRepeat
        showInStatusBar = try container.decodeIfPresent(Bool.self, forKey: .showInStatusBar)
            ?? defaults.showInStatusBar
        disabledKeys = try container.decodeIfPresent(Set<String>.self, forKey: .disabledKeys) ?? defaults.disabledKeys
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? defaults.language
    }
}

struct ShortcutBinding: Codable, Equatable {
    let app: AppShortcut
    let shortcut: KeyboardShortcuts.Shortcut
}
