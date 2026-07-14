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
