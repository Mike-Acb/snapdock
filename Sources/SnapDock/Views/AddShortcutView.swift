import AppKit
import KeyboardShortcuts
import SwiftUI

struct AddShortcutView: View {
    @EnvironmentObject private var store: ShortcutStore
    @ObservedObject private var localization = L10n.shared
    @Environment(\.dismiss) private var dismiss
    private let original: AppShortcut?
    private let isStandalone: Bool
    @State private var draft: AppShortcut?
    @State private var draftName = KeyboardShortcuts.Name("snapdock-draft-\(UUID().uuidString)")
    @State private var recordedShortcut: KeyboardShortcuts.Shortcut?
    @State private var errorMessage: LocalizedMessage?
    @State private var hostWindow: NSWindow?

    init(app: AppShortcut? = nil, isStandalone: Bool = true) {
        original = app
        self.isStandalone = isStandalone
        _draft = State(initialValue: app)
    }

    private var conflict: LocalizedMessage? {
        guard let recordedShortcut else { return nil }
        return store.conflict(for: recordedShortcut, excluding: original?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr(original == nil ? "imports.editor.add_title" : "imports.editor.edit_title"))
                .font(.title2.weight(.semibold))
            Text(L10n.tr("imports.editor.instructions"))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if let draft {
                    Image(nsImage: draft.icon).resizable().frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(draft.displayName).font(.headline)
                        Text(draft.appPath).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                } else {
                    Image(systemName: "app.dashed").font(.largeTitle)
                    Text(L10n.tr("imports.editor.no_application")).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.tr("imports.editor.choose_application"), action: chooseApplication)
            }
            HStack {
                Text(L10n.tr("imports.editor.shortcut"))
                Spacer()
                KeyboardShortcuts.Recorder(for: draftName) { shortcut in
                    recordedShortcut = shortcut
                    errorMessage = nil
                }
            }
            if let conflict {
                Text(conflict.text).foregroundStyle(.red).font(.callout)
            } else if let draft, store.hasDuplicate(bundleIdentifier: draft.bundleIdentifier, excluding: original?.id) {
                Text(L10n.tr("imports.editor.duplicate_application"))
                    .foregroundStyle(.secondary).font(.callout)
            }
            if let errorMessage {
                Text(errorMessage.text).foregroundStyle(.red).font(.callout)
            }
            Spacer(minLength: 0)
            HStack {
                Button(L10n.tr("imports.cancel"), action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.tr("imports.editor.save"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft == nil || recordedShortcut == nil || conflict != nil)
            }
        }
        .padding(20)
        .frame(width: 480, height: 300)
        .background(WindowAccessor { hostWindow = $0 })
        .onAppear {
            recordedShortcut = original.flatMap { KeyboardShortcuts.getShortcut(for: $0.hotkeyName) }
            KeyboardShortcuts.setShortcut(recordedShortcut, for: draftName)
        }
        .onDisappear(perform: cleanDraft)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSWindow, window === hostWindow {
                cleanDraft()
            }
        }
    }

    private func chooseApplication() {
        guard let url = AppPicker.pickApplication() else { return }
        let picked = AppPicker.makeShortcut(from: url)
        draft = AppShortcut(
            id: original?.id ?? picked.id,
            appPath: picked.appPath,
            bundleIdentifier: picked.bundleIdentifier,
            displayName: picked.displayName
        )
        errorMessage = nil
    }

    private func save() {
        guard let draft, let recordedShortcut else { return }
        if let reason = store.conflict(for: recordedShortcut, excluding: original?.id) {
            errorMessage = reason
            return
        }
        let previous = KeyboardShortcuts.getShortcut(for: draft.hotkeyName)
        KeyboardShortcuts.setShortcut(recordedShortcut, for: draft.hotkeyName)
        let saved = original == nil ? store.add(draft) : store.update(draft)
        if !saved {
            KeyboardShortcuts.setShortcut(previous, for: draft.hotkeyName)
            errorMessage = store.lastError ?? LocalizedMessage("imports.editor.save_failed")
            return
        }
        close()
    }

    private func cleanDraft() {
        KeyboardShortcuts.setShortcut(nil, for: draftName)
        draft = original
        recordedShortcut = nil
        errorMessage = nil
    }

    private func close() {
        cleanDraft()
        if isStandalone {
            hostWindow?.close()
        } else {
            dismiss()
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: WindowTrackingView, context: Context) {
        nsView.onWindow = onWindow
    }

    final class WindowTrackingView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let currentWindow = window
            DispatchQueue.main.async { [weak self] in self?.onWindow?(currentWindow) }
        }
    }
}
