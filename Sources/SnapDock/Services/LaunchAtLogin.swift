import Foundation
import ServiceManagement

@MainActor
enum LaunchAtLogin {
    private(set) static var lastError: LocalizedMessage?

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusText: LocalizedMessage {
        switch SMAppService.mainApp.status {
        case .enabled: return LocalizedMessage("runtime.login.enabled")
        case .requiresApproval: return LocalizedMessage("runtime.login.requiresApproval")
        case .notRegistered: return LocalizedMessage("runtime.login.disabled")
        case .notFound: return LocalizedMessage("runtime.login.appNotFound")
        @unknown default: return LocalizedMessage("runtime.login.unknown")
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
            return true
        } catch {
            lastError = LocalizedMessage(render: {
                L10n.tr("runtime.login.changeFailed", error.localizedDescription)
            })
            return false
        }
    }
}
