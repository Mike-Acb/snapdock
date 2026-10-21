import AppKit
import Combine
import Darwin
import Foundation

@MainActor
final class DockMonitor: ObservableObject {
    static let shared = DockMonitor()

    @Published private(set) var applications: [AppShortcut] = []
    @Published private(set) var lastError: LocalizedMessage?

    private let preferencesURL: URL
    private let workspaceNotifications: NotificationCenter
    private var applicationIDs: [String: UUID] = [:]
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var observers: [NSObjectProtocol] = []
    private var refreshDeadline: Date?
    private var pendingRefresh: Task<Void, Never>?
    private var pendingRefreshIsForced = false
    private var fingerprint: Fingerprint?
    private var isRunning = false

    init(preferencesURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/com.apple.dock.plist")) {
        self.preferencesURL = preferencesURL
        workspaceNotifications = NSWorkspace.shared.notificationCenter
    }

    deinit {
        pendingRefresh?.cancel()
        directorySource?.cancel()
        fileSource?.cancel()
        for observer in observers {
            workspaceNotifications.removeObserver(observer)
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        observers.append(workspaceNotifications.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleRefresh(force: true) }
        })
        observers.append(workspaceNotifications.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.bundleIdentifier == "com.apple.dock" else { return }
            Task { @MainActor [weak self] in self?.scheduleRefresh(force: true) }
        })
        refresh()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        pendingRefresh?.cancel()
        pendingRefresh = nil
        pendingRefreshIsForced = false
        directorySource?.cancel()
        directorySource = nil
        refreshDeadline = nil
        fileSource?.cancel()
        fileSource = nil
        for observer in observers {
            workspaceNotifications.removeObserver(observer)
        }
        observers.removeAll()
    }

    func refresh() {
        reload(force: true)
    }

    /// Entry point for file events. The watched directory also changes whenever any other app
    /// saves its preferences, so an unchanged Dock file is not parsed or republished.
    func refreshIfChanged() {
        reload(force: false)
    }

    private func reload(force: Bool) {
        if isRunning {
            if directorySource == nil {
                directorySource = watch(preferencesURL.deletingLastPathComponent(), isDirectory: true)
            }
            if fileSource == nil {
                fileSource = watch(preferencesURL, isDirectory: false)
            }
        }

        let current = Self.fingerprint(of: preferencesURL)
        if !force, current != nil, current == fingerprint {
            setError(watchError)
            return
        }
        fingerprint = current

        do {
            let data = try Data(contentsOf: preferencesURL)
            let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard let preferences = propertyList as? [String: Any] else {
                throw DockError.invalidPreferences
            }
            let parsed = try Self.parseApplications(from: preferences)
            let snapshot = parsed.map { application in
                let id = applicationIDs[application.appPath] ?? application.id
                applicationIDs[application.appPath] = id
                return AppShortcut(id: id, appPath: application.appPath,
                                   bundleIdentifier: application.bundleIdentifier,
                                   displayName: application.displayName)
            }
            if snapshot != applications {
                applications = snapshot
                Log.dock.notice(
                    "Dock 固定应用 \(snapshot.count) 个：\(snapshot.map(\.displayName).joined(separator: "、"), privacy: .public)"
                )
            }
            setError(watchError)
        } catch {
            setError(LocalizedMessage(render: {
                L10n.tr("runtime.dock.syncFailed", error.localizedDescription)
            }), log: true)
        }
    }

    private var watchError: LocalizedMessage? {
        isRunning && (directorySource == nil || fileSource == nil)
            ? LocalizedMessage("runtime.dock.watchFailed") : nil
    }

    /// `@Published` emits on every assignment, and each emission rebuilds the settings UI.
    private func setError(_ message: LocalizedMessage?, log: Bool = false) {
        let text = message?.text
        guard lastError?.text != text else { return }
        if log, let text {
            Log.dock.error("\(text, privacy: .public)")
        }
        lastError = message
    }

    struct Fingerprint: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let seconds: Int
        let nanoseconds: Int
    }

    nonisolated static func fingerprint(of url: URL) -> Fingerprint? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Fingerprint(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                           seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }

    nonisolated static func parseApplications(from preferences: [String: Any]) throws -> [AppShortcut] {
        guard let items = preferences["persistent-apps"] as? [[String: Any]] else {
            throw DockError.invalidPreferences
        }
        var applications: [AppShortcut] = []
        for item in items {
            guard item["tile-type"] as? String == "file-tile" else { continue }
            guard let tile = item["tile-data"] as? [String: Any] else {
                throw DockError.invalidApplication
            }
            if let fileType = tile["file-type"] as? Int, fileType != 41 { continue }
            guard let file = tile["file-data"] as? [String: Any],
                  let location = file["_CFURLString"] as? String else {
                throw DockError.invalidApplication
            }
            let url = location.hasPrefix("/") ? URL(fileURLWithPath: location) : URL(string: location)
            guard let url, url.isFileURL,
                  url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else {
                throw DockError.invalidApplication
            }
            let normalizedURL = URL(fileURLWithPath: url.path).standardizedFileURL
            guard normalizedURL.pathExtension.lowercased() == "app" else { continue }
            let bundleIdentifier = tile["bundle-identifier"] as? String
            guard bundleIdentifier?.lowercased() != "com.apple.finder",
                  normalizedURL.path != "/System/Library/CoreServices/Finder.app" else { continue }
            let label = (tile["file-label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = label.flatMap { $0.isEmpty ? nil : $0 }
                ?? normalizedURL.deletingPathExtension().lastPathComponent
            applications.append(AppShortcut(appPath: normalizedURL.path,
                                            bundleIdentifier: bundleIdentifier,
                                            displayName: displayName))
        }
        return applications
    }

    private func scheduleRefresh(force: Bool) {
        guard isRunning else { return }
        pendingRefreshIsForced = pendingRefreshIsForced || force
        pendingRefresh?.cancel()
        let deadline = refreshDeadline ?? Date().addingTimeInterval(1)
        refreshDeadline = deadline
        let delay = min(0.25, max(0, deadline.timeIntervalSinceNow))
        pendingRefresh = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard let self, self.isRunning else { return }
            let force = self.pendingRefreshIsForced
            self.pendingRefresh = nil
            self.pendingRefreshIsForced = false
            self.refreshDeadline = nil
            self.reload(force: force)
        }
    }

    private func watch(_ url: URL, isDirectory: Bool) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            let invalidated = source?.data.intersection([.rename, .delete, .revoke]).isEmpty == false
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                if invalidated {
                    if isDirectory {
                        self.directorySource?.cancel()
                        self.directorySource = nil
                    } else {
                        self.fileSource?.cancel()
                        self.fileSource = nil
                    }
                }
                self.scheduleRefresh(force: false)
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private enum DockError: LocalizedError {
        case invalidPreferences
        case invalidApplication

        var errorDescription: String? {
            switch self {
            case .invalidPreferences: return L10n.tr("runtime.dock.invalidPreferences")
            case .invalidApplication: return L10n.tr("runtime.dock.invalidApplication")
            }
        }
    }
}
