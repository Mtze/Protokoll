import SwiftUI
import SharedKit
import SearchIndex
import UniformTypeIdentifiers
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
    @State private var sessionToRename: Session?
    @State private var sessionToRetranscribe: Session?
    @State private var renameText = ""
    @State private var sessionToEditMaterials: Session?
    @State private var materialsText = ""
    @AppStorage(SettingsKeys.onboardingDone) private var onboardingDone = false
    @State private var showOnboarding = false
    @State private var projectFilter: String?
    @State private var showingImporter = false

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
            sidebar
        } detail: {
            if let selection, let session = model.sessions.first(where: { $0.id == selection }) {
                SessionDetailView(session: session,
                                  onDelete: { sessionToDelete = $0 },
                                  onRename: { beginRename($0) },
                                  onRetranscribe: { sessionToRetranscribe = $0 })
            } else {
                ContentUnavailableView("library.selectPrompt", systemImage: "sidebar.left")
            }
        }
        .searchable(text: $searchText, prompt: Text("library.search.prompt"))
        .focusedSceneValue(\.recordAction, recordTapped)
        .focusedSceneValue(\.importAction, { showingImporter = true })
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.audio, .movie],
                      allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first {
                Task { await model.importAudio(from: url) }
            }
        }
        .alert("import.error.title",
               isPresented: Binding(get: { model.importError != nil },
                                    set: { if !$0 { model.clearImportError() } })) {
            Button("common.ok", role: .cancel) { model.clearImportError() }
        } message: {
            Text(verbatim: model.importError ?? "")
        }
        .task(id: searchText + "\u{1}" + (projectFilter ?? "")) {
            await model.search(searchText, filter: SearchFilter(projectID: projectFilter))
        }
        .onAppear { if !onboardingDone { showOnboarding = true } }
        .onChange(of: model.pendingRevealSessionID) {
            // A tapped completion notification selects its session.
            if let id = model.pendingRevealSessionID {
                selection = id
                model.pendingRevealSessionID = nil
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(dismiss: { showOnboarding = false })
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                if let error = model.systemAudioError {
                    SystemAudioBanner(message: error)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial)
                }
                if let warning = model.inputClippedWarning {
                    InputClippedBanner(message: warning) { model.inputClippedWarning = nil }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { recordButton }
            ToolbarItem(placement: .navigation) { importButton }
            if model.isRecording {
                // Deliberately does NOT read `model.recordingLevels` here - see
                // RecordingToolbarIndicator.
                ToolbarItem(placement: .principal) { RecordingToolbarIndicator() }
            }
        }
        .modifier(SessionDialogs(model: model, selection: $selection,
                                 showingConsent: $showingConsent,
                                 sessionToDelete: $sessionToDelete,
                                 sessionToRename: $sessionToRename,
                                 sessionToRetranscribe: $sessionToRetranscribe,
                                 renameText: $renameText,
                                 sessionToEditMaterials: $sessionToEditMaterials,
                                 materialsText: $materialsText))
    }

    /// The session list (sidebar column), extracted to keep `body` type-checkable.
    private var sidebar: some View {
        List(visibleSessions, selection: $selection) { session in
            SessionRow(session: session, snippet: snippet(for: session.id),
                       projects: model.projects(for: session)).tag(session.id)
                .contextMenu { sessionMenuItems(for: session) }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { sessionToDelete = session } label: {
                        Label("action.delete", systemImage: "trash")
                    }
                }
        }
        // Wide enough that title, state, date and duration all show without resizing.
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 440)
        .navigationTitle("library.title")
        .safeAreaInset(edge: .top, spacing: 0) { sidebarHeader }
        .overlay {
            if model.sessions.isEmpty {
                ContentUnavailableView("library.empty.title", systemImage: "waveform", description: Text("library.empty.subtitle"))
            } else if !searchText.isEmpty && visibleSessions.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    /// Opens the rename dialog for `session`, prefilled with its current title.
    private func beginRename(_ session: Session) {
        renameText = session.displayTitle
        sessionToRename = session
    }

    /// Opens the materials dialog (ADR-13), prefilled with the current links.
    private func beginEditMaterials(_ session: Session) {
        materialsText = (session.metadata.materials ?? []).joined(separator: " ")
        sessionToEditMaterials = session
    }

    /// The per-session actions shown in the sidebar row context menu, mirrored by
    /// the "Session" system menu (`ProtokollCommands`).
    @ViewBuilder private func sessionMenuItems(for session: Session) -> some View {
        switch SessionAction.forDetail(status: session.metadata.pipeline.status,
                                       hasActiveJob: model.activeJob(for: session.id) != nil) {
        case .process:
            if model.pipelinesConfig.pipelines.isEmpty {
                Button { model.process(session) } label: { Label("action.process", systemImage: "gearshape.2") }
            } else {
                // With custom pipelines, Process becomes a picker (ADR-13); the
                // checkmark shows what would run, the choice persists.
                Menu {
                    pipelineChoice(for: session, id: nil, name: nil)
                    ForEach(model.pipelinesConfig.pipelines) { pipeline in
                        pipelineChoice(for: session, id: pipeline.id, name: pipeline.name)
                    }
                } label: {
                    Label("action.process", systemImage: "gearshape.2")
                }
            }
        case .retry:
            Button { model.retry(session) } label: { Label("action.retry", systemImage: "arrow.clockwise") }
        case .regenerate:
            Button { model.regenerateProtocol(session) } label: {
                Label("action.regenerate", systemImage: "arrow.triangle.2.circlepath")
            }
        case .none:
            EmptyView()
        }

        if SessionAction.hasRerunnableSteps(status: session.metadata.pipeline.status,
                                            steps: session.metadata.pipeline.steps,
                                            hasActiveJob: model.activeJob(for: session.id) != nil) {
            Button { model.runActions(session) } label: {
                Label("step.rerunAll", systemImage: "sparkles")
            }
        }

        // Re-transcribe from the audio. Offered whenever a transcript exists and
        // nothing is running: useful after changing the language/vocabulary/model
        // or installing a faster, less hallucination-prone engine. For a session
        // that has never been processed, Process above already does this.
        if model.canRetranscribe(session) {
            Button { sessionToRetranscribe = session } label: {
                Label("action.retranscribe", systemImage: "waveform.badge.magnifyingglass")
            }
        }

        Button { beginRename(session) } label: { Label("action.rename", systemImage: "pencil") }
        Button { beginEditMaterials(session) } label: { Label("action.materials", systemImage: "link") }
        Button { reveal(session) } label: { Label("action.reveal", systemImage: "folder") }

        if !model.projects.isEmpty {
            Menu {
                ForEach(model.projects) { project in
                    Button { toggleProject(project, for: session) } label: {
                        if session.metadata.projects.contains(project.id) {
                            Label { Text(verbatim: "\(ProjectColor.emoji(for: project.color))  \(project.name)") }
                                icon: { Image(systemName: "checkmark") }
                        } else {
                            Text(verbatim: "\(ProjectColor.emoji(for: project.color))  \(project.name)")
                        }
                    }
                }
            } label: {
                Label("project.assign", systemImage: "tag")
            }
        }

        Divider()

        Button(role: .destructive) { sessionToDelete = session } label: {
            Label("action.delete", systemImage: "trash")
        }
    }

    /// One entry of the Process pipeline picker: `id == nil` is the built-in
    /// default. Selecting persists the override, then processes.
    @ViewBuilder private func pipelineChoice(for session: Session, id: String?, name: String?) -> some View {
        let resolved = PipelineResolver.resolve(session: session.metadata,
                                                projects: model.projects,
                                                config: model.pipelinesConfig)?.id
        Button {
            model.setPipelineOverride(id ?? "", for: session)
            if let fresh = model.sessions.first(where: { $0.id == session.id }) {
                model.process(fresh)
            }
        } label: {
            let title = name ?? String(localized: "pipeline.builtin")
            if resolved == id {
                Label { Text(verbatim: title) } icon: { Image(systemName: "checkmark") }
            } else {
                Text(verbatim: title)
            }
        }
    }

    /// Toggles `session`'s membership in `project` and persists (F7).
    private func toggleProject(_ project: Project, for session: Session) {
        var ids = session.metadata.projects
        if let i = ids.firstIndex(of: project.id) { ids.remove(at: i) } else { ids.append(project.id) }
        model.setProjects(ids, for: session)
    }

    private func reveal(_ session: Session) {
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([session.folder])
        #endif
    }

    /// The sidebar header bar: the active project filter (when any projects
    /// exist) on the left, and the filter + refresh controls on the right.
    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            if !model.projects.isEmpty {
                if let id = projectFilter, let project = model.projects.first(where: { $0.id == id }) {
                    Circle().fill(Color(hex: project.color)).frame(width: 8, height: 8)
                    Text(project.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("library.filter.all").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !model.projects.isEmpty { filterMenu }
            Button {
                model.reloadSessions()
                Task { await model.rebuildIndex() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("library.refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// Record / stop, creating a new session right from the main window. Shared
    /// by the toolbar button and the `⌘N` menu command (published as a scene
    /// value) so both honor the consent reminder.
    private func recordTapped() {
        if model.isRecording {
            Task { await model.stopRecording() }
        } else if consentReminder {
            showingConsent = true
        } else {
            Task { await model.startRecording() }
        }
    }

    /// The project filter menu (F7). The icon fills when a filter is active.
    private var filterMenu: some View {
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

    /// Record / stop, creating a new session right from the main window.
    private var recordButton: some View {
        Button {
            recordTapped()
        } label: {
            Label(model.isRecording ? "menu.stop" : "menu.record",
                  systemImage: model.isRecording ? "stop.circle.fill" : "record.circle")
        }
        .tint(model.isRecording ? .red : .accentColor)
        .help(model.isRecording ? "menu.stop" : "action.newRecording")
    }

    /// Import an existing recording from a file, turning it into a session.
    private var importButton: some View {
        Button {
            showingImporter = true
        } label: {
            Label("action.importAudio", systemImage: "square.and.arrow.down")
        }
        .help("action.importAudio")
    }

    private func snippet(for id: String) -> String? {
        guard !searchText.isEmpty else { return nil }
        return model.searchResults.first { $0.sessionID == id }?.snippet
    }
}

/// The library's consent / delete / rename dialogs, factored out of `body` to
/// keep the main view's modifier chain within the type-checker's budget.
private struct SessionDialogs: ViewModifier {
    let model: AppModel
    @Binding var selection: Session.ID?
    @Binding var showingConsent: Bool
    @Binding var sessionToDelete: Session?
    @Binding var sessionToRename: Session?
    @Binding var sessionToRetranscribe: Session?
    @Binding var renameText: String
    @Binding var sessionToEditMaterials: Session?
    @Binding var materialsText: String

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "retranscribe.confirm.title",
                isPresented: Binding(get: { sessionToRetranscribe != nil },
                                     set: { if !$0 { sessionToRetranscribe = nil } }),
                titleVisibility: .visible,
                presenting: sessionToRetranscribe
            ) { session in
                Button("action.retranscribe") { model.retranscribe(session) }
                Button("common.cancel", role: .cancel) {}
            } message: { _ in
                Text("retranscribe.confirm.message")
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
            .alert(
                "rename.title",
                isPresented: Binding(get: { sessionToRename != nil }, set: { if !$0 { sessionToRename = nil } }),
                presenting: sessionToRename
            ) { session in
                TextField("rename.placeholder", text: $renameText)
                Button("common.save") { model.rename(session, to: renameText) }
                Button("common.cancel", role: .cancel) {}
            }
            .alert(
                "materials.title",
                isPresented: Binding(get: { sessionToEditMaterials != nil },
                                     set: { if !$0 { sessionToEditMaterials = nil } }),
                presenting: sessionToEditMaterials
            ) { session in
                TextField("materials.placeholder", text: $materialsText)
                Button("common.save") {
                    model.setMaterials(AppModel.parseMaterialLinks(materialsText), for: session)
                }
                Button("common.cancel", role: .cancel) {}
            } message: { _ in
                Text("materials.message")
            }
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
                    Text(session.metadata.startedAt, style: .time)
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

/// The live level meter in the library toolbar.
///
/// This exists purely to contain an observation. `AppModel.recordingLevels` is
/// rewritten every 55 ms (~18 Hz) while recording; reading it directly in
/// `LibraryView.body` made the *whole library* a dependent of it, and since
/// `LibraryView` builds `SessionDetailView` with closure properties - which
/// defeat SwiftUI's value comparison - the detail pane and its transcript list
/// rebuilt at 18 Hz too. Reading the array here instead keeps the invalidation
/// on this leaf, where redrawing 180x22 points is free.
private struct RecordingToolbarIndicator: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        RecordingIndicator(levels: model.recordingLevels,
                           startedAt: model.recordingStartedAt,
                           compact: true)
            .frame(width: 180, height: 22)
    }
}

/// Shown after a recording whose input clipped. Dismissible, because it is
/// advice for next time rather than a fault to fix now - the audio is already
/// captured and the clipping cannot be undone.
struct InputClippedBanner: View {
    let message: String
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "waveform.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text(message).font(.callout)
            Spacer()
            Button("action.dismiss", action: dismiss)
                .buttonStyle(.borderless)
        }
        .accessibilityElement(children: .combine)
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
