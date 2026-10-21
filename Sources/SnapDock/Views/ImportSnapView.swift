import AppKit
import KeyboardShortcuts
import SwiftUI

struct ImportSnapView: View {
    @EnvironmentObject private var store: ShortcutStore
    @ObservedObject private var localization = L10n.shared
    @Environment(\.dismiss) private var dismiss
    @State private var preview: SnapImportPreview?
    @State private var selectedIDs: Set<UUID> = []
    @State private var errorMessage: LocalizedMessage?

    private struct BindingRow: Identifiable {
        let binding: ShortcutBinding
        let conflict: LocalizedMessage?
        var id: UUID { binding.app.id }
    }

    private var rows: [BindingRow] {
        guard let preview else { return [] }
        var seen: Set<KeyboardShortcuts.Shortcut> = []
        return preview.bindings.map { binding in
            let duplicate = !seen.insert(binding.shortcut).inserted
            let reason = store.conflict(for: binding.shortcut)
                ?? (duplicate ? LocalizedMessage("imports.snap.duplicate_shortcut") : nil)
            return BindingRow(binding: binding, conflict: reason)
        }
    }

    private var selectedBindings: [ShortcutBinding] {
        rows.filter { $0.conflict == nil && selectedIDs.contains($0.id) }.map(\.binding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("imports.snap.title")).font(.title2.weight(.semibold))
            Text(L10n.tr("imports.snap.instructions"))
                .font(.callout).foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage.text).foregroundStyle(.red).textSelection(.enabled)
                Button(L10n.tr("imports.reload"), action: load)
            }
            if let preview {
                List {
                    Section(L10n.tr("imports.snap.settings_changes")) {
                        settingRow(L10n.tr("imports.snap.automatic_shortcuts"), old: enabled(store.settings.automaticEnabled), new: enabled(preview.settings.automaticEnabled))
                        settingRow(L10n.tr("imports.snap.automatic_modifiers"), old: modifiers(store.settings.modifiers), new: modifiers(preview.settings.modifiers))
                        settingRow(L10n.tr("imports.snap.hide_on_repeat"), old: enabled(store.settings.hideOnRepeat), new: enabled(preview.settings.hideOnRepeat))
                        settingRow(L10n.tr("imports.snap.menu_bar_icon"), old: enabled(store.settings.showInStatusBar), new: enabled(preview.settings.showInStatusBar))
                    }
                    Section(L10n.tr("imports.selected_shortcuts", selectedBindings.count)) {
                        ForEach(rows) { row in
                            Toggle(isOn: Binding(
                                get: { selectedIDs.contains(row.id) && row.conflict == nil },
                                set: { selected in
                                    if selected { selectedIDs.insert(row.id) }
                                    else { selectedIDs.remove(row.id) }
                                }
                            )) {
                                HStack(spacing: 10) {
                                    Image(nsImage: row.binding.app.icon).resizable().frame(width: 28, height: 28)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(row.binding.app.displayName)
                                        if let conflict = row.conflict {
                                            Text(L10n.tr("imports.skipped_reason", conflict.text)).font(.caption).foregroundStyle(.red)
                                        } else {
                                            Text(row.binding.app.appPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    Text(row.binding.shortcut.description).monospaced()
                                }
                            }
                            .disabled(row.conflict != nil)
                        }
                        if rows.isEmpty {
                            Text(L10n.tr("imports.snap.no_shortcuts"))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !preview.skipped.isEmpty {
                        Section(L10n.tr("imports.skipped_notes")) {
                            ForEach(Array(preview.skipped.enumerated()), id: \.offset) { _, reason in
                                Text(reason.text).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text(L10n.tr("imports.snap.backup_notice"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Spacer()
            }
            HStack {
                Button(L10n.tr("imports.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.tr("imports.snap.confirm", selectedBindings.count), action: confirmImport)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview == nil)
            }
        }
        .padding(20)
        .frame(width: 620, height: 550)
        .onAppear(perform: load)
    }

    private func settingRow(_ title: String, old: String, new: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(L10n.tr("imports.snap.setting_change", old, new)).foregroundStyle(old == new ? Color.secondary : Color.primary)
        }
    }

    private func enabled(_ value: Bool) -> String { L10n.tr(value ? "imports.enabled" : "imports.disabled") }

    private func modifiers(_ flags: NSEvent.ModifierFlags) -> String {
        let labels: [(NSEvent.ModifierFlags, String)] = [
            (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")
        ]
        return labels.compactMap { flags.contains($0.0) ? $0.1 : nil }.joined()
    }

    private func load() {
        do {
            preview = try SnapImporter.loadPreview()
            selectedIDs = Set(rows.filter { $0.conflict == nil }.map(\.id))
            errorMessage = nil
        } catch {
            preview = nil
            errorMessage = LocalizedMessage(error: error)
        }
    }

    private func confirmImport() {
        guard let preview else { return }
        let conflictNotes = rows.compactMap { row in
            row.conflict.map { reason in
                let name = row.binding.app.displayName
                return LocalizedMessage(render: { L10n.tr("imports.labeled_reason", name, reason.text) })
            }
        }
        let filtered = SnapImportPreview(
            settings: preview.settings,
            bindings: selectedBindings,
            skipped: preview.skipped + conflictNotes
        )
        do {
            try store.importSnap(filtered)
            dismiss()
        } catch {
            errorMessage = LocalizedMessage(error: error)
        }
    }
}
