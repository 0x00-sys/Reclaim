import Foundation

/// Conductor keeps one git worktree per workspace at ~/conductor/workspaces/<repo>/<city>,
/// with branch-named symlinks pointing at the active ones.
public struct ConductorScanner: StorageScanner {
    public let name = "Conductor"

    public init() {}

    public func scan(context: ScanContext) async throws -> [ScanItem] {
        let fm = FileManager.default
        let workspaces = context.home.appendingPathComponent("conductor/workspaces")
        guard fm.directoryExists(workspaces) else { return [] }

        let conductorRunning = context.processes.hasProcess(named: "Conductor")
            || context.processes.commandLines.contains { $0.contains("Conductor.app") }
        let inspector = WorktreeInspector(git: context.git)
        var items: [ScanItem] = []

        for repoDir in fm.contentsOfDirectoryIfPresent(workspaces) where fm.directoryExists(repoDir) {
            // Branch-name symlinks alias live workspaces; collect their targets.
            var aliasedTargets: Set<String> = []
            var workspaceDirs: [URL] = []
            for entry in fm.contentsOfDirectoryIfPresent(repoDir) {
                if let destination = try? fm.destinationOfSymbolicLink(atPath: entry.path) {
                    aliasedTargets.insert(
                        URL(filePath: destination, relativeTo: repoDir).standardizedFileURL.lastPathComponent
                    )
                } else if fm.directoryExists(entry), WorktreeInspector.isWorktreeRoot(entry) {
                    workspaceDirs.append(entry)
                }
            }

            for workspace in workspaceDirs {
                try Task.checkCancellation()
                let hasAlias = aliasedTargets.contains(workspace.lastPathComponent)
                var item = try await inspector.scanItem(
                    at: workspace,
                    tool: .conductor,
                    displayName: "\(repoDir.lastPathComponent)/\(workspace.lastPathComponent)",
                    hasActiveProcess: context.processes.referencesPath(workspace.path),
                    hasActiveSession: conductorRunning && hasAlias
                )
                if hasAlias && !conductorRunning {
                    // Evidence, not verdict: the Classifier owns the demotion rule.
                    item.cautionNote = "A branch symlink still points at this workspace."
                    (item.safety, item.reasons) = Classifier.classify(item)
                }
                items.append(item)
            }
        }

        let archivedContexts = context.home.appendingPathComponent("conductor/archived-contexts")
        if fm.directoryExists(archivedContexts) {
            var item = ScanItem(
                path: archivedContexts.path,
                displayName: "Conductor archived contexts",
                tool: .conductor,
                category: .toolSessions,
                lastActivity: latestModification(in: archivedContexts, maxDepth: 1)
            )
            (item.safety, item.reasons) = Classifier.classify(item)
            item.reasons.append("Contains notes, todos, and plans from archived workspaces — no code.")
            items.append(item)
        }
        return items
    }
}
