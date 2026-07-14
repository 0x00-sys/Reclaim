import Foundation
@testable import ReclaimKit

/// Builds throwaway git repositories with worktrees under a unique temp directory.
struct GitFixture {
    let root: URL
    let repo: URL
    let remote: URL
    let git = GitClient()

    static func make() async throws -> GitFixture {
        let root = URL(filePath: NSTemporaryDirectory())
            .appendingPathComponent("reclaim-tests-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo")
        let remote = root.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        let fixture = GitFixture(root: root, repo: repo, remote: remote)

        try await fixture.git("init", "--bare", cwd: remote.path)
        try await fixture.git("init", "-b", "main", cwd: repo.path)
        try await fixture.git("config", "user.email", "test@example.com", cwd: repo.path)
        try await fixture.git("config", "user.name", "Test", cwd: repo.path)
        try "hello\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try await fixture.git("add", ".", cwd: repo.path)
        try await fixture.git("commit", "-m", "initial", cwd: repo.path)
        try await fixture.git("remote", "add", "origin", remote.path, cwd: repo.path)
        try await fixture.git("push", "-u", "origin", "main", cwd: repo.path)
        return fixture
    }

    @discardableResult
    func git(_ arguments: String..., cwd: String) async throws -> String {
        let result = try await git.run(Array(arguments), in: cwd)
        guard result.succeeded else {
            throw NSError(domain: "GitFixture", code: Int(result.status),
                          userInfo: [NSLocalizedDescriptionKey: result.stderr])
        }
        return result.stdout
    }

    /// Adds a linked worktree on a new pushed branch. Returns its path.
    func addWorktree(name: String, pushed: Bool = true) async throws -> URL {
        let path = root.appendingPathComponent(name)
        try await git("worktree", "add", "-b", name, path.path, cwd: repo.path)
        if pushed {
            try await git("push", "-u", "origin", name, cwd: path.path)
        }
        return path
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }
}
