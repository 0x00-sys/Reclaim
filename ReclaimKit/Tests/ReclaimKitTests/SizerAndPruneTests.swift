import Foundation
import Testing
@testable import ReclaimKit

@Suite struct DirectorySizerTests {
    @Test func hardlinksAreCountedOnce() async throws {
        let dir = URL(filePath: NSTemporaryDirectory()).appendingPathComponent("reclaim-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("blob")
        try Data(repeating: 7, count: 1_000_000).write(to: original)
        for index in 0..<4 {
            try FileManager.default.linkItem(at: original, to: dir.appendingPathComponent("link\(index)"))
        }

        let size = try await DirectorySizer.allocatedSize(of: dir)
        // 5 directory entries, one megabyte of real data.
        #expect(size > 900_000 && size < 2_000_000, "hardlinked tree measured \(size) bytes")
    }
}

@Suite struct BuildCacheDiscoveryTests {
    @Test func findsFrameworkBuildCachesAndCargoTarget() async throws {
        let root = URL(filePath: NSTemporaryDirectory()).appendingPathComponent("reclaim-build-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let webProject = root.appendingPathComponent("web-app")
        try FileManager.default.createDirectory(at: webProject.appendingPathComponent(".next/cache"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: webProject.appendingPathComponent("node_modules/react"), withIntermediateDirectories: true)
        let rustProject = root.appendingPathComponent("rust-app")
        try FileManager.default.createDirectory(at: rustProject.appendingPathComponent("target/debug"), withIntermediateDirectories: true)
        try "".write(to: rustProject.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)
        // A "target" dir without Cargo.toml must NOT match.
        let plain = root.appendingPathComponent("not-rust")
        try FileManager.default.createDirectory(at: plain.appendingPathComponent("target"), withIntermediateDirectories: true)

        let items = try await NodeModulesScanner().scan(context: ScanContext(projectRoots: [root]))
        #expect(items.contains { $0.category == .buildCache && $0.path.hasSuffix("web-app/.next") && $0.safety == .safe })
        #expect(items.contains { $0.category == .nodeModules && $0.path.hasSuffix("web-app/node_modules") })
        #expect(items.contains { $0.category == .buildCache && $0.tool == .rust && $0.path.hasSuffix("rust-app/target") })
        #expect(!items.contains { $0.path.hasSuffix("not-rust/target") })
    }
}

@Suite(.serialized) struct ClaudeWorktreeTests {
    @Test func findsOrphanedClaudeWorktree() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }
        // A registered worktree under .claude/worktrees…
        let claudeDir = fixture.repo.appendingPathComponent(".claude/worktrees")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let registered = claudeDir.appendingPathComponent("feature-x")
        try await fixture.git("worktree", "add", "-b", "feature-x", registered.path, cwd: fixture.repo.path)
        // …and an orphan directory git no longer knows about.
        let orphan = claudeDir.appendingPathComponent("orphan-y")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

        let items = try await RepoWorktreeScanner().scan(context: ScanContext(projectRoots: [fixture.root]))
        let registeredItem = try #require(items.first { canonicalPath($0.path) == canonicalPath(registered.path) })
        #expect(registeredItem.tool == .claudeCode)
        #expect(registeredItem.worktree?.isRegistered == true)
        let orphanItem = try #require(items.first { canonicalPath($0.path) == canonicalPath(orphan.path) })
        #expect(orphanItem.tool == .claudeCode)
        #expect(orphanItem.safety != .safe) // no git state → never auto-cleanable
    }
}

@Suite(.serialized) struct StaleRegistrationTests {
    @Test func scannerReportsAndEnginePrunesStaleRegistration() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }
        let worktree = try await fixture.addWorktree(name: "feature-gone")
        // Simulate a tool deleting the directory behind git's back.
        try FileManager.default.removeItem(at: worktree)

        let context = ScanContext(projectRoots: [fixture.root])
        let items = try await RepoWorktreeScanner().scan(context: context)
        let stale = try #require(items.first { $0.worktree?.isPrunable == true })
        #expect(stale.safety == .safe)
        #expect(stale.sizeBytes == 0)

        let results = await CleanupEngine().clean(items: [stale])
        #expect(results[0].success == true)
        let remaining = try await GitClient().listWorktrees(repository: fixture.repo.path)
        #expect(!remaining.contains { canonicalPath($0.path) == canonicalPath(worktree.path) })
    }
}
