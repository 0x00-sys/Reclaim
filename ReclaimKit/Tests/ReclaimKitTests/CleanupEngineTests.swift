import Foundation
import Testing
@testable import ReclaimKit

@Suite(.serialized) struct CleanupEngineTests {

    private func scanItem(for url: URL, tool: Tool = .codex) async throws -> ScanItem {
        try await WorktreeInspector().scanItem(at: url, tool: tool)
    }

    @Test func removesCleanWorktreeAndPrunesRegistration() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }
        let worktree = try await fixture.addWorktree(name: "feature-clean")
        let item = try await scanItem(for: worktree)
        #expect(item.safety == .safe)

        let results = await CleanupEngine().clean(items: [item])
        #expect(results.count == 1)
        #expect(results[0].success == true)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        let remaining = try await GitClient().listWorktrees(repository: fixture.repo.path)
        #expect(!remaining.contains { $0.path == worktree.path })
    }

    @Test func refusesWorktreeThatBecameDirty() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }
        let worktree = try await fixture.addWorktree(name: "feature-race")
        let item = try await scanItem(for: worktree) // clean at scan time
        try "late edit".write(to: worktree.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let results = await CleanupEngine().clean(items: [item])
        #expect(results[0].success == false)
        #expect(results[0].message.contains("uncommitted"))
        #expect(FileManager.default.fileExists(atPath: worktree.path))
    }

    @Test func refusesWorktreeWithUntrackedFiles() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }
        let worktree = try await fixture.addWorktree(name: "feature-untracked")
        let item = try await scanItem(for: worktree)
        try "precious".write(to: worktree.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        let results = await CleanupEngine().clean(items: [item])
        #expect(results[0].success == false)
        #expect(FileManager.default.fileExists(atPath: worktree.path))
    }

    @Test func refusesWorktreeWithUnpushedCommits() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }
        let worktree = try await fixture.addWorktree(name: "feature-unpushed")
        let item = try await scanItem(for: worktree)
        try "work".write(to: worktree.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try await fixture.git("commit", "-am", "unpushed", cwd: worktree.path)

        let results = await CleanupEngine().clean(items: [item])
        #expect(results[0].success == false)
        #expect(results[0].message.contains("commit"))
        #expect(FileManager.default.fileExists(atPath: worktree.path))
    }

    @Test func refusesMainWorktreeEvenIfMislabeled() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }
        // Craft an item that lies about being a safe linked worktree.
        var item = try await scanItem(for: fixture.repo)
        item.safety = .safe
        item.worktree?.isMainWorktree = false

        let results = await CleanupEngine().clean(items: [item])
        #expect(results[0].success == false)
        #expect(FileManager.default.fileExists(atPath: fixture.repo.path))
    }

    @Test func refusesProtectedAndUnknownItems() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }
        let worktree = try await fixture.addWorktree(name: "feature-protected")
        var item = try await scanItem(for: worktree)

        item.safety = .protected
        var results = await CleanupEngine().clean(items: [item])
        #expect(results[0].success == false)

        item.safety = .unknown
        results = await CleanupEngine().clean(items: [item])
        #expect(results[0].success == false)
        #expect(FileManager.default.fileExists(atPath: worktree.path))
    }

    @Test func refusesLockedWorktree() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }
        let worktree = try await fixture.addWorktree(name: "feature-lock2")
        let item = try await scanItem(for: worktree)
        try await fixture.git("worktree", "lock", worktree.path, cwd: fixture.repo.path)

        let results = await CleanupEngine().clean(items: [item])
        #expect(results[0].success == false)
        #expect(FileManager.default.fileExists(atPath: worktree.path))
    }

    @Test func refusesSimulatorCategory() async throws {
        let dir = URL(filePath: NSTemporaryDirectory()).appendingPathComponent("reclaim-sim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var item = ScanItem(path: dir.path, displayName: "sims", tool: .xcode, category: .simulators)
        item.safety = .review

        let results = await CleanupEngine().clean(items: [item])
        #expect(results[0].success == false)
        #expect(results[0].message.contains("simctl"))
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func trashesPlainDirectory() async throws {
        let dir = URL(filePath: NSTemporaryDirectory()).appendingPathComponent("reclaim-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "cached".write(to: dir.appendingPathComponent("blob"), atomically: true, encoding: .utf8)
        var item = ScanItem(path: dir.path, displayName: "cache", tool: .npm, category: .toolCache)
        (item.safety, item.reasons) = Classifier.classify(item)
        #expect(item.safety == .safe)

        let results = await CleanupEngine().clean(items: [item])
        #expect(results[0].success == true)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func reportsMissingPath() async throws {
        var item = ScanItem(path: "/nonexistent/reclaim-\(UUID().uuidString)", displayName: "gone", tool: .npm, category: .toolCache)
        item.safety = .safe
        let results = await CleanupEngine().clean(items: [item])
        #expect(results[0].success == false)
    }
}
