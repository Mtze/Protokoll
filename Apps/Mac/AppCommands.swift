import SwiftUI
import SharedKit

/// Keyboard control for the Mac app (menu-bar commands + focused scene values).
///
/// The menu bar is the single source of truth for shortcuts: it is discoverable
/// and surfaced to assistive tech. Context-dependent commands (act on the
/// selected session) read values the views publish via `focusedSceneValue`, so
/// they work no matter which subview of the window holds focus. Where a command
/// needs a dialog (consent, delete confirm) the published closure just flips the
/// owning view's state, reusing the existing SwiftUI dialogs.

// MARK: - Focused values

/// A consent-aware record/stop action published by the library scene, so `⌘N`
/// runs the same flow (and consent dialog) as the toolbar record button.
struct RecordActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

/// Actions for the session shown in the detail pane, published so the menu-bar
/// Session commands can drive it. `nil` fields disable their command. The
/// closures are formed in the (main-actor) view body and only invoked from
/// main-actor command handlers, so they stay non-`Sendable` `() -> Void`.
struct DetailActions {
    /// Process / Retry / Regenerate - the label tracks the persisted status.
    struct Primary {
        let label: LocalizedStringKey
        let run: () -> Void
    }
    let primary: Primary?
    let delete: () -> Void
    let reveal: () -> Void
    let copyDocument: () -> Void
    let showProtocol: () -> Void
    let showTranscript: () -> Void
    /// Toggle playback, or `nil` when the session has no mic audio.
    let playPause: (() -> Void)?
}

struct DetailActionsKey: FocusedValueKey {
    typealias Value = DetailActions
}

extension FocusedValues {
    var recordAction: RecordActionKey.Value? {
        get { self[RecordActionKey.self] }
        set { self[RecordActionKey.self] = newValue }
    }
    var detailActions: DetailActions? {
        get { self[DetailActionsKey.self] }
        set { self[DetailActionsKey.self] = newValue }
    }
}

// MARK: - Commands

/// The app's keyboard commands. Attached once to the scene in `ProtokollApp`.
struct ProtokollCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.recordAction) private var recordAction
    @FocusedValue(\.detailActions) private var detailActions

    var body: some Commands {
        // A single "Session" menu gathers recording + selected-session actions.
        CommandMenu("commands.menu.session") {
            Button(model.isRecording ? "menu.stop" : "menu.record") {
                if let recordAction {
                    recordAction()
                } else {
                    Task { await model.toggleRecording() }
                }
            }
            .keyboardShortcut("n", modifiers: .command)

            Divider()

            Button(detailActions?.primary?.label ?? "action.process") {
                detailActions?.primary?.run()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(detailActions?.primary == nil)

            Button("action.reveal") { detailActions?.reveal() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(detailActions == nil)

            Button("action.delete") { detailActions?.delete() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(detailActions == nil)

            Divider()

            Button("detail.pane.protocol") { detailActions?.showProtocol() }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(detailActions == nil)

            Button("detail.pane.transcript") { detailActions?.showTranscript() }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(detailActions == nil)

            Button("action.copy") { detailActions?.copyDocument() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(detailActions == nil)

            // Bare Space, gated to when a session (with audio) is selected.
            Button("commands.playPause") { detailActions?.playPause?() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(detailActions?.playPause == nil)
        }

        // Window openers live in the standard Window menu.
        CommandGroup(after: .windowList) {
            Button("menu.library") { openWindow(id: WindowID.library) }
                .keyboardShortcut("0", modifiers: .command)
            Button("menu.diagnostics") { openWindow(id: WindowID.diagnostics) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
}
