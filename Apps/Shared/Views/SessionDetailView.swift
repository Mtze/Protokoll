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

    enum Pane: String, CaseIterable, Identifiable { case protocolDoc, transcript; var id: String { rawValue } }
    @State private var pane: Pane = .protocolDoc

    private var status: PipelineStatus { session.metadata.pipeline.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            metadataSection
            processingSection
            if hasMicAudio {
                GroupBox { audioPlayers.padding(4) }
            }
            documentSection
        }
        .padding()
        .navigationTitle(session.displayTitle)
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
                    if let duration = session.metadata.duration {
                        Text(SessionFormat.duration(duration)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if case let .failed(message) = status {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            metaActions
        }
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
            Button { revealInFinder() } label: {
                Image(systemName: "folder")
            }
            .help("action.reveal")
            .accessibilityLabel(Text("action.reveal"))
            Button(role: .destructive) { onDelete(session) } label: {
                Image(systemName: "trash")
            }
            .help("action.delete")
            .accessibilityLabel(Text("action.delete"))
        }
    }

    // MARK: 2. Audio

    private var hasMicAudio: Bool {
        FileManager.default.fileExists(atPath: session.micAudioURL.path)
    }

    @ViewBuilder private var audioPlayers: some View {
        let fileManager = FileManager.default
        VStack(alignment: .leading, spacing: 10) {
            AudioPlayerView(url: session.micAudioURL, title: "player.mic")
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
            Picker("detail.pane", selection: $pane) {
                Text("detail.pane.protocol").tag(Pane.protocolDoc)
                Text("detail.pane.transcript").tag(Pane.transcript)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                Text(documentText)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var documentText: String {
        let url = pane == .protocolDoc ? session.protocolURL : session.transcriptURL
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return String(localized: pane == .protocolDoc ? "detail.noProtocol" : "detail.noTranscript")
        }
        // Show just the body, not our YAML frontmatter.
        return Frontmatter.split(raw).body
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
