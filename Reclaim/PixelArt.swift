import SwiftUI
import AppKit
import ReclaimKit

/// Hand-drawn pixel sprites, one per tool, shown in the notch while that tool's
/// storage is being scanned. Two frames each; '#' pixels use the primary color,
/// '+' pixels a lighter shade.
enum PixelArt {
    struct Sprite {
        var frames: [[String]]
        var color: Color
        var highlight: Color
    }

    static func sprite(for tool: Tool?) -> Sprite {
        switch tool {
        case .claudeCode:
            // Claude's starburst.
            return Sprite(frames: [
                [
                    "...#...",
                    ".#.#.#.",
                    "..+#+..",
                    "###+###",
                    "..+#+..",
                    ".#.#.#.",
                    "...#...",
                ],
                [
                    ".#...#.",
                    "..#.#..",
                    ".+###+.",
                    ".##+##.",
                    ".+###+.",
                    "..#.#..",
                    ".#...#.",
                ],
            ], color: Color(red: 0.85, green: 0.47, blue: 0.34), highlight: Color(red: 0.95, green: 0.65, blue: 0.5))
        case .codex:
            // A braided ring.
            return Sprite(frames: [
                [
                    "..####..",
                    ".#....#.",
                    "#..++..#",
                    "#.+..+.#",
                    "#.+..+.#",
                    "#..++..#",
                    ".#....#.",
                    "..####..",
                ],
                [
                    "..####..",
                    ".#.++.#.",
                    "#......#",
                    "#+....+#",
                    "#+....+#",
                    "#......#",
                    ".#.++.#.",
                    "..####..",
                ],
            ], color: .white, highlight: Color(red: 0.6, green: 0.85, blue: 0.85))
        case .conductor:
            // A train viewed head-on.
            return Sprite(frames: [
                [
                    "..####..",
                    ".######.",
                    ".#+##+#.",
                    ".######.",
                    "..#### .",
                    ".######.",
                    "#.#..#.#",
                ],
                [
                    "..####..",
                    ".######.",
                    ".#+##+#.",
                    ".######.",
                    "..####..",
                    ".######.",
                    ".#.##.#.",
                ],
            ], color: Color(red: 0.95, green: 0.55, blue: 0.25), highlight: .white)
        case .cursor:
            // A pointer with a click pulse.
            return Sprite(frames: [
                [
                    "#.......",
                    "##......",
                    "###.....",
                    "####....",
                    "#####...",
                    "###.....",
                    "#.##....",
                    "...#....",
                ],
                [
                    "#....+..",
                    "##....+.",
                    "###.....",
                    "####..+.",
                    "#####...",
                    "###.....",
                    "#.##....",
                    "...#....",
                ],
            ], color: .white, highlight: Color(red: 0.5, green: 0.7, blue: 1.0))
        case .xcode:
            // A hammer, mid-swing.
            return Sprite(frames: [
                [
                    ".#####..",
                    ".######.",
                    ".#####..",
                    "...##...",
                    "...##...",
                    "...##...",
                    "...##...",
                ],
                [
                    "..#####.",
                    ".######.",
                    "..#####.",
                    "...##...",
                    "...##...",
                    "...##...",
                    "...##...",
                ],
            ], color: Color(red: 0.35, green: 0.62, blue: 1.0), highlight: .white)
        case .npm, .pnpm:
            // Stacked package blocks.
            return Sprite(frames: [
                [
                    "########",
                    "#+#..#+#",
                    "########",
                    "..####..",
                    "..#..#..",
                    "..####..",
                ],
                [
                    "########",
                    "#+#..#+#",
                    "########",
                    ".####...",
                    ".#..#...",
                    ".####...",
                ],
            ], color: tool == .npm ? Color(red: 0.9, green: 0.3, blue: 0.3) : Color(red: 0.95, green: 0.7, blue: 0.2), highlight: .white)
        case .git:
            // Branching commits.
            return Sprite(frames: [
                [
                    "##......",
                    "##......",
                    ".#......",
                    ".###.##.",
                    ".#...##.",
                    "##......",
                    "##......",
                ],
                [
                    "##......",
                    "##......",
                    ".#..##..",
                    ".####...",
                    ".#..##..",
                    "##......",
                    "##......",
                ],
            ], color: Color(red: 0.94, green: 0.45, blue: 0.25), highlight: .white)
        default:
            // The Reclaim invader.
            return Sprite(frames: [
                [
                    "..#..#..",
                    ".######.",
                    "##+##+##",
                    "########",
                    "#.####.#",
                    "#.#..#.#",
                    "..#..#..",
                ],
                [
                    "..#..#..",
                    ".######.",
                    "##+##+##",
                    "########",
                    "#.####.#",
                    ".#....#.",
                    "#..##..#",
                ],
            ], color: Color(red: 0.35, green: 0.62, blue: 1.0), highlight: Color(red: 0.65, green: 0.85, blue: 1.0))
        }
    }
}

struct PixelSpriteView: View {
    enum Palette { case blue, green }
    var tool: Tool? = nil
    var palette: Palette = .blue

    var body: some View {
        let sprite = resolvedSprite
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let frame = Int(timeline.date.timeIntervalSinceReferenceDate * 2) % sprite.frames.count
            Canvas { context, size in
                let art = sprite.frames[frame]
                let rows = art.count
                let cols = art.map(\.count).max() ?? 1
                let cell = min(size.width / CGFloat(cols), size.height / CGFloat(rows))
                let xOffset = (size.width - cell * CGFloat(cols)) / 2
                let yOffset = (size.height - cell * CGFloat(rows)) / 2
                for (row, line) in art.enumerated() {
                    for (col, char) in line.enumerated() where char == "#" || char == "+" {
                        let rect = CGRect(x: xOffset + CGFloat(col) * cell,
                                          y: yOffset + CGFloat(row) * cell,
                                          width: cell * 0.92, height: cell * 0.92)
                        context.fill(Path(rect), with: .color(char == "#" ? sprite.color : sprite.highlight))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var resolvedSprite: PixelArt.Sprite {
        if let tool {
            return PixelArt.sprite(for: tool)
        }
        var sprite = PixelArt.sprite(for: nil)
        if palette == .green {
            sprite.color = Color(red: 0.3, green: 0.9, blue: 0.5)
            sprite.highlight = Color(red: 0.6, green: 1.0, blue: 0.75)
        }
        return sprite
    }
}

/// Real application icons where the tool is installed; nil falls back to SF Symbols.
enum AppIconProvider {
    private static let candidates: [Tool: [String]] = [
        .cursor: ["/Applications/Cursor.app"],
        .codex: ["/Applications/Codex.app", "/Applications/ChatGPT.app"],
        .claudeCode: ["/Applications/Claude.app"],
        .conductor: ["/Applications/Conductor.app"],
        .xcode: ["/Applications/Xcode.app", "/Applications/Xcode-beta.app"],
    ]

    @MainActor private static var cache: [Tool: NSImage?] = [:]

    @MainActor static func icon(for tool: Tool) -> NSImage? {
        if let cached = cache[tool] { return cached }
        var image = (candidates[tool] ?? [])
            .first { FileManager.default.fileExists(atPath: $0) }
            .map { NSWorkspace.shared.icon(forFile: $0) }
        if image == nil,
           let url = ToolIntegration.promptURL(tool: tool, prompt: "x"),
           let handler = NSWorkspace.shared.urlForApplication(toOpen: url) {
            // CLI-only tools (like Claude Code) register a helper app for their
            // URL scheme; borrow that app's icon.
            image = NSWorkspace.shared.icon(forFile: handler.path)
        }
        cache[tool] = image
        return image
    }

    @MainActor static let finder: NSImage =
        NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
}
