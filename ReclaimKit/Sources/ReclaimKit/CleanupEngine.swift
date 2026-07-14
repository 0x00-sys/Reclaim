import Foundation

public struct CleanupResult: Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var displayName: String
    public var success: Bool
    public var message: String
    public var freedBytes: Int64?
}

/// Destructive operations live here and nowhere else.
///
/// Policy:
/// - Items classified protected or unknown are refused outright.
/// - Worktrees are re-inspected immediately before removal; any dirty state,
///   untracked files, or unpushed commits found at that moment aborts the item.
/// - Deletion goes through the macOS Trash (recoverable), then `git worktree prune`
///   clears the stale registration in the parent repository. We deliberately trash +
///   prune rather than `git worktree remove` so every deletion is recoverable;
///   git's own dirty-tree check is replicated by the re-inspection above.
/// - Simulator device data is never touched directly; it must go through simctl.
public actor CleanupEngine {
    private let git: GitClient

    public init(git: GitClient = GitClient()) {
        self.git = git
    }

    public func clean(
        items: [ScanItem],
        onProgress: (@MainActor @Sendable (CleanupResult) -> Void)? = nil
    ) async -> [CleanupResult] {
        var results: [CleanupResult] = []
        let processes = await ProcessSnapshot.capture()
        for item in items {
            let result = await clean(item, processes: processes)
            results.append(result)
            if let onProgress {
                await onProgress(result)
            }
        }
        // One prune per affected repository after all removals.
        let repos = Set(items.compactMap { $0.worktree?.repositoryPath })
        for repo in repos {
            try? await git.pruneWorktrees(repository: repo)
        }
        return results
    }

    private func clean(_ item: ScanItem, processes: ProcessSnapshot) async -> CleanupResult {
        func failure(_ message: String) -> CleanupResult {
            CleanupResult(path: item.path, displayName: item.displayName, success: false, message: message)
        }

        switch item.safety {
        case .protected:
            return failure("Refused: item is active or protected.")
        case .unknown:
            return failure("Refused: could not determine whether this is safe to remove.")
        case .safe, .review:
            break
        }
        if item.category == .simulators {
            return failure("Simulator data must be removed with `xcrun simctl delete unavailable` or Xcode ▸ Settings ▸ Components.")
        }
        if processes.referencesPath(item.path) {
            return failure("Refused: a running process references this path.")
        }
        switch await Self.openFileCheck(path: item.path) {
        case .inUse(let programs):
            return failure("Refused: files inside are open in \(programs.joined(separator: ", ")).")
        case .unknown:
            return failure("Refused: could not verify that nothing has these files open. Try again in a moment.")
        case .free:
            break
        }
        if let worktree = item.worktree, worktree.isPrunable,
           !FileManager.default.fileExists(atPath: item.path),
           let repo = worktree.repositoryPath {
            try? await git.pruneWorktrees(repository: repo)
            let remaining = (try? await git.listWorktrees(repository: repo)) ?? []
            if remaining.contains(where: { canonicalPath($0.path) == canonicalPath(item.path) }) {
                return failure("git worktree prune did not remove the registration (it may be locked).")
            }
            return CleanupResult(path: item.path, displayName: item.displayName, success: true,
                                 message: "Pruned stale registration from \(URL(filePath: repo).lastPathComponent).", freedBytes: 0)
        }
        guard FileManager.default.fileExists(atPath: item.path) else {
            return failure("Path no longer exists.")
        }

        if item.worktree != nil {
            return await removeWorktree(item)
        }
        return trash(item, alsoSiblings: item.path.hasSuffix(".sqlite") ? ["-wal", "-shm"] : [])
    }

    private func removeWorktree(_ item: ScanItem) async -> CleanupResult {
        func failure(_ message: String) -> CleanupResult {
            CleanupResult(path: item.path, displayName: item.displayName, success: false, message: message)
        }

        // The path must be a worktree root itself, not a directory inside one —
        // git resolves subdirectories to the enclosing worktree, which would make
        // the checks below pass while we delete only part of it.
        guard WorktreeInspector.isLinkedWorktree(item.url) || WorktreeInspector.isMainRepository(item.url) else {
            return failure("Refused: not the root of a git worktree.")
        }
        // Re-inspect right now; the scan result may be stale.
        guard let state = try? await WorktreeInspector(git: git).inspect(item.url) else {
            return failure("Refused: could not re-inspect the worktree.")
        }
        if state.isMainWorktree {
            return failure("Refused: this is the main worktree of its repository.")
        }
        if state.hasModifiedFiles {
            return failure("Refused: the worktree now has uncommitted changes.")
        }
        if state.hasUntrackedFiles {
            return failure("Refused: the worktree now contains untracked files.")
        }
        if let unpushed = state.unpushedCommits, unpushed > 0 {
            return failure("Refused: \(unpushed) commit(s) exist only on this machine.")
        }
        if state.repositoryPath != nil && state.unpushedCommits == nil {
            return failure("Refused: could not verify that all commits are pushed.")
        }
        if state.isLocked {
            return failure("Refused: the worktree is locked in git.")
        }

        var result = trash(item, alsoSiblings: [])
        if result.success, let repo = state.repositoryPath {
            try? await git.pruneWorktrees(repository: repo)
            // Codex wraps each worktree in an id directory; remove the wrapper if now empty.
            let parent = item.url.deletingLastPathComponent()
            if FileManager.default.contentsOfDirectoryIfPresent(parent).isEmpty,
               parent.path.contains("/.codex/worktrees/") {
                try? FileManager.default.trashItem(at: parent, resultingItemURL: nil)
            }
            result.message = "Moved to Trash and pruned from \(URL(filePath: repo).lastPathComponent)."
        }
        return result
    }

    enum OpenFileStatus: Sendable {
        case free
        case inUse(programs: [String])
        case unknown
    }

    /// Authoritative in-use check: asks lsof whether any process holds open
    /// files under the path. Command-line scanning misses daemons like gopls
    /// that keep cache files open; trashing those makes emptying the Trash fail.
    static func openFileCheck(path: String, timeout: TimeInterval = 25) async -> OpenFileStatus {
        guard let result = try? await runSubprocess(
            "/usr/sbin/lsof", ["-w", "-F", "c", "+D", path], timeout: timeout
        ) else { return .unknown }
        let programs = Set(
            result.stdout.split(separator: "\n")
                .filter { $0.hasPrefix("c") }
                .map { String($0.dropFirst()) }
        ).sorted()
        if !programs.isEmpty {
            return .inUse(programs: programs)
        }
        // lsof exits 1 when it finds nothing; a timeout kill leaves other codes.
        return result.status <= 1 ? .free : .unknown
    }

    private func trash(_ item: ScanItem, alsoSiblings suffixes: [String]) -> CleanupResult {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            for suffix in suffixes {
                let sibling = URL(filePath: item.path + suffix)
                if FileManager.default.fileExists(atPath: sibling.path) {
                    try? FileManager.default.trashItem(at: sibling, resultingItemURL: nil)
                }
            }
            if FileManager.default.fileExists(atPath: item.path) {
                return CleanupResult(path: item.path, displayName: item.displayName, success: false,
                                     message: "Trash operation reported success but the item still exists.")
            }
            return CleanupResult(path: item.path, displayName: item.displayName, success: true,
                                 message: "Moved to Trash.", freedBytes: item.sizeBytes)
        } catch {
            return CleanupResult(path: item.path, displayName: item.displayName, success: false,
                                 message: "Could not move to Trash: \(error.localizedDescription)")
        }
    }
}
