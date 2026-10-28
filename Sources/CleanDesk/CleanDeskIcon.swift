import AppKit

/// Lucide's brush-cleaning mark, rendered natively from its original SVG paths.
/// Copyright (c) 2026 Lucide Icons and Contributors, ISC License.
/// See Resources/CleanDeskMark.svg and Resources/Lucide-LICENSE.txt.
/// The app-icon build script reuses this source, keeping all three marks identical.
enum CleanDeskIcon {
    static func image(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect, color: .black)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func draw(in rect: NSRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        // The authoritative SVG uses a 24 × 24, top-left-origin coordinate space.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: rect.width / 24, y: -rect.height / 24)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(2)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(markPath())
        context.strokePath()
    }

    private static func markPath() -> CGPath {
        let path = CGMutablePath()
        // m16 22-1-4
        path.move(to: CGPoint(x: 16, y: 22))
        path.addLine(to: CGPoint(x: 15, y: 18))

        // Handle and brush collar, using the original circular SVG arcs.
        path.move(to: CGPoint(x: 19, y: 14))
        arc(path, to: CGPoint(x: 20, y: 13), radius: 1, sweep: false)
        path.addLine(to: CGPoint(x: 20, y: 12))
        arc(path, to: CGPoint(x: 18, y: 10), radius: 2, sweep: false)
        path.addLine(to: CGPoint(x: 15, y: 10))
        arc(path, to: CGPoint(x: 14, y: 9), radius: 1, sweep: true)
        path.addLine(to: CGPoint(x: 14, y: 4))
        arc(path, to: CGPoint(x: 10, y: 4), radius: 2, sweep: false)
        path.addLine(to: CGPoint(x: 10, y: 9))
        arc(path, to: CGPoint(x: 9, y: 10), radius: 1, sweep: true)
        path.addLine(to: CGPoint(x: 6, y: 10))
        arc(path, to: CGPoint(x: 4, y: 12), radius: 2, sweep: false)
        path.addLine(to: CGPoint(x: 4, y: 13))
        arc(path, to: CGPoint(x: 5, y: 14), radius: 1, sweep: false)

        // M19 14H5l-1.973 6.767A1 1 0 0 0 4 22h16a1 1 0 0 0 .973-1.233z
        path.move(to: CGPoint(x: 19, y: 14))
        path.addLine(to: CGPoint(x: 5, y: 14))
        path.addLine(to: CGPoint(x: 3.027, y: 20.767))
        arc(path, to: CGPoint(x: 4, y: 22), radius: 1, sweep: false)
        path.addLine(to: CGPoint(x: 20, y: 22))
        arc(path, to: CGPoint(x: 20.973, y: 20.767), radius: 1, sweep: false)
        path.closeSubpath()

        // m8 22 1-4
        path.move(to: CGPoint(x: 8, y: 22))
        path.addLine(to: CGPoint(x: 9, y: 18))
        return path
    }

    /// Converts an SVG small circular arc from endpoint to center parameters.
    /// All arcs in this icon use equal radii, zero rotation and large-arc = 0.
    private static func arc(_ path: CGMutablePath, to end: CGPoint, radius: CGFloat, sweep: Bool) {
        let start = path.currentPoint
        let dx = (start.x - end.x) / 2
        let dy = (start.y - end.y) / 2
        let distanceSquared = dx * dx + dy * dy
        guard distanceSquared > 0 else { return }
        let adjustedRadius = max(radius, sqrt(distanceSquared))
        let coefficient = (sweep ? 1.0 : -1.0)
            * sqrt(max(0, (adjustedRadius * adjustedRadius - distanceSquared) / distanceSquared))
        let center = CGPoint(
            x: (start.x + end.x) / 2 + coefficient * dy,
            y: (start.y + end.y) / 2 - coefficient * dx
        )
        path.addArc(
            center: center,
            radius: adjustedRadius,
            startAngle: atan2(start.y - center.y, start.x - center.x),
            endAngle: atan2(end.y - center.y, end.x - center.x),
            clockwise: !sweep
        )
    }
}
