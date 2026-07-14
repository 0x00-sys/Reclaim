import Foundation

public enum DirectorySizer {
    /// Allocated size of a file tree, hardlink-aware: files with multiple links are
    /// counted once, so pnpm-style node_modules don't inflate the reclaimable number.
    /// Uses du(1), which is also markedly faster than Foundation enumeration on big trees.
    public static func allocatedSize(of url: URL) async throws -> Int64 {
        let result = try await runSubprocess("/usr/bin/du", ["-sk", url.path])
        guard result.succeeded || !result.stdout.isEmpty else {
            throw CocoaError(.fileReadUnknown)
        }
        // Output: "<kilobytes>\t<path>". du exits nonzero on permission errors but
        // still reports what it could measure.
        guard let field = result.stdout.split(separator: "\t").first,
              let kilobytes = Int64(field.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw CocoaError(.fileReadCorruptFile) }
        return kilobytes * 1024
    }
}
