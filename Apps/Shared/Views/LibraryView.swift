import SwiftUI
import SharedKit

/// The library window: a `NavigationSplitView` listing sessions with a detail
/// pane showing transcript and protocol (F6). HIG-correct, Dark Mode and
/// Dynamic Type friendly, fully localized.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Session.ID?

    var body: some View {
        NavigationSplitView {
            List(model.sessions, selection: $selection) { session in
                SessionRow(session: session).tag(session.id)
            }
            .navigationTitle("library.title")
            .overlay {
                if model.sessions.isEmpty {
                    ContentUnavailableView("library.empty.title", systemImage: "waveform", description: Text("library.empty.subtitle"))
                }
            }
        } detail: {
            if let selection, let session = model.sessions.first(where: { $0.id == selection }) {
                SessionDetailView(session: session)
            } else {
                ContentUnavailableView("library.selectPrompt", systemImage: "sidebar.left")
            }
        }
        .toolbar {
            ToolbarItem { Button { model.reloadSessions() } label: { Label("library.refresh", systemImage: "arrow.clockwise") } }
        }
    }
}

private struct SessionRow: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.displayTitle).font(.body).lineLimit(1)
            HStack(spacing: 6) {
                StatusBadge(status: session.metadata.pipeline.status)
                Text(session.metadata.startedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                if let duration = session.metadata.duration {
                    Text(Self.durationText(duration)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? ""
    }
}

/// A localized, colored status badge for the pipeline state.
struct StatusBadge: View {
    let status: PipelineStatus

    var body: some View {
        Label(titleKey, systemImage: symbol)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var titleKey: LocalizedStringKey {
        switch status {
        case .recorded: return "status.recorded"
        case .transcribing: return "status.transcribing"
        case .transcribed: return "status.transcribed"
        case .summarizing: return "status.summarizing"
        case .done: return "status.done"
        case .failed: return "status.failed"
        }
    }

    private var symbol: String {
        switch status {
        case .recorded: return "mic"
        case .transcribing, .summarizing: return "gearshape.2"
        case .transcribed: return "text.alignleft"
        case .done: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch status {
        case .recorded: return .blue
        case .transcribing, .summarizing: return .orange
        case .transcribed: return .teal
        case .done: return .green
        case .failed: return .red
        }
    }
}
