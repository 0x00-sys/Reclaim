import Foundation

/// Finds git repositories under the user's project roots and lists their linked
/// worktrees, including ones created by tools we don't otherwise know about.
public struct RepoWorktreeScanner: StorageScanner {
    public let name = "Git worktrees"
    public var maxDepth: Int

    public init(maxDepth: Int = 3) {
        self.maxDepth = maxDepth
    }

    public func scan(context: ScanContext) async throws -> [ScanItem] {
        var repos: [URL] = []
        for root in context.projectRoots where context.fileManager.directoryExists(root) {
            findRepos(root, depth: 0, into: &repos)
        }

        let inspector = WorktreeInspector(git: context.git)
        var items: [ScanItem] = []
        var seen: Set<String> = []
        for repo in repos {
            try Task.checkCancellation()
            var entries = (try? await context.git.listWorktrees(repository: repo.path)) ?? []
            if !entries.isEmpty { entries.removeFirst() } // first entry is the main worktree
            // Claude Code puts per-project worktrees in <repo>/.claude/worktrees;
            // include any that lost their registration (orphans) too.
            let claudeWorktrees = context.fileManager.contentsOfDirectoryIfPresent(
                repo.appendingPathComponent(".claude/worktrees"), includeHidden: true
            )
            for orphan in claudeWorktrees
            where context.fileManager.directoryExists(orphan)
                && !entries.contains(where: { canonicalPath($0.path) == canonicalPath(orphan.path) }) {
                entries.append(GitWorktreeEntry(path: orphan.path, head: nil, branch: nil,
                                                isMain: false, isLocked: false, isPrunable: false))
            }
            for entry in entries {
                guard !seen.contains(entry.path) else { continue }
                seen.insert(entry.path)
                guard context.fileManager.directoryExists(URL(filePath: entry.path)) else {
                    // Registration whose directory is gone: prunable, zero bytes, pure hygiene.
                    items.append(ScanItem(
                        path: entry.path,
                        displayName: "\(repo.lastPathComponent): stale registration (\(URL(filePath: entry.path).lastPathComponent))",
                        tool: .git,
                        category: .worktree,
                        sizeBytes: 0,
                        worktree: WorktreeState(repositoryPath: repo.path, branch: entry.branch, isRegistered: true, isPrunable: true),
                        safety: .safe,
                        reasons: ["The worktree directory no longer exists; only the registration in \(repo.lastPathComponent)/.git remains."]
                    ))
                    continue
                }
                let isClaude = entry.path.contains("/.claude/worktrees/")
                let item = try await inspector.scanItem(
                    at: URL(filePath: entry.path),
                    tool: isClaude ? .claudeCode : .git,
                    displayName: "\(repo.lastPathComponent): \(URL(filePath: entry.path).lastPathComponent)",
                    hasActiveProcess: context.processes.referencesPath(entry.path)
                )
                items.append(item)
            }
        }
        return items
    }

    private func findRepos(_ url: URL, depth: Int, into repos: inout [URL]) {
        if WorktreeInspector.isMainRepository(url) {
            repos.append(url)
            return // don't look for nested repos
        }
        guard depth < maxDepth else { return }
        for child in FileManager.default.contentsOfDirectoryIfPresent(url)
        where (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if child.lastPathComponent == "node_modules" { continue }
            findRepos(child, depth: depth + 1, into: &repos)
        }
    }
}
