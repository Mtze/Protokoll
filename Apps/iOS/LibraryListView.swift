import SwiftUI
import SharedKit

/// iOS library (F12): searchable list of sessions with a detail viewer for
/// transcript + protocol.
struct LibraryListView: View {
    @Environment(IOSAppModel.self) private var model
    @State private var searchText = ""

    private var visible: [Session] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return model.sessions }
        let ids = Set(model.searchResults.map(\.sessionID))
        return model.sessions.filter { ids.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List(visible) { session in
                NavigationLink {
                    IOSDetailView(session: session)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.displayTitle).lineLimit(1)
                        HStack(spacing: 6) {
                            IOSStatusBadge(status: session.metadata.pipeline.status)
                            Text(session.metadata.startedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if model.sessions.isEmpty {
                    ContentUnavailableView("library.empty.title", systemImage: "waveform", description: Text("library.empty.subtitle"))
                }
            }
            .navigationTitle("library.title")
            .searchable(text: $searchText, prompt: Text("library.search.prompt"))
            .task(id: searchText) { await model.search(searchText) }
            .refreshable { model.reload(); await model.rebuildIndex() }
        }
    }
}

/// SwiftUI-only status badge (iOS copy; the Mac target has its own).
struct IOSStatusBadge: View {
    let status: PipelineStatus
    var body: some View {
        Text(titleKey).font(.caption2)
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

struct IOSDetailView: View {
    let session: Session
    enum Pane: String, CaseIterable, Identifiable { case protocolDoc, transcript; var id: String { rawValue } }
    @State private var pane: Pane = .protocolDoc

    var body: some View {
        VStack {
            if FileManager.default.fileExists(atPath: session.micAudioURL.path) {
                AudioPlayerView(url: session.micAudioURL, title: "player.mic")
                    .padding(.horizontal)
            }
            Picker("detail.pane", selection: $pane) {
                Text("detail.pane.protocol").tag(Pane.protocolDoc)
                Text("detail.pane.transcript").tag(Pane.transcript)
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal)
            ScrollView {
                Text(text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding()
            }
        }
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var text: String {
        let url = pane == .protocolDoc ? session.protocolURL : session.transcriptURL
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return String(localized: pane == .protocolDoc ? "detail.noProtocol" : "detail.noTranscript")
        }
        return Frontmatter.split(raw).body
    }
}
