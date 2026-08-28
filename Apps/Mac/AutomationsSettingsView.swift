import SwiftUI
import SharedKit

/// Container-backed store for platform connections (ADR-13), mirroring
/// ``PipelineSettingsStore``.
@MainActor
@Observable
final class ConnectionsStore {
    var connections: [PlatformConnection]
    private let container: Container

    init(container: Container) {
        self.container = container
        self.connections = (try? container.loadConnections()) ?? []
    }

    func save() { try? container.saveConnections(connections) }
    func add() { connections.append(PlatformConnection()) }

    /// Removes the connection plus its machine-local secret and launch spec.
    func delete(_ connection: PlatformConnection) {
        connections.removeAll { $0.id == connection.id }
        ConnectionKeychain.deleteKey(for: connection.id)
        CustomMCPSpec.delete(for: connection.id)
    }
}

/// Container-backed store for user-defined pipelines (ADR-13).
@MainActor
@Observable
final class PipelinesStore {
    var config: PipelinesConfig
    private let container: Container

    init(container: Container) {
        self.container = container
        self.config = (try? container.loadPipelines()) ?? PipelinesConfig()
    }

    func save() { try? container.savePipelines(config) }
    func add() { config.pipelines.append(PipelineDefinition()) }

    func delete(_ pipeline: PipelineDefinition) {
        config.pipelines.removeAll { $0.id == pipeline.id }
        if config.defaultPipelineID == pipeline.id { config.defaultPipelineID = "" }
    }
}

/// The Automations settings tab: platform connections, custom pipelines, and
/// the machine-local CLI command allowlist (ADR-13). Zero configuration here
/// keeps the app exactly at its built-in transcribe + summarize behavior.
struct AutomationsTab: View {
    @Bindable var connectionsStore: ConnectionsStore
    @Bindable var pipelinesStore: PipelinesStore
    /// Deleting a pipeline also clears projects that referenced it.
    @Bindable var projectsStore: ProjectsStore
    @AppStorage(SettingsKeys.stepCommandAllowlist) private var commandAllowlist = ""
    @State private var editedPipelineID: String?

    var body: some View {
        Form {
            Section("settings.connections") {
                Text("settings.connections.help").font(.caption).foregroundStyle(.secondary)
                ForEach($connectionsStore.connections) { $connection in
                    ConnectionRow(connection: $connection) {
                        connectionsStore.delete(connection)
                    }
                }
                Button { connectionsStore.add() } label: { Label("connection.new", systemImage: "plus") }
            }
            Section("settings.pipelines") {
                Text("settings.pipelines.help").font(.caption).foregroundStyle(.secondary)
                DefaultChoiceRow(isDefault: pipelinesStore.config.defaultPipelineID.isEmpty) {
                    pipelinesStore.config.defaultPipelineID = ""
                } label: {
                    Text("pipeline.default.name")
                }
                ForEach($pipelinesStore.config.pipelines) { $pipeline in
                    HStack {
                        DefaultChoiceRow(isDefault: pipelinesStore.config.defaultPipelineID == pipeline.id) {
                            pipelinesStore.config.defaultPipelineID = pipeline.id
                        } label: {
                            TextField("pipeline.name", text: $pipeline.name, prompt: Text("pipeline.name"))
                        }
                        Button { editedPipelineID = pipeline.id } label: {
                            Image(systemName: "list.bullet.rectangle")
                        }
                        .buttonStyle(.borderless)
                        .help("pipeline.edit")
                        Button(role: .destructive) {
                            pipelinesStore.delete(pipeline)
                            projectsStore.clearPipeline(pipeline.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("pipeline.delete")
                    }
                }
                Button { pipelinesStore.add() } label: { Label("pipeline.new", systemImage: "plus") }
            }
            Section("settings.automations.allowlist") {
                TextField("settings.automations.allowlist", text: $commandAllowlist,
                          prompt: Text(verbatim: "td"))
                Text("settings.automations.allowlist.help").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: sheetPipeline) { _ in
            if let index = pipelinesStore.config.pipelines.firstIndex(where: { $0.id == editedPipelineID }) {
                PipelineStepsEditor(pipeline: $pipelinesStore.config.pipelines[index],
                                    connections: connectionsStore.connections)
            }
        }
    }

    /// `sheet(item:)` binding bridging the selected pipeline id.
    private var sheetPipeline: Binding<PipelineDefinition?> {
        Binding(
            get: { pipelinesStore.config.pipelines.first { $0.id == editedPipelineID } },
            set: { if $0 == nil { editedPipelineID = nil } }
        )
    }
}

/// A radio-style row marking the default pipeline.
private struct DefaultChoiceRow<Label: View>: View {
    let isDefault: Bool
    let choose: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        HStack {
            Button(action: choose) {
                Image(systemName: isDefault ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isDefault ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help("pipeline.makeDefault")
            .accessibilityLabel(Text("pipeline.makeDefault"))
            .accessibilityAddTraits(isDefault ? .isSelected : [])
            label()
        }
    }
}

/// One connection: name, kind, base URL, secret (Keychain-backed like the
/// summary API key), and the machine-local launch spec for custom kinds.
private struct ConnectionRow: View {
    @Binding var connection: PlatformConnection
    let onDelete: () -> Void
    @State private var apiKey = ""
    @State private var spec = CustomMCPSpec.Spec()

    private var baseURLInvalid: Bool {
        let value = connection.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && !value.lowercased().hasPrefix("https://")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("connection.name", text: $connection.name, prompt: Text("connection.name"))
                Picker("connection.kind", selection: $connection.kind) {
                    Text("connection.kind.outline").tag(PlatformConnection.kindOutline)
                    Text("connection.kind.todoist").tag(PlatformConnection.kindTodoist)
                    Text("connection.kind.custom").tag(PlatformConnection.kindCustom)
                }
                .labelsHidden()
                .fixedSize()
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("connection.delete")
            }
            TextField("connection.baseurl", text: $connection.baseURL,
                      prompt: Text(verbatim: "https://…"))
            if baseURLInvalid {
                Label("connection.baseurl.invalid", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            SecureField("connection.apikey", text: $apiKey)
            if connection.kind == PlatformConnection.kindCustom {
                TextField("connection.custom.command", text: $spec.command,
                          prompt: Text(verbatim: "npx"))
                TextField("connection.custom.arguments", text: argumentsBinding,
                          prompt: Text(verbatim: "-y some-mcp-server@1.0.0"))
                TextField("connection.custom.keyenv", text: $spec.keyEnvVar,
                          prompt: Text(verbatim: "MY_API_KEY"))
                Text("connection.custom.help").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            apiKey = ConnectionKeychain.key(for: connection.id) ?? ""
            spec = CustomMCPSpec.load(for: connection.id)
        }
        .onChange(of: apiKey) { ConnectionKeychain.setKey(apiKey, for: connection.id) }
        .onChange(of: spec) { CustomMCPSpec.save(spec, for: connection.id) }
    }

    /// The launch arguments as one space-separated line.
    private var argumentsBinding: Binding<String> {
        Binding(
            get: { spec.arguments.joined(separator: " ") },
            set: { spec.arguments = $0.split(separator: " ").map(String.init) }
        )
    }
}

/// Sheet editing one pipeline's ordered action steps (ADR-13).
private struct PipelineStepsEditor: View {
    @Binding var pipeline: PipelineDefinition
    let connections: [PlatformConnection]
    @Environment(\.dismiss) private var dismiss
    @State private var editedStepID: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($pipeline.steps) { $step in
                        HStack {
                            Toggle("step.enabled", isOn: $step.enabled).labelsHidden()
                            Text(step.name.isEmpty ? String(localized: "step.new") : step.name)
                            Spacer()
                            Button { editedStepID = step.id } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless)
                            Button(role: .destructive) {
                                pipeline.steps.removeAll { $0.id == step.id }
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("step.delete")
                        }
                    }
                    .onMove { pipeline.steps.move(fromOffsets: $0, toOffset: $1) }
                    Button { pipeline.steps.append(ActionStep()) } label: {
                        Label("step.new", systemImage: "plus")
                    }
                } header: {
                    Text("pipeline.steps")
                } footer: {
                    Text("settings.pipelines.help").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(pipeline.name.isEmpty ? String(localized: "pipeline.name") : pipeline.name)
            .navigationDestination(item: $editedStepID) { stepID in
                if let index = pipeline.steps.firstIndex(where: { $0.id == stepID }) {
                    StepEditor(step: $pipeline.steps[index], connections: connections)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("step.done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }
}

/// Editor for a single action step: prompt, connection, access level, inputs,
/// and the CLI command escape hatch.
private struct StepEditor: View {
    @Binding var step: ActionStep
    let connections: [PlatformConnection]

    /// Custom connections have no known read-only tool list, so they always
    /// run with write access (ADR-13); the picker is locked accordingly.
    private var isCustomConnection: Bool {
        connections.first { $0.id == step.connectionID }?.kind == PlatformConnection.kindCustom
    }

    var body: some View {
        Form {
            Section {
                TextField("step.name", text: $step.name)
                Picker("step.connection", selection: $step.connectionID) {
                    Text(verbatim: "-").tag("")
                    ForEach(connections) { connection in
                        Text(connection.name.isEmpty ? connection.baseURL : connection.name)
                            .tag(connection.id)
                    }
                }
                Picker("step.access", selection: $step.access) {
                    Text("step.access.read").tag(ActionStep.accessRead)
                    Text("step.access.readwrite").tag(ActionStep.accessReadWrite)
                }
                .disabled(isCustomConnection)
                if step.access == ActionStep.accessReadWrite || isCustomConnection {
                    Label("step.access.warning", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("step.includeTranscript", isOn: $step.includeTranscript)
            }
            Section("step.prompt") {
                TextEditor(text: $step.prompt)
                    .font(.body.monospaced()).frame(minHeight: 100)
                Text("step.prompt.help").font(.caption).foregroundStyle(.secondary)
            }
            Section("step.inputs") {
                ForEach($step.inputs) { $input in
                    HStack {
                        TextField("step.input.key", text: $input.key)
                        TextField("step.input.label", text: $input.label)
                        TextField("step.input.default", text: $input.defaultValue)
                        Toggle("step.input.required", isOn: $input.required).labelsHidden()
                            .help("step.input.required")
                        Button(role: .destructive) {
                            step.inputs.removeAll { $0.id == input.id }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                Button { step.inputs.append(ActionInput()) } label: {
                    Label("step.input.new", systemImage: "plus")
                }
            }
            Section("step.commands") {
                TextField("step.commands", text: commandsBinding, prompt: Text(verbatim: "td"))
                Text("step.commands.help").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(step.name.isEmpty ? String(localized: "step.new") : step.name)
        // Normalize on appearance too: the connection may have become custom
        // since this step was configured, and the picker is locked then.
        .onAppear {
            if isCustomConnection { step.access = ActionStep.accessReadWrite }
        }
        .onChange(of: step.connectionID) {
            if isCustomConnection { step.access = ActionStep.accessReadWrite }
        }
    }

    private var commandsBinding: Binding<String> {
        Binding(
            get: { step.allowedCommands.joined(separator: ", ") },
            set: { step.allowedCommands = $0.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init) }
        )
    }
}
