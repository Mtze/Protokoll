import SwiftUI
import SharedKit

/// Detail pane, three clearly separated zones:
/// 1. metadata + right-aligned meta actions (Process / Regenerate / Show in Finder),
/// 2. the audio player(s), grouped in a bordered box,
/// 3. the Protocol / Transcript document.
struct SessionDetailView: View {
    @Environment(AppModel.self) private var model
    let session: Session

    enum Pane: String, CaseIterable, Identifiable { case protocolDoc, transcript; var id: String { rawValue } }
    @State private var pane: Pane = .protocolDoc

    private var status: PipelineStatus { session.metadata.pipeline.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            metadataSection
            if hasMicAudio {
                GroupBox { audioPlayers.padding(4) }
            }
            documentSection
        }
        .padding()
        .navigationTitle(session.displayTitle)
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

    /// Right-aligned actions. Show in Finder is icon-only with a hover label.
    private var metaActions: some View {
        HStack(spacing: 8) {
            if status == .recorded {
                Button { model.process(session) } label: {
                    Label("action.process", systemImage: "gearshape.2")
                }
                .buttonStyle(.borderedProminent)
                .help("action.process")
            }
            if status == .done {
                Button { model.regenerateProtocol(session) } label: {
                    Label("action.regenerate", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("action.regenerate")
            }
            Button { revealInFinder() } label: {
                Image(systemName: "folder")
            }
            .help("action.reveal")
            .accessibilityLabel(Text("action.reveal"))
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
