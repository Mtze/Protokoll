import SwiftUI
import SharedKit
import UniformTypeIdentifiers

/// The menubar panel: record/stop with a visible recording indicator (N4),
/// the aggregate health dot, unprocessed sessions with a Process action (F13),
/// and links to the library and diagnostics windows.
struct MenuContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsKeys.consentReminder) private var consentReminder = true
    @State private var showingConsent = false
    @State private var showingImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            Divider()
            recordButton
            importButton

            if model.isRecording {
                RecordingIndicator(levels: model.recordingLevels, startedAt: model.recordingStartedAt)
                    .frame(height: 28)
            }

            if let stopped = model.justStoppedSession {
                PostStopCard(session: stopped)
            }

            if let error = model.systemAudioError {
                SystemAudioBanner(message: error)
            }

            if let error = model.importError {
                Button { model.clearImportError() } label: {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .help("common.ok")
            }

            if !model.scheduler.jobs.isEmpty {
                Divider()
                jobsSection
            }

            if !model.unprocessedSessions.isEmpty {
                Divider()
                unprocessedSection
            }

            Divider()
            footerButtons
        }
        .padding(12)
        .frame(width: 320)
    }

    private var headerRow: some View {
        HStack {
            Image(systemName: "waveform.badge.mic").foregroundStyle(.tint)
            Text("app.name").font(.headline)
            Spacer()
            Button { openWindow(id: WindowID.diagnostics) } label: { HealthDot(health: model.health) }
                .buttonStyle(.plain)
                .help("diag.title")
        }
    }

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
            if model.isRecording {
                Label("menu.stop", systemImage: "stop.circle.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating)
            } else {
                Label("menu.record", systemImage: "record.circle")
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isRecording ? .red : .accentColor)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .keyboardShortcut("n", modifiers: .command)
        .confirmationDialog("consent.title", isPresented: $showingConsent, titleVisibility: .visible) {
            Button("consent.confirm") { Task { await model.startRecording() } }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("consent.message")
        }
    }

    private var importButton: some View {
        Button {
            showingImporter = true
        } label: {
            Label("action.importAudio", systemImage: "square.and.arrow.down")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.audio, .movie],
                      allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first {
                Task { await model.importAudio(from: url) }
            }
        }
    }

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("menu.processing").font(.caption).foregroundStyle(.secondary)
            ForEach(model.scheduler.jobs) { job in
                HStack {
                    stateIcon(job.state)
                    Text(job.title).lineLimit(1).font(.callout)
                    Spacer()
                    Text(LocalizedStringKey("step.\(job.step.rawValue)")).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func stateIcon(_ state: ProcessingJob.State) -> some View {
        switch state {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private var unprocessedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("menu.newRecordings").font(.caption).foregroundStyle(.secondary)
            ForEach(model.unprocessedSessions.prefix(5)) { session in
                HStack {
                    Text(session.displayTitle).lineLimit(1).font(.callout)
                    Spacer()
                    Button("action.process") { model.process(session) }
                        .controlSize(.small)
                }
            }
        }
    }

    private var footerButtons: some View {
        VStack(spacing: 6) {
            HStack {
                Button { openWindow(id: WindowID.library) } label: { Label("menu.library", systemImage: "books.vertical") }
                Spacer()
                Button { openWindow(id: WindowID.diagnostics) } label: { Label("menu.diagnostics", systemImage: "stethoscope") }
            }
            .buttonStyle(.plain)
            .font(.callout)
            HStack {
                Spacer()
                Button("menu.quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }
}

/// The post-stop card (ADR-13): right after a recording stops, offer to paste
/// material links (agenda doc, reference pages) and pick a pipeline before
/// processing. Skippable - closing the popover or dismissing keeps the session
/// untouched; while the card shows, auto-processing holds off for the session.
private struct PostStopCard: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var materialsText = ""
    @State private var pipelineID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("card.justRecorded", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { save(); model.dismissPostStopCard() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("common.dismiss")
            }
            Text(session.displayTitle).font(.callout).lineLimit(1)
            TextField("card.materials", text: $materialsText, prompt: Text("card.materials.prompt"), axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
            if !model.pipelinesConfig.pipelines.isEmpty {
                Picker("card.pipeline", selection: $pipelineID) {
                    Text("card.pipeline.auto").tag("")
                    ForEach(model.pipelinesConfig.pipelines) { pipeline in
                        Text(pipeline.name).tag(pipeline.id)
                    }
                }
                .font(.caption)
            }
            Button {
                save()
                if let current = model.sessions.first(where: { $0.id == session.id }) {
                    model.process(current)
                }
                model.dismissPostStopCard()
            } label: {
                Label("action.process", systemImage: "gearshape.arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { materialsText = (session.metadata.materials ?? []).joined(separator: "\n") }
    }

    /// Persists the card's values; parsing splits on whitespace/newlines.
    private func save() {
        model.setMaterials(AppModel.parseMaterialLinks(materialsText), for: session)
        if !pipelineID.isEmpty,
           let current = model.sessions.first(where: { $0.id == session.id }) {
            model.setPipelineOverride(pipelineID, for: current)
        }
    }
}

/// Stable window identifiers.
enum WindowID {
    static let library = "library"
    static let diagnostics = "diagnostics"
}

#if canImport(AppKit)
import AppKit
#endif
