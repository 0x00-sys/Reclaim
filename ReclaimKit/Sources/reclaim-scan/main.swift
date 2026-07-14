import Foundation
import ReclaimKit

// Read-only scan report on stdout. Never deletes anything.
// Usage: reclaim-scan [--sizes] [root ...]

let arguments = Array(CommandLine.arguments.dropFirst())
let measureSizes = arguments.contains("--sizes")
let roots = arguments.filter { !$0.hasPrefix("--") }

let context = ScanContext(
    processes: await ProcessSnapshot.capture(),
    projectRoots: roots.map { URL(filePath: $0) }
)
let scanners: [any StorageScanner] = [
    CodexScanner(), ConductorScanner(), RepoWorktreeScanner(),
    NodeModulesScanner(), PackageCacheScanner(), XcodeScanner(),
    ClaudeCodeScanner(), CursorScanner(),
]

var items: [ScanItem] = []
for scanner in scanners {
    do {
        let found = try await scanner.scan(context: context)
        items.append(contentsOf: found)
        FileHandle.standardError.write(Data("\(scanner.name): \(found.count) items\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("\(scanner.name) failed: \(error)\n".utf8))
    }
}

items = deduplicateScanItems(items)

if measureSizes {
    for index in items.indices where items[index].sizeBytes == nil {
        items[index].sizeBytes = try? await DirectorySizer.allocatedSize(of: items[index].url)
    }
    items.sort { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
}

let formatter = ByteCountFormatter()
for item in items {
    let size = item.sizeBytes.map { formatter.string(fromByteCount: $0) } ?? "?"
    var line = "[\(item.safety.rawValue)] \(item.tool.rawValue) · \(item.category.rawValue) · \(item.displayName) · \(size)"
    if let worktree = item.worktree {
        line += " · branch=\(worktree.branch ?? "detached") registered=\(worktree.isRegistered)"
        line += " dirty=\(worktree.hasModifiedFiles) untracked=\(worktree.hasUntrackedFiles)"
        line += " unpushed=\(worktree.unpushedCommits.map(String.init) ?? "?")"
    }
    print(line)
    print("    \(item.path)")
    for reason in item.reasons {
        print("    – \(reason)")
    }
}
