import AppKit
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: ShortcutStore
    @ObservedObject private var dock = DockMonitor.shared
    @ObservedObject private var hotkeys = HotkeyManager.shared
    @ObservedObject private var localization = L10n.shared
    @State private var selectedTab: String
    @State private var showEditor = false
    @State private var editingApp: AppShortcut?
    @State private var showSnapImport = false
    @State private var confirmRestore = false
    @State private var loginEnabled = LaunchAtLogin.isEnabled
    @State private var loginStatus = LaunchAtLogin.statusText
    @State private var loginError: LocalizedMessage?
    @State private var actionError: LocalizedMessage?

    init(initialTab: String = "automatic") {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                automaticTab.tabItem { Label(L10n.tr("interface.tab.automatic"), systemImage: "dock.rectangle") }.tag("automatic")
                manualTab.tabItem { Label(L10n.tr("interface.tab.manual"), systemImage: "keyboard") }.tag("manual")
                settingsTab.tabItem { Label(L10n.tr("interface.tab.settings"), systemImage: "gearshape") }.tag("settings")
            }
            .padding(16)
            if let error = actionError ?? store.lastError {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error.text).textSelection(.enabled)
                    Spacer()
                    Button(L10n.tr("interface.action.dismiss")) {
                        actionError = nil
                        store.lastError = nil
                    }
                }
                .font(.callout)
                .foregroundStyle(.red)
                .padding([.horizontal, .bottom], 16)
            }
        }
        .frame(minWidth: 640, minHeight: 500)
        .sheet(isPresented: $showEditor) {
            AddShortcutView(app: editingApp, isStandalone: false).environmentObject(store)
        }
        .sheet(isPresented: $showSnapImport) {
            ImportSnapView().environmentObject(store)
        }
        .alert(L10n.tr("interface.restore.title"), isPresented: $confirmRestore) {
            Button(L10n.tr("interface.action.cancel"), role: .cancel) {}
            Button(L10n.tr("interface.restore.confirm"), role: .destructive) {
                do { try store.restoreBeforeImport() }
                catch { actionError = LocalizedMessage(error: error) }
            }
        } message: {
            Text(L10n.tr("interface.restore.message"))
        }
        .onAppear(perform: refreshLoginStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .snapDockOpenSettings)) { notification in
            if let tab = notification.userInfo?["tab"] as? String,
               ["automatic", "manual", "settings"].contains(tab) {
                selectedTab = tab
            }
        }
        .environment(\.locale, localization.locale)
    }

    private var automaticTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L10n.tr("interface.automatic.enable"), isOn: $store.settings.automaticEnabled)
            HStack(spacing: 14) {
                Text(L10n.tr("interface.automatic.modifiers"))
                modifierToggle(L10n.tr("interface.modifier.control"), flag: .control)
                modifierToggle(L10n.tr("interface.modifier.option"), flag: .option)
                modifierToggle(L10n.tr("interface.modifier.shift"), flag: .shift)
                modifierToggle(L10n.tr("interface.modifier.command"), flag: .command)
            }
            Text(L10n.tr("interface.automatic.explanation"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(L10n.tr("interface.automatic.dock_apps")).font(.headline)
                Spacer()
                Button(L10n.tr("interface.action.refresh")) {
                    dock.refresh()
                    hotkeys.refresh()
                }
            }
            if let error = dock.lastError {
                Label(error.text, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            List {
                ForEach(Array(dock.applications.prefix(10).enumerated()), id: \.element.id) { index, app in
                    HStack(spacing: 12) {
                        Text(index == 9 ? "0" : String(index + 1))
                            .font(.body.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
                        Image(nsImage: app.icon).resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.displayName)
                            Text(hotkeys.automaticStatus[index] ?? L10n.tr("interface.status.waiting"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(HotkeyManager.dockShortcut(at: index, modifiers: store.settings.modifiers)?.description ?? "—")
                            .monospaced()
                        enableToggle(app.automaticKey)
                        Button(L10n.tr("interface.action.open")) { store.perform(app) }
                    }
                    .padding(.vertical, 3)
                }
                if dock.applications.isEmpty {
                    Text(L10n.tr("interface.automatic.empty"))
                        .foregroundStyle(.secondary).padding(.vertical, 8)
                }
            }
            if dock.applications.count > 10 {
                Text(L10n.tr("interface.automatic.first_ten"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var manualTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.tr("interface.manual.priority"))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("interface.action.refresh")) { hotkeys.refresh() }
                Button(L10n.tr("interface.action.add")) {
                    editingApp = nil
                    showEditor = true
                }
            }
            List {
                ForEach(store.shortcuts) { app in
                    HStack(spacing: 12) {
                        Image(nsImage: app.icon).resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.displayName)
                            Text(hotkeys.manualStatus[app.id] ?? L10n.tr("interface.status.waiting"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(app.shortcutDisplay).monospaced()
                        enableToggle(app.manualKey)
                        Button(L10n.tr("interface.action.open")) { store.perform(app) }
                        Button(L10n.tr("interface.action.edit")) {
                            editingApp = app
                            showEditor = true
                        }
                        Button(L10n.tr("interface.action.remove"), role: .destructive) { store.remove(app) }
                    }
                    .padding(.vertical, 3)
                }
                if store.shortcuts.isEmpty {
                    Text(L10n.tr("interface.manual.empty"))
                        .foregroundStyle(.secondary).padding(.vertical, 8)
                }
            }
            Button(L10n.tr("interface.action.import_apptivate")) {
                NotificationCenter.default.post(name: .snapDockOpenImportApptivate, object: nil)
            }
        }
        .padding(12)
    }

    private var settingsTab: some View {
        Form {
            Section(L10n.tr("interface.settings.behavior")) {
                Picker(L10n.tr("interface.settings.language"), selection: $store.settings.language) {
                    Text(L10n.tr("interface.language.system")).tag(AppLanguage.system)
                    Text(L10n.tr("interface.language.simplified_chinese")).tag(AppLanguage.simplifiedChinese)
                    Text(L10n.tr("interface.language.english")).tag(AppLanguage.english)
                }
                Toggle(L10n.tr("interface.settings.hide_on_repeat"), isOn: $store.settings.hideOnRepeat)
                Toggle(L10n.tr("interface.settings.show_status_item"), isOn: $store.settings.showInStatusBar)
                Text(L10n.tr("interface.settings.hidden_status_item_help"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.tr("interface.settings.launch_at_login")) {
                Toggle(L10n.tr("interface.settings.launch_at_login_enable"), isOn: Binding(
                    get: { loginEnabled },
                    set: { enabled in
                        let succeeded = LaunchAtLogin.setEnabled(enabled)
                        refreshLoginStatus()
                        loginError = succeeded ? nil : (LaunchAtLogin.lastError ?? LocalizedMessage("interface.settings.login_error"))
                    }
                ))
                Text(loginStatus.text).font(.callout).foregroundStyle(.secondary)
                if let loginError {
                    Text(loginError.text).font(.callout).foregroundStyle(.red)
                }
            }
            Section(L10n.tr("interface.settings.migration")) {
                HStack {
                    Button(L10n.tr("interface.action.import_snap")) { showSnapImport = true }
                    Button(L10n.tr("interface.restore.action")) { confirmRestore = true }
                        .disabled(!store.canRestoreImport)
                }
                Text(L10n.tr("interface.settings.migration_help"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Switches one entry off without removing it: the app stays listed and keeps its combination.
    private func enableToggle(_ key: String) -> some View {
        Toggle(L10n.tr("interface.shortcut.enable"), isOn: Binding(
            get: { store.isEnabled(key) },
            set: { store.setEnabled($0, key: key) }
        ))
        .toggleStyle(.switch)
        .controlSize(.small)
        .labelsHidden()
        .help(L10n.tr("interface.shortcut.disable_help"))
    }

    private func modifierToggle(_ title: String, flag: NSEvent.ModifierFlags) -> some View {
        let flags = store.settings.modifiers
        let isLast = flags.contains(flag) && flags.subtracting(flag).isEmpty
        return Toggle(title, isOn: Binding(
            get: { store.settings.modifiers.contains(flag) },
            set: { enabled in
                var next = store.settings.modifiers
                if enabled { next.insert(flag) } else { next.remove(flag) }
                guard !next.isEmpty else { return }
                store.settings.modifierFlagsRawValue = next.rawValue
            }
        ))
        .toggleStyle(.checkbox)
        .disabled(isLast)
    }

    private func refreshLoginStatus() {
        loginEnabled = LaunchAtLogin.isEnabled
        loginStatus = LaunchAtLogin.statusText
    }
}
