import Foundation

/// A configured external platform (ADR-13): a note/agenda service like Outline
/// or a task service like Todoist, reachable through an MCP server at run time.
/// Stored in `config/connections.json`. **Never holds a secret or anything
/// executable**: the container syncs via iCloud, so credentials live in the
/// macOS Keychain and custom MCP launch specs in local defaults; both reach the
/// pipeline through a local 0600 key manifest instead.
public struct PlatformConnection: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// Platform kind: ``kindOutline``, ``kindTodoist``, or ``kindCustom``.
    /// A plain string so newer kinds never break older decoders.
    public var kind: String
    /// Base URL of the platform instance (must be `https://`). Used to match a
    /// pasted material link to its connection and to configure the MCP server.
    public var baseURL: String

    public static let kindOutline = "outline"
    public static let kindTodoist = "todoist"
    public static let kindCustom = "custom"

    public init(
        id: String = UUID().uuidString,
        name: String = "",
        kind: String = PlatformConnection.kindOutline,
        baseURL: String = ""
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = PlatformConnection()
        func value(_ key: CodingKeys, _ fallback: String) -> String {
            (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil ?? fallback
        }
        id = value(.id, d.id)
        name = value(.name, d.name)
        kind = value(.kind, d.kind)
        baseURL = value(.baseURL, d.baseURL)
    }
}
