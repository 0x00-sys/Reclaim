import Foundation

/// Finds top-level node_modules directories under the configured project roots.
public struct NodeModulesScanner: StorageScanner {
    public let name = "node_modules"
    public var maxDepth: Int

    public init(maxDepth: Int = 5) {
        self.maxDepth = maxDepth
    }

    public func scan(context: ScanContext) async throws -> [ScanItem] {
        var found: [URL] = []
        for root in context.projectRoots where context.fileManager.directoryExists(root) {
            try search(root, depth: 0, into: &found)
        }

        var items: [ScanItem] = []
        for url in found {
            try Task.checkCancellation()
            let project = url.deletingLastPathComponent()
            var item = ScanItem(
                path: url.path,
                displayName: project.lastPathComponent,
                tool: .npm,
                category: .nodeModules,
                lastActivity: latestModification(in: project, maxDepth: 1),
                hasActiveProcess: context.processes.referencesPath(project.path)
            )
            (item.safety, item.reasons) = Classifier.classify(item)
            items.append(item)
        }
        return items
    }

    private func search(_ url: URL, depth: Int, into found: inout [URL]) throws {
        try Task.checkCancellation()
        for child in FileManager.default.contentsOfDirectoryIfPresent(url) {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if child.lastPathComponent == "node_modules" {
                found.append(child)  // never descend into one
            } else if depth < maxDepth {
                try search(child, depth: depth + 1, into: &found)
            }
        }
    }
}
