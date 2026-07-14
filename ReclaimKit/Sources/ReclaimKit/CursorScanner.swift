import Foundation

/// Cursor is Electron-based; its regenerable caches live in Application Support.
/// Cursor's own docs don't enumerate these paths, so they are flagged as community-verified.
public struct CursorScanner: StorageScanner {
    public let name = "Cursor"

    public init() {}

    public func scan(context: ScanContext) async throws -> [ScanItem] {
        let support = context.home.appendingPathComponent("Library/Application Support/Cursor")
        guard context.fileManager.directoryExists(support) else { return [] }
        let cursorRunning = context.processes.commandLines.contains { $0.contains("Cursor.app") }
        var items: [ScanItem] = []

        let caches = ["Cache", "CachedData", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", "CachedExtensionVSIXs", "logs", "Crashpad"]
        for name in caches {
            let url = support.appendingPathComponent(name)
            guard context.fileManager.directoryExists(url),
                  !context.fileManager.contentsOfDirectoryIfPresent(url).isEmpty
            else { continue }
            var item = ScanItem(
                path: url.path,
                displayName: "Cursor \(name)",
                tool: .cursor,
                category: .toolCache,
                lastActivity: latestModification(in: url, maxDepth: 0),
                hasActiveProcess: cursorRunning
            )
            (item.safety, item.reasons) = Classifier.classify(item)
            item.reasons.append("Standard Electron cache location; not documented by Cursor itself.")
            items.append(item)
        }
        // User/ (settings, chat history in globalStorage, workspaceStorage) is deliberately not listed:
        // clearing it loses chat history and preferences.
        return items
    }
}
