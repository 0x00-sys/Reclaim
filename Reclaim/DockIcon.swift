import AppKit

/// The asset catalog can't carry a dark-appearance mac icon, so the Dock icon
/// is re-rendered in code and swapped when the system appearance changes:
/// dark slab + white invader in dark mode, inverted in light mode.
@MainActor
enum DockIcon {
    private static var observer: NSObjectProtocol?
    private static let renderSize: CGFloat = 512

    static func install() {
        update()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                // The appearance value updates a beat after the notification.
                try? await Task.sleep(for: .milliseconds(150))
                update()
            }
        }
    }

    static func update() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSApp.applicationIconImage = render(dark: dark)
    }

    static func render(dark: Bool) -> NSImage {
        let size = renderSize
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { canvas in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Dock icons carry ~9% transparent margin per side; applicationIconImage
            // is displayed unmasked, so bake the margin in or the icon looks huge.
            let rect = canvas.insetBy(dx: canvas.width * 0.09, dy: canvas.height * 0.09)
            let slabPath = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
            ctx.addPath(slabPath)
            ctx.clip()
            let colors = dark
                ? [NSColor(calibratedWhite: 0.24, alpha: 1).cgColor,
                   NSColor(calibratedWhite: 0.05, alpha: 1).cgColor,
                   NSColor(calibratedWhite: 0.02, alpha: 1).cgColor]
                : [NSColor(calibratedWhite: 1.0, alpha: 1).cgColor,
                   NSColor(calibratedWhite: 0.93, alpha: 1).cgColor,
                   NSColor(calibratedWhite: 0.88, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: colors as CFArray, locations: [0, 0.45, 1])!
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: rect.maxY),
                                   end: CGPoint(x: 0, y: rect.minY),
                                   options: [])
            // The mascot lives in PixelArt; the icon just renders it monochrome.
            let invader = PixelArt.sprite(for: nil).frames[0]
            let rows = invader.count
            let cols = invader.map(\.count).max() ?? 1
            let cell = rect.width * 0.68 / CGFloat(cols)
            let originX = rect.midX - cell * CGFloat(cols) / 2
            let originY = rect.midY - cell * CGFloat(rows) / 2
            (dark ? NSColor(calibratedWhite: 0.96, alpha: 1) : NSColor(calibratedWhite: 0.07, alpha: 1)).setFill()
            for (row, line) in invader.enumerated() {
                // '+' marks the sprite's highlight pixels (the eyes) — in the
                // monochrome icon those stay holes, as the original icon drew them.
                for (col, char) in line.enumerated() where char == "#" {
                    CGRect(x: originX + CGFloat(col) * cell,
                           y: originY + CGFloat(rows - 1 - row) * cell,
                           width: cell * 0.88, height: cell * 0.88).fill()
                }
            }
            return true
        }
        return image
    }
}
