import AppKit
import KeyboardShortcuts
import SwiftUI

struct ImportApptivateView: View {
    @EnvironmentObject private var store: ShortcutStore
    @ObservedObject private var localization = L10n.shared
    @State private var loadResult: ApptivateImporter.Result?
    @State private var rows: [ApptivateImporter.PreviewRow] = []
    @State private var selectedIDs: Set<UUID> = []
    @State private var errorMessage: LocalizedMessage?
    @State private var didFinishMessage: LocalizedMessage?
    @State private var hostWindow: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("imports.apptivate.title")).font(.title2.weight(.semibold))
            Text(L10n.tr("imports.apptivate.instructions"))
                .font(.callout).foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage.text).foregroundStyle(.red).textSelection(.enabled)
                Button(L10n.tr("imports.reload"), action: loadPreview)
                Spacer()
            } else if let didFinishMessage {
                ScrollView {
                    Text(didFinishMessage.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                List {
                    Section(L10n.tr("imports.selected_shortcuts", selectedIDs.count)) {
                        ForEach(rows) { row in
                            Toggle(isOn: binding(for: row.entry.id)) {
                                HStack(spacing: 10) {
                                    Image(nsImage: row.entry.icon).resizable().frame(width: 28, height: 28)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(row.entry.displayName)
                                        Text(row.entry.appURL.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        if let reason = unavailableReason(for: row) {
                                            Text(reason.text).font(.caption).foregroundStyle(.red)
                                        }
                                    }
                                    Spacer()
                                    Text(row.entry.shortcutDisplay).monospaced()
                                }
                            }
                            .disabled(unavailableReason(for: row) != nil)
                        }
                        if rows.isEmpty {
                            Text(L10n.tr("imports.apptivate.no_shortcuts")).foregroundStyle(.secondary)
                        }
                    }
                    if let loadResult, !loadResult.skipped.isEmpty || !loadResult.notes.isEmpty {
                        Section(L10n.tr("imports.skipped_notes")) {
                            ForEach(Array(loadResult.skipped.enumerated()), id: \.offset) { _, skip in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(skip.label.text)
                                    Text(skip.reason.text).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            ForEach(Array(loadResult.notes.enumerated()), id: \.offset) { _, note in
                                Text(note.text).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            HStack {
                if errorMessage == nil, didFinishMessage == nil {
                    Button(L10n.tr("imports.select_all")) {
                        selectedIDs = Set(rows.filter { unavailableReason(for: $0) == nil }.map(\.id))
                    }
                    Button(L10n.tr("imports.deselect_all")) { selectedIDs = [] }.disabled(selectedIDs.isEmpty)
                }
                Spacer()
                Button(L10n.tr(didFinishMessage == nil ? "imports.cancel" : "imports.done")) { hostWindow?.close() }
                    .keyboardShortcut(.cancelAction)
                if errorMessage == nil, didFinishMessage == nil {
                    Button(L10n.tr("imports.apptivate.confirm", selectedIDs.count), action: confirmImport)
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedIDs.isEmpty)
                }
            }
        }
        .padding(16)
        .frame(width: 560, height: 440)
        .background(WindowAccessor { hostWindow = $0 })
        .onAppear(perform: loadPreview)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSWindow, window === hostWindow {
                loadResult = nil
                rows = []
                selectedIDs = []
                didFinishMessage = nil
                errorMessage = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, window === hostWindow, loadResult == nil {
                loadPreview()
            }
        }
    }

    private func unavailableReason(for row: ApptivateImporter.PreviewRow) -> LocalizedMessage? {
        if row.isDuplicate { return LocalizedMessage("imports.apptivate.already_exists") }
        return store.conflict(for: row.entry.shortcut)
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { selected in
                if selected { selectedIDs.insert(id) }
                else { selectedIDs.remove(id) }
            }
        )
    }

    private func loadPreview() {
        let result = ApptivateImporter.loadEntries()
        loadResult = result
        errorMessage = result.errorMessage
        didFinishMessage = nil
        rows = ApptivateImporter.previewRows(from: result, store: store)
        selectedIDs = Set(rows.filter { unavailableReason(for: $0) == nil }.map(\.id))
    }

    private func confirmImport() {
        let entries = rows.filter { selectedIDs.contains($0.id) }.map(\.entry)
        let outcome = ApptivateImporter.apply(
            entries: entries,
            to: store,
            notes: loadResult?.notes ?? [],
            skipped: loadResult?.skipped ?? []
        )
        didFinishMessage = outcome.message
    }
}
