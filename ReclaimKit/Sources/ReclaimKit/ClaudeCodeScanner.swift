import Foundation

/// Claude Code keeps everything in ~/.claude. Transcripts and memory are precious;
/// several cache directories are documented as regenerable.
public struct ClaudeCodeScanner: StorageScanner {
    public let name = "Claude Code"

    public init() {}

    public func scan(context: ScanContext) async throws -> [ScanItem] {
        let root = context.home.appendingPathComponent(".claude")
        guard context.fileManager.directoryExists(root) else { return [] }
        let claudeRunning = context.processes.hasProcess(named: "claude")
        var items: [ScanItem] = []

        let caches = ["cache", "image-cache", "paste-cache", "file-history", "backups", "shell-snapshots", "debug"]
        for name in caches {
            let url = root.appendingPathComponent(name)
            guard context.fileManager.directoryExists(url),
                  !context.fileManager.contentsOfDirectoryIfPresent(url).isEmpty
            else { continue }
            var item = ScanItem(
                path: url.path,
                displayName: "Claude Code \(name)",
                tool: .claudeCode,
                category: .toolCache,
                lastActivity: latestModification(in: url, maxDepth: 0),
                hasActiveProcess: claudeRunning
            )
            (item.safety, item.reasons) = Classifier.classify(item)
            if name == "file-history", item.safety == .safe {
                item.safety = .review
                item.reasons = ["Checkpoint snapshots used to rewind file edits; clearing removes the ability to restore past checkpoints."]
            }
            items.append(item)
        }

        let projects = root.appendingPathComponent("projects")
        if context.fileManager.directoryExists(projects) {
            var item = ScanItem(
                path: projects.path,
                displayName: "Claude Code project transcripts",
                tool: .claudeCode,
                category: .toolSessions,
                lastActivity: latestModification(in: projects, maxDepth: 1),
                hasActiveSession: claudeRunning
            )
            (item.safety, item.reasons) = Classifier.classify(item)
            item.reasons.append("Claude Code trims these automatically after cleanupPeriodDays (default 30); `claude project purge` removes a project on demand.")
            items.append(item)
        }
        return items
    }
}
