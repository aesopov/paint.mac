import AppKit

/// Union of round-ended hard segments for one gesture. Composite coverage
/// against the starting pixels so joins, pauses, and crossings never multiply
/// tool opacity. Separate gestures still build up paint/erasure normally.
struct HardBrushStroke {
    let original: Raster
    private var coverage: [Int: [Float]] = [:]

    init(original: Raster) { self.original = original }

    mutating func paint(on raster: inout Raster, from start: CGPoint, to end: CGPoint,
                        size: Double, color: PixelColor, opacity: Double, erase: Bool,
                        selection: SelectionMask?, antialias: Bool) {
        guard opacity > 0, color.a > 0 else { return }
        let start = antialias ? start : CGPoint(x: floor(start.x) + 0.5, y: floor(start.y) + 0.5)
        let end = antialias ? end : CGPoint(x: floor(end.x) + 0.5, y: floor(end.y) + 0.5)
        let radius = max(0.5, size / 2), profile = BrushProfile(radius: max(0.5, size / 2), hardness: 1, antialias: antialias)
        let area = CGRect(x: min(start.x, end.x) - radius - 1, y: min(start.y, end.y) - radius - 1,
                          width: abs(end.x - start.x) + radius * 2 + 2, height: abs(end.y - start.y) + radius * 2 + 2)
            .integral.intersection(raster.bounds).intersection(selection?.bounds ?? raster.bounds)
        guard !area.isNull, !area.isEmpty else { return }
        let dx = end.x - start.x, dy = end.y - start.y, lengthSquared = dx * dx + dy * dy
        let depth = raster.depth, colors = color.components(in: raster.format.profile)
        let strength = opacity * Double(color.a) / 255
        let side = raster.storage.tileSide, columns = raster.storage.columns
        for ty in Int(area.minY) / side...Int(area.maxY - 1) / side {
            for tx in Int(area.minX) / side...Int(area.maxX - 1) / side {
                let key = ty * columns + tx, ox = tx * side, oy = ty * side
                let region = area.intersection(CGRect(x: ox, y: oy, width: side, height: side))
                var mask = coverage.removeValue(forKey: key) ?? [Float](repeating: 0, count: side * side)
                let sourceData = original.storage.read(region), selectionData = selection?.storage.read(region)
                // Scratch reads/writes stay within the segment's affected tile
                // region; only the coverage array spans the complete tile.
                raster.storage.edit(in: region) { data, region in
                    mask.withUnsafeMutableBufferPointer { accumulated in
                        sourceData.withUnsafeBytes { sourceRaw in
                            let source = RGBSamples(raw: UnsafeMutableRawBufferPointer(mutating: sourceRaw), depth: depth)
                            data.withUnsafeMutableBytes { raw in
                                let pixels = RGBSamples(raw: raw, depth: depth), rw = Int(region.width)
                                for y in Int(region.minY)..<Int(region.maxY) { for x in Int(region.minX)..<Int(region.maxX) {
                                    let m = (y - oy) * side + x - ox
                                    guard accumulated[m] < 1 else { continue }
                                    let px = Double(x) + 0.5, py = Double(y) + 0.5
                                    let t = lengthSquared == 0 ? 0 : max(0, min(1, ((px - start.x) * dx + (py - start.y) * dy) / lengthSquared))
                                    let value = Float(profile.coverage(at: hypot(px - start.x - t * dx, py - start.y - t * dy)))
                                    guard value > accumulated[m] else { continue }
                                    accumulated[m] = value
                                    let position = (y - Int(region.minY)) * rw + x - Int(region.minX), i = position * 4
                                    let alpha = Double(value) * strength * Double(selectionData?[position] ?? 255) / 255
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
                coverage[key] = mask
            }
        }
    }
}
