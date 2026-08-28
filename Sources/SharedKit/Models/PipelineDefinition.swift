import Foundation

/// A declared parameter of an ``ActionStep``. The pipeline resolves the value
/// as: session override (`stepInputs`) > ``defaultValue``. Values and step
/// prompts may use template placeholders (`{materials}`, `{title}`, `{date}`,
/// `{projects}`) that the pipeline substitutes from session metadata.
public struct ActionInput: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var key: String
    public var label: String
    public var defaultValue: String
    public var required: Bool

    public init(id: String = UUID().uuidString, key: String = "", label: String = "",
                defaultValue: String = "", required: Bool = false) {
        self.id = id
        self.key = key
        self.label = label
        self.defaultValue = defaultValue
        self.required = required
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = ActionInput()
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? nil ?? d.id
        key = (try? container.decodeIfPresent(String.self, forKey: .key)) ?? nil ?? d.key
        label = (try? container.decodeIfPresent(String.self, forKey: .label)) ?? nil ?? d.label
        defaultValue = (try? container.decodeIfPresent(String.self, forKey: .defaultValue)) ?? nil ?? d.defaultValue
        required = (try? container.decodeIfPresent(Bool.self, forKey: .required)) ?? nil ?? d.required
    }
}

/// One custom post-summary action (ADR-13): a configurable prompt executed via
/// the `claude` CLI with the connection's MCP server attached. Transcribe and
/// summarize stay fixed built-in stages; actions run after them, in order.
public struct ActionStep: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// The user's instruction text, appended to a fixed safety/idempotency
    /// scaffold - it never replaces the built-in framing.
    public var prompt: String
    /// The ``PlatformConnection`` this step talks to.
    public var connectionID: String
    /// ``accessRead`` (list/search/get tools only) or ``accessReadWrite``
    /// (the whole MCP server). A plain string for forward tolerance.
    public var access: String
    /// Whether the raw transcript is piped in alongside protocol + materials.
    public var includeTranscript: Bool
    public var enabled: Bool
    public var inputs: [ActionInput]
    /// CLI escape hatch: commands (e.g. `td`) the step may run via
    /// `Bash(<cmd>:*)`. Honored only for commands also approved on the local
    /// machine's allowlist - this list alone grants nothing (the container
    /// syncs, the approval must not).
    public var allowedCommands: [String]

    public static let accessRead = "read"
    public static let accessReadWrite = "readWrite"

    public init(
        id: String = UUID().uuidString,
        name: String = "",
        prompt: String = "",
        connectionID: String = "",
        access: String = ActionStep.accessRead,
        includeTranscript: Bool = false,
        enabled: Bool = true,
        inputs: [ActionInput] = [],
        allowedCommands: [String] = []
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.connectionID = connectionID
        self.access = access
        self.includeTranscript = includeTranscript
        self.enabled = enabled
        self.inputs = inputs
        self.allowedCommands = allowedCommands
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = ActionStep()
        func value(_ key: CodingKeys, _ fallback: String) -> String {
            (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil ?? fallback
        }
        id = value(.id, d.id)
        name = value(.name, d.name)
        prompt = value(.prompt, d.prompt)
        connectionID = value(.connectionID, d.connectionID)
        access = value(.access, d.access)
        includeTranscript = (try? container.decodeIfPresent(Bool.self, forKey: .includeTranscript)) ?? nil ?? d.includeTranscript
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil ?? d.enabled
        inputs = (try? container.decodeIfPresent([ActionInput].self, forKey: .inputs)) ?? nil ?? d.inputs
        allowedCommands = (try? container.decodeIfPresent([String].self, forKey: .allowedCommands)) ?? nil ?? d.allowedCommands
    }
}

/// A user-defined processing pipeline (ADR-13): the implicit fixed prefix
/// transcribe + summarize, followed by this ordered list of custom actions.
public struct PipelineDefinition: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var steps: [ActionStep]

    public init(id: String = UUID().uuidString, name: String = "", steps: [ActionStep] = []) {
        self.id = id
        self.name = name
        self.steps = steps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = PipelineDefinition()
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? nil ?? d.id
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil ?? d.name
        steps = (try? container.decodeIfPresent([ActionStep].self, forKey: .steps)) ?? nil ?? d.steps
    }
}

/// All user-defined pipelines plus the global default choice, stored at
/// `config/pipelines.json`. An empty ``defaultPipelineID`` means the built-in
/// default (transcribe + summarize, no actions) - zero config keeps exactly
/// the pre-ADR-13 behavior.
public struct PipelinesConfig: Codable, Sendable, Equatable {
    public var pipelines: [PipelineDefinition]
    public var defaultPipelineID: String

    public init(pipelines: [PipelineDefinition] = [], defaultPipelineID: String = "") {
        self.pipelines = pipelines
        self.defaultPipelineID = defaultPipelineID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = PipelinesConfig()
        pipelines = (try? container.decodeIfPresent([PipelineDefinition].self, forKey: .pipelines)) ?? nil ?? d.pipelines
        defaultPipelineID = (try? container.decodeIfPresent(String.self, forKey: .defaultPipelineID)) ?? nil ?? d.defaultPipelineID
    }
}
