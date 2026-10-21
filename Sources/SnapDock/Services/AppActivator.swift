import AppKit
import Foundation

/// The parts of `NSRunningApplication` activation relies on, so tests can drive the fallback path.
@MainActor
protocol ActivatableApplication: AnyObject {
    var processIdentifier: pid_t { get }
    var bundleURL: URL? { get }
    var activationPolicy: NSApplication.ActivationPolicy { get }
    var isHidden: Bool { get }
    func hide() -> Bool
    func unhide() -> Bool
    func activate(options: NSApplication.ActivationOptions) -> Bool
}

extension NSRunningApplication: ActivatableApplication {}

/// System hooks used by `AppActivator`; tests replace them.
struct ActivationEnvironment {
    var frontmostProcessIdentifier: @MainActor () -> pid_t? = {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    var openApplication: @MainActor (
        URL, NSWorkspace.OpenConfiguration, @escaping @MainActor (ActivatableApplication?, Error?) -> Void
    ) -> Void = { url, configuration, completion in
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { running, error in
            Task { @MainActor in completion(running, error) }
        }
    }
    /// LaunchServices normally brings a running app forward within 200 ms.
    var openTimeout: TimeInterval = 1
    /// Busy apps such as WeChat take several hundred ms to finish hiding.
    var hideTimeout: TimeInterval = 2
    var activateTimeout: TimeInterval = 0.5
    var launchTimeout: TimeInterval = 5
    var pollInterval: TimeInterval = 0.02
}

@MainActor
enum AppActivator {
    static var environment = ActivationEnvironment()
    private static var latestRequestID = 0

    static func activateOrLaunch(
        _ app: AppShortcut,
        hideIfFrontmost: Bool = false,
        completion: @escaping (Result<Void, Error>) -> Void = { _ in }
    ) {
        perform(app, running: findRunningApplication(for: app),
                hideIfFrontmost: hideIfFrontmost, completion: completion)
    }

    static func perform(
        _ app: AppShortcut,
        running: ActivatableApplication?,
        hideIfFrontmost: Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        latestRequestID += 1
        let request = Request(id: latestRequestID, app: app, completion: completion)
        guard let running else {
            guard let url = resolveApplicationURL(for: app) else {
                request.fail(ActivationError.notFound(app.displayName))
                return
            }
            launch(url, request)
            return
        }

        let pid = running.processIdentifier
        if hideIfFrontmost, environment.frontmostProcessIdentifier() == pid {
            hide(running, request)
            return
        }

        Log.activation.notice(
            "切换：\(app.displayName, privacy: .public) pid=\(pid) 隐藏=\(running.isHidden)"
        )
        guard let url = running.bundleURL ?? resolveApplicationURL(for: app) else {
            activateDirectly(running, request)
            return
        }
        // Same path as a Dock click and the original Snap: LaunchServices unhides, activates and
        // reopens a window when none is open, in one request.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        environment.openApplication(url, configuration) { _, error in
            guard request.isCurrent() else { return }
            if let error {
                Log.activation.error(
                    "LaunchServices 打开失败：\(app.displayName, privacy: .public)：\(error.localizedDescription, privacy: .public)"
                )
                activateDirectly(running, request)
                return
            }
            // Agent apps may never become frontmost; there is nothing to verify.
            guard running.activationPolicy == .regular else {
                request.succeed("切换（LaunchServices）")
                return
            }
            waitUntilFrontmost(pid, request, deadline: request.started + environment.openTimeout) { isFrontmost in
                if isFrontmost {
                    request.succeed("切换（LaunchServices）")
                } else {
                    Log.activation.notice(
                        "LaunchServices 发出 \(request.elapsed) ms 后仍未到前台，改用 activate：\(app.displayName, privacy: .public)"
                    )
                    activateDirectly(running, request)
                }
            }
        }
    }

    private static func launch(_ url: URL, _ request: Request) {
        Log.activation.notice("启动：\(request.app.displayName, privacy: .public)")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        environment.openApplication(url, configuration) { running, error in
            if let error {
                request.fail(error)
                return
            }
            guard let running else {
                request.fail(ActivationError.launch(request.app.displayName))
                return
            }
            guard request.isCurrent(), running.activationPolicy == .regular else {
                request.succeed("启动")
                return
            }
            waitUntilFrontmost(running.processIdentifier, request,
                               deadline: Date() + environment.launchTimeout) { isFrontmost in
                if isFrontmost {
                    request.succeed("启动")
                } else {
                    Log.activation.notice("启动后未到前台，改用 activate：\(request.app.displayName, privacy: .public)")
                    activateDirectly(running, request)
                }
            }
        }
    }

    /// AppKit on macOS 26 returns the inverse of LaunchServices' status from `hide()` and
    /// `unhide()`, so a request that was sent comes back as `false`. Judge by the app's state.
    private static func hide(_ running: ActivatableApplication, _ request: Request) {
        _ = running.hide()
        poll(request, deadline: Date() + environment.hideTimeout, condition: { running.isHidden }) { isHidden in
            if isHidden {
                request.succeed("隐藏")
            } else {
                request.fail(ActivationError.hide(request.app.displayName))
            }
        }
    }

    /// Fallback for when LaunchServices did not bring the app forward.
    private static func activateDirectly(_ running: ActivatableApplication, _ request: Request) {
        guard running.isHidden else {
            activateNow(running, request)
            return
        }
        // The result is meaningless; see `hide(_:_:)`.
        _ = running.unhide()
        // activate() in the same turn as unhide() only reveals the windows behind the front app,
        // so wait until the system reports the app as visible.
        poll(request, deadline: Date() + environment.activateTimeout, condition: { !running.isHidden }) { _ in
            activateNow(running, request)
        }
    }

    private static func activateNow(_ running: ActivatableApplication, _ request: Request) {
        let accepted: Bool
        if #available(macOS 14.0, *) {
            accepted = running.activate(options: [.activateAllWindows])
        } else {
            accepted = running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
        // `true` only means the request was sent; the frontmost check below is the real result.
        guard accepted else {
            request.fail(ActivationError.activate(request.app.displayName))
            return
        }
        waitUntilFrontmost(running.processIdentifier, request,
                           deadline: Date() + environment.activateTimeout) { isFrontmost in
            if isFrontmost {
                request.succeed("切换（activate）")
            } else {
                request.fail(ActivationError.notFrontmost(request.app.displayName))
            }
        }
    }

    private static func waitUntilFrontmost(
        _ pid: pid_t,
        _ request: Request,
        deadline: Date,
        completion: @escaping (Bool) -> Void
    ) {
        poll(request, deadline: deadline, condition: { environment.frontmostProcessIdentifier() == pid },
             completion: completion)
    }

    /// Re-checks `condition` on later run-loop turns, where NSWorkspace state is refreshed.
    /// Stops without calling `completion` once a newer request has started.
    private static func poll(
        _ request: Request,
        deadline: Date,
        condition: @escaping () -> Bool,
        completion: @escaping (Bool) -> Void
    ) {
        guard request.isCurrent() else { return }
        if condition() {
            completion(true)
        } else if Date() >= deadline {
            completion(false)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + environment.pollInterval) {
                MainActor.assumeIsolated {
                    poll(request, deadline: deadline, condition: condition, completion: completion)
                }
            }
        }
    }

    private static func findRunningApplication(for app: AppShortcut) -> NSRunningApplication? {
        let applications = NSWorkspace.shared.runningApplications
        if let bundleIdentifier = app.bundleIdentifier,
           let running = applications.first(where: { !$0.isTerminated && $0.bundleIdentifier == bundleIdentifier }) {
            return running
        }

        let url = (resolveApplicationURL(for: app) ?? app.appURL).resolvingSymlinksInPath().standardizedFileURL
        return applications.first {
            !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == url
        }
    }

    static func resolveApplicationURL(for app: AppShortcut) -> URL? {
        if app.existsAtPath {
            return app.appURL
        }
        if let bundleIdentifier = app.bundleIdentifier {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        }
        return nil
    }

    @MainActor
    private final class Request {
        let id: Int
        let app: AppShortcut
        let started = Date()
        private let completion: (Result<Void, Error>) -> Void
        private var isAbandoned = false

        init(id: Int, app: AppShortcut, completion: @escaping (Result<Void, Error>) -> Void) {
            self.id = id
            self.app = app
            self.completion = completion
        }

        var elapsed: Int {
            Int(Date().timeIntervalSince(started) * 1000)
        }

        /// A newer key press wins; its request must not be undone by this one's fallback.
        func isCurrent() -> Bool {
            if id == AppActivator.latestRequestID { return true }
            if !isAbandoned {
                isAbandoned = true
                Log.activation.info("已被新的按键取代：\(self.app.displayName, privacy: .public)")
            }
            return false
        }

        func succeed(_ action: String) {
            Log.activation.notice(
                "\(action, privacy: .public)完成：\(self.app.displayName, privacy: .public)，用时 \(self.elapsed) ms"
            )
            completion(.success(()))
        }

        func fail(_ error: Error) {
            Log.activation.error(
                "失败：\(self.app.displayName, privacy: .public)，用时 \(self.elapsed) ms：\(error.localizedDescription, privacy: .public)"
            )
            completion(.failure(error))
        }
    }

    private enum ActivationError: LocalizedError {
        case notFound(String)
        case hide(String)
        case activate(String)
        case notFrontmost(String)
        case launch(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let name):
                return L10n.tr("runtime.activation.appNotFound", name)
            case .hide(let name):
                return L10n.tr("runtime.activation.hideFailed", name)
            case .activate(let name):
                return L10n.tr("runtime.activation.activationRejected", name)
            case .notFrontmost(let name):
                return L10n.tr("runtime.activation.notFrontmost", name)
            case .launch(let name):
                return L10n.tr("runtime.activation.launchFailed", name)
            }
        }
    }
}
