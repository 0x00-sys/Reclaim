import Foundation

/// npm and pnpm caches and stores.
public struct PackageCacheScanner: StorageScanner {
    public let name = "Package caches"

    public init() {}

    public func scan(context: ScanContext) async throws -> [ScanItem] {
        let home = context.home
        let candidates: [(URL, Tool, String)] = [
            (home.appendingPathComponent(".npm/_cacache"), .npm, "npm cache"),
            (home.appendingPathComponent("Library/Caches/pnpm"), .pnpm, "pnpm metadata cache"),
            (home.appendingPathComponent("Library/pnpm/store"), .pnpm, "pnpm content-addressed store"),
        ]
        var items: [ScanItem] = []
        for (url, tool, title) in candidates where context.fileManager.directoryExists(url) {
            let busy = context.processes.hasProcess(named: tool == .npm ? "npm" : "pnpm")
            var item = ScanItem(
                path: url.path,
                displayName: title,
                tool: tool,
                category: .packageCache,
                lastActivity: latestModification(in: url, maxDepth: 1),
                hasActiveProcess: busy
            )
            (item.safety, item.reasons) = Classifier.classify(item)
            if tool == .pnpm && url.lastPathComponent == "store" {
                item.reasons.append("Deleting the whole store is safe but slows the next install; `pnpm store prune` removes only unreferenced packages.")
            }
            items.append(item)
        }
        return items
    }
}
