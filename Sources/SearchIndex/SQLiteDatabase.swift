import Foundation
import SQLite3

/// A thin wrapper over the system `libsqlite3` (dependency-free - see ADR-5).
/// Not thread-safe by itself; ``SearchIndex`` serializes access via an actor.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    // SQLite wants to copy bound text/blobs (TRANSIENT), not borrow them.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    struct SQLiteError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(path: String) throws {
        if sqlite3_open(path, &handle) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            throw SQLiteError(message: "open failed: \(message)")
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit { sqlite3_close(handle) }

    /// Runs one or more statements with no bindings (schema/DDL, pragmas).
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw SQLiteError(message: message)
        }
    }

    /// Runs a parameterized write statement.
    func run(_ sql: String, _ parameters: [String?] = []) throws {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        if sqlite3_step(statement) != SQLITE_DONE {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    /// Runs a query, returning each row as an array of column strings.
    func query(_ sql: String, _ parameters: [String?] = []) throws -> [[String?]] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        var rows: [[String?]] = []
        let columnCount = sqlite3_column_count(statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String?] = []
            for index in 0..<columnCount {
                if let text = sqlite3_column_text(statement, index) {
                    row.append(String(cString: text))
                } else {
                    row.append(nil)
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func prepare(_ sql: String, _ parameters: [String?]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(handle, sql, -1, &statement, nil) != SQLITE_OK {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(handle)))
        }
        for (offset, value) in parameters.enumerated() {
            let position = Int32(offset + 1)
            if let value {
                sqlite3_bind_text(statement, position, value, -1, Self.transient)
            } else {
                sqlite3_bind_null(statement, position)
            }
        }
        return statement
    }
}
