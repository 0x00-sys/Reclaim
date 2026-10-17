import Foundation

/// T3 Code keeps one git worktree per thread at <T3CODE_HOME>/worktrees/<project>/<name>
/// (default ~/.t3), scratch folders for project-less threads at scratch/<name>, and its
/// thread projections in userdata/statev2.sqlite (state.sqlite on older builds).
/// Layout per t3code apps/server/src/config.ts (deriveServerPaths).
///
/// Worktrees are enumerated from the directory layout rather than from git
/// registrations, so they are found even when the parent repository lives
/// outside the configured project roots.
public struct T3CodeScanner: StorageScanner {
    public let name = "T3 Code"

    public init() {}

    public func scan(context: ScanContext) async throws -> [ScanItem] {
        let fm = FileManager.default
        let root = context.environment["T3CODE_HOME"].map { URL(filePath: $0) }
            ?? context.home.appendingPathComponent(".t3")
        guard fm.directoryExists(root) else { return [] }

        let threads = T3ThreadIndex.load(databasePaths: Self.liveDatabases(root: root).map(\.path))
        let inspector = WorktreeInspector(git: context.git)
        var items: [ScanItem] = []

        // Usually worktrees/<project>/<name>, but some builds put the worktree
        // directly at worktrees/<name>. Never descend past a worktree root.
        let worktreesRoot = root.appendingPathComponent("worktrees")
        for outer in fm.contentsOfDirectoryIfPresent(worktreesRoot) where fm.directoryExists(outer) {
            let worktrees = WorktreeInspector.isWorktreeRoot(outer)
                ? [outer]
                : fm.contentsOfDirectoryIfPresent(outer).filter {
                    fm.directoryExists($0) && WorktreeInspector.isWorktreeRoot($0)
                }
            for worktree in worktrees {
                try Task.checkCancellation()
                // Canonical so this item replaces the generic git scanner's copy.
                let path = canonicalPath(worktree.path)
                let binding = threads[path]
                var item = try await inspector.scanItem(
                    at: URL(filePath: path),
                    tool: .t3Code,
                    displayName: worktree == outer
                        ? worktree.lastPathComponent
                        : "\(outer.lastPathComponent)/\(worktree.lastPathComponent)",
                    hasActiveProcess: context.processes.referencesPath(path),
                    cautionNote: binding.flatMap { Self.openThreadCaution($0, noun: "worktree") }
                )
                Self.annotate(&item, binding: binding)
                items.append(item)
            }
        }

        let scratchRoot = root.appendingPathComponent("scratch")
        // Empty scratch folders (only hidden files, if anything) are noise.
        for scratch in fm.contentsOfDirectoryIfPresent(scratchRoot)
        where fm.directoryExists(scratch) && !fm.contentsOfDirectoryIfPresent(scratch).isEmpty {
            try Task.checkCancellation()
            let path = canonicalPath(scratch.path)
            let binding = threads[path]
            var item = ScanItem(
                path: path,
                displayName: "Scratch: \(binding?.latestTitle ?? scratch.lastPathComponent)",
                tool: .t3Code,
                category: .toolSessions,
                lastActivity: latestModification(in: scratch, maxDepth: 1),
                hasActiveProcess: context.processes.referencesPath(path),
                cautionNote: binding.flatMap { Self.openThreadCaution($0, noun: "scratch folder") }
            )
            (item.safety, item.reasons) = Classifier.classify(item)
            item.reasons.append("Working folder of a project-less thread; holds whatever the agent created there.")
            Self.annotate(&item, binding: binding)
            items.append(item)
        }

        if let legacy = Self.legacyDatabase(root: root) {
            var item = ScanItem(
                path: legacy.path,
                displayName: "T3 Code legacy database (state.sqlite)",
                tool: .t3Code,
                category: .toolSessions,
                lastActivity: Self.modificationDate(legacy),
                hasActiveProcess: context.processes.referencesPath(legacy.path),
                cautionNote: "Older T3 Code builds still read state.sqlite; keep it if you might downgrade.",
                companionPaths: ["-wal", "-shm"].map { legacy.path + $0 }
            )
            (item.safety, item.reasons) = Classifier.classify(item)
            item.reasons.append("Superseded by statev2.sqlite, which this T3 Code version writes; untouched for days.")
            items.append(item)
        }
        return items
    }

    /// The databases the running T3 Code reads, per state directory (userdata,
    /// and dev for development builds). statev2 supersedes state.sqlite.
    static func liveDatabases(root: URL) -> [URL] {
        ["userdata", "dev"].compactMap { stateDir in
            let dir = root.appendingPathComponent(stateDir)
            return ["statev2.sqlite", "state.sqlite"]
                .map { dir.appendingPathComponent($0) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    /// userdata/state.sqlite counts as legacy only when statev2.sqlite exists,
    /// is newer, and state.sqlite has not been written for a week: a T3 Code
    /// build that still uses state.sqlite writes it constantly.
    static func legacyDatabase(root: URL, now: Date = .now) -> URL? {
        let dir = root.appendingPathComponent("userdata")
        let legacy = dir.appendingPathComponent("state.sqlite")
        let current = dir.appendingPathComponent("statev2.sqlite")
        guard let legacyDate = modificationDate(legacy),
              let currentDate = modificationDate(current),
              currentDate > legacyDate,
              now.timeIntervalSince(legacyDate) > 7 * 86_400
        else { return nil }
        // The WAL is written even when the main file is not.
        if let walDate = modificationDate(URL(filePath: legacy.path + "-wal")),
           now.timeIntervalSince(walDate) <= 7 * 86_400 {
            return nil
        }
        return legacy
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// An open thread used this recently still counts as live work. T3 Code
    /// users rarely archive, so "not archived" alone would protect everything.
    static let recentThreadWindow: TimeInterval = 14 * 86_400

    /// Open threads used within the window; unknown last-use counts as recent.
    static func recentOpenThreads(_ binding: T3Binding, now: Date = .now) -> [T3ThreadSummary] {
        binding.openThreads.filter { thread in
            thread.lastUsed.map { now.timeIntervalSince($0) < recentThreadWindow } ?? true
        }
    }

    /// Evidence, not verdict: the Classifier turns this into a Safe→Review demotion.
    static func openThreadCaution(_ binding: T3Binding, noun: String, now: Date = .now) -> String? {
        let recent = recentOpenThreads(binding, now: now)
        guard let newest = recent.first else { return nil }
        let one = recent.count == 1
        let threads = one ? "An open T3 Code thread" : "\(recent.count) recently used T3 Code threads"
        var note = "\(threads) (latest: “\(newest.title)”) use\(one ? "s" : "") this \(noun); removing it breaks \(one ? "that thread" : "them")."
        if noun == "worktree" {
            note += " Cleaning only its build artifacts keeps \(one ? "it" : "them") working."
        }
        return note
    }

    static func annotate(_ item: inout ScanItem, binding: T3Binding?, now: Date = .now) {
        guard let binding else {
            item.reasons.append("No T3 Code thread references this folder.")
            return
        }
        item.sessionTitle = binding.openThreads.first?.title ?? binding.latestTitle
        if let used = binding.lastUsed, used > (item.lastActivity ?? .distantPast) {
            item.lastActivity = used
        }
        if !binding.hasOpenThreads {
            item.reasons.append("Every T3 Code thread that used this folder is archived or deleted.")
        } else if recentOpenThreads(binding, now: now).isEmpty, let used = binding.openThreads.first?.lastUsed {
            let days = Int(now.timeIntervalSince(used) / 86_400)
            item.reasons.append("Its open T3 Code thread was last used \(days) days ago; reopening it later would find the worktree gone.")
        }
    }
}
