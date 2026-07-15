import Foundation
import Testing
@testable import ReclaimKit

@Suite struct ClaudeProjectEncodingTests {
    @Test func encodeCollapsesNonAlphanumerics() {
        #expect(ClaudeCodeScanner.encode("/Users/x/my-repo") == "-Users-x-my-repo")
        #expect(ClaudeCodeScanner.encode("/Users/x/my.app_v2") == "-Users-x-my-app-v2")
    }

    @Test func knownPathResolvesLiveAndOrphaned() {
        let mapping = ["-Users-x-my-repo": ["/Users/x/my-repo"]]
        let live = ClaudeCodeScanner.resolveProjectPath(
            encodedName: "-Users-x-my-repo", encodedToRaw: mapping, fileExists: { _ in true })
        let orphan = ClaudeCodeScanner.resolveProjectPath(
            encodedName: "-Users-x-my-repo", encodedToRaw: mapping, fileExists: { _ in false })
        #expect(live.path == "/Users/x/my-repo")
        #expect(orphan.path == "/Users/x/my-repo")
        if case .live = live {} else { Issue.record("expected live") }
        if case .orphaned = orphan {} else { Issue.record("expected orphaned") }
    }

    @Test func collidingEncodingsStayLiveWhileAnyCandidateExists() {
        // "/Users/x/my-repo" (deleted) and "/Users/x/my/repo" (alive) share an
        // encoded name; the transcripts must never classify orphaned.
        let mapping = ["-Users-x-my-repo": ["/Users/x/my-repo", "/Users/x/my/repo"]]
        let result = ClaudeCodeScanner.resolveProjectPath(
            encodedName: "-Users-x-my-repo", encodedToRaw: mapping,
            fileExists: { $0 == "/Users/x/my/repo" })
        if case .live(let path) = result {
            #expect(path == "/Users/x/my/repo")
        } else {
            Issue.record("expected live via the surviving colliding path")
        }
    }

    @Test func unmountedVolumePathIsNeverOrphaned() {
        let mapping = ["-Volumes-Work-app": ["/Volumes/Work/app"]]
        let result = ClaudeCodeScanner.resolveProjectPath(
            encodedName: "-Volumes-Work-app", encodedToRaw: mapping, fileExists: { _ in false })
        if case .unresolved = result {} else {
            Issue.record("an absent /Volumes path must resolve unresolved, not orphaned")
        }
    }

    @Test func unknownNameFallsBackToNaiveDecodeOnlyWhenPathExists() {
        let live = ClaudeCodeScanner.resolveProjectPath(
            encodedName: "-Users-x-plain", encodedToRaw: [:],
            fileExists: { $0 == "/Users/x/plain" })
        if case .live(let path) = live {
            #expect(path == "/Users/x/plain")
        } else {
            Issue.record("expected live via naive decode")
        }
    }

    @Test func unknownNameWithMissingDecodedPathIsUnresolvedNotOrphaned() {
        // "my-repo" and "my/repo" encode identically; without the config mapping
        // a missing decoded path proves nothing and must never classify Safe.
        let result = ClaudeCodeScanner.resolveProjectPath(
            encodedName: "-Users-x-my-repo", encodedToRaw: [:], fileExists: { _ in false })
        if case .unresolved = result {} else { Issue.record("expected unresolved") }
    }
}

@Suite struct ClaudeCodeScannerFixtureTests {
    /// Build a fake home with .claude/projects dirs and a .claude.json mapping.
    private func makeHome() throws -> URL {
        let home = URL(filePath: NSTemporaryDirectory())
            .appendingPathComponent("claude-scan-\(UUID().uuidString)")
        let projects = home.appendingPathComponent(".claude/projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        return home
    }

    @Test func orphanedProjectClassifiesSafeLiveStaysReview() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let projects = home.appendingPathComponent(".claude/projects")

        // A live project directory inside the fake home, plus one that is gone.
        let liveSource = home.appendingPathComponent("code/alive")
        try FileManager.default.createDirectory(at: liveSource, withIntermediateDirectories: true)
        let goneSource = home.appendingPathComponent("code/gone")

        for source in [liveSource, goneSource] {
            let dir = projects.appendingPathComponent(ClaudeCodeScanner.encode(source.path))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: dir.appendingPathComponent("session.jsonl"))
        }
        let config: [String: Any] = ["projects": [liveSource.path: [:], goneSource.path: [:]]]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: home.appendingPathComponent(".claude.json"))

        // Old mtimes so nothing counts as an active session.
        let old = Date(timeIntervalSinceNow: -86_400)
        for dir in FileManager.default.contentsOfDirectoryIfPresent(projects, includeHidden: true) {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.path)
        }

        let items = try await ClaudeCodeScanner().scan(context: ScanContext(home: home))
        let transcripts = items.filter { $0.category == .toolSessions }
        #expect(transcripts.count == 2)
        let orphan = try #require(transcripts.first { $0.path.contains(ClaudeCodeScanner.encode(goneSource.path)) })
        let live = try #require(transcripts.first { $0.path.contains(ClaudeCodeScanner.encode(liveSource.path)) })
        #expect(orphan.safety == .safe)
        #expect(live.safety == .review)
    }

    @Test func configBackupsAreSafeItems() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude.json.backup.1"))

        let items = try await ClaudeCodeScanner().scan(context: ScanContext(home: home))
        let backup = try #require(items.first { $0.path.hasSuffix(".claude.json.backup.1") })
        #expect(backup.safety == .safe)
    }
}
