import SwiftUI
import SharedKit

/// The library window: a `NavigationSplitView` listing sessions with a detail
/// pane showing transcript and protocol (F6). HIG-correct, Dark Mode and
/// Dynamic Type friendly, fully localized. A Record action in the toolbar
/// creates a new session without opening the menu bar.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKeys.consentReminder) private var consentReminder = true
    @State private var selection: Session.ID?
    @State private var searchText = ""
    @State private var showingConsent = false

    /// Sessions to show: full list, or the FTS-matched subset when searching.
    private var visibleSessions: [Session] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return model.sessions }
        let matchedIDs = Set(model.searchResults.map(\.sessionID))
        return model.sessions.filter { matchedIDs.contains($0.id) }
    }

    var body: some View {
        NavigationSplitView {
            List(visibleSessions, selection: $selection) { session in
                SessionRow(session: session, snippet: snippet(for: session.id)).tag(session.id)
            }
            // Wide enough that title, state, date and duration all show without resizing.
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 440)
            .navigationTitle("library.title")
            .overlay {
                if model.sessions.isEmpty {
                    ContentUnavailableView("library.empty.title", systemImage: "waveform", description: Text("library.empty.subtitle"))
                } else if !searchText.isEmpty && visibleSessions.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        } detail: {
            if let selection, let session = model.sessions.first(where: { $0.id == selection }) {
                SessionDetailView(session: session)
            } else {
                ContentUnavailableView("library.selectPrompt", systemImage: "sidebar.left")
            }
        }
        .searchable(text: $searchText, prompt: Text("library.search.prompt"))
        .task(id: searchText) { await model.search(searchText) }
        .toolbar {
            ToolbarItem(placement: .navigation) { recordButton }
            if model.isRecording {
                ToolbarItem(placement: .principal) {
                    RecordingIndicator(levels: model.recordingLevels, startedAt: model.recordingStartedAt, compact: true)
                        .frame(width: 180, height: 22)
                }
            }
            ToolbarItem {
                Button {
                    model.reloadSessions()
                    Task { await model.rebuildIndex() }
                } label: { Label("library.refresh", systemImage: "arrow.clockwise") }
                .help("library.refresh")
            }
        }
        .confirmationDialog("consent.title", isPresented: $showingConsent, titleVisibility: .visible) {
            Button("consent.confirm") { Task { await model.startRecording() } }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("consent.message")
        }
    }

    /// Record / stop, creating a new session right from the main window.
    private var recordButton: some View {
        Button {
            if model.isRecording {
                Task { await model.stopRecording() }
            } else if consentReminder {
                showingConsent = true
            } else {
                Task { await model.startRecording() }
            }
        } label: {
            Label(model.isRecording ? "menu.stop" : "menu.record",
                  systemImage: model.isRecording ? "stop.circle.fill" : "record.circle")
        }
        .tint(model.isRecording ? .red : .accentColor)
        .help(model.isRecording ? "menu.stop" : "action.newRecording")
    }

    private func snippet(for id: String) -> String? {
        guard !searchText.isEmpty else { return nil }
        return model.searchResults.first { $0.sessionID == id }?.snippet
    }
}

private struct SessionRow: View {
    let session: Session
    var snippet: String?

    private var status: PipelineStatus { session.metadata.pipeline.status }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Color is the only state indicator in the sidebar; hover names it.
            Circle()
                .fill(status.uiColor)
                .frame(width: 10, height: 10)
                .padding(.top, 5)
                .accessibilityLabel(Text(status.nameKey))
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle).font(.body).lineLimit(1)
                HStack(spacing: 6) {
                    Text(session.metadata.startedAt, style: .date)
                    if let duration = session.metadata.duration {
                        Text("·")
                        Text(SessionFormat.duration(duration))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let snippet, !snippet.isEmpty {
                    Text(snippet).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .help(status.nameKey)
    }
}

/// Shared duration formatting for rows and the detail header.
enum SessionFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? ""
    }
}

/// UI presentation for a pipeline state, shared by the sidebar dot, the detail
/// badge, and their hover descriptions.
extension PipelineStatus {
    var uiColor: Color {
        switch self {
        case .recorded: return .blue
        case .transcribing, .summarizing: return .orange
        case .transcribed: return .teal
        case .done: return .green
        case .failed: return .red
        }
    }

    var nameKey: LocalizedStringKey {
        switch self {
        case .recorded: return "status.recorded"
        case .transcribing: return "status.transcribing"
        case .transcribed: return "status.transcribed"
        case .summarizing: return "status.summarizing"
        case .done: return "status.done"
        case .failed: return "status.failed"
        }
    }

    var symbol: String {
        switch self {
        case .recorded: return "mic"
        case .transcribing, .summarizing: return "gearshape.2"
        case .transcribed: return "text.alignleft"
        case .done: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

/// A localized, colored status badge for the pipeline state (detail header).
struct StatusBadge: View {
    let status: PipelineStatus

    var body: some View {
        Label(status.nameKey, systemImage: status.symbol)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(status.uiColor.opacity(0.15), in: Capsule())
            .foregroundStyle(status.uiColor)
            .help(status.nameKey)
    }
}
