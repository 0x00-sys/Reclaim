import Foundation

public struct GitWorktreeEntry: Sendable, Equatable {
    public var path: String
    public var branch: String?
    public var isMain: Bool
    public var isLocked: Bool
    public var isPrunable: Bool

    public init(path: String, branch: String? = nil, isMain: Bool = false,
                isLocked: Bool = false, isPrunable: Bool = false) {
        self.path = path
        self.branch = branch
        self.isMain = isMain
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }
}

/// Thin wrapper over the git CLI. All calls use argument arrays, never a shell.
public struct GitClient: Sendable {
    public var gitPath: String

    public init(gitPath: String = "/usr/bin/git") {
        self.gitPath = gitPath
    }

    func run(_ arguments: [String], in directory: String?) async throws -> SubprocessResult {
        try await runSubprocess(gitPath, arguments, currentDirectory: directory)
    }

    /// Resolves the path a `.git` file or directory belongs to. For a linked worktree,
    /// `--git-common-dir` points at the main repository's `.git` directory.
    public func commonGitDirectory(of workingTree: String) async throws -> String? {
        let result = try await run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: workingTree)
        guard result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The main working tree that owns a linked worktree (parent of the common `.git` dir).
    public func mainWorktreePath(of workingTree: String) async throws -> String? {
        guard let common = try await commonGitDirectory(of: workingTree) else { return nil }
        guard common.hasSuffix("/.git") else { return nil } // bare repos have no main working tree
        return String(common.dropLast("/.git".count))
    }

    public func listWorktrees(repository: String) async throws -> [GitWorktreeEntry] {
        let result = try await run(["worktree", "list", "--porcelain"], in: repository)
        guard result.succeeded else { return [] }
        var entries: [GitWorktreeEntry] = []
        var current: GitWorktreeEntry?
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                if let current { entries.append(current) }
                current = GitWorktreeEntry(
                    path: String(line.dropFirst("worktree ".count)),
                    isMain: entries.isEmpty && current == nil
                )
            } else if line.hasPrefix("branch ") {
                current?.branch = String(line.dropFirst("branch ".count))
                    .replacingOccurrences(of: "refs/heads/", with: "")
            } else if line.hasPrefix("locked") {
                current?.isLocked = true
            } else if line.hasPrefix("prunable") {
                current?.isPrunable = true
            }
        }
        if let current { entries.append(current) }
        return entries
    }

    public func status(workingTree: String) async throws -> (modified: Bool, untracked: Bool) {
        let result = try await run(["status", "--porcelain"], in: workingTree)
        guard result.succeeded else { return (false, false) }
        var modified = false
        var untracked = false
        for line in result.stdout.split(separator: "\n") {
            if line.hasPrefix("??") {
                // Finder droppings are not user work.
                if !line.hasSuffix(".DS_Store") { untracked = true }
            } else {
                modified = true
            }
        }
        return (modified, untracked)
    }

    public func currentBranch(workingTree: String) async throws -> String? {
        let result = try await run(["branch", "--show-current"], in: workingTree)
        guard result.succeeded else { return nil }
        let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    /// Commits reachable from HEAD that exist on no remote-tracking ref.
    /// nil means it could not be determined (e.g. repo with no remotes at all).
    public func unpushedCommitCount(workingTree: String) async throws -> Int? {
        let remotes = try await run(["remote"], in: workingTree)
        guard remotes.succeeded,
              !remotes.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let result = try await run(["rev-list", "--count", "HEAD", "--not", "--remotes"], in: workingTree)
        guard result.succeeded else { return nil }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func lastCommitDate(workingTree: String) async throws -> Date? {
        let result = try await run(["log", "-1", "--format=%ct"], in: workingTree)
        guard result.succeeded,
              let seconds = TimeInterval(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public func pruneWorktrees(repository: String) async throws {
        _ = try await run(["worktree", "prune"], in: repository)
    }
}
