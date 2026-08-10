import SwiftUI
import SharedKit

/// Detail pane: metadata header, a segmented switch between Protocol and
/// Transcript, and the rendered Markdown. Offers Process / Regenerate actions.
struct SessionDetailView: View {
    @Environment(AppModel.self) private var model
    let session: Session

    enum Pane: String, CaseIterable, Identifiable { case protocolDoc, transcript; var id: String { rawValue } }
    @State private var pane: Pane = .protocolDoc

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
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
        .padding()
        .navigationTitle(session.displayTitle)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.displayTitle).font(.title2).bold()
            HStack(spacing: 8) {
                StatusBadge(status: session.metadata.pipeline.status)
                if let language = session.metadata.language {
                    Label(language.uppercased(), systemImage: "globe").font(.caption).foregroundStyle(.secondary)
                }
                Text(session.metadata.startedAt, style: .date).font(.caption).foregroundStyle(.secondary)
            }
            if case let .failed(message) = session.metadata.pipeline.status {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            actions
        }
    }

    private var actions: some View {
        HStack {
            if session.metadata.pipeline.status == .recorded {
                Button { model.process(session) } label: { Label("action.process", systemImage: "gearshape.2") }
                    .buttonStyle(.borderedProminent)
            }
            if session.metadata.pipeline.status == .done {
                Button { model.regenerateProtocol(session) } label: { Label("action.regenerate", systemImage: "arrow.triangle.2.circlepath") }
            }
            Button { revealInFinder() } label: { Label("action.reveal", systemImage: "folder") }
        }
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
