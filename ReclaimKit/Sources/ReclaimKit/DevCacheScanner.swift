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
    }

    static let entries: [Entry] = [
        // Package managers
        Entry(relativePath: ".npm/_cacache", tool: .npm, title: "npm cache",
              category: .packageCache, note: nil, processHint: "npm"),
        Entry(relativePath: "Library/Caches/pnpm", tool: .pnpm, title: "pnpm metadata cache",
              category: .packageCache, note: nil, processHint: "pnpm"),
        Entry(relativePath: "Library/pnpm/store", tool: .pnpm, title: "pnpm content-addressed store",
              category: .packageCache,
              note: "Deleting the whole store is safe but slows the next install; `pnpm store prune` removes only unreferenced packages.",
              processHint: "pnpm"),
        // Claude Code regenerable data
        Entry(relativePath: ".claude/cache", tool: .claudeCode, title: "Claude Code cache",
              category: .toolCache, note: nil, processHint: "claude"),
        Entry(relativePath: ".claude/image-cache", tool: .claudeCode, title: "Claude Code image-cache",
              category: .toolCache, note: nil, processHint: "claude"),
        Entry(relativePath: ".claude/paste-cache", tool: .claudeCode, title: "Claude Code paste-cache",
              category: .toolCache, note: nil, processHint: "claude"),
        Entry(relativePath: ".claude/backups", tool: .claudeCode, title: "Claude Code backups",
              category: .toolCache, note: nil, processHint: "claude"),
        Entry(relativePath: ".claude/shell-snapshots", tool: .claudeCode, title: "Claude Code shell-snapshots",
              category: .toolCache, note: nil, processHint: "claude"),
        Entry(relativePath: ".claude/debug", tool: .claudeCode, title: "Claude Code debug logs",
              category: .toolCache, note: nil, processHint: "claude"),
        Entry(relativePath: ".claude/file-history", tool: .claudeCode, title: "Claude Code file-history",
              category: .toolCache, note: nil, processHint: "claude",
              caution: "Checkpoint snapshots used to rewind file edits; clearing removes the ability to restore past checkpoints."),
        // Cursor (Electron caches; paths are community-verified, not vendor-documented)
        Entry(relativePath: "Library/Application Support/Cursor/Cache", tool: .cursor, title: "Cursor Cache",
              category: .toolCache, note: "Standard Electron cache location; not documented by Cursor itself.", processHint: "Cursor"),
        Entry(relativePath: "Library/Application Support/Cursor/CachedData", tool: .cursor, title: "Cursor CachedData",
              category: .toolCache, note: "Standard Electron cache location; not documented by Cursor itself.", processHint: "Cursor"),
        Entry(relativePath: "Library/Application Support/Cursor/Code Cache", tool: .cursor, title: "Cursor Code Cache",
              category: .toolCache, note: "Standard Electron cache location; not documented by Cursor itself.", processHint: "Cursor"),
        Entry(relativePath: "Library/Application Support/Cursor/GPUCache", tool: .cursor, title: "Cursor GPUCache",
              category: .toolCache, note: "Standard Electron cache location; not documented by Cursor itself.", processHint: "Cursor"),
        Entry(relativePath: "Library/Application Support/Cursor/DawnGraphiteCache", tool: .cursor, title: "Cursor DawnGraphiteCache",
              category: .toolCache, note: "Standard Electron cache location; not documented by Cursor itself.", processHint: "Cursor"),
        Entry(relativePath: "Library/Application Support/Cursor/DawnWebGPUCache", tool: .cursor, title: "Cursor DawnWebGPUCache",
              category: .toolCache, note: "Standard Electron cache location; not documented by Cursor itself.", processHint: "Cursor"),
        Entry(relativePath: "Library/Application Support/Cursor/CachedExtensionVSIXs", tool: .cursor, title: "Cursor CachedExtensionVSIXs",
              category: .toolCache, note: "Standard Electron cache location; not documented by Cursor itself.", processHint: "Cursor"),
        Entry(relativePath: "Library/Application Support/Cursor/logs", tool: .cursor, title: "Cursor logs",
              category: .toolCache, note: "Standard Electron cache location; not documented by Cursor itself.", processHint: "Cursor"),
        Entry(relativePath: "Library/Application Support/Cursor/Crashpad", tool: .cursor, title: "Cursor Crashpad",
              category: .toolCache, note: "Standard Electron cache location; not documented by Cursor itself.", processHint: "Cursor"),
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
                lastActivity: latestModification(in: url, maxDepth: 0),
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
