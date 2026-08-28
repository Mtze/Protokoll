import Foundation

/// A project or tag that sessions can belong to (F7). Stored in
/// `projects/projects.json`; sessions reference these by `id`.
public struct Project: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// A hex color string (e.g. `#3B82F6`) for the UI swatch.
    public var color: String
    /// Default processing pipeline for this project's sessions (ADR-13).
    /// `nil`/unknown = the global default applies.
    public var pipelineID: String?

    public init(id: String = UUID().uuidString, name: String, color: String, pipelineID: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.pipelineID = pipelineID
    }
}
