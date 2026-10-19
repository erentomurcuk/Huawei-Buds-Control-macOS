import SwiftUI
import AppKit

// MARK: - Earbud artwork
//
// The app targets Huawei FreeBuds, so the generic AirPods symbols that the UI
// used before were both inaccurate and easy to confuse with Apple's own buds.
// Instead a neutral single-bud silhouette is drawn here and reused as a
// template image, which keeps it crisp in the menu bar and in the panel.

enum BudArtwork {
    /// A single earbud, drawn top-down: a round housing with a short stem.
    static func image(height: CGFloat, mirrored: Bool = false, weight: CGFloat = 1) -> NSImage {
        let width = (height * 0.66).rounded()
        let scale: CGFloat = 3
        let pixelsWide = max(1, Int((width * scale).rounded()))
        let pixelsHigh = max(1, Int((height * scale).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return NSImage(size: NSSize(width: width, height: height)) }

        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let path = budPath(in: NSRect(x: 0, y: 0, width: width, height: height), weight: weight)
        if mirrored {
            let transform = NSAffineTransform()
            transform.translateX(by: width, yBy: 0)
            transform.scaleX(by: -1, yBy: 1)
            transform.concat()
        }
        NSColor.black.setFill()
        path.fill()

        // Clear the driver cut-out after filling the housing/stem union. Using
        // even-odd on overlapping subpaths would also punch a hole where the
        // stem joins the housing.
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        NSGraphicsContext.current?.compositingOperation = .clear
        BudArtwork.driverPath(in: bounds).fill()

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    /// Path in AppKit's bottom-left origin coordinate system: the round housing
    /// sits at the top and the stem points down, like a bud seen from the front.
    private static func budPath(in rect: NSRect, weight: CGFloat) -> NSBezierPath {
        let w = rect.width
        let h = rect.height
        let housing = NSRect(x: 0, y: h - w * 0.94, width: w, height: w * 0.94)
        let stem = NSRect(x: w * 0.33, y: 0, width: w * 0.34, height: h - w * 0.62)

        let path = NSBezierPath(ovalIn: housing)
        path.appendRoundedRect(stem, xRadius: w * 0.17, yRadius: w * 0.17)
        path.windingRule = .nonZero
        return path
    }

    /// A small driver cut-out makes the glyph read as an earbud rather than a
    /// lollipop, and keeps it legible at menu bar size.
    private static func driverPath(in rect: NSRect) -> NSBezierPath {
        let w = rect.width
        return NSBezierPath(ovalIn: NSRect(x: w * 0.12, y: rect.height - w * 0.56,
                                           width: w * 0.24, height: w * 0.24))
    }

}

// MARK: - Menu bar icon

enum MenuBarArtwork {
    /// The menu bar glyph is a pair of buds, baked into a template image so the
    /// menu bar receives an image of exact dimensions rather than a font-based
    /// symbol whose baseline would shift it relative to the battery text.
    static let menuIcon: NSImage = templateImage(named: "earbuds", pointSize: 15)

    /// Renders an SF Symbol into a template image, scaled to fit a canvas that
    /// matches the glyph's aspect ratio so nothing is clipped.
    static func templateImage(named name: String, pointSize: CGFloat) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            return NSImage(size: NSSize(width: pointSize, height: pointSize))
        }

        let size = glyph.size
        let scale: CGFloat = 3   // bake at 3× for Retina crispness
        let pixelsWide = max(1, Int((size.width * scale).rounded()))
        let pixelsHigh = max(1, Int((size.height * scale).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return glyph }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        glyph.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }
}

struct MenuBarIcon: View {
    let connected: Bool
    let battery: Int?
    let name: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(nsImage: MenuBarArtwork.menuIcon)
                .renderingMode(.template)

            if connected, let battery {
                Text("\(battery)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(connected ? Color.primary : Color.secondary)
        .opacity(connected ? 1 : 0.7)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let device = name ?? "Huawei earbuds"
        guard connected else { return "\(device), not connected" }
        guard let battery else { return "\(device), connected" }
        return "\(device), \(battery) percent"
    }
}

// MARK: - Panel header artwork

/// The header mark for the device panel and the menu bar header.
struct HeaderMark: View {
    var connected: Bool
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.accent.opacity(connected ? 0.16 : 0.08))
            Circle()
                .strokeBorder(Theme.accent.opacity(connected ? 0.16 : 0.06), lineWidth: 1)

            Image(systemName: "earbuds")
                .font(.system(size: size * 0.44, weight: .regular))
                .foregroundStyle(connected ? Theme.accent : Color.secondary)
        }
        .frame(width: size, height: size)
        .animation(Theme.spring, value: connected)
    }
}

/// A single bud glyph for the battery columns.
struct BudIcon: View {
    var mirrored = false

    var body: some View {
        Image(nsImage: BudArtwork.image(height: 22, mirrored: mirrored))
            .renderingMode(.template)
            .foregroundStyle(.secondary)
            .frame(height: 26)
    }
}
