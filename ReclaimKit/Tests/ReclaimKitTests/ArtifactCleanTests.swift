import Foundation
import Testing
@testable import ReclaimKit

@Suite struct BuildArtifactLocatorTests {
    private func makeTree(_ files: [String], dirs: [String]) throws -> URL {
        let root = URL(filePath: NSTemporaryDirectory())
            .appendingPathComponent("artifacts-\(UUID().uuidString)")
        for dir in dirs + [""] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for file in files {
            try Data().write(to: root.appendingPathComponent(file))
        }
        return root
    }

    @Test func nodeProjectFindsNestedNodeModulesAndPrunes() throws {
        let root = try makeTree(
            ["package.json"],
            dirs: ["node_modules/react", "packages/web/node_modules/lodash", "src"])
        defer { try? FileManager.default.removeItem(at: root) }
        let found = BuildArtifactLocator.locate(in: root).map(\.lastPathComponent)
        #expect(found == ["node_modules", "node_modules"])
    }

    @Test func rustProjectOnlyMatchesTarget() throws {
        let root = try makeTree(["Cargo.toml"], dirs: ["target/debug", "src", "node_modules"])
        defer { try? FileManager.default.removeItem(at: root) }
        let found = BuildArtifactLocator.locate(in: root).map(\.lastPathComponent)
        #expect(found == ["target"])
    }

    @Test func symlinkedArtifactIsIgnored() throws {
        let root = try makeTree(["package.json"], dirs: ["real"])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("node_modules"),
            withDestinationURL: root.appendingPathComponent("real"))
        #expect(BuildArtifactLocator.locate(in: root).isEmpty)
    }
}

@Suite struct ArtifactCleanEngineTests {
    @Test func cleansUntrackedArtifactsKeepsWorktree() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }
        let worktree = try await fixture.addWorktree(name: "feature")

        // Ignored node_modules next to real (dirty) work.
        try "node_modules\n".write(to: worktree.appendingPathComponent(".gitignore"),
                                   atomically: true, encoding: .utf8)
        let modules = worktree.appendingPathComponent("node_modules/pkg")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: modules.appendingPathComponent("index.js"))

        let item = try await WorktreeInspector().scanItem(at: worktree, tool: .git)
        #expect(item.artifactPaths?.map(canonicalPath) ==
                [canonicalPath(worktree.appendingPathComponent("node_modules").path)])

        let results = await CleanupEngine().cleanArtifacts(in: item)
        #expect(results.count == 1)
        #expect(results[0].success)
        #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("node_modules").path))
        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("file.txt").path))
    }

    @Test func refusesArtifactDirContainingTrackedFiles() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }
        let worktree = try await fixture.addWorktree(name: "tracked-dist")

        // A committed dist/ is source, not artifact.
        let dist = worktree.appendingPathComponent("dist")
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        try Data("bundle".utf8).write(to: dist.appendingPathComponent("app.js"))
        try await fixture.git("add", ".", cwd: worktree.path)
        try await fixture.git("commit", "-m", "ship dist", cwd: worktree.path)

        let item = try await WorktreeInspector().scanItem(at: worktree, tool: .git)
        let results = await CleanupEngine().cleanArtifacts(in: item)
        #expect(results.allSatisfy { !$0.success })
        #expect(FileManager.default.fileExists(atPath: dist.appendingPathComponent("app.js").path))
    }

    @Test func artifactCleanWorksOnProtectedWorktree() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }

        // The MAIN worktree is always protected as an item; its artifacts are not.
        try "node_modules\n".write(to: fixture.repo.appendingPathComponent(".gitignore"),
                                   atomically: true, encoding: .utf8)
        let modules = fixture.repo.appendingPathComponent("node_modules/dep")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data("y".utf8).write(to: modules.appendingPathComponent("main.js"))

        let item = try await WorktreeInspector().scanItem(at: fixture.repo, tool: .git)
        #expect(item.safety == .protected)
        let results = await CleanupEngine().cleanArtifacts(in: item)
        #expect(results.contains { $0.success })
        #expect(!FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent("node_modules").path))
    }
}

@Suite struct VerdictUpgradeTests {
    @Test func staleReviewVerdictUpgradesWhenWorktreeWasPushed() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }
        let worktree = try await fixture.addWorktree(name: "pushed-later", pushed: false)

        // Scan while unpushed: Review. Then the user pushes; the stored verdict is stale.
        var item = try await WorktreeInspector().scanItem(at: worktree, tool: .git)
        try await fixture.git("commit", "--allow-empty", "-m", "wip", cwd: worktree.path)
        item = try await WorktreeInspector().scanItem(at: worktree, tool: .git)
        #expect(item.safety == .review)
        try await fixture.git("push", "-u", "origin", "pushed-later", cwd: worktree.path)

        let results = await CleanupEngine().clean(items: [item])
        #expect(results.count == 1)
        #expect(results[0].success, "fresh re-inspection should override the stale Review verdict")
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
    }

    @Test func unknownWorktreeWithMissingRepoStillRefused() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }
        let worktree = try await fixture.addWorktree(name: "orphan-to-be")

        var item = try await WorktreeInspector().scanItem(at: worktree, tool: .git)
        // Sever the parent repository: work inside can no longer be verified.
        try FileManager.default.removeItem(at: fixture.repo)
        item.safety = .unknown

        let results = await CleanupEngine().clean(items: [item])
        #expect(results.count == 1)
        #expect(!results[0].success)
        #expect(results[0].canForce)
        #expect(FileManager.default.fileExists(atPath: worktree.path))
    }
}
