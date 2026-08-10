import AppKit
import SwiftUI
import SharedKit

/// The Mac menubar app entry point (ADR-1: on-demand processing, no daemon).
///
/// A `MenuBarExtra` (SF Symbol mic) is the primary surface; the library and
/// diagnostics are separate windows. Confirm-on-quit guards active processing
/// (ADR-4: killed jobs leave a checkpoint and are re-runnable).
@main
struct MeetingNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(model)
                .task { await model.bootstrap() }
        } label: {
            Image(systemName: model.isRecording ? "waveform.badge.mic" : "mic")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)

        Window(Text("library.title"), id: WindowID.library) {
            LibraryView().environment(model)
        }
        .defaultSize(width: 900, height: 600)

        Window(Text("diag.title"), id: WindowID.diagnostics) {
            DiagnosticsView().environment(model)
        }
        .defaultSize(width: 520, height: 480)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
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
