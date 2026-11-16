import AppKit

enum RectangleCornerStyle: String, CaseIterable {
    case square = "Square", round = "Round", squircle = "Squircle"
    case bevel = "Bevel", scoop = "Scoop", notch = "Notch"
}

struct RectangleCorners: Equatable {
    var style: RectangleCornerStyle = .square
    var radius: Double = 16
    static let square = RectangleCorners()
    var isStyled: Bool { style != .square && radius.isFinite && radius > 0 }

    func path(in rect: CGRect) -> CGPath {
        let r = radius.isFinite ? max(0, min(radius, min(rect.width, rect.height) / 2)) : 0
        guard style != .square, r > 0 else { return CGPath(rect: rect, transform: nil) }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        let vertices: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)),
            (CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: 0, y: 1), CGPoint(x: -1, y: 0)),
            (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: -1, y: 0), CGPoint(x: 0, y: -1)),
            (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: 0, y: -1), CGPoint(x: 1, y: 0))
        ]
        for (v, incoming, outgoing) in vertices {
            let start = CGPoint(x: v.x - incoming.x * r, y: v.y - incoming.y * r)
            let end = CGPoint(x: v.x + outgoing.x * r, y: v.y + outgoing.y * r)
            path.addLine(to: start)
            switch style {
            case .square: path.addLine(to: v); path.addLine(to: end)
            case .bevel: path.addLine(to: end)
            case .notch:
                path.addLine(to: CGPoint(x: start.x + outgoing.x * r, y: start.y + outgoing.y * r))
                path.addLine(to: end)
            case .round, .squircle:
                // A continuous cubic approximation to a fourth-power corner
                // uses longer tangents than the circular quarter arc.
                let k = style == .round ? 0.5522847498307936 : 0.909138
                path.addCurve(to: end,
                              control1: CGPoint(x: start.x + incoming.x * r * k, y: start.y + incoming.y * r * k),
                              control2: CGPoint(x: end.x - outgoing.x * r * k, y: end.y - outgoing.y * r * k))
            case .scoop:
                let k = 0.5522847498307936
                path.addCurve(to: end,
                              control1: CGPoint(x: start.x + outgoing.x * r * k, y: start.y + outgoing.y * r * k),
                              control2: CGPoint(x: end.x - incoming.x * r * k, y: end.y - incoming.y * r * k))
            }
        }
        path.closeSubpath()
        return path
    }
}

enum ShapeBorderStyle: String, CaseIterable {
    case solid = "Solid", dotted = "Dotted", dashed = "Dashed"
}

struct ShapeBorder: Equatable {
    var style: ShapeBorderStyle = .solid
    var dashLength: Double = 8
    var gap: Double = 4
    static let solid = ShapeBorder()

    func apply(to context: CGContext, width: Double) {
        let dash = dashLength.isFinite ? max(0.5, min(8192, dashLength)) : 8
        let spacing = gap.isFinite ? max(0, min(8192, gap)) : 4
        context.setLineCap(style == .dotted ? .round : .butt)
        switch style {
        case .solid: context.setLineDash(phase: 0, lengths: [])
        case .dashed: context.setLineDash(phase: 0, lengths: [dash, spacing])
        case .dotted: context.setLineDash(phase: 0, lengths: [0, max(1, width) + spacing])
        }
    }
}
