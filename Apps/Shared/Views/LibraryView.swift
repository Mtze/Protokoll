import SwiftUI
import SharedKit
import SearchIndex
#if canImport(AppKit)
import AppKit
#endif

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
    @State private var sessionToDelete: Session?
    @AppStorage(SettingsKeys.onboardingDone) private var onboardingDone = false
    @State private var showOnboarding = false
    @State private var projectFilter: String?

    /// Sessions to show: filtered by the selected project (browse, in-memory),
    /// then narrowed to the FTS-matched subset when searching (F7/F10).
    private var visibleSessions: [Session] {
        var list = model.sessions
        if let projectFilter {
            list = list.filter { $0.metadata.projects.contains(projectFilter) }
        }
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            let matchedIDs = Set(model.searchResults.map(\.sessionID))
            list = list.filter { matchedIDs.contains($0.id) }
        }
        return list
    }

    var body: some View {
        NavigationSplitView {
            List(visibleSessions, selection: $selection) { session in
                SessionRow(session: session, snippet: snippet(for: session.id),
                           projects: model.projects(for: session)).tag(session.id)
                    .contextMenu {
                        Button(role: .destructive) { sessionToDelete = session } label: {
                            Label("action.delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { sessionToDelete = session } label: {
                            Label("action.delete", systemImage: "trash")
                        }
                    }
            }
            // Wide enough that title, state, date and duration all show without resizing.
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 440)
            .navigationTitle("library.title")
            .safeAreaInset(edge: .top, spacing: 0) {
                if !model.projects.isEmpty {
                    projectFilterHeader
                }
            }
            .overlay {
                if model.sessions.isEmpty {
                    ContentUnavailableView("library.empty.title", systemImage: "waveform", description: Text("library.empty.subtitle"))
                } else if !searchText.isEmpty && visibleSessions.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        } detail: {
            if let selection, let session = model.sessions.first(where: { $0.id == selection }) {
                SessionDetailView(session: session, onDelete: { sessionToDelete = $0 })
            } else {
                ContentUnavailableView("library.selectPrompt", systemImage: "sidebar.left")
            }
        }
        .searchable(text: $searchText, prompt: Text("library.search.prompt"))
        .task(id: searchText + "\u{1}" + (projectFilter ?? "")) {
            await model.search(searchText, filter: SearchFilter(projectID: projectFilter))
        }
        .onAppear { if !onboardingDone { showOnboarding = true } }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(dismiss: { showOnboarding = false })
        }
        .safeAreaInset(edge: .top) {
            if let error = model.systemAudioError {
                SystemAudioBanner(message: error)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
            }
        }
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
        .confirmationDialog(
            "delete.confirm.title",
            isPresented: Binding(get: { sessionToDelete != nil }, set: { if !$0 { sessionToDelete = nil } }),
            titleVisibility: .visible,
            presenting: sessionToDelete
        ) { session in
            Button("action.delete", role: .destructive) {
                if selection == session.id { selection = nil }
                model.deleteSession(session)
            }
            Button("common.cancel", role: .cancel) {}
        } message: { _ in
            Text("delete.confirm.message")
        }
    }

    /// A compact filter control at the top-right of the sidebar (F7). The icon
    /// fills when a filter is active, and the active project is named alongside
    /// it, so what's filtered is always clear.
    private var projectFilterHeader: some View {
        HStack(spacing: 6) {
            if let id = projectFilter, let project = model.projects.first(where: { $0.id == id }) {
                Circle().fill(Color(hex: project.color)).frame(width: 8, height: 8)
                Text(project.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("library.filter.all").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button { projectFilter = nil } label: {
                    Label("library.filter.all",
                          systemImage: projectFilter == nil ? "checkmark.circle.fill" : "circle.dashed")
                }
                Divider()
                ForEach(model.projects) { project in
                    Button { projectFilter = project.id } label: {
                        if projectFilter == project.id {
                            Label { Text(verbatim: "\(ProjectColor.emoji(for: project.color))  \(project.name)") }
                                icon: { Image(systemName: "checkmark") }
                        } else {
                            Text(verbatim: "\(ProjectColor.emoji(for: project.color))  \(project.name)")
                        }
                    }
                }
            } label: {
                Image(systemName: projectFilter == nil
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(projectFilter == nil ? Color.secondary : Color.accentColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("library.filter")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
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
    var projects: [Project] = []

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
                if !projects.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(projects) { ProjectChip(name: $0.name, colorHex: $0.color) }
                    }
                }
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

/// A tappable warning shown when system-audio capture (F2) failed; opens the
/// Screen Recording settings pane.
struct SystemAudioBanner: View {
    let message: String

    var body: some View {
        Button { Self.openScreenRecordingSettings() } label: {
            Label(message, systemImage: "speaker.slash.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
        .help("systemaudio.openSettings")
    }

    static func openScreenRecordingSettings() {
        #if canImport(AppKit)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        #endif
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
