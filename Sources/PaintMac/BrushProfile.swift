import AppKit

/// Hardness controls intentional opacity falloff, independently of edge AA.
struct BrushProfile {
    let radius: Double
    let hardness: Double
    let antialias: Bool
    init(radius: Double, hardness: Double, antialias: Bool) {
        self.radius = radius
        self.hardness = hardness.isFinite ? max(0, min(1, hardness)) : 1
        self.antialias = antialias
    }
    @inline(__always) static func ramp(_ value: Double) -> Double {
        let t = max(0, min(1, value)); return t * t * (3 - 2 * t)
    }
    @inline(__always) func coverage(at distance: Double) -> Double {
        if hardness == 1 { return antialias ? max(0, min(1, radius + 0.5 - distance)) : (distance <= radius ? 1 : 0) }
        return Self.ramp((radius - distance) / (radius * (1 - hardness)))
    }
}

/// Deposit soft dabs at fixed distances along the input path. Source-over in
/// the coverage mask makes crossings smooth; compositing against the original
/// raster applies tool opacity, color alpha, and selection coverage only once.
struct SoftBrushStroke {
    let original: Raster
    private var coverage: [Int: [Float]] = [:]
    private var lastPoint: CGPoint?
    private var distanceToNextDab = 0.0
    private var dab: SoftBrushDab?
    init(original: Raster) {
        self.original = original
    }
    mutating func paint(on raster: inout Raster, from start: CGPoint, to end: CGPoint, size: Double,
                        color: PixelColor, opacity: Double, erase: Bool, selection: SelectionMask?, antialias: Bool, hardness: Double) {
        if dab?.size != size || dab?.hardness != hardness { dab = SoftBrushDab(size: size, hardness: hardness) }
        let dab = dab!
        func snapped(_ point: CGPoint) -> CGPoint {
            antialias ? point : CGPoint(x: floor(point.x) + 0.5, y: floor(point.y) + 0.5)
        }
        var points: [CGPoint] = []
        if lastPoint == nil { lastPoint = snapped(start); points.append(lastPoint!); distanceToNextDab = dab.spacing }
        let a = lastPoint!, b = snapped(end), dx = b.x - a.x, dy = b.y - a.y, length = hypot(dx, dy)
        if length > 0 {
            var distance = distanceToNextDab
            while distance <= length {
                points.append(CGPoint(x: a.x + dx * distance / length, y: a.y + dy * distance / length))
                distance += dab.spacing
            }
            distanceToNextDab = distance - length; lastPoint = b
        }
        // Repeated/stationary input adds no dabs. Spacing carries across events,
        // including short segments, so event frequency cannot change coverage.
        guard !points.isEmpty else { return }
        let bounds = raster.bounds.intersection(selection?.bounds ?? raster.bounds)
        let depth = raster.depth, colors = color.components(in: raster.format.profile)
        let columns = raster.storage.columns, side = raster.storage.tileSide
        var touched = Set<Int>()
        for point in points {
            let r = CGRect(x: point.x - dab.radius, y: point.y - dab.radius, width: 2 * dab.radius, height: 2 * dab.radius).integral.intersection(bounds)
            guard !r.isNull, !r.isEmpty else { continue }
            for ty in Int(r.minY) / side...Int(r.maxY - 1) / side {
                for tx in Int(r.minX) / side...Int(r.maxX - 1) / side { touched.insert(ty * columns + tx) }
            }
        }
        for key in touched {
            let ox = key % columns * side, oy = key / columns * side
            let tileRegion = CGRect(x: ox, y: oy, width: side, height: side).intersection(bounds)
            var accumulated = coverage.removeValue(forKey: key) ?? [Float](repeating: 0, count: side * side)
            let sourceData = original.storage.read(tileRegion)
            let selectionData = selection?.storage.read(tileRegion)
            raster.storage.edit(in: tileRegion) { data, region in
                accumulated.withUnsafeMutableBufferPointer { mask in
                    sourceData.withUnsafeBytes { sourceRaw in
                        let source = RGBSamples(raw: UnsafeMutableRawBufferPointer(mutating: sourceRaw), depth: depth)
                        data.withUnsafeMutableBytes { raw in
                            let pixels = RGBSamples(raw: raw, depth: depth), rw = Int(region.width)
                            for point in points {
                                let r = CGRect(x: point.x - dab.radius, y: point.y - dab.radius, width: 2 * dab.radius, height: 2 * dab.radius).integral.intersection(region)
                                guard !r.isNull, !r.isEmpty else { continue }
                                for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) {
                                    let m = (y - oy) * side + x - ox, position = (y - Int(region.minY)) * rw + x - Int(region.minX)
                                    let sx = Double(x) + 0.5 - point.x, sy = Double(y) + 0.5 - point.y
                                    let value = dab.coverage(distanceSquared: sx * sx + sy * sy)
                                    guard value > 0, mask[m] < 1 else { continue }
                                    mask[m] += value * (1 - mask[m])
                                    let coverage = depth == .eight ? Double((mask[m] * 255).rounded()) / 255 : Double(mask[m])
                                    let alpha = coverage * opacity * Double(color.a) / 255 * Double(selectionData?[position] ?? 255) / 255
                                    let i = position * 4
                                    if erase {
                                        for c in 0..<4 { pixels[i + c] = source[i + c] * (1 - alpha) }
                                    } else {
                                        for (c, channel) in colors.enumerated() {
                                            pixels[i + c] = channel * pixels.maximum * alpha + source[i + c] * (1 - alpha)
                                        }
                                        pixels[i + 3] = pixels.maximum * alpha + source[i + 3] * (1 - alpha)
                                    }
                                } }
                            }
                        }
                    }
                }
            }
            coverage[key] = accumulated
        }
    }

}

/// Fine spacing avoids visible stamps. Adjust each dab's falloff to retain
/// the paint density of 25%-diameter spacing, with a cached radial lookup so
/// wide brushes don't evaluate powers for every pixel of every dab.
private struct SoftBrushDab {
    let size: Double
    let hardness: Double
    let radius: Double
    let spacing: Double
    private let samples: [Float]
    init(size: Double, hardness: Double) {
        self.size = size; self.hardness = hardness
        let radius = max(0.5, size / 2), spacing = max(0.5, size * 0.1)
        self.radius = radius; self.spacing = spacing
        let profile = BrushProfile(radius: radius, hardness: hardness, antialias: true)
        let weight = min(1, spacing / (radius * 0.5))
        samples = (0...4096).map { i in
            let coverage = profile.coverage(at: radius * sqrt(Double(i) / 4096))
            return Float(1 - pow(1 - coverage, weight))
        }
    }
    @inline(__always) func coverage(distanceSquared: Double) -> Float {
        let t = distanceSquared / (radius * radius) * 4096
        guard t < 4096 else { return 0 }
        let i = Int(t), f = Float(t - Double(i))
        return samples[i] + (samples[i + 1] - samples[i]) * f
    }
}

extension Raster {
    /// Nested vector strokes write coverage into a small linear grayscale buffer.
    /// Copy blending replaces coverage instead of repeatedly accumulating it.
    /// This retains Quartz's accurate ellipse geometry and round joins, even
    /// for wide outlines, and avoids stamping hundreds of overlapping disks.
    /// Hard inside-filled shapes share this path to partition fill/outline
    /// coverage without multiplying their shared antialiased outer edge.
    mutating func strokeMaskedShape(in rect: CGRect, ellipse: Bool, size: Double, color: PixelColor,
                                  opacity: Double, clip: CGRect?, selection: SelectionMask?, antialias: Bool,
                                  fillColor: PixelColor?, hardness: Double, alignment: ShapeOutlineAlignment = .center,
                                  corners: RectangleCorners = .square, border: ShapeBorder = .solid, sourcePath: CGPath? = nil) {
        let radius = max(0.5, size / 2) * alignment.strokeMultiplier
        let profile = BrushProfile(radius: radius, hardness: hardness, antialias: antialias)
        let expansion = alignment.expansion(for: size) + 1
        let region = rect.insetBy(dx: -expansion, dy: -expansion).integral.intersection(bounds)
            .intersection(clip ?? bounds).intersection(selection?.bounds ?? bounds).integral.intersection(bounds)
        guard !region.isNull, !region.isEmpty else { return }
        let rw = Int(region.width), rh = Int(region.height)
        let path = sourcePath ?? (ellipse ? CGPath(ellipseIn: rect, transform: nil) : corners.path(in: rect))
        let outlinePath = ShapeOutlineAlignment.strokePath(path, rect: rect, ellipse: ellipse, width: radius * 2)
        func mask(fill: Bool) -> Data? {
            var data = Data(count: rw * rh)
            let succeeded = data.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: rw, height: rh, bitsPerComponent: 8, bytesPerRow: rw,
                                          space: SelectionMask.colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                ctx.translateBy(x: -region.minX, y: region.maxY); ctx.scaleBy(x: 1, y: -1)
                ctx.clip(to: clip ?? bounds); ctx.setShouldAntialias(antialias)
                ctx.setBlendMode(.copy); ctx.setLineJoin(.round)
                if fill { ctx.setFillColor(gray: 1, alpha: 1); ctx.addPath(path); ctx.fillPath() }
                else {
                    border.apply(to: ctx, width: radius * 2)
                    let softness = radius * (1 - profile.hardness)
                    let steps = softness == 0 ? 1 : min(128, max(8, Int(ceil(softness * 2))))
                    for i in 0..<steps {
                        let t = softness == 0 ? 1 : (Double(i) + 0.5) / Double(steps)
                        let width = 2 * (radius - softness * t)
                        ctx.setLineWidth(width)
                        ctx.setStrokeColor(gray: BrushProfile.ramp(t), alpha: 1)
                        if alignment == .inside && border.style == .solid && width >= min(rect.width, rect.height) {
                            ctx.setFillColor(gray: BrushProfile.ramp(t), alpha: 1)
                            ctx.addPath(path); ctx.fillPath()
                        } else { ctx.addPath(outlinePath); ctx.strokePath() }
                    }
                }
                return true
            }
            return succeeded ? data : nil
        }
        guard let outline = mask(fill: false) else { return }
        let fill = fillColor != nil || alignment != .center ? mask(fill: true) : nil
        let depth = depth, strokeColors = color.components(in: format.profile), fillColors = (fillColor ?? .clear).components(in: format.profile)
        let channels = Array(zip(strokeColors, fillColors))
        let ox = Int(region.minX), oy = Int(region.minY)
        editPixels(in: region) { raw, _ in
            let pixels = RGBSamples(raw: raw, depth: depth)
            for y in 0..<rh { for x in 0..<rw {
                let m = y * rw + x, i = m * 4
                let shapeCoverage = Double(fill?[m] ?? 0) / 255, rawStroke = Double(outline[m]) / 255
                let strokeCoverage: Double, overlap: Double
                switch alignment {
                case .inside: strokeCoverage = min(rawStroke, shapeCoverage); overlap = strokeCoverage
                case .outside: strokeCoverage = max(0, rawStroke - shapeCoverage); overlap = 0
                case .center: strokeCoverage = rawStroke; overlap = min(rawStroke, shapeCoverage)
                }
                let strokeOpacity = Double(color.a) / 255
                let strokeAlpha = strokeCoverage * strokeOpacity
                // Coverage at a shared antialiased edge is correlated. Multiplying
                // fill by (1 - strokeAlpha) leaks fill color around an opaque border.
                let fillAlpha = max(0, shapeCoverage - overlap * strokeOpacity) * Double(fillColor?.a ?? 0) / 255
                let alpha = strokeAlpha + fillAlpha
                guard alpha > 0 else { continue }
                let strength = opacity * Double(selection?.value(x: x + ox, y: y + oy) ?? 255) / 255
                let applied = alpha * strength
                for (c, values) in channels.enumerated() {
                    let source = (values.0 * strokeAlpha + values.1 * fillAlpha) * strength * pixels.maximum
                    pixels[i + c] = source + pixels[i + c] * (1 - applied)
                }
                pixels[i + 3] = pixels.maximum * applied + pixels[i + 3] * (1 - applied)
            } }
        }
    }
}
