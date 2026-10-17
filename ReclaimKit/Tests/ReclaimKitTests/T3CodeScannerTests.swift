import Foundation
import SQLite3
import Testing
@testable import ReclaimKit

/// Creates a SQLite database from raw SQL for thread-index fixtures.
func makeDatabase(at url: URL, sql: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else {
        throw NSError(domain: "SQLiteFixture", code: 1)
    }
    defer { sqlite3_close(db) }
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
        let message = error.map { String(cString: $0) } ?? "unknown"
        sqlite3_free(error)
        throw NSError(domain: "SQLiteFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private let v2Schema = """
    CREATE TABLE orchestration_v2_projection_threads (
      thread_id TEXT PRIMARY KEY, project_id TEXT, title TEXT NOT NULL,
      created_at TEXT, updated_at TEXT NOT NULL, archived_at TEXT, deleted_at TEXT,
      payload_json TEXT NOT NULL);
    CREATE TABLE orchestration_v2_projection_messages (
      message_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, role TEXT NOT NULL,
      created_at TEXT NOT NULL);
    """

/// One v2 thread row; `visited`/`messaged` drive the "last used" signal.
private func v2Thread(
    id: String, title: String, path: String,
    visited: Date? = nil, messaged: Date? = nil, updated: Date = .now,
    archived: Bool = false, deleted: Bool = false
) -> String {
    var payload = "{\"worktreePath\":\"\(path)\""
    if let visited { payload += ",\"lastVisitedAt\":\"\(iso(visited))\"" }
    payload += "}"
    func value(_ flag: Bool) -> String { flag ? "'\(iso(updated))'" : "NULL" }
    var sql = """
        INSERT INTO orchestration_v2_projection_threads
        VALUES ('\(id)', 'p', '\(title)', '\(iso(updated))', '\(iso(updated))',
                \(value(archived)), \(value(deleted)), '\(payload)');
        """
    if let messaged {
        sql += "INSERT INTO orchestration_v2_projection_messages VALUES ('m-\(id)', '\(id)', 'user', '\(iso(messaged))');"
    }
    return sql
}

@Suite struct T3ThreadIndexTests {
    private func tempDir() throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory()).appendingPathComponent("t3-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func groupsThreadsPerPathWithLastUse() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("statev2.sqlite")
        let old = Date(timeIntervalSinceNow: -40 * 86_400)
        let recent = Date(timeIntervalSinceNow: -3600)
        try makeDatabase(at: db, sql: v2Schema
            + v2Thread(id: "a", title: "Old idea", path: "/tmp/wt-one", visited: old)
            // The user message is newer than the visit; it wins.
            + v2Thread(id: "b", title: "Fix login", path: "/tmp/wt-one", visited: old, messaged: recent)
            + v2Thread(id: "c", title: "Gone", path: "/tmp/wt-two", deleted: true))

        let index = T3ThreadIndex.load(databasePaths: [db.path])
        let one = try #require(index[canonicalPath("/tmp/wt-one")])
        #expect(one.openThreads.map(\.title) == ["Fix login", "Old idea"])
        #expect(abs((one.lastUsed ?? .distantPast).timeIntervalSince(recent)) < 1)
        let two = try #require(index[canonicalPath("/tmp/wt-two")])
        #expect(!two.hasOpenThreads)
        #expect(two.totalThreads == 1)
    }

    @Test func v2RowWinsOverStaleLegacyRow() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("statev2.sqlite")
        try makeDatabase(at: db, sql: v2Schema
            + v2Thread(id: "a", title: "Archived now", path: "/tmp/wt", archived: true)
            + """
            CREATE TABLE projection_threads (thread_id TEXT PRIMARY KEY, title TEXT, worktree_path TEXT,
              updated_at TEXT, deleted_at TEXT, archived_at TEXT, latest_user_message_at TEXT);
            INSERT INTO projection_threads VALUES ('a', 'Archived now', '/tmp/wt', '2026-01-01T00:00:00Z', NULL, NULL, NULL);
            """)
        let binding = try #require(T3ThreadIndex.load(databasePaths: [db.path])[canonicalPath("/tmp/wt")])
        #expect(!binding.hasOpenThreads)
        #expect(binding.totalThreads == 1)
    }

    @Test func readsLegacySchemaWithoutArchiveColumn() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("state.sqlite")
        try makeDatabase(at: db, sql: """
            CREATE TABLE projection_threads (thread_id TEXT PRIMARY KEY, title TEXT, worktree_path TEXT,
              updated_at TEXT, deleted_at TEXT);
            INSERT INTO projection_threads VALUES ('a', 'Legacy', '/tmp/wt', '2026-01-01T00:00:00Z', NULL);
            """)
        let binding = try #require(T3ThreadIndex.load(databasePaths: [db.path])[canonicalPath("/tmp/wt")])
        #expect(binding.openThreads.map(\.title) == ["Legacy"])
    }

    @Test func unknownSchemaOrMissingFileDegradesToEmpty() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("other.sqlite")
        try makeDatabase(at: db, sql: "CREATE TABLE unrelated (id INTEGER);")
        #expect(T3ThreadIndex.load(databasePaths: [db.path, dir.appendingPathComponent("missing").path]).isEmpty)
    }
}

@Suite struct T3CodeScannerTests {
    /// A fixture repo plus a T3 home whose worktrees live at worktrees/<project>/<name>.
    private func makeT3(threads: (String) -> String) async throws -> (GitFixture, URL, URL) {
        let fixture = try await GitFixture.make()
        let t3 = fixture.root.appendingPathComponent("t3home")
        let worktree = t3.appendingPathComponent("worktrees/my-app/t3-0001")
        try FileManager.default.createDirectory(at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await fixture.git("worktree", "add", "-b", "feature", worktree.path, cwd: fixture.repo.path)
        try await fixture.git("push", "-u", "origin", "feature", cwd: worktree.path)
        let userdata = t3.appendingPathComponent("userdata")
        try FileManager.default.createDirectory(at: userdata, withIntermediateDirectories: true)
        try makeDatabase(at: userdata.appendingPathComponent("statev2.sqlite"),
                         sql: v2Schema + threads(canonicalPath(worktree.path)))
        return (fixture, t3, worktree)
    }

    private func scan(_ fixture: GitFixture, t3: URL) async throws -> [ScanItem] {
        let context = ScanContext(home: fixture.root, git: fixture.git, environment: ["T3CODE_HOME": t3.path])
        return try await T3CodeScanner().scan(context: context)
    }

    @Test func recentlyUsedThreadDemotesCleanWorktreeToReview() async throws {
        let (fixture, t3, worktree) = try await makeT3 { path in
            v2Thread(id: "a", title: "Fix login", path: path, visited: .now)
        }
        defer { fixture.tearDown() }
        let item = try #require(try await scan(fixture, t3: t3).first { $0.path == canonicalPath(worktree.path) })
        #expect(item.tool == .t3Code)
        #expect(item.displayName == "my-app/t3-0001")
        #expect(item.safety == .review)
        #expect(item.sessionTitle == "Fix login")
        #expect(item.reasons.contains { $0.contains("removing it breaks that thread") })
    }

    @Test func idleOpenThreadLeavesCleanWorktreeSafe() async throws {
        let old = Date(timeIntervalSinceNow: -30 * 86_400)
        let (fixture, t3, worktree) = try await makeT3 { path in
            v2Thread(id: "a", title: "Old work", path: path, visited: old, messaged: old)
        }
        defer { fixture.tearDown() }
        let item = try #require(try await scan(fixture, t3: t3).first { $0.path == canonicalPath(worktree.path) })
        #expect(item.safety == .safe)
        #expect(item.reasons.contains { $0.contains("last used 30 days ago") })
    }

    @Test func deletedThreadIsReportedAndStaysSafe() async throws {
        let (fixture, t3, worktree) = try await makeT3 { path in
            v2Thread(id: "a", title: "Done", path: path, visited: .now, deleted: true)
        }
        defer { fixture.tearDown() }
        let item = try #require(try await scan(fixture, t3: t3).first { $0.path == canonicalPath(worktree.path) })
        #expect(item.safety == .safe)
        #expect(item.reasons.contains { $0.contains("archived or deleted") })
    }

    @Test func findsFlatWorktreesAndNonEmptyScratchFolders() async throws {
        let (fixture, t3, _) = try await makeT3 { _ in "" }
        defer { fixture.tearDown() }
        let flat = t3.appendingPathComponent("worktrees/docs-site")
        try await fixture.git("worktree", "add", "-b", "docs", flat.path, cwd: fixture.repo.path)
        let scratch = t3.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data().write(to: scratch.appendingPathComponent("empty/.DS_Store"))
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: scratch.appendingPathComponent("notes/out.png"))

        let items = try await scan(fixture, t3: t3)
        #expect(items.contains { $0.displayName == "docs-site" && $0.category == .worktree })
        let scratchItems = items.filter { $0.category == .toolSessions }
        #expect(scratchItems.map(\.displayName) == ["Scratch: notes"])
        #expect(scratchItems.first?.safety == .review)
    }

    @Test func legacyDatabaseOnlyWhenSupersededAndIdle() throws {
        let root = URL(filePath: NSTemporaryDirectory()).appendingPathComponent("t3-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let userdata = root.appendingPathComponent("userdata")
        try FileManager.default.createDirectory(at: userdata, withIntermediateDirectories: true)
        let legacy = userdata.appendingPathComponent("state.sqlite")
        let current = userdata.appendingPathComponent("statev2.sqlite")
        try Data().write(to: legacy)
        try Data().write(to: current)
        func age(_ url: URL, days: Double) throws {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -days * 86_400)], ofItemAtPath: url.path)
        }

        try age(legacy, days: 2)
        #expect(T3CodeScanner.legacyDatabase(root: root) == nil)  // still written recently
        try age(legacy, days: 20)
        #expect(T3CodeScanner.legacyDatabase(root: root)?.lastPathComponent == "state.sqlite")
        try FileManager.default.removeItem(at: current)
        #expect(T3CodeScanner.legacyDatabase(root: root) == nil)  // state.sqlite is the live db
    }
}
