import Foundation

/// Resolves which pipeline processes a session (ADR-13).
///
/// Precedence: session override > first assigned project with a pipeline >
/// global default > built-in default. Returns `nil` for the built-in default
/// (transcribe + summarize, no actions).
public enum PipelineResolver {
    public static func resolve(
        session: SessionMetadata,
        projects: [Project],
        config: PipelinesConfig
    ) -> PipelineDefinition? {
        func find(_ id: String) -> PipelineDefinition? {
            config.pipelines.first { $0.id == id }
        }
        // A non-nil session override always wins, even when it names the
        // built-in default (empty) or a since-deleted pipeline (both resolve
        // to nil = built-in, never silently fall through to the project).
        if let override = session.pipelineID {
            return find(override)
        }
        for projectID in session.projects {
            if let pipelineID = projects.first(where: { $0.id == projectID })?.pipelineID,
               let pipeline = find(pipelineID) {
                return pipeline
            }
        }
        return find(config.defaultPipelineID)
    }
}
