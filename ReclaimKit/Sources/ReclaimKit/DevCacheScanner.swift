import Foundation

/// Regenerable caches from the wider development toolchain (Go, Bun, Homebrew,
/// Playwright, npx, Cargo, uv, …) plus Electron app updater downloads.
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
            // pnpm honors XDG_DATA_HOME; installs set up that way keep the store here.
            Entry(relativePath: ".local/share/pnpm/store", tool: .pnpm, title: "pnpm content-addressed store (XDG)",
                  category: .packageCache,
                  note: "`pnpm store prune` removes only unreferenced packages.",
                  processHint: "pnpm", activityDepth: 1),
            Entry(relativePath: "Library/Caches/Yarn", tool: .yarn, title: "Yarn cache",
                  category: .packageCache, note: "`yarn cache clean` is the official way.", processHint: "yarn", activityDepth: 1),
            Entry(relativePath: ".yarn/berry/cache", tool: .yarn, title: "Yarn Berry global cache",
                  category: .packageCache, note: nil, processHint: "yarn", activityDepth: 1),
            Entry(relativePath: ".cache/node/corepack", tool: .node, title: "Corepack package-manager downloads",
                  category: .packageCache, note: "Corepack re-downloads the pinned pnpm/yarn version on next use.",
                  processHint: "corepack", activityDepth: 1),
        ]

        // Claude Code regenerable data
        for name in ["cache", "image-cache", "paste-cache", "backups", "shell-snapshots", "debug",
                     "telemetry", "usage-data", "tasks"] {
            list.append(Entry(relativePath: ".claude/\(name)", tool: .claudeCode,
                              title: "Claude Code \(name)", category: .toolCache,
                              note: nil, processHint: "claude"))
        }
        let claudeCautions: [(name: String, title: String, caution: String)] = [
            ("file-history", "Claude Code file-history",
             "Checkpoint snapshots used to rewind file edits; clearing removes the ability to restore past checkpoints."),
            ("todos", "Claude Code todos",
             "Task lists from past sessions; an interrupted session loses its resumable to-do state."),
            ("plans", "Claude Code plans",
             "Saved plan documents from plan-mode sessions; not regenerated."),
            ("plugins", "Claude Code plugins cache",
             "Installed plugins re-download on next use, but local plugin config may live here."),
        ]
        for entry in claudeCautions {
            list.append(Entry(relativePath: ".claude/\(entry.name)", tool: .claudeCode,
                              title: entry.title, category: .toolCache,
                              note: nil, processHint: "claude", caution: entry.caution))
        }

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
            Entry(relativePath: ".cargo/registry", tool: .rust, title: "Cargo registry cache",
                  category: .packageCache, note: "Crate downloads and their unpacked sources; cargo fetches them again on the next build.",
                  processHint: "cargo", daemonHints: ["rust-analyzer"], activityDepth: 1),
            Entry(relativePath: ".cargo/git", tool: .rust, title: "Cargo git checkouts",
                  category: .packageCache, note: "Git dependencies; cargo re-clones them on the next build.",
                  processHint: "cargo", daemonHints: ["rust-analyzer"], activityDepth: 1),
            Entry(relativePath: ".cache/uv", tool: .python, title: "uv cache",
                  category: .packageCache, note: "`uv cache clean` is the official way; `uv cache prune` keeps what is still referenced.",
                  processHint: "uv", activityDepth: 1),
            Entry(relativePath: ".cache/pre-commit", tool: .python, title: "pre-commit hook environments",
                  category: .packageCache, note: "`pre-commit clean` is the official way; hooks reinstall on the next commit.",
                  processHint: "pre-commit"),
            Entry(relativePath: ".cache/puppeteer", tool: .puppeteer, title: "Puppeteer browsers",
                  category: .toolCache, note: "Chrome for Testing builds; `npx puppeteer browsers install` restores them.",
                  processHint: nil),
            Entry(relativePath: ".cache/chrome-devtools-mcp", tool: .puppeteer, title: "Chrome DevTools MCP browser profile",
                  category: .toolCache, note: nil, processHint: nil,
                  caution: "Browser profile of the chrome-devtools-mcp server; clearing it signs that browser out of every site."),
            Entry(relativePath: ".cache/prisma", tool: .prisma, title: "Prisma engines",
                  category: .toolCache, note: "Query and schema engines; Prisma downloads them again on generate.",
                  processHint: "prisma"),
            Entry(relativePath: ".cache/codex-runtimes", tool: .codex, title: "Codex runtimes cache",
                  category: .toolCache, note: "Runtime downloads in the XDG cache directory; Codex fetches them again when needed.",
                  processHint: "codex"),
            // Local AI model stores: multi-GB, re-downloaded on demand.
            Entry(relativePath: ".ollama/models", tool: .ollama, title: "Ollama models",
                  category: .modelCache,
                  note: "`ollama pull` restores any model; `ollama rm <model>` removes a single one.",
                  processHint: "ollama", activityDepth: 2),
            Entry(relativePath: ".cache/huggingface", tool: .huggingFace, title: "Hugging Face cache",
                  category: .modelCache,
                  note: "Model and dataset downloads from the Hugging Face hub; re-fetched on next use.",
                  processHint: nil, activityDepth: 2),
            Entry(relativePath: ".lmstudio/models", tool: .lmStudio, title: "LM Studio models",
                  category: .modelCache, note: nil, processHint: "LM Studio", activityDepth: 2),
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
        items += updaterCaches(context: context)
        return items
    }

    /// electron-updater (used by most Electron dev tools) stages downloaded
    /// installers in ~/Library/Caches/<app>-updater; the running app fetches a
    /// fresh one when the next update ships.
    func updaterCaches(context: ScanContext) -> [ScanItem] {
        let caches = context.home.appendingPathComponent("Library/Caches")
        return FileManager.default.contentsOfDirectoryIfPresent(caches)
            .filter { $0.lastPathComponent.hasSuffix("-updater") && FileManager.default.directoryExists($0) }
            .filter { !FileManager.default.contentsOfDirectoryIfPresent($0, includeHidden: true).isEmpty }
            .map { url in
                let app = String(url.lastPathComponent.dropLast("-updater".count))
                var item = ScanItem(
                    path: url.path,
                    displayName: "\(app) update downloads",
                    tool: app.lowercased().hasPrefix("t3code") ? .t3Code : .appUpdater,
                    category: .toolCache,
                    lastActivity: latestModification(in: url, maxDepth: 1)
                )
                (item.safety, item.reasons) = Classifier.classify(item)
                item.reasons.append("Installers staged by electron-updater; an in-progress download is protected by the open-files check.")
                return item
            }
    }
}
