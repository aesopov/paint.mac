import AppKit

enum ShapePaintMode: String, CaseIterable {
    case outline = "Outline Only"
    case outlineAndFill = "Outline & Fill"
    case fill = "Fill Only"

    var drawsOutline: Bool { self != .fill }

    /// Extend the existing Spectrum shape outline with a light interior or a
    /// solid silhouette. Native template tinting keeps all three states legible.
    func icon(for tool: PaintTool, corners: RectangleCorners = .square, border: ShapeBorder = .solid) -> NSImage {
        let hasCorners = (tool == .rectangle || tool == .selection) && corners.isStyled
        let patterned = tool.isGeometry && (tool == .line || drawsOutline) && border.style != .solid
        if hasCorners || patterned {
            return styledIcon(for: tool, corners: corners, border: border)
        }
        guard tool == .rectangle || tool == .ellipse, self != .outline else { return tool.icon }
        let outline = tool.icon, mode = self
        let image = NSImage(size: outline.size, flipped: false) { bounds in
            let rect = tool == .rectangle ? bounds.insetBy(dx: 1, dy: 2) : bounds.insetBy(dx: 0.1, dy: 2.1)
            let interior = mode == .fill ? rect : rect.insetBy(dx: 2, dy: 2)
            let path = tool == .rectangle ? NSBezierPath(rect: interior) : NSBezierPath(ovalIn: interior)
            NSColor.black.withAlphaComponent(mode == .fill ? 1 : 0.35).setFill(); path.fill()
            if mode == .outlineAndFill { outline.draw(in: bounds) }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "\(tool.title), \(rawValue)"
        return image
    }

    private func styledIcon(for tool: PaintTool, corners: RectangleCorners, border: ShapeBorder) -> NSImage {
        let mode = self
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { bounds in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState(); defer { ctx.restoreGState() }
            let rect = bounds.insetBy(dx: 1.5, dy: 2.5)
            let iconCorners = RectangleCorners(style: corners.style, radius: min(5, max(0, corners.radius) / 4))
            let path: CGPath
            if tool == .line {
                let line = CGMutablePath(); line.move(to: CGPoint(x: 2, y: 3)); line.addLine(to: CGPoint(x: 16, y: 15)); path = line
            } else if tool == .ellipse { path = CGPath(ellipseIn: rect, transform: nil) }
            else { path = iconCorners.path(in: rect) }
            if tool != .selection && tool != .line && mode != .outline {
                ctx.setFillColor(NSColor.black.withAlphaComponent(mode == .fill ? 1 : 0.35).cgColor)
                ctx.addPath(path); ctx.fillPath()
            }
            if tool == .selection || tool == .line || mode.drawsOutline {
                ctx.setStrokeColor(NSColor.black.cgColor); ctx.setLineWidth(1.2); ctx.setLineJoin(.round)
                if tool == .selection { ctx.setLineDash(phase: 0, lengths: [2, 2]) }
                else {
                    let scaled = ShapeBorder(style: border.style, dashLength: max(1, min(6, border.dashLength / 3)), gap: max(0.8, min(3, border.gap / 3)))
                    scaled.apply(to: ctx, width: 1.2)
                }
                ctx.addPath(path); ctx.strokePath()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "\(tool.title), \(rawValue), \(corners.style.rawValue), \(border.style.rawValue)"
        return image
    }
}
