import Foundation
import SQLite3

public struct CodexThread: Sendable {
    public var cwd: String
    public var archived: Bool
    public var updatedAt: Date?
}

/// Reads the Codex app's thread index (read-only) to map worktrees to sessions.
/// Schema knowledge is best-effort; any failure degrades to "no session info".
public enum CodexThreadIndex {
    public static func load(databasePath: String) -> [String: CodexThread] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT cwd, archived, updated_at FROM threads", -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [:] }
        defer { sqlite3_finalize(statement) }

        var threads: [String: CodexThread] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cwdC = sqlite3_column_text(statement, 0) else { continue }
            let cwd = String(cString: cwdC)
            let archived = sqlite3_column_int(statement, 1) != 0
            let updatedAt = parseTimestamp(statement, column: 2)
            // Keep the most recently updated thread per directory.
            if let existing = threads[cwd], (existing.updatedAt ?? .distantPast) >= (updatedAt ?? .distantPast) {
                continue
            }
            threads[cwd] = CodexThread(cwd: cwd, archived: archived, updatedAt: updatedAt)
        }
        return threads
    }

    private static func parseTimestamp(_ statement: OpaquePointer, column: Int32) -> Date? {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
            let value = sqlite3_column_int64(statement, column)
            // Heuristic: values past year ~33658 in seconds are milliseconds.
            let seconds = value > 1_000_000_000_000 ? TimeInterval(value) / 1000 : TimeInterval(value)
            return Date(timeIntervalSince1970: seconds)
        case SQLITE_FLOAT:
            return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, column) else { return nil }
            let string = String(cString: text)
            return Self.plainFormatter.date(from: string)
                ?? Self.fractionalFormatter.date(from: string)
        default:
            return nil
        }
    }

    // ISO8601DateFormatter is documented thread-safe; creating one per row is not free.
    private nonisolated(unsafe) static let plainFormatter = ISO8601DateFormatter()
    private nonisolated(unsafe) static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
