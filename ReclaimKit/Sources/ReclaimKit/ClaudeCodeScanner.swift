import Foundation

/// Claude Code's regenerable caches are table entries in DevCacheScanner; what
/// remains here is the project-transcript store, which needs its own wording.
public struct ClaudeCodeScanner: StorageScanner {
    public let name = "Claude Code"

    public init() {}

    public func scan(context: ScanContext) async throws -> [ScanItem] {
        let projects = context.home.appendingPathComponent(".claude/projects")
        guard FileManager.default.directoryExists(projects) else { return [] }
        var item = ScanItem(
            path: projects.path,
            displayName: "Claude Code project transcripts",
            tool: .claudeCode,
            category: .toolSessions,
            lastActivity: latestModification(in: projects, maxDepth: 1),
            hasActiveSession: context.processes.hasProcess(named: "claude")
        )
        (item.safety, item.reasons) = Classifier.classify(item)
        item.reasons.append("Claude Code trims these automatically after cleanupPeriodDays (default 30); `claude project purge` removes a project on demand.")
        return [item]
    }
}
