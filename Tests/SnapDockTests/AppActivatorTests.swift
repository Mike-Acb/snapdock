import AppKit
import XCTest
@testable import SnapDock

final class AppActivatorTests: XCTestCase {
    @MainActor
    func testLaunchServicesBringsHiddenAppForwardWithoutDirectActivation() async throws {
        let system = FakeSystem()
        let app = FakeApplication(pid: 10)
        app.isHidden = true
        let saved = AppActivator.environment
        defer { AppActivator.environment = saved }
        AppActivator.environment = system.environment()

        let result = await perform(app, hideIfFrontmost: true)

        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(system.opened, [try XCTUnwrap(app.bundleURL)])
        XCTAssertEqual(app.events, [])
        XCTAssertEqual(system.frontmost, app.processIdentifier)
    }

    @MainActor
    func testFallbackActivatesOnlyAfterUnhideCompletes() async throws {
        let system = FakeSystem()
        let app = FakeApplication(pid: 11)
        app.isHidden = true
        app.openBringsForward = false
        app.onActivate = { [unowned app] in
            // Matches macOS: activating while still hidden leaves the app behind the front app.
            if !app.isHidden { system.frontmost = app.processIdentifier }
        }
        let saved = AppActivator.environment
        defer { AppActivator.environment = saved }
        AppActivator.environment = system.environment()

        let result = await perform(app, hideIfFrontmost: true)

        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(app.events, ["unhide", "activate"])
        XCTAssertEqual(system.frontmost, app.processIdentifier)
    }

    @MainActor
    func testReportsFailureWhenAppNeverBecomesFrontmost() async throws {
        let system = FakeSystem()
        let app = FakeApplication(pid: 12)
        app.openBringsForward = false
        let saved = AppActivator.environment
        defer { AppActivator.environment = saved }
        AppActivator.environment = system.environment()

        let result = await perform(app, hideIfFrontmost: true)

        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(app.events, ["activate"])
        XCTAssertEqual(system.frontmost, FakeSystem.otherApp)
    }

    @MainActor
    func testNewerKeyPressCancelsPendingFallback() async throws {
        let system = FakeSystem()
        let stale = FakeApplication(pid: 13)
        stale.openBringsForward = false
        stale.onActivate = { [unowned stale] in system.frontmost = stale.processIdentifier }
        let latest = FakeApplication(pid: 14)
        let saved = AppActivator.environment
        defer { AppActivator.environment = saved }
        AppActivator.environment = system.environment()

        let staleFinished = expectation(description: "Superseded request stays silent")
        staleFinished.isInverted = true
        AppActivator.perform(stale.shortcut, running: stale, hideIfFrontmost: true) { _ in
            staleFinished.fulfill()
        }
        // Press the next key while the first request is still waiting for its app to come forward.
        try await Task.sleep(nanoseconds: 50_000_000)
        let result = await perform(latest, hideIfFrontmost: true)
        await fulfillment(of: [staleFinished], timeout: AppActivator.environment.openTimeout * 3)

        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(stale.events, [])
        XCTAssertEqual(system.frontmost, latest.processIdentifier)
    }

    @MainActor
    func testRepeatHidesOnlyWhenEnabledAndFrontmost() async throws {
        let system = FakeSystem()
        let app = FakeApplication(pid: 15)
        system.frontmost = app.processIdentifier
        let saved = AppActivator.environment
        defer { AppActivator.environment = saved }
        AppActivator.environment = system.environment()

        let reopened = await perform(app, hideIfFrontmost: false)
        XCTAssertNoThrow(try reopened.get())
        XCTAssertEqual(app.events, [])
        XCTAssertEqual(system.opened.count, 1)

        let hidden = await perform(app, hideIfFrontmost: true)
        XCTAssertNoThrow(try hidden.get())
        XCTAssertEqual(app.events, ["hide"])
        XCTAssertTrue(app.isHidden)
        XCTAssertEqual(system.opened.count, 1)
    }

    @MainActor
    func testReportsHideFailureWhenAppStaysVisible() async throws {
        let system = FakeSystem()
        let app = FakeApplication(pid: 18)
        app.hideTakesEffect = false
        system.frontmost = app.processIdentifier
        let saved = AppActivator.environment
        defer { AppActivator.environment = saved }
        AppActivator.environment = system.environment()

        let result = await perform(app, hideIfFrontmost: true)

        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(app.events, ["hide"])
        XCTAssertFalse(app.isHidden)
    }

    @MainActor
    func testAgentAppIsNotRequiredToBecomeFrontmost() async throws {
        let system = FakeSystem()
        let app = FakeApplication(pid: 16)
        app.activationPolicy = .accessory
        app.openBringsForward = false
        let saved = AppActivator.environment
        defer { AppActivator.environment = saved }
        AppActivator.environment = system.environment()

        let result = await perform(app, hideIfFrontmost: true)

        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(app.events, [])
    }

    @MainActor
    func testLaunchFallsBackToActivateWhenLaunchedAppStaysBehind() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundle = directory.appendingPathComponent("Launched.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let system = FakeSystem()
        let app = FakeApplication(pid: 17, url: bundle)
        app.openBringsForward = false
        app.onActivate = { [unowned app] in system.frontmost = app.processIdentifier }
        let saved = AppActivator.environment
        defer { AppActivator.environment = saved }
        AppActivator.environment = system.environment()

        let finished = expectation(description: "Launch finished")
        var result: Result<Void, Error>?
        AppActivator.perform(app.shortcut, running: nil, hideIfFrontmost: true) {
            result = $0
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)

        XCTAssertNoThrow(try XCTUnwrap(result).get())
        XCTAssertEqual(system.opened.map(\.path), [bundle.path])
        XCTAssertEqual(app.events, ["activate"])
    }

    @MainActor
    private func perform(_ app: FakeApplication, hideIfFrontmost: Bool) async -> Result<Void, Error> {
        let finished = expectation(description: "Activation finished")
        var result: Result<Void, Error> = .failure(CancellationError())
        AppActivator.perform(app.shortcut, running: app, hideIfFrontmost: hideIfFrontmost) {
            result = $0
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)
        return result
    }
}

@MainActor
private final class FakeSystem {
    static let otherApp: pid_t = 1
    var frontmost: pid_t? = otherApp
    var opened: [URL] = []

    func environment() -> ActivationEnvironment {
        var environment = ActivationEnvironment()
        environment.frontmostProcessIdentifier = { [unowned self] in self.frontmost }
        environment.openApplication = { [unowned self] url, _, completion in
            self.opened.append(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let app = FakeApplication.registry[url.path]
                    if let app, app.openBringsForward {
                        app.isHidden = false
                        self.frontmost = app.processIdentifier
                    }
                    completion(app, nil)
                }
            }
        }
        environment.openTimeout = 0.15
        environment.hideTimeout = 0.15
        environment.activateTimeout = 0.15
        environment.launchTimeout = 0.15
        environment.pollInterval = 0.01
        return environment
    }
}

@MainActor
private final class FakeApplication: ActivatableApplication {
    /// Keyed by path: file URLs for existing directories gain a trailing slash.
    static var registry: [String: FakeApplication] = [:]

    let processIdentifier: pid_t
    let bundleURL: URL?
    var activationPolicy: NSApplication.ActivationPolicy = .regular
    var isHidden = false
    var hideTakesEffect = true
    var openBringsForward = true
    var onActivate: @MainActor () -> Void = {}
    private(set) var events: [String] = []

    init(pid: pid_t, url: URL? = nil) {
        processIdentifier = pid
        bundleURL = url ?? URL(fileURLWithPath: "/Applications/Fake\(pid).app")
        Self.registry[bundleURL!.path] = self
    }

    var shortcut: AppShortcut {
        AppShortcut(appPath: bundleURL!.path, bundleIdentifier: "local.fake.\(processIdentifier)",
                    displayName: "Fake \(processIdentifier)")
    }

    /// Like AppKit on macOS 26: `false` although the request was sent, and the target process
    /// applies it later.
    func hide() -> Bool {
        events.append("hide")
        if hideTakesEffect { setHiddenLater(true) }
        return false
    }

    func unhide() -> Bool {
        events.append("unhide")
        setHiddenLater(false)
        return false
    }

    private func setHiddenLater(_ hidden: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            MainActor.assumeIsolated { self.isHidden = hidden }
        }
    }

    func activate(options: NSApplication.ActivationOptions) -> Bool {
        events.append(isHidden ? "activate-while-hidden" : "activate")
        onActivate()
        return true
    }
}
