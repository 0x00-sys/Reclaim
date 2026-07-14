import Foundation

public struct ScanContext: Sendable {
    public var home: URL
    public var git: GitClient
    public var processes: ProcessSnapshot
    /// Directories the user wants scanned for repositories and node_modules.
    public var projectRoots: [URL]
    public var fileManager: FileManager { .default }

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        git: GitClient = GitClient(),
        processes: ProcessSnapshot = ProcessSnapshot(commandLines: []),
        projectRoots: [URL] = []
    ) {
        self.home = home
        self.git = git
        self.processes = processes
        self.projectRoots = projectRoots
    }
}

public protocol StorageScanner: Sendable {
    var name: String { get }
    func scan(context: ScanContext) async throws -> [ScanItem]
}

extension FileManager {
    func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func contentsOfDirectoryIfPresent(_ url: URL) -> [URL] {
        (try? contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }
}

/// Tool-specific scanners know more than the generic git scanner; when both report
/// the same path, keep the tool-specific item.
public func deduplicateScanItems(_ items: [ScanItem]) -> [ScanItem] {
    var byPath: [String: ScanItem] = [:]
    var order: [String] = []
    for item in items {
        if let existing = byPath[item.path] {
            if existing.tool == .git && item.tool != .git {
                byPath[item.path] = item
            }
        } else {
            byPath[item.path] = item
            order.append(item.path)
        }
    }
    return order.compactMap { byPath[$0] }
}

/// Symlink-resolved absolute path (git always reports canonical paths; /tmp and /var are symlinks on macOS).
func canonicalPath(_ path: String) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard let resolved = realpath(path, &buffer) else { return path }
    return String(cString: resolved)
}

func latestModification(in url: URL, maxDepth: Int = 2) -> Date? {
    // A cheap "last touched" signal: newest mtime among the first two levels.
    var newest: Date? = nil
    func visit(_ current: URL, depth: Int) {
        guard let values = try? current.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]) else { return }
        if let date = values.contentModificationDate, date > (newest ?? .distantPast) {
            newest = date
        }
        guard depth < maxDepth, values.isDirectory == true else { return }
        for child in FileManager.default.contentsOfDirectoryIfPresent(current) {
            visit(child, depth: depth + 1)
        }
    }
    visit(url, depth: 0)
    return newest
}
