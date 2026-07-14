import Foundation

/// Regenerable caches from the wider development toolchain (Go, Bun, Homebrew,
/// Playwright, npx, …) plus Codex user-content directories worth reviewing.
public struct DevCacheScanner: StorageScanner {
    public let name = "Developer caches"

    public init() {}

    struct Entry {
        var relativePath: String
        var tool: Tool
        var title: String
        var category: StorageCategory
        var note: String?
        var processHint: String?
        /// Additional daemons that hold these files open (e.g. editor language servers).
        var daemonHints: [String] = []
        /// Demotes an otherwise-safe verdict to Review (applied by the Classifier).
        var caution: String? = nil
        /// How deep to look for the newest mtime; caches whose root mtime never
        /// changes (npm/pnpm content stores) need one level of depth.
        var activityDepth: Int = 0
    }

    static let entries: [Entry] = {
        var list: [Entry] = [
            // Package managers
            Entry(relativePath: ".npm/_cacache", tool: .npm, title: "npm cache",
                  category: .packageCache, note: nil, processHint: "npm", activityDepth: 1),
            Entry(relativePath: "Library/Caches/pnpm", tool: .pnpm, title: "pnpm metadata cache",
                  category: .packageCache, note: nil, processHint: "pnpm", activityDepth: 1),
            Entry(relativePath: "Library/pnpm/store", tool: .pnpm, title: "pnpm content-addressed store",
                  category: .packageCache,
                  note: "Deleting the whole store is safe but slows the next install; `pnpm store prune` removes only unreferenced packages.",
                  processHint: "pnpm", activityDepth: 1),
        ]

        // Claude Code regenerable data
        for name in ["cache", "image-cache", "paste-cache", "backups", "shell-snapshots", "debug"] {
            list.append(Entry(relativePath: ".claude/\(name)", tool: .claudeCode,
                              title: "Claude Code \(name)", category: .toolCache,
                              note: nil, processHint: "claude"))
        }
        list.append(Entry(relativePath: ".claude/file-history", tool: .claudeCode,
                          title: "Claude Code file-history", category: .toolCache,
                          note: nil, processHint: "claude",
                          caution: "Checkpoint snapshots used to rewind file edits; clearing removes the ability to restore past checkpoints."))

        // Cursor (Electron caches; paths are community-verified, not vendor-documented)
        let cursorNote = "Standard Electron cache location; not documented by Cursor itself."
        for name in ["Cache", "CachedData", "Code Cache", "GPUCache", "DawnGraphiteCache",
                     "DawnWebGPUCache", "CachedExtensionVSIXs", "logs", "Crashpad"] {
            list.append(Entry(relativePath: "Library/Application Support/Cursor/\(name)", tool: .cursor,
                              title: "Cursor \(name)", category: .toolCache,
                              note: cursorNote, processHint: "Cursor"))
        }

        list += [
            Entry(relativePath: "Library/Caches/go-build", tool: .go, title: "Go build cache",
                  category: .packageCache, note: "`go clean -cache` is the official way; rebuilt on the next build.", processHint: "go", daemonHints: ["gopls", "golangci-lint"]),
            Entry(relativePath: "go/pkg/mod", tool: .go, title: "Go module cache",
                  category: .packageCache, note: "Modules are re-downloaded on demand. Prefer `go clean -modcache`: the cache is write-protected and trashing it can fail.", processHint: "go", daemonHints: ["gopls", "golangci-lint"]),
            Entry(relativePath: "Library/Caches/ms-playwright", tool: .playwright, title: "Playwright browsers",
                  category: .toolCache, note: "Browsers are re-downloaded by `npx playwright install`.", processHint: "playwright"),
            Entry(relativePath: ".bun/install/cache", tool: .bun, title: "Bun install cache",
                  category: .packageCache, note: nil, processHint: "bun"),
            Entry(relativePath: ".npm/_npx", tool: .npm, title: "npx package cache",
                  category: .packageCache, note: nil, processHint: "npx"),
            Entry(relativePath: "Library/Caches/Homebrew", tool: .homebrew, title: "Homebrew downloads",
                  category: .packageCache, note: "`brew cleanup` also trims this.", processHint: "brew"),
            Entry(relativePath: "Library/Caches/pip", tool: .pip, title: "pip cache",
                  category: .packageCache, note: nil, processHint: "pip"),
            Entry(relativePath: "Library/Caches/typescript", tool: .npm, title: "TypeScript server cache",
                  category: .toolCache, note: nil, processHint: "tsserver"),
            Entry(relativePath: "Library/Caches/node-gyp", tool: .npm, title: "node-gyp headers",
                  category: .toolCache, note: nil, processHint: "node-gyp"),
            Entry(relativePath: "Library/Caches/electron", tool: .npm, title: "Electron binaries cache",
                  category: .toolCache, note: nil, processHint: "electron"),
            Entry(relativePath: "Library/Caches/deno", tool: .deno, title: "Deno cache",
                  category: .packageCache, note: nil, processHint: "deno"),
            Entry(relativePath: ".gradle/caches", tool: .gradle, title: "Gradle caches",
                  category: .packageCache, note: nil, processHint: "gradle"),
            Entry(relativePath: "Library/Caches/CocoaPods", tool: .cocoapods, title: "CocoaPods cache",
                  category: .packageCache, note: nil, processHint: "pod"),
            // Codex user content: never "safe", but worth surfacing.
            Entry(relativePath: ".codex/generated_images", tool: .codex, title: "Codex generated images",
                  category: .toolSessions, note: "Images you generated in Codex; not recoverable once deleted.", processHint: nil),
            Entry(relativePath: ".codex/archived_sessions", tool: .codex, title: "Codex archived sessions",
                  category: .toolSessions, note: nil, processHint: nil),
        ]
        return list
    }()

    public func scan(context: ScanContext) async throws -> [ScanItem] {
        var items: [ScanItem] = []
        for entry in Self.entries {
            try Task.checkCancellation()
            let url = context.home.appendingPathComponent(entry.relativePath)
            guard FileManager.default.directoryExists(url),
                  !FileManager.default.contentsOfDirectoryIfPresent(url).isEmpty
            else { continue }
            var item = ScanItem(
                path: url.path,
                displayName: entry.title,
                tool: entry.tool,
                category: entry.category,
                lastActivity: latestModification(in: url, maxDepth: entry.activityDepth),
                hasActiveProcess: ([entry.processHint].compactMap { $0 } + entry.daemonHints)
                    .contains { context.processes.hasProcess(named: $0) },
                cautionNote: entry.caution
            )
            (item.safety, item.reasons) = Classifier.classify(item)
            if let note = entry.note {
                item.reasons.append(note)
            }
            items.append(item)
        }
        return items
    }
}
