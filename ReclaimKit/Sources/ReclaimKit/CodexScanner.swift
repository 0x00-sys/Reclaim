import Foundation

/// Codex (the OpenAI coding agent) keeps worktrees under ~/.codex/worktrees/<id>/<repo>,
/// session transcripts under sessions/, and several regenerable caches.
public struct CodexScanner: StorageScanner {
    public let name = "Codex"

    public init() {}

    public func scan(context: ScanContext) async throws -> [ScanItem] {
        // Codex honors $CODEX_HOME; mirror it before assuming ~/.codex.
        let root = context.environment["CODEX_HOME"]
            .map { URL(filePath: $0) } ?? context.home.appendingPathComponent(".codex")
        guard FileManager.default.directoryExists(root) else { return [] }

        let codexRunning = context.processes.commandLines.contains {
            $0.contains("codex") && ($0.contains("app-server") || $0.contains("codex exec") || $0.hasSuffix("codex"))
        }
        let threads = CodexThreadIndex.load(databasePath: root.appendingPathComponent("state_5.sqlite").path)
        let sessionIndex = CodexSessionIndex.load(indexFile: root.appendingPathComponent("session_index.jsonl"))
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
                let session = CodexSessionIndex.threadID(forWorktree: inner).flatMap { sessionIndex[$0] }
                // The two stores can disagree; the newer timestamp wins so a
                // stale one never hides a live session.
                let lastSessionUpdate = [session?.updatedAt, thread?.updatedAt].compactMap { $0 }.max()
                let sessionRecent = lastSessionUpdate.map {
                    Date.now.timeIntervalSince($0) < agentSessionActivityWindow
                } ?? false
                var item = try await inspector.scanItem(
                    at: inner,
                    tool: .codex,
                    displayName: inner == outer
                        ? inner.lastPathComponent
                        : "\(outer.lastPathComponent)/\(inner.lastPathComponent)",
                    hasActiveProcess: context.processes.referencesPath(inner.path),
                    // archived != true: a missing sqlite row must not cancel the
                    // protection when the session index alone proved recency.
                    hasActiveSession: codexRunning && sessionRecent && thread?.archived != true
                )
                item.sessionTitle = session?.threadName
                if let updated = lastSessionUpdate, updated > (item.lastActivity ?? .distantPast) {
                    item.lastActivity = updated
                }
                if thread == nil && session == nil {
                    item.reasons.append("No Codex session references this worktree.")
                } else if thread?.archived == true {
                    item.reasons.append("The Codex session for this worktree is archived.")
                }
                // Codex wraps most worktrees in an id directory; clean it up too.
                item.trashParentIfEmpty = inner != outer
                items.append(item)
            }
        }

        // Regenerable data plus user content worth surfacing. All resolved
        // against the same root so CODEX_HOME has exactly one meaning.
        struct Cache {
            var relative: String
            var title: String
            var category: StorageCategory = .toolCache
            var protectedWhileRunning = false
            var companionSuffixes: [String] = []
            var note: String? = nil
        }
        let caches: [Cache] = [
            Cache(relative: "logs_2.sqlite", title: "Codex telemetry log",
                  protectedWhileRunning: true, companionSuffixes: ["-wal", "-shm"]),
            Cache(relative: "sqlite", title: "Codex stale database snapshots"),
            Cache(relative: "cache", title: "Codex cache"),
            Cache(relative: "shell_snapshots", title: "Codex shell snapshots"),
            Cache(relative: "generated_images", title: "Codex generated images", category: .toolSessions,
                  note: "Images you generated in Codex; not recoverable once deleted."),
            Cache(relative: "archived_sessions", title: "Codex archived sessions", category: .toolSessions),
        ]
        for cache in caches {
            let url = root.appendingPathComponent(cache.relative)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var item = ScanItem(
                path: url.path,
                displayName: cache.title,
                tool: .codex,
                category: cache.category,
                lastActivity: latestModification(in: url, maxDepth: 0),
                hasActiveProcess: codexRunning && cache.protectedWhileRunning,
                companionPaths: cache.companionSuffixes.map { url.path + $0 }
            )
            (item.safety, item.reasons) = Classifier.classify(item)
            if let note = cache.note {
                item.reasons.append(note)
            }
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
