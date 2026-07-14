import Foundation

/// Builds a full WorktreeState for a directory that looks like a linked git worktree.
public struct WorktreeInspector: Sendable {
    public var git: GitClient

    public init(git: GitClient = GitClient()) {
        self.git = git
    }

    /// nil = no `.git` entry; true = `.git` directory (main repo); false = `.git` file (linked worktree).
    private static func gitEntryIsDirectory(_ url: URL) -> Bool? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path,
                                             isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue
    }

    /// True when the directory contains a `.git` *file* (linked worktree), not a `.git` directory.
    public static func isLinkedWorktree(_ url: URL) -> Bool { gitEntryIsDirectory(url) == false }

    public static func isMainRepository(_ url: URL) -> Bool { gitEntryIsDirectory(url) == true }

    /// The directory is the root of a working tree (linked worktree or main repo).
    public static func isWorktreeRoot(_ url: URL) -> Bool { gitEntryIsDirectory(url) != nil }

    /// Pass `registeredEntries` when the caller already ran `git worktree list`
    /// for the repository; it saves one subprocess per worktree.
    public func inspect(_ url: URL, registeredEntries: [GitWorktreeEntry]? = nil) async throws -> WorktreeState {
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
            let registered: [GitWorktreeEntry]
            if let registeredEntries {
                registered = registeredEntries
            } else {
                registered = try await git.listWorktrees(repository: repo)
            }
            if let entry = registered.first(where: { canonicalPath($0.path) == canonical }) {
                state.isRegistered = true
                state.isLocked = entry.isLocked
            }
        }

        // The four state queries are independent; run them concurrently.
        async let branch = git.currentBranch(workingTree: path)
        async let status = git.status(workingTree: path)
        async let unpushed = git.unpushedCommitCount(workingTree: path)
        async let lastCommit = git.lastCommitDate(workingTree: path)
        state.branch = try await branch
        (state.hasModifiedFiles, state.hasUntrackedFiles) = try await status
        state.unpushedCommits = try await unpushed
        state.lastCommitDate = try await lastCommit
        return state
    }

    /// Convenience: inspect and produce a classified ScanItem.
    public func scanItem(
        at url: URL,
        tool: Tool,
        displayName: String? = nil,
        hasActiveProcess: Bool = false,
        hasActiveSession: Bool = false,
        registeredEntries: [GitWorktreeEntry]? = nil
    ) async throws -> ScanItem {
        let state = try await inspect(url, registeredEntries: registeredEntries)
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
