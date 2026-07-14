import Foundation

/// Codex (the OpenAI coding agent) keeps worktrees under ~/.codex/worktrees/<id>/<repo>,
/// session transcripts under sessions/, and several regenerable caches.
public struct CodexScanner: StorageScanner {
    public let name = "Codex"

    /// A session updated within this window counts as active even without a live process match.
    static let activeSessionWindow: TimeInterval = 30 * 60

    public init() {}

    public func scan(context: ScanContext) async throws -> [ScanItem] {
        let root = context.home.appendingPathComponent(".codex")
        guard FileManager.default.directoryExists(root) else { return [] }

        let codexRunning = context.processes.commandLines.contains {
            $0.contains("codex") && ($0.contains("app-server") || $0.contains("codex exec") || $0.hasSuffix("codex"))
        }
        let threads = CodexThreadIndex.load(databasePath: root.appendingPathComponent("state_5.sqlite").path)
        let inspector = WorktreeInspector(git: context.git)
        var items: [ScanItem] = []

        // Worktrees: an outer id dir usually wraps a single repo-named worktree,
        // but some entries are the worktree directly. Only directories whose own
        // root has a .git entry are worktrees; never descend past one.
        let worktreesRoot = root.appendingPathComponent("worktrees")
        for outer in FileManager.default.contentsOfDirectoryIfPresent(worktreesRoot) where FileManager.default.directoryExists(outer) {
            try Task.checkCancellation()
            let candidates: [URL]
            if WorktreeInspector.isWorktreeRoot(outer) {
                candidates = [outer]
            } else {
                candidates = FileManager.default.contentsOfDirectoryIfPresent(outer).filter {
                    FileManager.default.directoryExists($0) && WorktreeInspector.isWorktreeRoot($0)
                }
            }
            for inner in candidates {
                let thread = threads[inner.path] ?? threads[outer.path]
                let sessionRecent = (thread?.updatedAt).map {
                    Date.now.timeIntervalSince($0) < Self.activeSessionWindow
                } ?? false
                var item = try await inspector.scanItem(
                    at: inner,
                    tool: .codex,
                    displayName: inner == outer
                        ? inner.lastPathComponent
                        : "\(outer.lastPathComponent)/\(inner.lastPathComponent)",
                    hasActiveProcess: context.processes.referencesPath(inner.path),
                    hasActiveSession: codexRunning && sessionRecent && thread?.archived == false
                )
                if let thread {
                    if let updated = thread.updatedAt, updated > (item.lastActivity ?? .distantPast) {
                        item.lastActivity = updated
                    }
                    if thread.archived {
                        item.reasons.append("The Codex session for this worktree is archived.")
                    }
                } else {
                    item.reasons.append("No Codex session references this worktree.")
                }
                // Codex wraps most worktrees in an id directory; clean it up too.
                item.trashParentIfEmpty = inner != outer
                items.append(item)
            }
        }

        // Regenerable data. Everything here is recreated or only useful for debugging.
        let caches: [(relative: String, title: String, protectedWhileRunning: Bool, companionSuffixes: [String])] = [
            ("logs_2.sqlite", "Codex telemetry log", true, ["-wal", "-shm"]),
            ("sqlite", "Codex stale database snapshots", false, []),
            ("cache", "Codex cache", false, []),
            ("shell_snapshots", "Codex shell snapshots", false, []),
        ]
        for cache in caches {
            let url = root.appendingPathComponent(cache.relative)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var item = ScanItem(
                path: url.path,
                displayName: cache.title,
                tool: .codex,
                category: .toolCache,
                lastActivity: latestModification(in: url, maxDepth: 0),
                hasActiveProcess: codexRunning && cache.protectedWhileRunning,
                companionPaths: cache.companionSuffixes.map { url.path + $0 }
            )
            (item.safety, item.reasons) = Classifier.classify(item)
            items.append(item)
        }

        let sessions = root.appendingPathComponent("sessions")
        if FileManager.default.directoryExists(sessions) {
            var item = ScanItem(
                path: sessions.path,
                displayName: "Codex session transcripts",
                tool: .codex,
                category: .toolSessions,
                lastActivity: latestModification(in: sessions, maxDepth: 1),
                hasActiveSession: codexRunning
            )
            (item.safety, item.reasons) = Classifier.classify(item)
            items.append(item)
        }
        return items
    }
}
