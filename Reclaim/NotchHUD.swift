import SwiftUI
import AppKit
import ReclaimKit

// MARK: - Shape

/// The classic notch silhouette: concave "ears" at the top corners flaring into
/// the screen edge, rounded corners at the bottom.
nonisolated struct NotchShape: Shape {
    var earRadius: CGFloat = 10
    var bottomRadius: CGFloat = 13

    func path(in rect: CGRect) -> Path {
        let e = earRadius
        let r = bottomRadius
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + e, y: rect.minY + e),
                          control: CGPoint(x: rect.minX + e, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + e, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + e + r, y: rect.maxY),
                          control: CGPoint(x: rect.minX + e, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - e - r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - e, y: rect.maxY - r),
                          control: CGPoint(x: rect.maxX - e, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - e, y: rect.minY + e))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - e, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Controller

@MainActor
@Observable
final class NotchState {
    var expanded = false
}

/// Compact status panel that behaves like the notch growing downward.
/// Hardware notch screens use its exact metrics; external displays get a
/// simulated notch cut into the menu bar. Hover expands it into a detail card.
@MainActor
final class NotchHUDController {
    static let earRadius: CGFloat = 10

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private let state = NotchState()
    private weak var model: AppModel?

    private struct Geometry {
        var screen: NSScreen
        var notchWidth: CGFloat   // visible body width, without ears
        var topInset: CGFloat     // hardware notch height, or menu bar height when simulated

        static func detect() -> Geometry? {
            if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
               let left = screen.auxiliaryTopLeftArea,
               let right = screen.auxiliaryTopRightArea {
                return Geometry(
                    screen: screen,
                    notchWidth: screen.frame.width - left.width - right.width,
                    topInset: screen.safeAreaInsets.top
                )
            }
            guard let screen = NSScreen.main else { return nil }
            let menuBar = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
            return Geometry(
                screen: screen,
                notchWidth: min(230, max(170, screen.frame.width * 0.12)),
                topInset: menuBar
            )
        }
    }

    func update(model: AppModel) {
        self.model = model
        let enabled = UserDefaults.standard.object(forKey: "showNotchHUD") as? Bool ?? true
        guard enabled else { hide(); return }
        if model.isScanning {
            hideTask?.cancel()
            show(model: model)
        } else if panel != nil {
            layout(animated: true)
            hideTask?.cancel()
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, self?.state.expanded != true else { return }
                self?.hide()
            }
        }
    }

    private func show(model: AppModel) {
        if panel == nil {
            let panel = NSPanel(
                contentRect: .zero,
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
        guard let geometry = Geometry.detect() else { return }
        panel?.contentView = NSHostingView(rootView: NotchHUDView(
            model: model,
            state: state,
            topInset: geometry.topInset,
            onHover: { [weak self] hovering in self?.setExpanded(hovering) }
        ))
        layout(animated: false)
        panel?.orderFrontRegardless()
    }

    private func setExpanded(_ expanded: Bool) {
        guard state.expanded != expanded else { return }
        withAnimation(.snappy(duration: 0.25)) {
            state.expanded = expanded
        }
        layout(animated: true)
        if !expanded, let model, !model.isScanning {
            update(model: model)
        }
    }

    private func layout(animated: Bool) {
        guard let panel, let geometry = Geometry.detect(), let model else { return }
        let ears = Self.earRadius * 2
        let size: NSSize
        if state.expanded {
            size = NSSize(width: max(380, geometry.notchWidth + 120) + ears,
                          height: geometry.topInset + 168)
        } else {
            // Fit the collapsed strip to its text so the panel hugs the content.
            let status = model.isScanning ? model.scanProgress : "\(model.safeBytes.formattedBytes) safe to clean"
            let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            let textWidth = (status as NSString).size(withAttributes: [.font: font]).width
                + (model.totalBytes.formattedBytes as NSString).size(withAttributes: [.font: font]).width
            let fitted = textWidth + 76 // sprite, spacings, padding
            size = NSSize(width: max(geometry.notchWidth, fitted) + ears,
                          height: geometry.topInset + 28)
        }
        let frame = NSRect(
            x: geometry.screen.frame.midX - size.width / 2,
            y: geometry.screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        if animated, panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        state.expanded = false
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - Views

struct NotchHUDView: View {
    let model: AppModel
    let state: NotchState
    let topInset: CGFloat
    let onHover: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // This region sits behind the hardware notch (or over the menu bar
            // when simulated) — it stays empty on purpose.
            Color.clear.frame(height: topInset)
            if state.expanded {
                ExpandedNotchContent(model: model)
                    .transition(.opacity)
            } else {
                CollapsedNotchContent(model: model)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(NotchShape(earRadius: NotchHUDController.earRadius).fill(.black))
        .padding(.horizontal, 0)
        .onHover(perform: onHover)
    }
}

struct CollapsedNotchContent: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            PixelSpriteView(tool: model.isScanning ? model.currentTool : nil,
                            palette: model.isScanning ? .blue : .green)
                .frame(width: 16, height: 14)
            Text(model.isScanning
                 ? (model.scanProgress.isEmpty ? "Scanning…" : model.scanProgress)
                 : "\(model.safeBytes.formattedBytes) safe to clean")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(model.totalBytes.formattedBytes)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .monospacedDigit()
        }
        .padding(.horizontal, NotchHUDController.earRadius + 12)
        .frame(height: 28, alignment: .center)
    }
}

struct ExpandedNotchContent: View {
    let model: AppModel

    private var categories: [(StorageCategory, Int64)] {
        Dictionary(grouping: model.items, by: \.category)
            .map { ($0.key, $0.value.compactMap(\.sizeBytes).reduce(0, +)) }
            .sorted { $0.1 > $1.1 }
            .prefix(4)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PixelSpriteView(tool: model.isScanning ? model.currentTool : nil,
                                palette: model.isScanning ? .blue : .green)
                    .frame(width: 22, height: 18)
                Text(model.isScanning
                     ? (model.scanProgress.isEmpty ? "Scanning…" : model.scanProgress)
                     : "Scan complete")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                if model.isScanning {
                    ProgressView().controlSize(.small).tint(.white)
                }
            }
            Divider().overlay(.white.opacity(0.15))
            ForEach(categories, id: \.0) { category, size in
                HStack(spacing: 8) {
                    Image(systemName: category.systemImage)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 16)
                    Text(category.rawValue)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Text(size.formattedBytes)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
            HStack {
                Text("\(model.items.count) items")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text("\(model.safeBytes.formattedBytes) safe of \(model.totalBytes.formattedBytes)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(red: 0.3, green: 0.9, blue: 0.5))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, NotchHUDController.earRadius + 14)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }
}
