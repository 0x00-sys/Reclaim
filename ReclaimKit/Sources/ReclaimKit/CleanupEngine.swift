import Foundation

public struct CleanupResult: Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var displayName: String
    public var success: Bool
    public var message: String
    public var freedBytes: Int64? = nil
    /// The refusal protects unpushed/uncommitted work; the user may override it
    /// with an explicit force clean. Hard refusals (main worktree, locked,
    /// files in use, simulators) never set this.
    public var canForce: Bool = false
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
        force: Bool = false,
        onProgress: (@MainActor @Sendable (CleanupResult) -> Void)? = nil
    ) async -> [CleanupResult] {
        var results: [CleanupResult] = []
        let processes = await ProcessSnapshot.capture()
        for item in items {
            let result = await clean(item, processes: processes, force: force)
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

    private func clean(_ item: ScanItem, processes: ProcessSnapshot, force: Bool = false) async -> CleanupResult {
        func failure(_ message: String) -> CleanupResult {
            CleanupResult(path: item.path, displayName: item.displayName, success: false, message: message)
        }

        switch item.safety {
        case .protected:
            return failure("Refused: item is active or protected.")
        case .unknown where item.worktree == nil:
            return failure("Refused: could not determine whether this is safe to remove.")
        case .unknown, .safe, .review:
            // A worktree's stored verdict may be stale (the user pushed since the
            // scan); removeWorktree re-inspects and that fresh result decides.
            break
        }
        if item.category == .simulators {
            return failure("Simulator data must be removed with `xcrun simctl delete unavailable` or Xcode ▸ Settings ▸ Components.")
        }
        if let refusal = await inUseRefusal(path: item.path, name: "this item", processes: processes) {
            return failure(refusal)
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
            return await removeWorktree(item, force: force)
        }
        return trash(item)
    }

    private func removeWorktree(_ item: ScanItem, force: Bool = false) async -> CleanupResult {
        func failure(_ message: String, canForce: Bool = false) -> CleanupResult {
            CleanupResult(path: item.path, displayName: item.displayName, success: false,
                          message: message, canForce: canForce)
        }

        // The path must be a worktree root itself, not a directory inside one —
        // git resolves subdirectories to the enclosing worktree, which would make
        // the checks below pass while we delete only part of it.
        guard WorktreeInspector.isWorktreeRoot(item.url) else {
            return failure("Refused: not the root of a git worktree.")
        }
        // Re-inspect right now; the scan result may be stale.
        guard let state = try? await WorktreeInspector(git: git).inspect(item.url) else {
            return failure("Refused: could not re-inspect the worktree.")
        }
        if state.isMainWorktree {
            return failure("Refused: this is the main worktree of its repository.")
        }
        if state.isLocked {
            // git worktree lock is an explicit user protection; force does not override it.
            return failure("Refused: the worktree is locked in git.")
        }
        if !force {
            // These guard unpushed/uncommitted work and may be overridden by an
            // explicit, double-confirmed force clean. Deletion is still Trash-first.
            if state.repositoryPath == nil {
                return failure("Refused: the parent repository is missing, so this worktree's work cannot be verified as pushed.", canForce: true)
            }
            if state.hasModifiedFiles {
                return failure("Refused: the worktree now has uncommitted changes.", canForce: true)
            }
            if state.hasUntrackedFiles {
                return failure("Refused: the worktree now contains untracked files.", canForce: true)
            }
            if let unpushed = state.unpushedCommits, unpushed > 0 {
                return failure("Refused: \(unpushed) commit(s) exist only on this machine.", canForce: true)
            }
            if state.repositoryPath != nil && state.unpushedCommits == nil {
                return failure("Refused: could not verify that all commits are pushed.", canForce: true)
            }
        }

        var result = trash(item)
        if result.success, let repo = state.repositoryPath {
            try? await git.pruneWorktrees(repository: repo)
            result.message = "Moved to Trash and pruned from \(URL(filePath: repo).lastPathComponent)."
        }
        return result
    }

    /// Trash only the regenerable build-artifact directories inside a worktree,
    /// keeping the code. Works on worktrees whose whole-item verdict is refused
    /// (unpushed commits, dirty tree, even the main worktree): the artifacts are
    /// not part of that work. Each candidate is re-located fresh, must contain
    /// zero git-tracked files, and must have nothing open inside it.
    public func cleanArtifacts(in item: ScanItem) async -> [CleanupResult] {
        func failure(_ path: String, _ message: String) -> CleanupResult {
            CleanupResult(path: path, displayName: URL(filePath: path).lastPathComponent,
                          success: false, message: message)
        }
        guard WorktreeInspector.isWorktreeRoot(item.url) else {
            return [failure(item.path, "Refused: not the root of a git worktree.")]
        }
        let processes = await ProcessSnapshot.capture()
        var results: [CleanupResult] = []
        for candidate in await BuildArtifactLocator.candidates(in: item.url, git: git) {
            let artifact = candidate.url
            // Belt and braces: never operate outside the worktree.
            guard canonicalPath(artifact.path).hasPrefix(canonicalPath(item.path) + "/") else { continue }
            let name = String(artifact.path.dropFirst(item.path.count + 1))
            switch candidate.tracked {
            case .some(false):
                break
            case .some(true):
                results.append(failure(artifact.path, "Refused: \(name) contains files tracked by git."))
                continue
            case .none:
                results.append(failure(artifact.path, "Refused: could not verify that \(name) is untracked."))
                continue
            }
            if let refusal = await inUseRefusal(path: artifact.path, name: name, processes: processes) {
                results.append(failure(artifact.path, refusal))
                continue
            }
            results.append(trash(url: artifact, displayName: name, sizeBytes: nil))
        }
        if results.isEmpty {
            results.append(failure(item.path, "No build artifacts found to clean."))
        }
        return results
    }

    /// The one "is anything using this path" policy, shared by whole-item and
    /// artifact-only cleans. nil = free to remove; otherwise the refusal text.
    private func inUseRefusal(path: String, name: String, processes: ProcessSnapshot) async -> String? {
        if processes.referencesPath(path) {
            return "Refused: a running process references \(name)."
        }
        switch await Self.openFileCheck(path: path) {
        case .inUse(let programs):
            return "Refused: files in \(name) are open in \(programs.joined(separator: ", "))."
        case .unknown:
            return "Refused: could not verify that nothing has \(name) open. Try again in a moment."
        case .free:
            return nil
        }
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

    private func trash(_ item: ScanItem) -> CleanupResult {
        trash(url: item.url, displayName: item.displayName, sizeBytes: item.sizeBytes,
              companions: item.companionPaths, trashParentIfEmpty: item.trashParentIfEmpty)
    }

    private func trash(
        url: URL, displayName: String, sizeBytes: Int64?,
        companions: [String] = [], trashParentIfEmpty: Bool = false
    ) -> CleanupResult {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            for companion in companions where FileManager.default.fileExists(atPath: companion) {
                try? FileManager.default.trashItem(at: URL(filePath: companion), resultingItemURL: nil)
            }
            if trashParentIfEmpty {
                // Hidden droppings like .DS_Store don't count as contents.
                let parent = url.deletingLastPathComponent()
                if FileManager.default.contentsOfDirectoryIfPresent(parent).isEmpty {
                    try? FileManager.default.trashItem(at: parent, resultingItemURL: nil)
                }
            }
            if FileManager.default.fileExists(atPath: url.path) {
                return CleanupResult(path: url.path, displayName: displayName, success: false,
                                     message: "Trash operation reported success but the item still exists.")
            }
            return CleanupResult(path: url.path, displayName: displayName, success: true,
                                 message: "Moved to Trash.", freedBytes: sizeBytes)
        } catch {
            return CleanupResult(path: url.path, displayName: displayName, success: false,
                                 message: "Could not move to Trash: \(error.localizedDescription)")
        }
    }
}
