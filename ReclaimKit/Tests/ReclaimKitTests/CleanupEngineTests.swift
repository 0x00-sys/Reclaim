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

    @Test func forceCleanOverridesGitStateRefusalsOnly() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }
        let worktree = try await fixture.addWorktree(name: "feature-force")
        let item = try await scanItem(for: worktree)
        try "precious".write(to: worktree.appendingPathComponent("wip.txt"), atomically: true, encoding: .utf8)

        // Normal clean refuses and marks the refusal as force-eligible.
        let refused = await CleanupEngine().clean(items: [item])
        #expect(refused[0].success == false)
        #expect(refused[0].canForce == true)
        #expect(FileManager.default.fileExists(atPath: worktree.path))

        // Force clean succeeds and prunes the registration.
        let forced = await CleanupEngine().clean(items: [item], force: true)
        #expect(forced[0].success == true)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
    }

    @Test func forceNeverRemovesMainOrLockedWorktrees() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }

        var main = try await scanItem(for: fixture.repo)
        main.safety = .safe
        main.worktree?.isMainWorktree = false // even a lying item must be refused
        let mainResult = await CleanupEngine().clean(items: [main], force: true)
        #expect(mainResult[0].success == false)
        #expect(mainResult[0].canForce == false)
        #expect(FileManager.default.fileExists(atPath: fixture.repo.path))

        let locked = try await fixture.addWorktree(name: "feature-forcelock")
        let lockedItem = try await scanItem(for: locked)
        try await fixture.git("worktree", "lock", locked.path, cwd: fixture.repo.path)
        let lockedResult = await CleanupEngine().clean(items: [lockedItem], force: true)
        #expect(lockedResult[0].success == false)
        #expect(lockedResult[0].canForce == false)
        #expect(FileManager.default.fileExists(atPath: locked.path))
    }

    @Test func refusesSubdirectoryOfWorktree() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }
        let worktree = try await fixture.addWorktree(name: "feature-subdir")
        let subdir = worktree.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        // git resolves subdir to the worktree, so a naive engine would see "clean" and trash it.
        var item = try await scanItem(for: subdir)
        item.safety = .safe

        let results = await CleanupEngine().clean(items: [item])
        #expect(results[0].success == false)
        #expect(results[0].message.contains("not the root"))
        #expect(FileManager.default.fileExists(atPath: subdir.path))
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

    @Test func refusesDirectoryWithOpenFiles() async throws {
        let dir = URL(filePath: NSTemporaryDirectory()).appendingPathComponent("reclaim-inuse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("held-open.dat")
        try Data(repeating: 1, count: 128).write(to: file)
        let handle = try FileHandle(forReadingFrom: file) // this process holds it open

        var item = ScanItem(path: dir.path, displayName: "in-use", tool: .npm, category: .toolCache)
        item.safety = .safe
        let results = await CleanupEngine().clean(items: [item])
        #expect(results[0].success == false)
        #expect(results[0].message.contains("open"))
        #expect(FileManager.default.fileExists(atPath: dir.path))

        try handle.close()
        let retried = await CleanupEngine().clean(items: [item])
        #expect(retried[0].success == true)
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
