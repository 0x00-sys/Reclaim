import Foundation

/// Builds a full WorktreeState for a directory that looks like a linked git worktree.
public struct WorktreeInspector: Sendable {
    public var git: GitClient

    public init(git: GitClient = GitClient()) {
        self.git = git
    }

    /// True when the directory contains a `.git` *file* (linked worktree), not a `.git` directory.
    public static func isLinkedWorktree(_ url: URL) -> Bool {
        let gitPath = url.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath.path, isDirectory: &isDirectory) else { return false }
        return !isDirectory.boolValue
    }

    public static func isMainRepository(_ url: URL) -> Bool {
        let gitPath = url.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    public func inspect(_ url: URL) async throws -> WorktreeState {
        let path = url.path
        let canonical = canonicalPath(path)
        var state = WorktreeState()
        state.isMainWorktree = Self.isMainRepository(url)

        guard let repo = try await git.mainWorktreePath(of: path) else {
            // Broken gitdir pointer: the parent repository is gone or moved.
            return state
        }
        state.repositoryPath = repo
        if state.isMainWorktree || canonicalPath(repo) == canonical {
            state.isMainWorktree = true
            state.isRegistered = true
        } else {
            let registered = try await git.listWorktrees(repository: repo)
            if let entry = registered.first(where: { canonicalPath($0.path) == canonical }) {
                state.isRegistered = true
                state.isLocked = entry.isLocked
            }
        }

        state.branch = try await git.currentBranch(workingTree: path)
        let status = try await git.status(workingTree: path)
        state.hasModifiedFiles = status.modified
        state.hasUntrackedFiles = status.untracked
        state.unpushedCommits = try await git.unpushedCommitCount(workingTree: path)
        state.lastCommitDate = try await git.lastCommitDate(workingTree: path)
        return state
    }

    /// Convenience: inspect and produce a classified ScanItem.
    public func scanItem(
        at url: URL,
        tool: Tool,
        displayName: String? = nil,
        hasActiveProcess: Bool = false,
        hasActiveSession: Bool = false
    ) async throws -> ScanItem {
        let state = try await inspect(url)
        var item = ScanItem(
            path: url.path,
            displayName: displayName ?? url.lastPathComponent,
            tool: tool,
            category: .worktree,
            lastActivity: state.lastCommitDate ?? latestModification(in: url, maxDepth: 1),
            worktree: state,
            hasActiveProcess: hasActiveProcess,
            hasActiveSession: hasActiveSession
        )
        (item.safety, item.reasons) = Classifier.classify(item)
        return item
    }
}
