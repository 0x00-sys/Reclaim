import Foundation

/// Finds regenerable build-artifact directories inside a worktree so they can
/// be cleaned on their own, even when the worktree itself is protected. The
/// project-type table follows codex-clean's scheme; the tracked-files guard at
/// cleanup time (CleanupEngine) is what makes the generic fallback names safe.
public enum BuildArtifactLocator {
    /// Marker file at the worktree root -> artifact directory names to hunt for.
    /// Framework caches come from NodeModulesScanner's table so the global scan
    /// and the per-worktree artifact clean never disagree about what counts.
    static let markers: [(file: String, artifacts: [String])] = [
        ("Cargo.toml", ["target"]),
        ("go.mod", ["vendor"]),
        ("package.json", ["node_modules", "dist", "build", ".cache"] + NodeModulesScanner.buildDirectories.keys.sorted()),
        ("pyproject.toml", [".venv", "__pycache__", ".pytest_cache", ".ruff_cache"]),
        ("setup.py", [".venv", "__pycache__", ".pytest_cache", ".ruff_cache"]),
        ("requirements.txt", [".venv", "__pycache__", ".pytest_cache", ".ruff_cache"]),
    ]
    /// No marker matched: cast a wide net; the cleanup-time guard rejects
    /// anything containing tracked files.
    static let fallbackArtifacts = ["target", "node_modules", ".venv", "__pycache__", "build", "dist"]

    public static func artifactNames(projectRoot: URL) -> [String] {
        var names: [String] = []
        for marker in markers
        where FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(marker.file).path) {
            names += marker.artifacts.filter { !names.contains($0) }
        }
        return names.isEmpty ? fallbackArtifacts : names
    }

    /// The one entry point pairing located artifact directories with their
    /// git-tracked state (true/false/nil = unknown), so the scan-time
    /// advertisement and the clean-time guard can never disagree. One git
    /// subprocess per worktree, not per candidate.
    public static func candidates(in root: URL, git: GitClient) async -> [(url: URL, tracked: Bool?)] {
        let located = locate(in: root)
        guard !located.isEmpty else { return [] }
        let tracked = try? await git.trackedFiles(under: located.map(\.path), workingTree: root.path)
        // ls-files reports paths relative to the worktree root; compare in
        // canonical form (contentsOfDirectory resolves /var -> /private/var,
        // the caller's root may not). A prefix mismatch means "unknown", which
        // destructive callers must treat as tracked.
        let rootCanonical = canonicalPath(root.path)
        return located.map { url in
            guard let tracked else { return (url, nil) }
            let urlCanonical = canonicalPath(url.path)
            guard urlCanonical.hasPrefix(rootCanonical + "/") else { return (url, nil) }
            let relative = String(urlCanonical.dropFirst(rootCanonical.count + 1))
            return (url, tracked.contains { $0 == relative || $0.hasPrefix(relative + "/") })
        }
    }

    /// Directories matching the artifact names, searched to a bounded depth.
    /// A match is pruned (never descended into), symlinks are never followed,
    /// and .git is skipped entirely.
    public static func locate(in root: URL, maxDepth: Int = 5) -> [URL] {
        let names = Set(artifactNames(projectRoot: root))
        var found: [URL] = []
        func visit(_ directory: URL, depth: Int) {
            for child in FileManager.default.contentsOfDirectoryIfPresent(directory, includeHidden: true) {
                let name = child.lastPathComponent
                if name == ".git" { continue }
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true
                else { continue }
                if names.contains(name) {
                    found.append(child)
                } else if depth < maxDepth {
                    visit(child, depth: depth + 1)
                }
            }
        }
        visit(root, depth: 1)
        return found.sorted { $0.path < $1.path }
    }
}
