import Foundation

/// Maps Codex worktrees to their thread names without touching sqlite:
/// the worktree's git metadata directory holds codex-thread.json with the
/// owning thread id, and ~/.codex/session_index.jsonl maps ids to names.
/// (Mechanism observed in the codex-clean project; everything is best-effort
/// and degrades to "no title".)
public enum CodexSessionIndex {
    public struct Session: Sendable {
        public var threadName: String?
        public var updatedAt: Date?
    }

    /// Parse ~/.codex/session_index.jsonl: one JSON object per line with
    /// id, thread_name?, updated_at?.
    public static func load(indexFile: URL) -> [String: Session] {
        guard let data = try? Data(contentsOf: indexFile),
              let text = String(data: data, encoding: .utf8)
        else { return [:] }
        var sessions: [String: Session] = [:]
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["id"] as? String
            else { continue }
            let updated = (object["updated_at"] as? String).flatMap(ISO8601.date(from:))
            sessions[id] = Session(threadName: object["thread_name"] as? String, updatedAt: updated)
        }
        return sessions
    }

    /// The thread id owning a worktree: read the `.git` FILE at its root
    /// (gitdir: <repo>/.git/worktrees/<name>), then codex-thread.json in
    /// that metadata directory.
    public static func threadID(forWorktree root: URL) -> String? {
        let gitFile = root.appendingPathComponent(".git")
        guard let contents = try? String(contentsOf: gitFile, encoding: .utf8),
              let gitdir = contents.split(separator: "\n").first?.trimmingCharacters(in: .whitespaces),
              gitdir.hasPrefix("gitdir: ")
        else { return nil }
        let metadataDir = String(gitdir.dropFirst("gitdir: ".count))
        // git can write the gitdir pointer relative to the worktree root
        // (worktree.useRelativePaths); resolve against root, never the cwd.
        let metadataURL = metadataDir.hasPrefix("/")
            ? URL(filePath: metadataDir)
            : URL(filePath: metadataDir, relativeTo: root).standardizedFileURL
        let threadFile = metadataURL.appendingPathComponent("codex-thread.json")
        guard let data = try? Data(contentsOf: threadFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["ownerThreadId"] as? String
    }
}
