import AppKit

/// Local retouching in the raster's tagged, premultiplied RGB sample space.
/// Fixed image-space dab spacing makes results independent of input frequency.
struct RetouchStroke {
    enum Kind { case blur, sharpen, smudge }
    let kind: Kind
    let size: Double
    let hardness: Double
    let strength: Double
    let antialias: Bool
    private var lastPoint: CGPoint?
    private var distanceToNext = 0.0
    private var carried: [Float]?
    private var carrySide = 0

    init(kind: Kind, size: Double, hardness: Double, strength: Double, antialias: Bool) {
        self.kind = kind; self.size = max(1, min(300, size))
        self.hardness = hardness; self.strength = max(0, min(1, strength)); self.antialias = antialias
    }
    mutating func paint(on raster: inout Raster, to point: CGPoint, selection: SelectionMask?) {
        let point = antialias ? point : CGPoint(x: floor(point.x) + 0.5, y: floor(point.y) + 0.5)
        let spacing = max(0.5, size * 0.15)
        guard let start = lastPoint else {
            lastPoint = point; distanceToNext = spacing
            if kind == .smudge {
                carrySide = Int(ceil(size)) + 2
                carried = pickup(raster, center: point)
            } else { dab(on: &raster, at: point, spacing: spacing, selection: selection) }
            return
        }
        let dx = point.x - start.x, dy = point.y - start.y, length = hypot(dx, dy)
        guard length > 1e-8 else { return }
        var distance = distanceToNext
        while distance <= length + 1e-8 {
            let center = CGPoint(x: start.x + dx * distance / length, y: start.y + dy * distance / length)
            dab(on: &raster, at: center, spacing: spacing, selection: selection)
            distance += spacing
        }
        distanceToNext = distance - length; lastPoint = point
    }
    private func pickup(_ raster: Raster, center: CGPoint) -> [Float] {
        let origin = CGPoint(x: center.x - Double(carrySide) / 2, y: center.y - Double(carrySide) / 2)
        let patch = Patch(raster, region: CGRect(origin: origin, size: CGSize(width: carrySide, height: carrySide)).insetBy(dx: -1, dy: -1))
        var result = [Float](repeating: 0, count: carrySide * carrySide * 4)
        for y in 0..<carrySide { for x in 0..<carrySide {
            let px = origin.x + Double(x) + 0.5, py = origin.y + Double(y) + 0.5
            guard raster.bounds.contains(CGPoint(x: px, y: py)) else { continue }
            for c in 0..<4 { result[(y * carrySide + x) * 4 + c] = patch.sample(x: px - 0.5, y: py - 0.5, channel: c) }
        } }
        return result
    }
    private mutating func dab(on raster: inout Raster, at center: CGPoint, spacing: Double, selection: SelectionMask?) {
        guard strength > 0 else { return }
        let radius = size / 2
        let area = CGRect(x: center.x - radius - 1, y: center.y - radius - 1, width: size + 2, height: size + 2)
            .integral.intersection(raster.bounds).intersection(selection?.bounds ?? raster.bounds)
        guard !area.isNull, !area.isEmpty else { return }
        let kernel = max(1, Int(ceil(size / 24)))
        let patch = Patch(raster, region: area.insetBy(dx: -CGFloat(kernel * 3), dy: -CGFloat(kernel * 3)))
        guard patch.width > 0, patch.height > 0 else { return }
        let filtered = kind == .smudge ? [] : Self.blurred(patch.values, width: patch.width, height: patch.height, radius: kernel)
        let profile = BrushProfile(radius: radius, hardness: hardness, antialias: antialias)
        let flow = Float(1 - pow(1 - strength, spacing / (size * 0.25)))
        let payload = carried, side = carrySide, kind = kind, depth = raster.depth
        raster.editPixels(in: area, selection: selection) { raw, region in
            let pixels = RGBSamples(raw: raw, depth: depth), rw = Int(region.width)
            for y in 0..<Int(region.height) { for x in 0..<rw {
                let px = region.minX + CGFloat(x) + 0.5, py = region.minY + CGFloat(y) + 0.5
                let weight = Float(profile.coverage(at: hypot(px - center.x, py - center.y))) * flow
                guard weight > 0 else { continue }
                let src = ((Int(py) - patch.y) * patch.width + Int(px) - patch.x) * 4
                let i = (y * rw + x) * 4
                let alpha = patch.values[src + 3]
                let targetAlpha: Float
                if kind == .smudge, let payload {
                    targetAlpha = Patch.interpolate(payload, width: side, height: side,
                                                    x: px - center.x + Double(side) / 2 - 0.5,
                                                    y: py - center.y + Double(side) / 2 - 0.5, channel: 3)
                } else { targetAlpha = kind == .sharpen ? alpha : max(0, min(1, filtered[src + 3])) }
                let appliedAlpha = max(0, min(1, alpha + (targetAlpha - alpha) * weight))
                for c in 0..<4 {
                    let target: Float
                    if kind == .smudge, let payload {
                        target = Patch.interpolate(payload, width: side, height: side,
                                                   x: px - center.x + Double(side) / 2 - 0.5,
                                                   y: py - center.y + Double(side) / 2 - 0.5, channel: c)
                    } else if kind == .sharpen {
                        if c == 3 { target = alpha }
                        else {
                            let blurredAlpha = filtered[src + 3]
                            let neighbor = blurredAlpha > 0 ? filtered[src + c] / blurredAlpha * alpha : patch.values[src + c]
                            target = max(0, min(alpha, 2 * patch.values[src + c] - neighbor))
                        }
                    } else { target = filtered[src + c] }
                    let value = c == 3 ? appliedAlpha : max(0, min(appliedAlpha, patch.values[src + c] + (target - patch.values[src + c]) * weight))
                    pixels[i + c] = Double(value) * pixels.maximum
                }
            } }
        }
        if kind == .smudge, let carried {
            let fresh = pickup(raster, center: center), pickupRate: Float = 0.15
            self.carried = zip(carried, fresh).map { $0 + ($1 - $0) * pickupRate }
        }
    }
    /// Three separable box passes approximate a Gaussian in bounded scratch
    /// memory. The halo crosses tile boundaries; canvas edges clamp samples.
    private static func blurred(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var source = values, result = [Float](repeating: 0, count: values.count)
        let divisor = Float(radius * 2 + 1)
        for _ in 0..<3 {
            for y in 0..<height { for c in 0..<4 {
                var sum: Float = 0
                for x in -radius...radius { sum += source[(y * width + max(0, min(width - 1, x))) * 4 + c] }
                for x in 0..<width {
                    result[(y * width + x) * 4 + c] = sum / divisor
                    sum += source[(y * width + min(width - 1, x + radius + 1)) * 4 + c]
                    sum -= source[(y * width + max(0, x - radius)) * 4 + c]
                }
            } }
            swap(&source, &result)
            for x in 0..<width { for c in 0..<4 {
                var sum: Float = 0
                for y in -radius...radius { sum += source[(max(0, min(height - 1, y)) * width + x) * 4 + c] }
                for y in 0..<height {
                    result[(y * width + x) * 4 + c] = sum / divisor
                    sum += source[(min(height - 1, y + radius + 1) * width + x) * 4 + c]
                    sum -= source[(max(0, y - radius) * width + x) * 4 + c]
                }
            } }
            swap(&source, &result)
        }
        return source
    }
    private struct Patch {
        let x: Int, y: Int, width: Int, height: Int
        let values: [Float]
        init(_ raster: Raster, region: CGRect) {
            let region = region.integral.intersection(raster.bounds)
            if region.isNull || region.isEmpty { x = 0; y = 0; width = 0; height = 0; values = []; return }
            x = Int(region.minX); y = Int(region.minY); width = Int(region.width); height = Int(region.height)
            let bytes = raster.storage.read(region)
            let count = width * height * 4, depth = raster.depth
            values = bytes.withUnsafeBytes { raw in
                let p = RGBSamples(raw: UnsafeMutableRawBufferPointer(mutating: raw), depth: depth)
                return (0..<count).map { Float(p[$0] / p.maximum) }
            }
        }
        func sample(x px: Double, y py: Double, channel: Int) -> Float {
            Self.interpolate(values, width: width, height: height, x: px - Double(x), y: py - Double(y), channel: channel)
        }
        static func interpolate(_ values: [Float], width: Int, height: Int, x: Double, y: Double, channel: Int) -> Float {
            guard width > 0, height > 0 else { return 0 }
            let x0 = Int(floor(x)), y0 = Int(floor(y)), fx = Float(x - floor(x)), fy = Float(y - floor(y))
            func at(_ x: Int, _ y: Int) -> Float { values[(max(0, min(height - 1, y)) * width + max(0, min(width - 1, x))) * 4 + channel] }
            let a = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx
            let b = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx
            return a * (1 - fy) + b * fy
        }
    }
}
