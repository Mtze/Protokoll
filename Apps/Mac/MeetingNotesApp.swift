import SwiftUI
import SharedKit

/// The Mac menubar app entry point (ADR-1: on-demand processing, no daemon).
///
/// A `MenuBarExtra` (SF Symbol mic) is the primary surface; the library and
/// diagnostics are separate windows. Confirm-on-quit guards active processing
/// (ADR-4: killed jobs leave a checkpoint and are re-runnable).
@main
struct MeetingNotesApp: App {
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
    }
}
