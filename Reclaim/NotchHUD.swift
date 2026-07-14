import SwiftUI
import AppKit
import ReclaimKit

// MARK: - Pixel sprite

/// Tiny two-frame pixel creature in the Vibe Island spirit.
struct PixelSpriteView: View {
    enum Palette { case blue, green }
    var palette: Palette = .blue

    private static let frames: [[String]] = [
        [
            "..#..#..",
            ".######.",
            "##.##.##",
            "########",
            "#.####.#",
            "#.#..#.#",
            "..#..#..",
        ],
        [
            "..#..#..",
            ".######.",
            "##.##.##",
            "########",
            "#.####.#",
            ".#....#.",
            "#..##..#",
        ],
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let frame = Int(timeline.date.timeIntervalSinceReferenceDate * 2) % 2
            Canvas { context, size in
                let art = Self.frames[frame]
                let rows = art.count
                let cols = art[0].count
                let cell = min(size.width / CGFloat(cols), size.height / CGFloat(rows))
                let xOffset = (size.width - cell * CGFloat(cols)) / 2
                let yOffset = (size.height - cell * CGFloat(rows)) / 2
                let color: Color = palette == .blue ? Color(red: 0.35, green: 0.62, blue: 1) : Color(red: 0.3, green: 0.9, blue: 0.5)
                for (row, line) in art.enumerated() {
                    for (col, char) in line.enumerated() where char == "#" {
                        let rect = CGRect(x: xOffset + CGFloat(col) * cell,
                                          y: yOffset + CGFloat(row) * cell,
                                          width: cell * 0.92, height: cell * 0.92)
                        context.fill(Path(rect), with: .color(color))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Notch panel

/// Compact status panel that hugs the notch while a scan or cleanup is running.
/// It never shows when there is nothing useful to say.
@MainActor
final class NotchHUDController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func update(model: AppModel) {
        let enabled = UserDefaults.standard.object(forKey: "showNotchHUD") as? Bool ?? true
        guard enabled else { hide(); return }
        if model.isScanning {
            hideTask?.cancel()
            show(model: model)
        } else if panel != nil {
            // Linger briefly with the final numbers, then get out of the way.
            hideTask?.cancel()
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    private func show(model: AppModel) {
        if panel == nil {
            let size = NSSize(width: 360, height: 44)
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isMovable = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.contentView = NSHostingView(rootView: NotchHUDView(model: model))
            self.panel = panel
        }
        position()
        panel?.orderFrontRegardless()
    }

    private func position() {
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.frame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height
        ))
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

struct NotchHUDView: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            PixelSpriteView(palette: model.isScanning ? .blue : .green)
                .frame(width: 26, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.isScanning ? (model.scanProgress.isEmpty ? "Scanning…" : model.scanProgress) : "Scan complete")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(model.totalBytes.formattedBytes) found · \(model.safeBytes.formattedBytes) safe")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            if model.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(red: 0.3, green: 0.9, blue: 0.5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .frame(width: 360, height: 44)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18)
                .fill(.black)
        )
    }
}
