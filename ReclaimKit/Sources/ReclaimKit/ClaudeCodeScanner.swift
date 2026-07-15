import Foundation

/// Claude Code's regenerable caches are table entries in DevCacheScanner; this
/// scanner owns the per-project transcript store and the config backup files.
///
/// ~/.claude/projects contains one directory per project the user opened Claude
/// in, named by a lossy encoding of the project path (every character outside
/// [A-Za-z0-9] becomes "-"). A transcript directory whose source project no
/// longer exists on disk is dead weight and safe to clean; one whose project
/// still exists stays review-only. Because the encoding is lossy ("my-repo" and
/// "my/repo" encode identically), directory names are resolved against the raw
/// project paths recorded in ~/.claude.json rather than decoded blindly; the
/// naive decode is only trusted when the decoded path actually exists.
public struct ClaudeCodeScanner: StorageScanner {
    public let name = "Claude Code"

    public init() {}

    public func scan(context: ScanContext) async throws -> [ScanItem] {
        let root = context.home.appendingPathComponent(".claude")
        guard FileManager.default.directoryExists(root) else { return [] }

        var items: [ScanItem] = []
        items += projectItems(root: root, home: context.home, processes: context.processes)
        items += configBackupItems(home: context.home)
        return items
    }

    private func projectItems(root: URL, home: URL, processes: ProcessSnapshot) -> [ScanItem] {
        let claudeRunning = processes.hasProcess(named: "claude")
        let projectsRoot = root.appendingPathComponent("projects")
        let knownPaths = Self.knownProjectPaths(configFile: home.appendingPathComponent(".claude.json"))
        // The encoding is lossy, so several raw paths can share one encoded name;
        // keep them all and let resolution consider every candidate.
        let encodedToRaw = Dictionary(grouping: knownPaths, by: Self.encode)

        var items: [ScanItem] = []
        for dir in FileManager.default.contentsOfDirectoryIfPresent(projectsRoot)
        where FileManager.default.directoryExists(dir) {
            let resolution = Self.resolveProjectPath(
                encodedName: dir.lastPathComponent, encodedToRaw: encodedToRaw
            )
            let lastActivity = latestModification(in: dir, maxDepth: 1)
            let sessionRecent = lastActivity.map {
                Date.now.timeIntervalSince($0) < agentSessionActivityWindow
            } ?? false

            // A claude process whose working directory is inside the source
            // project protects its transcripts even when writes are sparse.
            let processInProject = resolution.path.map { processes.referencesPath($0) } ?? false
            var item = ScanItem(
                path: dir.path,
                displayName: "Transcripts: \((resolution.path.map { URL(filePath: $0).lastPathComponent }) ?? dir.lastPathComponent)",
                tool: .claudeCode,
                category: .toolSessions,
                lastActivity: lastActivity,
                hasActiveProcess: processInProject,
                hasActiveSession: claudeRunning && sessionRecent
            )
            (item.safety, item.reasons) = Classifier.classify(item)
            switch resolution {
            case .orphaned(let path):
                if item.safety == .review {
                    item.safety = .safe
                    item.reasons = ["The project (\(path)) no longer exists on disk; nothing can open these transcripts from Claude Code."]
                }
            case .live(let path):
                item.reasons.append("Session history for \(path), which still exists.")
            case .unresolved:
                item.reasons.append("Could not map this directory back to a project path; treat as history worth reviewing.")
            }
            item.reasons.append("Claude Code trims these automatically after cleanupPeriodDays (default 30); `claude project purge` removes a project on demand.")
            items.append(item)
        }
        return items
    }

    /// ~/.claude.json.backup* files live in the home directory itself and are
    /// pure dead weight once Claude has a healthy current config.
    private func configBackupItems(home: URL) -> [ScanItem] {
        var items: [ScanItem] = []
        for file in FileManager.default.contentsOfDirectoryIfPresent(home, includeHidden: true)
        where file.lastPathComponent.hasPrefix(".claude.json.backup") {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            var item = ScanItem(
                path: file.path,
                displayName: "Claude Code config backup (\(file.lastPathComponent))",
                tool: .claudeCode,
                category: .toolCache,
                sizeBytes: (values?.fileSize).map(Int64.init),
                lastActivity: values?.contentModificationDate
            )
            (item.safety, item.reasons) = Classifier.classify(item)
            item.reasons.append("Automatic backup of ~/.claude.json; the live config is untouched.")
            items.append(item)
        }
        return items
    }

    enum ProjectResolution {
        case live(String)
        case orphaned(String)
        case unresolved

        var path: String? {
            switch self {
            case .live(let path), .orphaned(let path): path
            case .unresolved: nil
            }
        }
    }

    /// Claude Code's project-directory encoding: every character outside
    /// [A-Za-z0-9] collapses to "-". Lossy, so only used for matching known paths.
    static func encode(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    static func resolveProjectPath(
        encodedName: String,
        encodedToRaw: [String: [String]],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> ProjectResolution {
        if let candidates = encodedToRaw[encodedName], !candidates.isEmpty {
            // The encoding is lossy, so several raw paths can share this name;
            // ANY of them existing keeps the transcripts alive.
            // exists(atPath:) follows symlinks: a symlinked-but-alive project is live.
            if let alive = candidates.first(where: fileExists) {
                return .live(alive)
            }
            // A path on an unmounted or disconnected volume is absent, not
            // deleted; never promote those to orphaned.
            if candidates.contains(where: { $0.hasPrefix("/Volumes/") }) {
                return .unresolved
            }
            return .orphaned(candidates[0])
        }
        // Fallback decode assumes no dashes in the original path; only trust it
        // when the decoded path is actually there. A missing decoded path proves
        // nothing (the real path may have contained "-"), so never call it orphaned.
        let decoded = encodedName.replacingOccurrences(of: "-", with: "/")
        if !decoded.isEmpty, fileExists(decoded) {
            return .live(decoded)
        }
        return .unresolved
    }

    /// Raw project paths from ~/.claude.json's top-level "projects" object.
    static func knownProjectPaths(configFile: URL) -> [String] {
        guard let data = try? Data(contentsOf: configFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [String: Any]
        else { return [] }
        return Array(projects.keys)
    }
}
