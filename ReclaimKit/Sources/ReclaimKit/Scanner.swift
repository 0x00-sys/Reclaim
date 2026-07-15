import Foundation

/// One product-level threshold for "an agent session touched this recently
/// enough to count as active"; every agent scanner shares it.
let agentSessionActivityWindow: TimeInterval = 30 * 60

public struct ScanContext: Sendable {
    public var home: URL
    public var git: GitClient
    public var processes: ProcessSnapshot
    /// Directories the user wants scanned for repositories and node_modules.
    public var projectRoots: [URL]
    /// Injected so env-honoring scanners (CODEX_HOME) stay fixture-testable.
    public var environment: [String: String]

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        git: GitClient = GitClient(),
        processes: ProcessSnapshot = ProcessSnapshot(commandLines: []),
        projectRoots: [URL] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.home = home
        self.git = git
        self.processes = processes
        self.projectRoots = projectRoots
        self.environment = environment
    }
}

public protocol StorageScanner: Sendable {
    var name: String { get }
    func scan(context: ScanContext) async throws -> [ScanItem]
}

/// The one scanner roster shared by the app and the CLI. The Tool tags drive
/// the notch sprite while that scanner runs.
public let defaultScanners: [(scanner: any StorageScanner, tool: Tool?)] = [
    (CodexScanner(), .codex),
    (ConductorScanner(), .conductor),
    (RepoWorktreeScanner(), .git),
    (NodeModulesScanner(), .npm),
    (DevCacheScanner(), nil),
    (XcodeScanner(), .xcode),
    (ClaudeCodeScanner(), .claudeCode),
    (InstallerScanner(), .installer),
]

extension FileManager {
    func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func contentsOfDirectoryIfPresent(_ url: URL, includeHidden: Bool = false) -> [URL] {
        (try? contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: includeHidden ? [] : [.skipsHiddenFiles]
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
