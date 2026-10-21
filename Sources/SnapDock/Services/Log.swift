import os

/// Unified-log channels. NSLog output is redacted as `<private>` on current macOS, so every
/// value that matters for diagnosis is logged with public privacy. View with:
/// `log stream --style compact --predicate 'subsystem == "local.snapdock.app"'`
enum Log {
    static let subsystem = "local.snapdock.app"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let activation = Logger(subsystem: subsystem, category: "activation")
    static let dock = Logger(subsystem: subsystem, category: "dock")
}
