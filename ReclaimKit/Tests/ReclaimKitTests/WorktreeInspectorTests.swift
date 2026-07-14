import Foundation
import Testing
@testable import ReclaimKit

@Suite(.serialized) struct WorktreeInspectorTests {

    @Test func inspectsCleanPushedWorktree() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }
        let worktree = try await fixture.addWorktree(name: "feature-a")

        let state = try await WorktreeInspector().inspect(worktree)
        #expect(state.isMainWorktree == false)
        #expect(state.isRegistered == true)
        #expect(state.repositoryPath?.hasSuffix("/repo") == true)
        #expect(state.branch == "feature-a")
        #expect(state.hasModifiedFiles == false)
        #expect(state.hasUntrackedFiles == false)
        #expect(state.unpushedCommits == 0)
    }

    @Test func detectsMainWorktree() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }
        let state = try await WorktreeInspector().inspect(fixture.repo)
        #expect(state.isMainWorktree == true)
    }

    @Test func detectsDirtyAndUntracked() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }
        let worktree = try await fixture.addWorktree(name: "feature-dirty")
        try "edited".write(to: worktree.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try "new".write(to: worktree.appendingPathComponent("scratch.txt"), atomically: true, encoding: .utf8)

        let state = try await WorktreeInspector().inspect(worktree)
        #expect(state.hasModifiedFiles == true)
        #expect(state.hasUntrackedFiles == true)
    }

    @Test func dsStoreDoesNotCountAsUntracked() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }
        let worktree = try await fixture.addWorktree(name: "feature-dsstore")
        try Data().write(to: worktree.appendingPathComponent(".DS_Store"))

        let state = try await WorktreeInspector().inspect(worktree)
        #expect(state.hasUntrackedFiles == false)
    }

    @Test func countsUnpushedCommits() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }
        let worktree = try await fixture.addWorktree(name: "feature-ahead")
        try "more".write(to: worktree.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try await fixture.git("commit", "-am", "local only", cwd: worktree.path)

        let state = try await WorktreeInspector().inspect(worktree)
        #expect(state.unpushedCommits == 1)
    }

    @Test func detachedHeadUnpushedDetection() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }
        let worktree = try await fixture.addWorktree(name: "feature-detach")
        try await fixture.git("checkout", "--detach", cwd: worktree.path)
        try "detached work".write(to: worktree.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try await fixture.git("commit", "-am", "detached commit", cwd: worktree.path)

        let state = try await WorktreeInspector().inspect(worktree)
        #expect(state.branch == nil)
        #expect(state.unpushedCommits == 1)
    }

    @Test func repoWithoutRemoteHasNilUnpushed() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }
        let worktree = try await fixture.addWorktree(name: "feature-noremote", pushed: false)
        try await fixture.git("remote", "remove", "origin", cwd: fixture.repo.path)

        let state = try await WorktreeInspector().inspect(worktree)
        #expect(state.unpushedCommits == nil)
    }

    @Test func lockedWorktreeDetected() async throws {
        let fixture = try await GitFixture.make()
        defer { fixture.tearDown() }
        let worktree = try await fixture.addWorktree(name: "feature-locked")
        try await fixture.git("worktree", "lock", worktree.path, cwd: fixture.repo.path)

        let state = try await WorktreeInspector().inspect(worktree)
        #expect(state.isLocked == true)
    }
}
