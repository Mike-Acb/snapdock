import Combine
import Foundation
import XCTest
@testable import SnapDock

final class DockMonitorTests: XCTestCase {
    func testFiltersNonApplicationsAndFinderWithoutChangingOrder() throws {
        let preferences: [String: Any] = [
            "persistent-apps": [
                tile("file:///System/Library/CoreServices/Finder.app/"),
                tile("file:///Applications/First.app/", label: "First"),
                ["tile-type": "spacer-tile"],
                tile("file:///Users/example/Documents/", fileType: 2),
                tile("file:///Applications/OtherFinder.app/", bundleIdentifier: "com.apple.finder"),
                tile("file://localhost/Applications/Second%20App.app/", label: "Second App"),
                tile("file:///Users/example/note.txt", fileType: 1)
            ],
            "recent-apps": [tile("file:///Applications/Recent.app/")],
            "persistent-others": [tile("file:///Applications/Outside.app/")]
        ]

        let applications = try DockMonitor.parseApplications(from: preferences)

        XCTAssertEqual(applications.map(\.appPath), ["/Applications/First.app", "/Applications/Second App.app"])
        XCTAssertEqual(applications.map(\.displayName), ["First", "Second App"])
    }

    func testPreservesMissingApplicationAndDecodesEscapesOnlyOnce() throws {
        let applications = try DockMonitor.parseApplications(from: [
            "persistent-apps": [
                tile("file:///definitely-missing-snapdock/Absent%2520App.app/"),
                tile("file:///Applications/Next.app/")
            ]
        ])

        XCTAssertEqual(applications.map(\.appPath), ["/definitely-missing-snapdock/Absent%20App.app", "/Applications/Next.app"])
        XCTAssertEqual(applications.first?.displayName, "Absent%20App")
    }

    @MainActor
    func testRefreshRetainsLastSnapshotOnMalformedFileAndIdentityAfterReordering() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("com.apple.dock.plist")
        let first = tile("file:///Applications/First.app/")
        let second = tile("file:///Applications/Second.app/")
        try write(["persistent-apps": [first, second]], to: url)
        let monitor = DockMonitor(preferencesURL: url)
        monitor.refresh()
        let original = monitor.applications
        XCTAssertEqual(original.map(\.appPath), ["/Applications/First.app", "/Applications/Second.app"])

        try write(["persistent-apps": "invalid"], to: url)
        monitor.refresh()
        XCTAssertEqual(monitor.applications, original)
        XCTAssertNotNil(monitor.lastError)

        try write(["persistent-apps": [second, first]], to: url)
        monitor.refresh()
        XCTAssertEqual(monitor.applications.map(\.id), original.reversed().map(\.id))
        XCTAssertNil(monitor.lastError)
    }

    @MainActor
    func testFileEventsSkipUnchangedDockFileAndRepeatedErrors() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("com.apple.dock.plist")
        try write(["persistent-apps": [tile("file:///Applications/First.app/")]], to: url)
        let monitor = DockMonitor(preferencesURL: url)
        monitor.refresh()
        var emissions = 0
        let subscriptions = [
            monitor.$applications.dropFirst().sink { _ in emissions += 1 },
            monitor.$lastError.dropFirst().sink { _ in emissions += 1 }
        ]
        defer { subscriptions.forEach { $0.cancel() } }

        // Rewrite in place with the same size and timestamps: only a forced refresh reads it.
        let original = try XCTUnwrap(DockMonitor.fingerprint(of: url))
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(repeating: 0x78, count: Int(original.size)))
        try handle.close()
        let stamp = timespec(tv_sec: original.seconds, tv_nsec: original.nanoseconds)
        var times = [stamp, stamp]
        XCTAssertEqual(utimensat(AT_FDCWD, url.path, &times, 0), 0)
        XCTAssertEqual(DockMonitor.fingerprint(of: url), original)

        monitor.refreshIfChanged()
        XCTAssertNil(monitor.lastError)
        XCTAssertEqual(emissions, 0)

        monitor.refresh()
        XCTAssertNotNil(monitor.lastError)
        monitor.refresh()
        XCTAssertEqual(emissions, 1)

        try write(["persistent-apps": [tile("file:///Applications/Second.app/")]], to: url)
        monitor.refreshIfChanged()
        XCTAssertEqual(monitor.applications.map(\.appPath), ["/Applications/Second.app"])
        XCTAssertNil(monitor.lastError)
        XCTAssertEqual(emissions, 3)
    }

    @MainActor
    func testWatchesSuccessiveAtomicReplacementsWithinTwoSeconds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("com.apple.dock.plist")
        try write(["persistent-apps": [tile("file:///Applications/First.app/")]], to: url)
        let monitor = DockMonitor(preferencesURL: url)
        monitor.start()
        monitor.start()
        defer {
            monitor.stop()
            monitor.stop()
        }

        for name in ["Second", "Third"] {
            let changed = expectation(description: "Observed \(name)")
            let subscription = monitor.$applications
                .filter { $0.first?.appPath == "/Applications/\(name).app" }
                .prefix(1)
                .sink { _ in changed.fulfill() }
            try write(["persistent-apps": [tile("file:///Applications/\(name).app/")]], to: url)
            await fulfillment(of: [changed], timeout: 2)
            subscription.cancel()
        }
    }

    private func tile(_ url: String, label: String? = nil, bundleIdentifier: String? = nil, fileType: Int = 41) -> [String: Any] {
        var data: [String: Any] = [
            "file-type": fileType,
            "file-data": ["_CFURLString": url, "_CFURLStringType": 15]
        ]
        if let label { data["file-label"] = label }
        if let bundleIdentifier { data["bundle-identifier"] = bundleIdentifier }
        return ["tile-type": "file-tile", "tile-data": data]
    }

    private func write(_ preferences: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0)
        try data.write(to: url, options: .atomic)
    }
}
