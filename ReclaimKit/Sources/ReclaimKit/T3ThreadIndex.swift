import Foundation
import SQLite3

public struct T3ThreadSummary: Sendable, Equatable {
    public var title: String
    /// When the user last visited or messaged the thread. nil = unknown.
    public var lastUsed: Date?
}

/// Every T3 Code thread bound to one directory (worktree or scratch folder).
public struct T3Binding: Sendable, Equatable {
    /// Threads that are neither archived nor deleted, most recently used first.
    public var openThreads: [T3ThreadSummary]
    /// All threads that ever used the directory, including archived/deleted ones.
    public var totalThreads: Int
    /// Title of the most recently used thread, open or not.
    public var latestTitle: String?
    public var lastUsed: Date?

    public var hasOpenThreads: Bool { !openThreads.isEmpty }
}

/// Reads T3 Code's thread projections (read-only) to map directories to threads.
/// Two schemas exist: the current orchestration_v2 table keeps the worktree in
/// payload_json, the legacy projection_threads table has a worktree_path column
/// (and older builds lack archived_at). Rows are merged per thread id with the
/// v2 row winning, since statev2 still carries the stale imported v1 table.
/// Any failure degrades to "no thread info", never to an error.
public enum T3ThreadIndex {
    struct Row {
        var threadID: String
        var path: String
        var title: String
        var lastUsed: Date?
        var isOpen: Bool
    }

    /// Keys are canonical paths.
    public static func load(databasePaths: [String]) -> [String: T3Binding] {
        var rowsByThread: [String: Row] = [:]
        for path in databasePaths {
            for row in rows(databasePath: path) where rowsByThread[row.threadID] == nil {
                rowsByThread[row.threadID] = row
            }
        }
        var grouped: [String: [Row]] = [:]
        for row in rowsByThread.values {
            grouped[canonicalPath(row.path), default: []].append(row)
        }
        return grouped.mapValues { rows in
            let sorted = rows.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
            return T3Binding(
                openThreads: sorted.filter(\.isOpen).map { T3ThreadSummary(title: $0.title, lastUsed: $0.lastUsed) },
                totalThreads: sorted.count,
                latestTitle: sorted.first?.title,
                lastUsed: sorted.first?.lastUsed
            )
        }
    }

    /// Queries tried in order; per schema the first that prepares wins.
    /// "Last used" is the newer of the last visit and the last user message:
    /// updated_at also moves on background bookkeeping, so it is the fallback.
    static let queries: [[String]] = [
        [
            """
            SELECT t.thread_id, json_extract(t.payload_json, '$.worktreePath'), t.title,
                   coalesce(NULLIF(max(coalesce(json_extract(t.payload_json, '$.lastVisitedAt'), ''),
                                       coalesce(m.last_user, '')), ''), t.updated_at),
                   t.archived_at IS NULL AND t.deleted_at IS NULL
            FROM orchestration_v2_projection_threads t
            LEFT JOIN (SELECT thread_id, max(created_at) AS last_user
                       FROM orchestration_v2_projection_messages WHERE role = 'user'
                       GROUP BY thread_id) m ON m.thread_id = t.thread_id
            WHERE json_extract(t.payload_json, '$.worktreePath') IS NOT NULL
            """,
            """
            SELECT thread_id, json_extract(payload_json, '$.worktreePath'), title,
                   coalesce(json_extract(payload_json, '$.lastVisitedAt'), updated_at),
                   archived_at IS NULL AND deleted_at IS NULL
            FROM orchestration_v2_projection_threads
            WHERE json_extract(payload_json, '$.worktreePath') IS NOT NULL
            """,
        ],
        [
            """
            SELECT thread_id, worktree_path, title, coalesce(latest_user_message_at, updated_at),
                   archived_at IS NULL AND deleted_at IS NULL
            FROM projection_threads WHERE worktree_path IS NOT NULL
            """,
            // Builds before archiving existed.
            """
            SELECT thread_id, worktree_path, title, updated_at, deleted_at IS NULL
            FROM projection_threads WHERE worktree_path IS NOT NULL
            """,
        ],
    ]

    static func rows(databasePath: String) -> [Row] {
        guard FileManager.default.fileExists(atPath: databasePath) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        var rows: [Row] = []
        for schema in queries {
            for sql in schema {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                    sqlite3_finalize(statement)
                    continue
                }
                defer { sqlite3_finalize(statement) }
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let id = text(statement, 0), let path = text(statement, 1), !path.isEmpty else { continue }
                    rows.append(Row(
                        threadID: id,
                        path: path,
                        title: text(statement, 2) ?? "Untitled thread",
                        lastUsed: text(statement, 3).flatMap(ISO8601.date(from:)),
                        isOpen: sqlite3_column_int(statement, 4) != 0
                    ))
                }
                break
            }
        }
        return rows
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
