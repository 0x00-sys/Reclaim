import SwiftUI
import AppKit
import ReclaimKit

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

    /// The panel matches the physical notch: exactly its width, extending a thin
    /// info strip below it, so it reads as the notch growing downward.
    private struct Geometry {
        var screen: NSScreen
        var width: CGFloat
        var notchHeight: CGFloat
        var stripHeight: CGFloat = 26

        var size: NSSize { NSSize(width: width, height: notchHeight + stripHeight) }

        static func detect() -> Geometry? {
            // A real notch: match its exact hardware dimensions.
            if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
               let left = screen.auxiliaryTopLeftArea,
               let right = screen.auxiliaryTopRightArea {
                return Geometry(
                    screen: screen,
                    width: screen.frame.width - left.width - right.width,
                    notchHeight: screen.safeAreaInsets.top
                )
            }
            // External displays have no notch, so draw one where it would be:
            // flush with the top edge, cutting into the menu bar. Real MacBook
            // notches are ~12.5% of the screen width and exactly menu-bar deep.
            guard let screen = NSScreen.main else { return nil }
            let menuBarHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
            return Geometry(
                screen: screen,
                width: min(240, max(170, screen.frame.width * 0.125)),
                notchHeight: menuBarHeight
            )
        }
    }

    private func show(model: AppModel) {
        guard let geometry = Geometry.detect() else { return }
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: geometry.size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isMovable = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            self.panel = panel
        }
        panel?.setContentSize(geometry.size)
        panel?.contentView = NSHostingView(rootView: NotchHUDView(model: model, stripHeight: geometry.stripHeight))
        let frame = geometry.screen.frame
        // Always flush with the top edge: behind the hardware notch on built-in
        // displays, over the menu bar (as a drawn notch) on external ones.
        panel?.setFrameOrigin(NSPoint(
            x: frame.midX - geometry.size.width / 2,
            y: frame.maxY - geometry.size.height
        ))
        panel?.orderFrontRegardless()
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
    let stripHeight: CGFloat

    private var status: String {
        if model.isScanning {
            return model.scanProgress.isEmpty ? "Scanning…" : model.scanProgress
        }
        return "\(model.safeBytes.formattedBytes) safe to clean"
    }

    private var sprite: some View {
        PixelSpriteView(tool: model.isScanning ? model.currentTool : nil,
                        palette: model.isScanning ? .blue : .green)
            .frame(width: 16, height: 14)
    }

    private var statusText: some View {
        Text(status)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0) // hidden behind the hardware notch
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    sprite
                    statusText
                    Spacer(minLength: 4)
                    Text(model.totalBytes.formattedBytes)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                        .monospacedDigit()
                }
                HStack(spacing: 6) {
                    sprite
                    statusText
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: stripHeight - 4)
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 11, bottomTrailingRadius: 11)
                .fill(.black)
        )
    }
}
