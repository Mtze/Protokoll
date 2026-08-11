import AppKit
import SwiftUI
import SharedKit

/// The Mac menubar app entry point (ADR-1: on-demand processing, no daemon).
///
/// A `MenuBarExtra` (SF Symbol mic) is the primary surface; the library and
/// diagnostics are separate windows. Confirm-on-quit guards active processing
/// (ADR-4: killed jobs leave a checkpoint and are re-runnable).
@main
struct ProtokollApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        // Primary window: the full Library app. Opens at launch and drives
        // bootstrap (session load, crash recovery, index rebuild, diagnostics).
        Window(Text("library.title"), id: WindowID.library) {
            LibraryView()
                .environment(model)
                .task { await model.bootstrap() }
        }
        .defaultSize(width: 900, height: 600)
        .commands { ProtokollCommands(model: model) }

        // Quick-access recorder in the menu bar, alongside the full app.
        MenuBarExtra {
            MenuContentView()
                .environment(model)
        } label: {
            Image(systemName: model.isRecording ? "waveform.badge.mic" : "mic")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)

        Window(Text("diag.title"), id: WindowID.diagnostics) {
            DiagnosticsView().environment(model)
        }
        .defaultSize(width: 520, height: 480)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(container: model.container).environment(model)
        }
    }
}

/// App delegate for confirm-on-quit (ADR-4): if the scheduler has active work,
/// warn before terminating so an in-flight transcription isn't killed silently.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared?.scheduler.hasActiveWork == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "quit.confirm.title")
        alert.informativeText = String(localized: "quit.confirm.message")
        alert.addButton(withTitle: String(localized: "quit.confirm.quit"))
        alert.addButton(withTitle: String(localized: "common.cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
