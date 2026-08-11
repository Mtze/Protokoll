import Foundation
import SharedKit

/// A full-text hit against a session's transcript or protocol.
public struct SearchHit: Sendable, Equatable, Identifiable {
    public var sessionID: String
    public var title: String
    public var kind: DocumentKind
    /// A highlighted snippet around the match.
    public var snippet: String

    public var id: String { "\(sessionID)-\(kind.rawValue)" }
}

/// Which document a search hit came from.
public enum DocumentKind: String, Sendable, CaseIterable {
    case transcript
    case protocolDoc = "protocol"
}

/// Optional filters applied alongside the full-text query (F7/F6).
public struct SearchFilter: Sendable, Equatable {
    public var projectID: String?
    public var status: String?
    public var since: Date?
    public var until: Date?

    public init(projectID: String? = nil, status: String? = nil, since: Date? = nil, until: Date? = nil) {
        self.projectID = projectID
        self.status = status
        self.since = since
        self.until = until
    }

    public static let none = SearchFilter()
    var isEmpty: Bool { projectID == nil && status == nil && since == nil && until == nil }
}

/// The local, rebuildable FTS5 search index (ADR-2). Lives in Application
/// Support **outside** the container, is never synced, and can be regenerated
/// from the files at any time - so index corruption is a non-event.
///
/// An `actor` (plan: indexer is an actor) serializing all SQLite access.
public actor SearchIndex {
    private let db: SQLiteDatabase
    public let path: URL

    /// Opens (creating if needed) the index at `path` and ensures the schema.
    public init(path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        self.path = path
        self.db = try SQLiteDatabase(path: path.path)
        try Self.createSchema(db)
    }

    /// Default index location: `~/Library/Application Support/Protokoll/index.sqlite`.
    public static func defaultURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Protokoll/index.sqlite")
    }

    private static func createSchema(_ db: SQLiteDatabase) throws {
        try db.execute("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            title TEXT,
            startedAt REAL,
            status TEXT,
            projects TEXT,
            folderPath TEXT
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS documents USING fts5(
            sessionID UNINDEXED,
            kind UNINDEXED,
            content,
            tokenize = 'unicode61'
        );
        """)
    }

    // MARK: Indexing

    /// Rebuilds the entire index from the container's files (ADR-2 rebuildability).
    public func rebuild(from container: Container) throws {
        try db.execute("DELETE FROM sessions; DELETE FROM documents;")
        let sessions = (try? container.allSessions()) ?? []
        for session in sessions { try upsert(session) }
        AppLog.search.info("index rebuilt sessions=\(sessions.count, privacy: .public)")
    }

    /// Inserts or updates a single session (metadata + its documents).
    public func upsert(_ session: Session) throws {
        let projects = session.metadata.projects.joined(separator: ",")
        try db.run(
            "INSERT OR REPLACE INTO sessions (id, title, startedAt, status, projects, folderPath) VALUES (?,?,?,?,?,?)",
            [session.id, session.displayTitle, String(session.metadata.startedAt.timeIntervalSince1970),
             session.metadata.pipeline.status.name, projects, session.folder.path]
        )
        try db.run("DELETE FROM documents WHERE sessionID = ?", [session.id])
        for (kind, url) in [(DocumentKind.transcript, session.transcriptURL), (.protocolDoc, session.protocolURL)] {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let body = Frontmatter.split(raw).body
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            try db.run(
                "INSERT INTO documents (sessionID, kind, content) VALUES (?,?,?)",
                [session.id, kind.rawValue, body]
            )
        }
    }

    /// Removes a session from the index.
    public func remove(id: String) throws {
        try db.run("DELETE FROM sessions WHERE id = ?", [id])
        try db.run("DELETE FROM documents WHERE sessionID = ?", [id])
    }

    // MARK: Search

    /// Full-text search over transcript + protocol (F10), newest first, with
    /// optional project/status/date filters.
    public func search(_ text: String, filter: SearchFilter = .none, limit: Int = 50) throws -> [SearchHit] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var sql = """
        SELECT d.sessionID, s.title, d.kind, snippet(documents, 2, '[', ']', '…', 12)
        FROM documents d JOIN sessions s ON s.id = d.sessionID
        WHERE documents MATCH ?
        """
        var params: [String?] = [ftsQuery(trimmed)]
        if let projectID = filter.projectID {
            sql += " AND (',' || s.projects || ',') LIKE ?"
            params.append("%,\(projectID),%")
        }
        if let status = filter.status {
            sql += " AND s.status = ?"
            params.append(status)
        }
        if let since = filter.since {
            sql += " AND s.startedAt >= ?"
            params.append(String(since.timeIntervalSince1970))
        }
        if let until = filter.until {
            sql += " AND s.startedAt <= ?"
            params.append(String(until.timeIntervalSince1970))
        }
        sql += " ORDER BY s.startedAt DESC LIMIT \(limit)"

        let rows = try db.query(sql, params)
        // Log hit count and filter presence, never the query text itself.
        AppLog.search.debug("search hits=\(rows.count, privacy: .public) filtered=\(!filter.isEmpty, privacy: .public)")
        return rows.compactMap { row in
            guard let sessionID = row[0], let kindRaw = row[2],
                  let kind = DocumentKind(rawValue: kindRaw) else { return nil }
            return SearchHit(sessionID: sessionID, title: row[1] ?? sessionID, kind: kind, snippet: row[3] ?? "")
        }
    }

    /// Escapes a user query into an FTS5 phrase (prefix match on the last term),
    /// so arbitrary punctuation can't break the MATCH grammar.
    private func ftsQuery(_ text: String) -> String {
        let terms = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard !terms.isEmpty else { return "\"\(text)\"" }
        return terms.map { "\"\($0)\"" }.joined(separator: " ") + "*"
    }

    /// Number of indexed sessions (for tests/diagnostics).
    public func sessionCount() throws -> Int {
        Int(try db.query("SELECT COUNT(*) FROM sessions").first?.first??.description ?? "0") ?? 0
    }
}
