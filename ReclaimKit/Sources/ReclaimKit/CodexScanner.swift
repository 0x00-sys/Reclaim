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
        guard context.fileManager.directoryExists(root) else { return [] }

        let codexRunning = context.processes.commandLines.contains {
            $0.contains("codex") && ($0.contains("app-server") || $0.contains("codex exec") || $0.hasSuffix("codex"))
        }
        let threads = CodexThreadIndex.load(databasePath: root.appendingPathComponent("state_5.sqlite").path)
        let inspector = WorktreeInspector(git: context.git)
        var items: [ScanItem] = []

        // Worktrees: outer id dir wraps a single repo-named worktree.
        let worktreesRoot = root.appendingPathComponent("worktrees")
        for outer in context.fileManager.contentsOfDirectoryIfPresent(worktreesRoot) where context.fileManager.directoryExists(outer) {
            try Task.checkCancellation()
            for inner in context.fileManager.contentsOfDirectoryIfPresent(outer) where context.fileManager.directoryExists(inner) {
                let thread = threads[inner.path] ?? threads[outer.path]
                let sessionRecent = (thread?.updatedAt).map {
                    Date.now.timeIntervalSince($0) < Self.activeSessionWindow
                } ?? false
                var item = try await inspector.scanItem(
                    at: inner,
                    tool: .codex,
                    displayName: "\(outer.lastPathComponent)/\(inner.lastPathComponent)",
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
                items.append(item)
            }
        }

        // Regenerable data. Everything here is recreated or only useful for debugging.
        let caches: [(String, String)] = [
            ("logs_2.sqlite", "Codex telemetry log"),
            ("sqlite", "Codex stale database snapshots"),
            ("cache", "Codex cache"),
            ("shell_snapshots", "Codex shell snapshots"),
        ]
        for (relative, title) in caches {
            let url = root.appendingPathComponent(relative)
            guard context.fileManager.fileExists(atPath: url.path) else { continue }
            var item = ScanItem(
                path: url.path,
                displayName: title,
                tool: .codex,
                category: .toolCache,
                lastActivity: latestModification(in: url, maxDepth: 0),
                hasActiveProcess: codexRunning && relative == "logs_2.sqlite"
            )
            (item.safety, item.reasons) = Classifier.classify(item)
            items.append(item)
        }

        let sessions = root.appendingPathComponent("sessions")
        if context.fileManager.directoryExists(sessions) {
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
