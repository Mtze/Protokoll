import SwiftUI
import SharedKit
import SearchIndex

/// iOS library (F12): searchable list of sessions with a detail viewer for
/// transcript + protocol.
struct LibraryListView: View {
    @Environment(IOSAppModel.self) private var model
    @State private var searchText = ""
    @State private var sessionToDelete: Session?
    @State private var projectFilter: String?

    private var visible: [Session] {
        var list = model.sessions
        if let projectFilter {
            list = list.filter { $0.metadata.projects.contains(projectFilter) }
        }
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            let ids = Set(model.searchResults.map(\.sessionID))
            list = list.filter { ids.contains($0.id) }
        }
        return list
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
                            Text(session.metadata.startedAt, style: .time).font(.caption).foregroundStyle(.secondary)
                        }
                        let projects = model.projects(for: session)
                        if !projects.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(projects) { ProjectChip(name: $0.name, colorHex: $0.color) }
                            }
                        }
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { sessionToDelete = session } label: {
                        Label("action.delete", systemImage: "trash")
                    }
                }
            }
            .overlay {
                if model.sessions.isEmpty {
                    ContentUnavailableView("library.empty.title", systemImage: "waveform", description: Text("library.empty.subtitle"))
                }
            }
            .navigationTitle("library.title")
            .toolbar {
                if !model.projects.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { projectFilter = nil } label: {
                                Label("library.filter.all", systemImage: projectFilter == nil ? "checkmark" : "")
                            }
                            Divider()
                            ForEach(model.projects) { project in
                                Button { projectFilter = project.id } label: {
                                    Label(project.name, systemImage: projectFilter == project.id ? "checkmark" : "circle")
                                }
                            }
                        } label: {
                            Label("library.filter", systemImage: projectFilter == nil
                                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: Text("library.search.prompt"))
            .task(id: searchText + "\u{1}" + (projectFilter ?? "")) {
                await model.search(searchText, filter: SearchFilter(projectID: projectFilter))
            }
            .refreshable { model.reload(); await model.rebuildIndex() }
            .confirmationDialog(
                "delete.confirm.title",
                isPresented: Binding(get: { sessionToDelete != nil }, set: { if !$0 { sessionToDelete = nil } }),
                titleVisibility: .visible,
                presenting: sessionToDelete
            ) { session in
                Button("action.delete", role: .destructive) { model.deleteSession(session) }
                Button("common.cancel", role: .cancel) {}
            } message: { _ in
                Text("delete.confirm.message")
            }
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
    @Environment(IOSAppModel.self) private var model
    let session: Session
    enum Pane: String, CaseIterable, Identifiable { case protocolDoc, transcript; var id: String { rawValue } }
    @State private var pane: Pane = .protocolDoc
    /// One player shared by the audio control and the tap-to-seek transcript list.
    @State private var audioModel = AudioPlayerModel()

    private var hasMicAudio: Bool {
        FileManager.default.fileExists(atPath: session.micAudioURL.path)
    }

    var body: some View {
        VStack {
            if hasMicAudio {
                // Single combined mic+system track (ADR-7) - no "Microphone" label.
                AudioPlayerView(url: session.micAudioURL, model: audioModel, title: "player.recording")
                    .padding(.horizontal)
            }
            HStack {
                Picker("detail.pane", selection: $pane) {
                    Text("detail.pane.protocol").tag(Pane.protocolDoc)
                    Text("detail.pane.transcript").tag(Pane.transcript)
                }
                .pickerStyle(.segmented).labelsHidden()
                if let body = documentBody, !body.isEmpty {
                    DocumentActions(bodyText: body, fileURL: currentDocumentURL, exportName: exportName)
                }
            }
            .padding(.horizontal)
            ScrollView {
                documentContent.padding()
            }
        }
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.projects.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(model.projects) { project in
                            Button { toggleProject(project) } label: {
                                Label(project.name,
                                      systemImage: session.metadata.projects.contains(project.id) ? "checkmark" : "circle")
                            }
                        }
                    } label: {
                        Label("project.assign", systemImage: "tag")
                    }
                }
            }
        }
    }

    private func toggleProject(_ project: Project) {
        var ids = session.metadata.projects
        if let i = ids.firstIndex(of: project.id) { ids.remove(at: i) } else { ids.append(project.id) }
        model.setProjects(ids, for: session)
    }

    private var currentDocumentURL: URL {
        pane == .protocolDoc ? session.protocolURL : session.transcriptURL
    }

    private var documentBody: String? {
        guard let raw = try? String(contentsOf: currentDocumentURL, encoding: .utf8) else { return nil }
        return Frontmatter.split(raw).body
    }

    @ViewBuilder private var documentContent: some View {
        if let body = documentBody, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch pane {
            case .protocolDoc:
                MarkdownText(markdown: body)
            case .transcript:
                let segments = TranscriptParser.parse(body)
                if segments.isEmpty {
                    MarkdownText(markdown: body)
                } else {
                    TranscriptSegmentList(segments: segments, model: audioModel, canSeek: hasMicAudio)
                }
            }
        } else {
            Text(pane == .protocolDoc ? "detail.noProtocol" : "detail.noTranscript")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var exportName: String {
        let kind = String(localized: pane == .protocolDoc ? "detail.pane.protocol" : "detail.pane.transcript")
        return "\(session.displayTitle) - \(kind).md"
    }
}
