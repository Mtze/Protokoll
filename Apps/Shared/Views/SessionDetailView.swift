import SwiftUI
import SharedKit

/// Detail pane, three clearly separated zones:
/// 1. metadata + right-aligned meta actions (Process / Regenerate / Show in Finder),
/// 2. the audio player(s), grouped in a bordered box,
/// 3. the Protocol / Transcript document.
struct SessionDetailView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    /// Invoked when the user asks to delete this session; the library owns the
    /// confirmation dialog and selection reset.
    var onDelete: (Session) -> Void = { _ in }
    /// Invoked when the user asks to rename this session; the library owns the
    /// rename dialog.
    var onRename: (Session) -> Void = { _ in }

    enum Pane: String, CaseIterable, Identifiable { case protocolDoc, transcript; var id: String { rawValue } }
    @State private var pane: Pane = .protocolDoc
    /// One player shared by the audio control and the tap-to-seek transcript list.
    @State private var audioModel = AudioPlayerModel()
    /// The current document, read and parsed off the main actor by `loadDocument`.
    @State private var document = LoadedDocument()

    private var status: PipelineStatus { session.metadata.pipeline.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            metadataSection
            processingSection
            if hasMicAudio {
                GroupBox { audioPlayers.padding(4) }
                    // Seek keys fire only while the player holds focus, so they
                    // never fight the search field or scrolling (F: keyboard).
                    .focusable()
                    .onKeyPress(.leftArrow) {
                        audioModel.seek(to: audioModel.currentTime - 10); return .handled
                    }
                    .onKeyPress(.rightArrow) {
                        audioModel.seek(to: audioModel.currentTime + 10); return .handled
                    }
            }
            documentSection
        }
        .padding()
        .navigationTitle(session.displayTitle)
        .focusedSceneValue(\.detailActions, detailActions)
    }

    /// Actions the menu-bar Session commands drive for this session. Rebuilt each
    /// body pass so labels/state track the current status and pane.
    private var detailActions: DetailActions {
        let action = SessionAction.forDetail(status: status, hasActiveJob: model.activeJob(for: session.id) != nil)
        let primary: DetailActions.Primary?
        switch action {
        case .process: primary = .init(label: "action.process") { model.process(session) }
        case .retry: primary = .init(label: "action.retry") { model.retry(session) }
        case .regenerate: primary = .init(label: "action.regenerate") { model.regenerateProtocol(session) }
        case .none: primary = nil
        }
        let playPause: (() -> Void)? = hasMicAudio ? { audioModel.playPause() } : nil
        return DetailActions(
            primary: primary,
            rename: { onRename(session) },
            delete: { onDelete(session) },
            reveal: { revealInFinder() },
            copyDocument: { if !document.body.isEmpty { DocumentPasteboard.copy(document.body) } },
            showProtocol: { pane = .protocolDoc },
            showTranscript: { pane = .transcript },
            playPause: playPause,
            assignedProjectIDs: Set(session.metadata.projects),
            toggleProject: { toggleProject($0) }
        )
    }

    /// Live feedback for the processing chain (F13/N6): queued, running with the
    /// engine's latest progress line, or a clear failure with a Retry action.
    @ViewBuilder private var processingSection: some View {
        if let job = model.activeJob(for: session.id) {
            GroupBox {
                HStack(alignment: .center, spacing: 10) {
                    switch job.state {
                    case .queued:
                        ProgressView().controlSize(.small)
                        Text("detail.processing.queued")
                        Spacer()
                    case .running:
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.step == .transcribe ? "status.transcribing" : "status.summarizing")
                                .font(.callout)
                            if !job.progress.isEmpty {
                                Text(job.progress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                    case let .failed(message):
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("status.failed").font(.callout).foregroundStyle(.red)
                            Text(message).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled).lineLimit(3)
                        }
                        Spacer()
                        Button { model.retry(session) } label: {
                            Label("action.retry", systemImage: "arrow.clockwise")
                        }
                        .help("action.retry")
                    case .finished:
                        EmptyView()
                    }
                }
            }
        }
    }

    // MARK: 1. Metadata + meta actions

    private var metadataSection: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.displayTitle).font(.title2).bold().lineLimit(2)
                HStack(spacing: 8) {
                    StatusBadge(status: status)
                    if let language = session.metadata.language {
                        Label(language.uppercased(), systemImage: "globe").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(session.metadata.startedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    Text(session.metadata.startedAt, style: .time).font(.caption).foregroundStyle(.secondary)
                    if let duration = session.metadata.duration {
                        Text(SessionFormat.duration(duration)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if case let .failed(message) = status {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                let projects = model.projects(for: session)
                if !projects.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(projects) { ProjectChip(name: $0.name, colorHex: $0.color) }
                    }
                }
            }
            Spacer(minLength: 8)
            metaActions
        }
    }

    /// Toggle the session's membership in a project and persist (F7).
    private func toggleProject(_ project: Project) {
        var ids = session.metadata.projects
        if let i = ids.firstIndex(of: project.id) { ids.remove(at: i) } else { ids.append(project.id) }
        model.setProjects(ids, for: session)
    }

    /// Right-aligned actions, derived from the persisted status so they survive
    /// a restart (a failed session keeps its Retry button). Show in Finder is
    /// icon-only with a hover label.
    private var metaActions: some View {
        HStack(spacing: 8) {
            switch SessionAction.forDetail(status: status, hasActiveJob: model.activeJob(for: session.id) != nil) {
            case .process:
                Button { model.process(session) } label: {
                    Label("action.process", systemImage: "gearshape.2")
                }
                .buttonStyle(.borderedProminent)
                .help("action.process")
            case .retry:
                Button { model.retry(session) } label: {
                    Label("action.retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .help("action.retry")
            case .regenerate:
                Button { model.regenerateProtocol(session) } label: {
                    Label("action.regenerate", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("action.regenerate")
            case .none:
                EmptyView()
            }
            if !model.projects.isEmpty {
                Menu {
                    ForEach(model.projects) { project in
                        Button { toggleProject(project) } label: {
                            if session.metadata.projects.contains(project.id) {
                                Label { Text(verbatim: "\(ProjectColor.emoji(for: project.color))  \(project.name)") }
                                    icon: { Image(systemName: "checkmark") }
                            } else {
                                Text(verbatim: "\(ProjectColor.emoji(for: project.color))  \(project.name)")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "tag")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("project.assign")
                .accessibilityLabel(Text("project.assign"))
            }
        }
    }

    // MARK: 2. Audio

    private var hasMicAudio: Bool {
        FileManager.default.fileExists(atPath: session.micAudioURL.path)
    }

    @ViewBuilder private var audioPlayers: some View {
        let fileManager = FileManager.default
        VStack(alignment: .leading, spacing: 10) {
            // Single combined mic+system track (ADR-7) - no misleading "Microphone".
            AudioPlayerView(url: session.micAudioURL, model: audioModel, title: "player.recording")
            // Legacy sessions may still carry a separate system-audio track.
            if session.metadata.audioTracks.contains(.system),
               fileManager.fileExists(atPath: session.systemAudioURL.path) {
                Divider()
                AudioPlayerView(url: session.systemAudioURL, title: "player.system")
            }
        }
    }

    // MARK: 3. Document

    private var documentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("detail.pane", selection: $pane) {
                    Text("detail.pane.protocol").tag(Pane.protocolDoc)
                    Text("detail.pane.transcript").tag(Pane.transcript)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if !document.body.isEmpty {
                    DocumentActions(bodyText: document.body, fileURL: currentDocumentURL, exportName: exportName)
                }
            }

            ScrollView {
                documentContent.padding(.vertical, 4)
            }
        }
        .frame(maxHeight: .infinity)
        // Reload whenever the file identity changes: pane switch, session switch,
        // or the pipeline rewriting protocol.md in place (the key includes mtime).
        .task(id: DocumentLoader.key(for: currentDocumentURL, pane: pane.rawValue)) {
            await loadDocument()
        }
    }

    private var currentDocumentURL: URL {
        pane == .protocolDoc ? session.protocolURL : session.transcriptURL
    }

    /// Reads and parses the current document off the main actor, then hands the
    /// segment starts to the shared player so it can drive the highlight.
    private func loadDocument() async {
        let url = currentDocumentURL
        let wantsTranscript = pane == .transcript
        let loaded = await Task.detached(priority: .userInitiated) {
            DocumentLoader.load(url, parseTranscript: wantsTranscript)
        }.value
        guard !Task.isCancelled else { return }
        document = loaded
        audioModel.segmentStarts = wantsTranscript ? loaded.segments : []
    }

    @ViewBuilder private var documentContent: some View {
        if !document.isEmpty {
            if document.rows.isEmpty {
                MarkdownText(blocks: document.blocks)
            } else {
                TranscriptSegmentList(items: document.rows, model: audioModel, canSeek: hasMicAudio)
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

    private func revealInFinder() {
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([session.folder])
        #endif
    }
}

#if canImport(AppKit)
import AppKit
#endif
