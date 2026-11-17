import AppKit

/// A brush-local spatial reservoir. Mix the *unpainted* canvas into it before
/// depositing, so even a fully opaque dab can pick up newly encountered detail.
/// Values stay premultiplied in the raster's tagged RGB space, including alpha.
struct SmudgeBrush {
    private let size: Double
    private let length: Double
    private let preserveAlpha: Bool
    private let side: Int
    private let profile: BrushProfile
    private var reservoir: [SIMD4<Float>]
    private var source: [SIMD4<Float>] = []

    init(size: Double, hardness: Double, antialias: Bool, length: Double, preserveAlpha: Bool) {
        self.size = size; self.length = max(0, min(1, length)); self.preserveAlpha = preserveAlpha
        side = Int(ceil(size)) + 2
        profile = BrushProfile(radius: size / 2, hardness: hardness, antialias: antialias)
        reservoir = Array(repeating: .zero, count: side * side)
    }

    mutating func pickUp(_ raster: Raster, at center: CGPoint) {
        sample(raster, at: center, pickup: 1, initial: true)
    }

    mutating func dab(on raster: inout Raster, at center: CGPoint, distance: Double,
                      strength: Double, selection: SelectionMask?) {
        guard strength > 0, length > 0 else { return }
        let area = CGRect(x: center.x - size / 2 - 1, y: center.y - size / 2 - 1, width: size + 2, height: size + 2)
            .integral.intersection(raster.bounds).intersection(selection?.bounds ?? raster.bounds)
        guard !area.isNull, !area.isEmpty else { return }
        // Length retains this fraction per 5% of a brush diameter. Normalize by
        // distance so future spacing changes don't change the retention rate.
        // At 100% retain the initial pickup; 0% is an explicit no-op above.
        let pickup = Float(1 - pow(length, distance / (size * 0.05)))
        sample(raster, at: center, pickup: pickup, initial: false)
        let flow = Float(1 - pow(1 - strength, distance / (size * 0.25)))
        let side = side, profile = profile, depth = raster.depth, preserveAlpha = preserveAlpha
        let origin = CGPoint(x: center.x - Double(side) / 2, y: center.y - Double(side) / 2)
        reservoir.withUnsafeBufferPointer { payload in
            raster.editPixels(in: area, selection: selection) { raw, region in
                let pixels = RGBSamples(raw: raw, depth: depth), rw = Int(region.width)
                for y in 0..<Int(region.height) { for x in 0..<rw {
                    let px = region.minX + Double(x) + 0.5, py = region.minY + Double(y) + 0.5
                    let weight = Float(profile.coverage(at: hypot(px - center.x, py - center.y))) * flow
                    guard weight > 0 else { continue }
                    let i = (y * rw + x) * 4
                    let old = SIMD4<Float>(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]), Float(pixels[i + 3])) / Float(pixels.maximum)
                    var target = Self.bilinear(payload, width: side, height: side, x: px - origin.x - 0.5, y: py - origin.y - 0.5)
                    if preserveAlpha {
                        guard target.w > 0, old.w > 0 else { continue }
                        target *= old.w / target.w
                        target.w = old.w
                    }
                    let mixed = old + (target - old) * weight
                    let alpha = preserveAlpha ? old.w : max(0, min(1, mixed.w))
                    for c in 0..<3 { pixels[i + c] = Double(max(0, min(alpha, mixed[c]))) * pixels.maximum }
                    // Preserve original integer alpha exactly, including 16-bit low bits.
                    if !preserveAlpha { pixels[i + 3] = Double(alpha) * pixels.maximum }
                } }
            }
        }
    }

    /// One bounded read per dab; reuse the float scratch and reservoir arrays.
    /// Refresh the whole patch at the same rate, including its interpolation
    /// padding. Weighting pickup by softness preserves stale color at the fringe
    /// and creates long colored rails. The brush profile belongs to deposition.
    private mutating func sample(_ raster: Raster, at center: CGPoint, pickup: Float, initial: Bool) {
        guard pickup > 0 else { return }
        let origin = CGPoint(x: center.x - Double(side) / 2, y: center.y - Double(side) / 2)
        let area = CGRect(origin: origin, size: CGSize(width: side, height: side)).insetBy(dx: -1, dy: -1)
            .integral.intersection(raster.bounds)
        guard !area.isNull, !area.isEmpty else {
            if initial { reservoir = Array(repeating: .zero, count: side * side) }
            return
        }
        let width = Int(area.width), height = Int(area.height), count = width * height
        if source.count < count { source = Array(repeating: .zero, count: count) }
        let data = raster.storage.read(area), depth = raster.depth
        source.withUnsafeMutableBufferPointer { values in
            data.withUnsafeBytes { raw in
                let p = RGBSamples(raw: UnsafeMutableRawBufferPointer(mutating: raw), depth: depth)
                let scale = Float(1 / p.maximum)
                for i in 0..<count { let j = i * 4
                    values[i] = SIMD4(Float(p[j]), Float(p[j + 1]), Float(p[j + 2]), Float(p[j + 3])) * scale
                }
            }
        }
        let side = side
        source.withUnsafeBufferPointer { values in
            reservoir.withUnsafeMutableBufferPointer { carried in
                for y in 0..<side { for x in 0..<side {
                    let i = y * side + x
                    let px = origin.x + Double(x), py = origin.y + Double(y)
                    let sample: SIMD4<Float> = raster.bounds.contains(CGPoint(x: px + 0.5, y: py + 0.5))
                        ? Self.bilinear(values, width: width, height: height, x: px - area.minX, y: py - area.minY) : .zero
                    carried[i] = initial ? sample : carried[i] + (sample - carried[i]) * pickup
                } }
            }
        }
    }

    private static func bilinear(_ values: UnsafeBufferPointer<SIMD4<Float>>, width: Int, height: Int,
                                 x: Double, y: Double) -> SIMD4<Float> {
        let ix = Int(floor(x)), iy = Int(floor(y)), fx = Float(x - floor(x)), fy = Float(y - floor(y))
        let x0 = max(0, min(width - 1, ix)), x1 = max(0, min(width - 1, ix + 1))
        let y0 = max(0, min(height - 1, iy)) * width, y1 = max(0, min(height - 1, iy + 1)) * width
        let top = values[y0 + x0] + (values[y0 + x1] - values[y0 + x0]) * fx
        let bottom = values[y1 + x0] + (values[y1 + x1] - values[y1 + x0]) * fx
        return top + (bottom - top) * fy
    }
}
