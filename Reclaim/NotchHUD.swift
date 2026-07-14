import SwiftUI
import AppKit
import ReclaimKit

// MARK: - Shape

/// The classic notch silhouette: concave "ears" at the top corners flaring into
/// the screen edge, rounded corners at the bottom.
nonisolated struct NotchShape: Shape {
    var earRadius: CGFloat = 8
    var bottomRadius: CGFloat = 12

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

// MARK: - Geometry

/// Where and how big the notch is on the current screen arrangement.
struct NotchMetrics: Equatable {
    var hasHardwareNotch: Bool
    var notchWidth: CGFloat      // visible body width, without ears
    var topInset: CGFloat        // hardware notch height, or menu bar height when simulated
    var screenFrame: NSRect

    static let earRadius: CGFloat = 8

    /// Height of the black area when collapsed. On hardware the content strip
    /// hangs below the physical notch; on external displays the whole thing is
    /// barely deeper than the menu bar, like a real notch would be.
    var collapsedHeight: CGFloat { hasHardwareNotch ? topInset + 24 : topInset + 6 }
    var collapsedContentTopInset: CGFloat { hasHardwareNotch ? topInset : 0 }

    var expandedSize: CGSize {
        CGSize(width: max(340, notchWidth + 120),
               height: (hasHardwareNotch ? topInset : 6) + 148)
    }

    static func detect() -> NotchMetrics? {
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            return NotchMetrics(
                hasHardwareNotch: true,
                notchWidth: screen.frame.width - left.width - right.width,
                topInset: screen.safeAreaInsets.top,
                screenFrame: screen.frame
            )
        }
        guard let screen = NSScreen.main else { return nil }
        let menuBar = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return NotchMetrics(
            hasHardwareNotch: false,
            notchWidth: min(220, max(160, screen.frame.width * 0.11)),
            topInset: menuBar,
            screenFrame: screen.frame
        )
    }
}

// MARK: - Controller

@MainActor
@Observable
final class NotchState {
    var expanded = false
    var metrics: NotchMetrics?
}

/// Status panel that behaves like the notch growing downward. The window is
/// resized instantly; the black shape inside spring-animates between sizes,
/// which is what makes the expand/collapse feel native.
@MainActor
final class NotchHUDController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var shrinkTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private let state = NotchState()
    private weak var model: AppModel?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screenLayoutChanged() }
        }
    }

    private func screenLayoutChanged() {
        guard panel != nil else { return }
        state.metrics = NotchMetrics.detect()
        applyWindowFrame()
    }

    func update(model: AppModel) {
        self.model = model
        let enabled = UserDefaults.standard.object(forKey: "showNotchHUD") as? Bool ?? true
        guard enabled else { hide(); return }
        if model.isScanning {
            hideTask?.cancel()
            show(model: model)
        } else if panel != nil {
            hideTask?.cancel()
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, self?.state.expanded != true else { return }
                self?.hide()
            }
        }
    }

    private func show(model: AppModel) {
        guard let metrics = NotchMetrics.detect() else { return }
        state.metrics = metrics
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
            panel.contentView = NSHostingView(rootView: NotchHUDView(
                model: model,
                state: state,
                onHover: { [weak self] hovering in self?.setExpanded(hovering) }
            ))
            self.panel = panel
        }
        applyWindowFrame()
        panel?.orderFrontRegardless()
    }

    private func setExpanded(_ expanded: Bool) {
        guard state.expanded != expanded else { return }
        shrinkTask?.cancel()
        if expanded {
            // Grow the window first (invisible; the panel is transparent),
            // then let the shape spring into the new room.
            state.expanded = true
            applyWindowFrame()
        } else {
            state.expanded = false
            // Let the shape finish collapsing before taking its room away.
            shrinkTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                self?.applyWindowFrame()
                if let self, let model = self.model, !model.isScanning {
                    self.update(model: model)
                }
            }
        }
    }

    private func applyWindowFrame() {
        guard let panel, let metrics = state.metrics else { return }
        let ears = NotchMetrics.earRadius * 2
        let size: NSSize
        if state.expanded {
            size = NSSize(width: metrics.expandedSize.width + ears,
                          height: metrics.expandedSize.height)
        } else {
            size = NSSize(width: collapsedWidth(metrics) + ears, height: metrics.collapsedHeight)
        }
        panel.setFrame(NSRect(
            x: metrics.screenFrame.midX - size.width / 2,
            y: metrics.screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        ), display: true)
    }

    /// Collapsed width hugs the status text but never shrinks below the notch.
    private func collapsedWidth(_ metrics: NotchMetrics) -> CGFloat {
        guard let model else { return metrics.notchWidth }
        let status = model.isScanning
            ? (model.scanProgress.isEmpty ? "Scanning…" : model.scanProgress)
            : "\(model.safeBytes.formattedBytes) safe to clean"
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let width = (status as NSString).size(withAttributes: [.font: font]).width
            + (model.totalBytes.formattedBytes as NSString).size(withAttributes: [.font: font]).width
            + 72
        return max(metrics.notchWidth, min(width, 340))
    }

    func hide() {
        hideTask?.cancel()
        shrinkTask?.cancel()
        hideTask = nil
        shrinkTask = nil
        state.expanded = false
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - Views

struct NotchHUDView: View {
    let model: AppModel
    let state: NotchState
    let onHover: (Bool) -> Void

    var body: some View {
        Group {
            if let metrics = state.metrics {
                VStack(spacing: 0) {
                    if state.expanded {
                        ExpandedNotchContent(model: model, metrics: metrics)
                    } else {
                        CollapsedNotchContent(model: model, metrics: metrics)
                    }
                }
                .background(NotchShape(earRadius: NotchMetrics.earRadius).fill(.black))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.expanded)
                .contentShape(NotchShape(earRadius: NotchMetrics.earRadius))
                .onHover(perform: onHover)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct CollapsedNotchContent: View {
    let model: AppModel
    let metrics: NotchMetrics

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: metrics.collapsedContentTopInset)
            HStack(spacing: 6) {
                PixelSpriteView(tool: model.isScanning ? model.currentTool : nil,
                                palette: model.isScanning ? .blue : .green)
                    .frame(width: 15, height: 13)
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
            .padding(.horizontal, NotchMetrics.earRadius + 10)
            .frame(maxHeight: .infinity)
        }
        .frame(height: metrics.collapsedHeight)
    }
}

struct ExpandedNotchContent: View {
    let model: AppModel
    let metrics: NotchMetrics

    private var categories: [(StorageCategory, Int64)] {
        Dictionary(grouping: model.items, by: \.category)
            .map { ($0.key, $0.value.compactMap(\.sizeBytes).reduce(0, +)) }
            .sorted { $0.1 > $1.1 }
            .prefix(4)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Color.clear.frame(height: metrics.hasHardwareNotch ? metrics.topInset : 2)
            HStack(spacing: 8) {
                PixelSpriteView(tool: model.isScanning ? model.currentTool : nil,
                                palette: model.isScanning ? .blue : .green)
                    .frame(width: 20, height: 16)
                Text(model.isScanning
                     ? (model.scanProgress.isEmpty ? "Scanning…" : model.scanProgress)
                     : "Scan complete")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                if model.isScanning {
                    ProgressView().controlSize(.mini).tint(.white)
                }
            }
            Divider().overlay(.white.opacity(0.15))
            ForEach(categories, id: \.0) { category, size in
                HStack(spacing: 8) {
                    Image(systemName: category.systemImage)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 14)
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
            .padding(.bottom, 10)
        }
        .padding(.horizontal, NotchMetrics.earRadius + 12)
        .frame(width: metrics.expandedSize.width, height: metrics.expandedSize.height)
    }
}
