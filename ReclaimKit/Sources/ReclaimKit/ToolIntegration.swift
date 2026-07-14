import Foundation
import AppKit

/// Deep links for opening an AI tool with a prefilled prompt.
/// Every scheme here is documented by the tool's vendor:
/// - Codex:      https://developers.openai.com/codex/app/commands
/// - Claude Code: https://code.claude.com/docs/en/deep-links
/// - Conductor:  https://www.conductor.build/docs/reference/deep-links
/// - Cursor:     https://cursor.com/docs/reference/deeplinks
public enum ToolIntegration {

    public static func supportsPromptURL(_ tool: Tool) -> Bool {
        switch tool {
        case .codex, .claudeCode, .conductor, .cursor: true
        default: false
        }
    }

    /// True when something on this Mac actually handles the tool's URL scheme.
    /// Tools that aren't installed shouldn't be offered in the UI.
    @MainActor private static var installedCache: [Tool: Bool] = [:]

    @MainActor public static func isInstalled(_ tool: Tool) -> Bool {
        if let cached = installedCache[tool] { return cached }
        guard supportsPromptURL(tool),
              let url = promptURL(tool: tool, prompt: "x")
        else {
            installedCache[tool] = false
            return false
        }
        let installed = NSWorkspace.shared.urlForApplication(toOpen: url) != nil
        installedCache[tool] = installed
        return installed
    }

    public static func promptURL(tool: Tool, prompt: String, path: String? = nil) -> URL? {
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
        }
        switch tool {
        case .codex:
            var string = "codex://new?prompt=\(encode(prompt))"
            if let path { string += "&path=\(encode(path))" }
            return URL(string: string)
        case .claudeCode:
            var string = "claude-cli://open?q=\(encode(String(prompt.prefix(5000))))"
            if let path { string += "&cwd=\(encode(path))" }
            return URL(string: string)
        case .conductor:
            // Conductor uses flat key=value pairs directly after the scheme.
            var string = "conductor://prompt=\(encode(prompt))"
            if let path { string += "&path=\(encode(path))" }
            return URL(string: string)
        case .cursor:
            return URL(string: "cursor://anysphere.cursor-deeplink/prompt?text=\(encode(prompt))")
        default:
            return nil
        }
    }

    public static func inspectionPrompt(for item: ScanItem) -> String {
        var lines = [
            "Please inspect \(item.path) and help me decide whether it can be cleaned up safely.",
        ]
        if let worktree = item.worktree {
            if let repo = worktree.repositoryPath {
                lines.append("It is a git worktree of \(repo).")
            }
            if worktree.hasModifiedFiles || worktree.hasUntrackedFiles {
                lines.append("It has uncommitted or untracked changes — check whether they are worth keeping, and commit and push anything valuable.")
            }
            if let unpushed = worktree.unpushedCommits, unpushed > 0 {
                lines.append("It has \(unpushed) unpushed commit(s) — push them or confirm they are disposable.")
            }
            lines.append("If nothing is worth keeping, remove the worktree with `git worktree remove` and prune stale entries.")
        } else {
            lines.append("Category: \(item.category.rawValue). Reasons flagged: \(item.reasons.joined(separator: " "))")
        }
        return lines.joined(separator: " ")
    }
}
