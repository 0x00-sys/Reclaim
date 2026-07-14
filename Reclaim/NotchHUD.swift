import SwiftUI
import AppKit
import ReclaimKit

// MARK: - Geometry

enum NotchConstants {
    /// Size of the expanded card (the window is fixed at this size plus shadow room).
    static let openSize = CGSize(width: 420, height: 176)
    static let shadowPadding: CGFloat = 24
    /// Corner radii, closed → open. The top radius draws the concave "ears".
    static let closedTopRadius: CGFloat = 6
    static let closedBottomRadius: CGFloat = 14
    static let openTopRadius: CGFloat = 19
    static let openBottomRadius: CGFloat = 24
    /// Springs: opening is slightly bouncy, closing critically damped.
    static let openSpring: Animation = .spring(response: 0.42, dampingFraction: 0.8)
    static let closeSpring: Animation = .spring(response: 0.45, dampingFraction: 1.0)
    static let hoverOpenDelay: Duration = .milliseconds(300)
    static let hoverCloseDelay: Duration = .milliseconds(100)

    static var windowSize: NSSize {
        NSSize(width: openSize.width + shadowPadding * 2,
               height: openSize.height + shadowPadding)
    }
}

/// Closed-notch metrics for a screen.
struct NotchMetrics: Equatable {
    var hasHardwareNotch: Bool
    /// Physical notch height, or menu bar height on plain displays.
    var topInset: CGFloat
    /// Width of the hardware notch (+ slight overhang to hide the seam), or a
    /// realistic simulated width on plain displays.
    var baseWidth: CGFloat
    var screenFrame: NSRect

    static func detect() -> NotchMetrics? {
        // Prefer the screen with a real notch; otherwise follow the main screen.
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            return NotchMetrics(
                hasHardwareNotch: true,
                topInset: screen.safeAreaInsets.top,
                baseWidth: screen.frame.width - left.width - right.width + 4,
                screenFrame: screen.frame
            )
        }
        guard let screen = NSScreen.main else { return nil }
        return NotchMetrics(
            hasHardwareNotch: false,
            topInset: max(24, screen.frame.maxY - screen.visibleFrame.maxY),
            baseWidth: min(220, max(160, screen.frame.width * 0.11)),
            screenFrame: screen.frame
        )
    }

    /// Closed size. On hardware notches a text strip hangs below the physical
    /// notch; on plain displays the whole thing is exactly menu-bar deep.
    func closedSize(fittingStatusWidth statusWidth: CGFloat) -> CGSize {
        let width = min(max(baseWidth, statusWidth), 340)
        let height = hasHardwareNotch ? topInset + 24 : topInset
        return CGSize(width: width, height: height)
    }

    var closedContentTopInset: CGFloat { hasHardwareNotch ? topInset : 0 }
    var openContentTopInset: CGFloat { hasHardwareNotch ? topInset : 4 }
}

// MARK: - Shape

/// Notch silhouette with animatable corner radii: concave quad-curve ears at the
/// top, convex rounded corners at the bottom.
nonisolated struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let t = topRadius
        let b = bottomRadius
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                          control: CGPoint(x: rect.minX + t, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        path.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                          control: CGPoint(x: rect.minX + t, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                          control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - t, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Controller

@MainActor
@Observable
final class NotchViewModel {
    var expanded = false
    var metrics: NotchMetrics?
}

/// The window is created once at a fixed size and never resized; every open,
/// close, and resize animation is SwiftUI layout inside it. Transparent window
/// regions don't intercept clicks (the hosting view only hit-tests real content).
@MainActor
final class NotchHUDController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var cachedScreenFrames: Set<NSRect> = []
    private let viewModel = NotchViewModel()
    private weak var model: AppModel?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screenLayoutChanged() }
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
            hideTask?.cancel()
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, self?.viewModel.expanded != true else { return }
                self?.hide()
            }
        }
    }

    private func show(model: AppModel) {
        guard let metrics = NotchMetrics.detect() else { return }
        viewModel.metrics = metrics
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: NotchConstants.windowSize),
                styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isMovable = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
            panel.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
            panel.contentView = NSHostingView(rootView: NotchHUDRoot(model: model, viewModel: viewModel))
            self.panel = panel
        }
        position()
        panel?.orderFrontRegardless()
    }

    private func position() {
        guard let panel, let metrics = viewModel.metrics else { return }
        let size = NotchConstants.windowSize
        panel.setFrameOrigin(NSPoint(
            x: metrics.screenFrame.midX - size.width / 2,
            y: metrics.screenFrame.maxY - size.height
        ))
    }

    private func screenLayoutChanged() {
        let frames = Set(NSScreen.screens.map(\.frame))
        guard frames != cachedScreenFrames else { return }
        cachedScreenFrames = frames
        guard panel != nil else { return }
        viewModel.metrics = NotchMetrics.detect()
        position()
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        viewModel.expanded = false
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - Views

struct NotchHUDRoot: View {
    let model: AppModel
    let viewModel: NotchViewModel

    var body: some View {
        Group {
            if let metrics = viewModel.metrics {
                NotchView(model: model, viewModel: viewModel, metrics: metrics)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct NotchView: View {
    let model: AppModel
    let viewModel: NotchViewModel
    let metrics: NotchMetrics

    @State private var hovering = false
    @State private var hoverTask: Task<Void, Never>?

    private var expanded: Bool { viewModel.expanded }

    private var closedSize: CGSize {
        let status = model.isScanning
            ? (model.scanProgress.isEmpty ? "Scanning…" : model.scanProgress)
            : "\(model.safeBytes.formattedBytes) safe to clean"
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let statusWidth = (status as NSString).size(withAttributes: [.font: font]).width
            + (model.totalBytes.formattedBytes as NSString).size(withAttributes: [.font: font]).width
            + 70
        return metrics.closedSize(fittingStatusWidth: statusWidth)
    }

    var body: some View {
        let shape = NotchShape(
            topRadius: expanded ? NotchConstants.openTopRadius : NotchConstants.closedTopRadius,
            bottomRadius: expanded ? NotchConstants.openBottomRadius : NotchConstants.closedBottomRadius
        )
        ZStack(alignment: .top) {
            Color.black
            Group {
                if expanded {
                    ExpandedNotchContent(model: model, metrics: metrics)
                        .transition(.scale(scale: 0.8, anchor: .top).combined(with: .opacity))
                } else {
                    CollapsedNotchContent(model: model, metrics: metrics)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.35), value: expanded)
            // Seals the hairline seam against the physical notch.
            Rectangle()
                .fill(.black)
                .frame(height: 1)
                .padding(.horizontal, expanded ? NotchConstants.openTopRadius : NotchConstants.closedTopRadius)
        }
        .frame(width: expanded ? NotchConstants.openSize.width : closedSize.width,
               height: expanded ? NotchConstants.openSize.height : closedSize.height)
        .clipShape(shape)
        .shadow(color: .black.opacity(expanded ? 0.55 : 0), radius: 6, y: 3)
        .animation(expanded ? NotchConstants.openSpring : NotchConstants.closeSpring, value: expanded)
        .contentShape(shape)
        .onHover(perform: hoverChanged)
        .onTapGesture {
            hoverTask?.cancel()
            viewModel.expanded = true
        }
    }

    private func hoverChanged(_ isHovering: Bool) {
        hovering = isHovering
        hoverTask?.cancel()
        if isHovering {
            guard !expanded else { return }
            hoverTask = Task {
                try? await Task.sleep(for: NotchConstants.hoverOpenDelay)
                guard !Task.isCancelled, hovering, !viewModel.expanded else { return }
                viewModel.expanded = true
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: NotchConstants.hoverCloseDelay)
                guard !Task.isCancelled, !hovering else { return }
                viewModel.expanded = false
            }
        }
    }
}

struct CollapsedNotchContent: View {
    let model: AppModel
    let metrics: NotchMetrics

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: metrics.closedContentTopInset)
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
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
        }
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
            Color.clear.frame(height: metrics.openContentTopInset)
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
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 16)
        .frame(width: NotchConstants.openSize.width, height: NotchConstants.openSize.height)
    }
}
