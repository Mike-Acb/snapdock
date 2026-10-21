import Combine
import Foundation
import KeyboardShortcuts

enum AppLanguage: String, Codable, CaseIterable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .system
    }

    func resolvedIdentifier(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        guard self == .system else { return rawValue }
        return Bundle.preferredLocalizations(
            from: ["en", "zh-Hans"],
            forPreferences: preferredLanguages + ["en"]
        ).first ?? "en"
    }
}

/// The UI changes language on the main thread; error descriptions resolve lazily at presentation.
final class L10n: ObservableObject {
    static let shared = L10n()
    static let didChangeNotification = Notification.Name("SnapDockLanguageDidChange")

    @Published private(set) var revision = 0
    private(set) var language: AppLanguage = .system
    private(set) var resolvedLanguage: String
    var locale: Locale { Locale(identifier: resolvedLanguage) }

    private static let resourceBundle: Bundle = {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("SnapDock_SnapDock.bundle")
        return packaged.flatMap { Bundle(url: $0) } ?? .module
    }()

    private static let bundles: [String: Bundle] = {
        Dictionary(uniqueKeysWithValues: ["en", "zh-Hans"].map { language in
            // The native build system lowercases folder names (zh-hans.lproj); swiftbuild keeps zh-Hans.lproj.
            guard let path = resourceBundle.path(forResource: language, ofType: "lproj")
                    ?? resourceBundle.path(forResource: language.lowercased(), ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                preconditionFailure("Missing SnapDock localization: \(language)")
            }
            return (language, bundle)
        })
    }()

    private var bundle: Bundle

    private init() {
        let identifier = AppLanguage.system.resolvedIdentifier()
        resolvedLanguage = identifier
        bundle = Self.bundles[identifier]!
        KeyboardShortcuts.localizationLanguage = identifier
    }

    func apply(language: AppLanguage) {
        self.language = language
        let identifier = language.resolvedIdentifier()
        guard identifier != resolvedLanguage else { return }
        resolvedLanguage = identifier
        bundle = Self.bundles[identifier]!
        KeyboardShortcuts.localizationLanguage = identifier
        revision += 1
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    func refreshSystemLanguage() {
        guard language == .system else { return }
        apply(language: .system)
    }

    static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        format(key, arguments: arguments)
    }

    fileprivate static func format(_ key: String, arguments: [CVarArg]) -> String {
        let localization = shared
        let format = localization.bundle.localizedString(forKey: key, value: nil, table: nil)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: localization.locale, arguments: arguments)
    }
}

/// Keep a message's meaning rather than its translation in preview, validation, and error state.
struct LocalizedMessage: LocalizedError {
    private let render: () -> String

    var text: String { render() }
    var errorDescription: String? { text }

    init(_ key: String, _ arguments: CVarArg...) {
        render = { L10n.format(key, arguments: arguments) }
    }

    init(render: @escaping () -> String) {
        self.render = render
    }

    init(error: Error) {
        render = { error.localizedDescription }
    }
}
