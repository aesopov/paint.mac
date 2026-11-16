import AppKit

/// The dragged geometry is the reference boundary, independent of thickness.
enum ShapeOutlineAlignment: String, CaseIterable {
    case inside = "Inside", center = "Center", outside = "Outside"

    var strokeMultiplier: Double { self == .center ? 1 : 2 }
    func expansion(for size: Double) -> Double {
        switch self {
        case .inside: return 0
        case .center: return max(1, size) / 2
        case .outside: return max(1, size)
        }
    }

    static func strokePath(_ path: CGPath, rect: CGRect, ellipse: Bool, width: Double) -> CGPath {
        guard ellipse, width >= min(rect.width, rect.height) else { return path }
        // Quartz's Bézier offsetter folds the inner contour of very wide
        // ellipses, creating a false hole. A finely sampled closed polyline
        // gives its stroker ordinary round joins and the correct union instead.
        let radius = max(rect.width, rect.height) / 2
        let segments = max(64, min(2048, Int(ceil(.pi * sqrt(radius / 0.04) / 4)) * 4))
        let points = (0..<segments).map { index -> CGPoint in
            let angle = Double(index) * 2 * .pi / Double(segments)
            return CGPoint(x: rect.midX + rect.width / 2 * cos(angle),
                           y: rect.midY + rect.height / 2 * sin(angle))
        }
        let outline = CGMutablePath(); outline.addLines(between: points); outline.closeSubpath()
        return outline
    }

    /// Clip a doubled stroke to one side of the original path. Unlike shrinking
    /// an ellipse's axes, this keeps the true boundary and constant thickness;
    /// very thick inside strokes also work when the interior disappears.
    func clipOutline(in context: CGContext, path: CGPath, region: CGRect, antialias: Bool) {
        switch self {
        case .center: break
        case .inside: context.addPath(path); context.clip()
        case .outside:
            // Quartz's aliased even-odd clip includes one extra edge row on
            // ellipses compared with filling that same ellipse. Invert a fill
            // mask so Outside excludes the exact pixels of the reference shape.
            let width = Int(region.width), height = Int(region.height)
            var bytes = [UInt8](repeating: 255, count: width * height)
            let image = bytes.withUnsafeMutableBytes { raw -> CGImage? in
                guard let mask = CGContext(data: raw.baseAddress, width: width, height: height,
                                           bitsPerComponent: 8, bytesPerRow: width,
                                           space: SelectionMask.colorSpace, bitmapInfo: 0) else { return nil }
                // No vertical flip: CGImage clipping supplies it in the caller's
                // top-left drawing coordinates, including asymmetric regions.
                mask.translateBy(x: -region.minX, y: -region.minY)
                mask.setShouldAntialias(antialias); mask.setFillColor(gray: 0, alpha: 1)
                mask.addPath(path); mask.fillPath()
                return mask.makeImage()
            }
            if let image { context.clip(to: region, mask: image) }
            else { context.addRect(region); context.addPath(path); context.clip(using: .evenOdd) }
        }
    }
}
