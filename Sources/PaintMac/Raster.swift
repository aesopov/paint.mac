import AppKit
import CoreImage
import Metal

struct PixelColor: Equatable, Codable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8 = 255
    var extendedRGB: [Double]? = nil

    static let black = PixelColor(r: 29, g: 32, b: 39)
    static let white = PixelColor(r: 255, g: 255, b: 255)
    static let clear = PixelColor(r: 0, g: 0, b: 0, a: 0)

    init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        let extended = color.usingColorSpace(.extendedSRGB) ?? c
        let values = [extended.redComponent, extended.greenComponent, extended.blueComponent]
        if values.contains(where: { $0 < -0.00001 || $0 > 1.00001 }) { extendedRGB = values.map { Double($0) } }
        r = UInt8((max(0, min(1, c.redComponent)) * 255).rounded())
        g = UInt8((max(0, min(1, c.greenComponent)) * 255).rounded())
        b = UInt8((max(0, min(1, c.blueComponent)) * 255).rounded())
        a = UInt8((max(0, min(1, c.alphaComponent)) * 255).rounded())
        let quantized = [Double(r), Double(g), Double(b)].map { $0 / 255 }
        if zip(values, quantized).contains(where: { abs(Double($0) - $1) > 0.00001 }) { extendedRGB = values.map { Double($0) } }
    }

    var nsColor: NSColor {
        if let extendedRGB, extendedRGB.count == 3, extendedRGB.allSatisfy(\.isFinite) {
            let components = (extendedRGB + [Double(a) / 255]).map { CGFloat($0) }
            return components.withUnsafeBufferPointer { NSColor(colorSpace: .extendedSRGB, components: $0.baseAddress!, count: 4) }
        }
        return NSColor(srgbRed: Double(r) / 255, green: Double(g) / 255,
                       blue: Double(b) / 255, alpha: Double(a) / 255)
    }
    var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
}

/// Premultiplied RGBA8/RGBA16 in the tagged RGB profile; top row first.
struct Raster: Equatable {
    let width: Int
    let height: Int
    var storage: TileGrid
    var resolution = ImageResolution.standard
    var format: RGBFormat { RGBFormat(profile: storage.profile, depth: storage.channels == 8 ? .sixteen : .eight) }
    var depth: RGBDepth { format.depth }
    var stride: Int { storage.channels }
    /// Contiguous pixels are an explicit compatibility boundary for codecs,
    /// export, and whole-image operations. Live painting uses bounded regions.
    var bytes: Data {
        get { storage.read() }
        set { storage.write(newValue, in: bounds) }
    }
    var ciImage: CIImage { storage.ciImage }
    var isTransparent: Bool {
        let alphaOffset = depth == .eight ? 3 : 6
        if storage.base[alphaOffset...] .contains(where: { $0 > 0 }) && storage.tiles.count < storage.rows * storage.columns { return false }
        let side = storage.tileSide
        for (key, tile) in storage.tiles {
            let w = min(side, width - key % storage.columns * side)
            let h = min(side, height - key / storage.columns * side)
            let empty = tile.data.withUnsafeBytes { raw -> Bool in
                let p = raw.bindMemory(to: UInt8.self)
                for y in 0..<h { for x in 0..<w {
                    let i = (y * side + x) * stride + alphaOffset
                    if p[i] > 0 || (depth == .sixteen && p[i + 1] > 0) { return false }
                } }
                return true
            }
            if !empty { return false }
        }
        return true
    }
    static func == (lhs: Raster, rhs: Raster) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height && lhs.storage == rhs.storage
    }
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init(width: Int, height: Int, color: PixelColor = .clear, format: RGBFormat = .standard) {
        self.width = width; self.height = height
        let values = color.components(in: format.profile), alpha = Double(color.a) / 255
        var base = Data(count: format.depth.bytesPerPixel)
        base.withUnsafeMutableBytes { raw in
            let p = RGBSamples(raw: raw, depth: format.depth)
            for c in 0..<3 { p[c] = values[c] * alpha * p.maximum }; p[3] = alpha * p.maximum
        }
        storage = TileGrid(width: width, height: height, channels: format.depth.bytesPerPixel, base: Array(base))
        storage.profile = format.profile
    }

    init(image: CGImage, format requested: RGBFormat? = nil) throws {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 32_000_000 else { throw PaintError.imageTooLarge }
        let format = requested ?? RGBFormat(profile: .imported(image.colorSpace), depth: image.bitsPerComponent > 8 ? .sixteen : .eight)
        try format.validate()
        self.init(width: width, height: height, format: format)
        var pixels = Data(count: width * height * format.depth.bytesPerPixel)
        let rendered = pixels.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: width, height: height,
                                      bitsPerComponent: format.depth.rawValue, bytesPerRow: width * format.depth.bytesPerPixel,
                                      space: format.profile.space, bitmapInfo: format.depth.bitmapInfo) else { return false }
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw PaintError.invalidImage }
        storage = TileGrid(width: width, height: height, channels: format.depth.bytesPerPixel, data: pixels)
        storage.profile = format.profile
    }
    func converted(to target: RGBFormat) throws -> Raster {
        guard format != target else { return self }
        var result = try Raster(image: cgImage, format: target)
        result.resolution = resolution
        return result
    }
    var cgImage: CGImage {
        CGImage(width: width, height: height, bitsPerComponent: depth.rawValue,
                bitsPerPixel: depth.rawValue * 4, bytesPerRow: width * stride,
                space: format.profile.space, bitmapInfo: CGBitmapInfo(rawValue: depth.bitmapInfo),
                provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    func pixel(x: Int, y: Int) -> PixelColor {
        guard x >= 0, y >= 0, x < width, y < height else { return .clear }
        if format == .standard {
            let a = Int(storage.value(x: x, y: y, channel: 3))
            guard a > 0 else { return .clear }
            return PixelColor(r: UInt8(min(255, Int(storage.value(x: x, y: y, channel: 0)) * 255 / a)),
                              g: UInt8(min(255, Int(storage.value(x: x, y: y, channel: 1)) * 255 / a)),
                              b: UInt8(min(255, Int(storage.value(x: x, y: y, channel: 2)) * 255 / a)), a: UInt8(a))
        }
        func value(_ c: Int) -> Double {
            let b = depth == .eight ? c : c * 2
            let low = storage.value(x: x, y: y, channel: b)
            if depth == .eight { return Double(low) / 255 }
            return Double(UInt16(low) | UInt16(storage.value(x: x, y: y, channel: b + 1)) << 8) / 65535
        }
        let a = value(3)
        guard a > 0 else { return .clear }
        let components = (0..<3).map { min(1, value($0) / a) } + [a]
        return PixelColor(NSColor(cgColor: CGColor(colorSpace: format.profile.space, components: components.map { CGFloat($0) })!)!)
    }

    mutating func fill(color: PixelColor, rect: CGRect? = nil) {
        let area = (rect ?? bounds).integral.intersection(bounds)
        guard !area.isNull, !area.isEmpty else { return }
        let solid = Raster(width: width, height: height, color: color, format: format).storage
        if area == bounds { storage = solid; return }
        let stride = stride, base = solid.base
        storage.edit(in: area) { data, _ in
            data.withUnsafeMutableBytes { raw in
                for i in 0..<raw.count { raw[i] = base[i % stride] }
            }
        }
    }

    /// A bounded scratch surface preserves Quartz geometry without allocating
    /// or copying an entire layer. Selection coverage is applied exactly once.
    mutating func editPixels(in area: CGRect, selection: SelectionMask? = nil,
                             _ body: (UnsafeMutableRawBufferPointer, CGRect) -> Void) {
        let depth = depth
        storage.edit(in: area) { data, region in
            let before = selection == nil ? Data() : data
            data.withUnsafeMutableBytes { body($0, region) }
            if let selection {
                data.withUnsafeMutableBytes { raw in
                    before.withUnsafeBytes { old in
                        let p = RGBSamples(raw: raw, depth: depth), src = RGBSamples(raw: UnsafeMutableRawBufferPointer(mutating: old), depth: depth)
                        let rw = Int(region.width)
                        for y in 0..<Int(region.height) { for x in 0..<rw {
                            let a = Int(selection.value(x: x + Int(region.minX), y: y + Int(region.minY))), i = (y * rw + x) * 4
                            for c in 0..<4 { p[i + c] = (p[i + c] * Double(a) + src[i + c] * Double(255 - a)) / 255 }
                        } }
                    }
                }
            }
        }
    }

    /// Draw one capsule, optionally with a radial hardness falloff.
    mutating func stroke(from start: CGPoint, to end: CGPoint, size: Double,
                         color: PixelColor, opacity: Double, erase: Bool, clip: CGRect?, selection: SelectionMask? = nil,
                         antialias: Bool = true, hardness: Double = 1) {
        strokeSegment(from: start, to: end, size: size, color: color, opacity: opacity, erase: erase,
                      clip: clip, selection: selection, antialias: antialias, hardness: hardness)
    }

    mutating func strokeSegment(from start: CGPoint, to end: CGPoint, size: Double,
                                color: PixelColor, opacity: Double, erase: Bool, clip: CGRect?, selection: SelectionMask?,
                                antialias: Bool, hardness: Double) {
        let start = antialias ? start : CGPoint(x: floor(start.x) + 0.5, y: floor(start.y) + 0.5)
        let end = antialias ? end : CGPoint(x: floor(end.x) + 0.5, y: floor(end.y) + 0.5)
        let radius = max(0.5, size / 2), profile = BrushProfile(radius: max(0.5, size / 2), hardness: hardness, antialias: antialias)
        let region = CGRect(x: min(start.x, end.x) - radius - 1,
                            y: min(start.y, end.y) - radius - 1,
                            width: abs(end.x - start.x) + radius * 2 + 2,
                            height: abs(end.y - start.y) + radius * 2 + 2)
            .integral.intersection(bounds).intersection(clip ?? bounds).intersection(selection?.bounds ?? bounds)
        guard !region.isNull, !region.isEmpty else { return }
        let dx = end.x - start.x, dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        let depth = depth, colors = color.components(in: format.profile)
        func render() {
            editPixels(in: region) { ptr, region in
                let p = RGBSamples(raw: ptr, depth: depth)
                for y in Int(region.minY)..<Int(region.maxY) {
                    for x in Int(region.minX)..<Int(region.maxX) {
                        let px = Double(x) + 0.5, py = Double(y) + 0.5
                        let t = lengthSquared == 0 ? 0 : max(0, min(1, ((px - start.x) * dx + (py - start.y) * dy) / lengthSquared))
                        let distance = hypot(px - start.x - t * dx, py - start.y - t * dy)
                        let coverage = profile.coverage(at: distance)
                        let selectionAlpha = selection.map { Double($0.value(x: x, y: y)) / 255 } ?? 1
                        let alpha = coverage * opacity * Double(color.a) / 255 * selectionAlpha
                        guard alpha > 0 else { continue }
                        let i = ((y - Int(region.minY)) * Int(region.width) + x - Int(region.minX)) * 4
                        if erase {
                            for c in 0..<4 { p[i + c] = p[i + c] * (1 - alpha) }
                        } else {
                            for (c, value) in colors.enumerated() {
                                p[i + c] = value * p.maximum * alpha + p[i + c] * (1 - alpha)
                            }
                            p[i + 3] = p.maximum * alpha + p[i + 3] * (1 - alpha)
                        }
                    }
                }
            }
        }
        render()
    }

    /// Rasterize a complete shape once. Quartz handles wide outlines without repeatedly
    /// visiting overlapping brush disks, and applies opacity uniformly around the path.
    mutating func strokeShape(in rect: CGRect, ellipse: Bool, size: Double,
                              color: PixelColor, opacity: Double, clip: CGRect?, selection: SelectionMask? = nil,
                              antialias: Bool = true, fillColor: PixelColor? = nil, hardness: Double = 1,
                              alignment: ShapeOutlineAlignment = .center, drawOutline: Bool = true,
                              corners: RectangleCorners = .square, border: ShapeBorder = .solid) {
        guard rect.width > 0, rect.height > 0 else { return }
        if !drawOutline {
            guard let fillColor else { return }
            fillShape(in: rect, ellipse: ellipse, color: fillColor, opacity: opacity, clip: clip, selection: selection, antialias: antialias, corners: corners)
            return
        }
        if BrushProfile(radius: 1, hardness: hardness, antialias: antialias).hardness < 1 || (fillColor != nil && alignment == .inside) {
            strokeMaskedShape(in: rect, ellipse: ellipse, size: size, color: color, opacity: opacity, clip: clip,
                            selection: selection, antialias: antialias, fillColor: fillColor, hardness: hardness, alignment: alignment, corners: corners, border: border)
            return
        }
        let radius = alignment.expansion(for: size) + 2
        let area = rect.insetBy(dx: -radius, dy: -radius).integral.intersection(clip ?? bounds).intersection(bounds).intersection(selection?.bounds ?? bounds)
        guard !area.isNull, !area.isEmpty else { return }
        let format = format
        editPixels(in: area, selection: selection) { ptr, region in
            let w = Int(region.width), h = Int(region.height)
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h,
                                      bitsPerComponent: format.depth.rawValue, bytesPerRow: w * format.depth.bytesPerPixel,
                                      space: format.profile.space,
                                      bitmapInfo: format.depth.bitmapInfo) else { return }
            ctx.translateBy(x: -region.minX, y: region.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.clip(to: area)
            ctx.setShouldAntialias(antialias)
            ctx.setLineWidth(max(1, size) * alignment.strokeMultiplier)
            ctx.setLineJoin(.round)
            border.apply(to: ctx, width: max(1, size) * alignment.strokeMultiplier)
            // Composite fill and outline together so tool opacity is applied once,
            // including where the stroke covers the inside edge of the fill.
            if fillColor != nil {
                ctx.setAlpha(opacity)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            ctx.setStrokeColor(color.nsColor.withAlphaComponent(Double(color.a) / 255 * (fillColor == nil ? opacity : 1)).cgColor)
            if let fillColor {
                ctx.setFillColor(fillColor.nsColor.cgColor)
            }
            let path = ellipse ? CGPath(ellipseIn: rect, transform: nil) : corners.path(in: rect)
            let outline = ShapeOutlineAlignment.strokePath(path, rect: rect, ellipse: ellipse, width: max(1, size) * alignment.strokeMultiplier)
            if alignment == .center {
                if outline === path {
                    ctx.addPath(path)
                    ctx.drawPath(using: fillColor == nil ? .stroke : .fillStroke)
                } else {
                    if fillColor != nil { ctx.addPath(path); ctx.fillPath() }
                    ctx.addPath(outline); ctx.strokePath()
                }
            } else {
                if fillColor != nil { ctx.addPath(path); ctx.fillPath() }
                ctx.saveGState()
                alignment.clipOutline(in: ctx, path: path, region: area, antialias: antialias)
                if alignment == .inside && border.style == .solid && max(1, size) * 2 >= min(rect.width, rect.height) {
                    ctx.setFillColor(color.nsColor.withAlphaComponent(Double(color.a) / 255 * (fillColor == nil ? opacity : 1)).cgColor)
                    ctx.addPath(path); ctx.fillPath()
                } else { ctx.addPath(outline); ctx.strokePath() }
                ctx.restoreGState()
            }
            if fillColor != nil { ctx.endTransparencyLayer() }
        }
    }

    private mutating func fillShape(in rect: CGRect, ellipse: Bool, color: PixelColor, opacity: Double,
                                    clip: CGRect?, selection: SelectionMask?, antialias: Bool, corners: RectangleCorners) {
        let area = rect.insetBy(dx: -1, dy: -1).integral.intersection(clip ?? bounds).intersection(bounds)
            .intersection(selection?.bounds ?? bounds)
        guard !area.isNull, !area.isEmpty else { return }
        let format = format
        editPixels(in: area, selection: selection) { raw, region in
            guard let ctx = CGContext(data: raw.baseAddress, width: Int(region.width), height: Int(region.height),
                                      bitsPerComponent: format.depth.rawValue, bytesPerRow: Int(region.width) * format.depth.bytesPerPixel,
                                      space: format.profile.space, bitmapInfo: format.depth.bitmapInfo) else { return }
            ctx.translateBy(x: -region.minX, y: region.maxY); ctx.scaleBy(x: 1, y: -1)
            ctx.clip(to: area); ctx.setShouldAntialias(antialias)
            ctx.setFillColor(color.nsColor.withAlphaComponent(Double(color.a) / 255 * opacity).cgColor)
            ctx.addPath(ellipse ? CGPath(ellipseIn: rect, transform: nil) : corners.path(in: rect))
            ctx.fillPath()
        }
    }

    mutating func strokeLine(from start: CGPoint, to end: CGPoint, size: Double, color: PixelColor, opacity: Double,
                             selection: SelectionMask?, antialias: Bool, hardness: Double, border: ShapeBorder) {
        if border.style == .solid || start == end {
            stroke(from: start, to: end, size: size, color: color, opacity: opacity, erase: false,
                   clip: nil, selection: selection, antialias: antialias, hardness: hardness)
            return
        }
        let path = CGMutablePath(); path.move(to: start); path.addLine(to: end)
        strokeMaskedShape(in: CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)),
                          ellipse: false, size: size, color: color, opacity: opacity, clip: nil, selection: selection,
                          antialias: antialias, fillColor: nil, hardness: hardness, border: border, sourcePath: path)
    }

    mutating func floodFill(at point: CGPoint, color: PixelColor, tolerance: Int, clip: CGRect?, selection: SelectionMask? = nil) {
        let x = Int(floor(point.x)), y = Int(floor(point.y))
        let area = (clip ?? bounds).integral.intersection(bounds).intersection(selection?.bounds ?? bounds)
        guard area.contains(CGPoint(x: x, y: y)) else { return }
        let target = pixel(x: x, y: y)
        if depth == .eight && target == color { return }
        let w = width, h = height, depth = depth
        let replacementColor = color.components(in: format.profile)
        let seed = storage.read(CGRect(x: x, y: y, width: 1, height: 1))
        let targetSamples = seed.withUnsafeBytes { raw -> [Double] in
            let p = RGBSamples(raw: UnsafeMutableRawBufferPointer(mutating: raw), depth: depth)
            let a = p[3]
            return (0..<3).map { a == 0 ? 0 : min(1, p[$0] / a) } + [a / p.maximum]
        }
        var visited = [Bool](repeating: false, count: w * h)
        var stack = [y * w + x]
        bytes.withUnsafeMutableBytes { ptr in
            let p = RGBSamples(raw: ptr, depth: depth)
            while let index = stack.popLast() {
                guard !visited[index] else { continue }
                visited[index] = true
                let px = index % w, py = index / w, i = index * 4
                guard area.contains(CGPoint(x: px, y: py)) else { continue }
                let coverage = Int(selection?.value(x: px, y: py) ?? 255)
                guard coverage > 0 else { continue }
                let a = p[i + 3]
                let current = (0..<3).map { a == 0 ? 0 : min(1, p[i + $0] / a) } + [a / p.maximum]
                guard zip(current, targetSamples).allSatisfy({ abs($0 - $1) * 255 <= Double(tolerance) + 0.001 }) else { continue }
                let alpha = Double(color.a) / 255
                let replacement = replacementColor.map { $0 * alpha * p.maximum } + [alpha * p.maximum]
                for c in 0..<4 { p[i + c] = (replacement[c] * Double(coverage) + p[i + c] * Double(255 - coverage)) / 255 }
                // Mark on pop so every connected pixel is visited, with bounded neighbor indices.
                if px > 0 && !visited[index - 1] { stack.append(index - 1) }
                if px + 1 < w && !visited[index + 1] { stack.append(index + 1) }
                if py > 0 && !visited[index - w] { stack.append(index - w) }
                if py + 1 < h && !visited[index + w] { stack.append(index + w) }
            }
        }
    }

    func cropped(to rect: CGRect) -> Raster {
        let area = rect.integral.intersection(bounds)
        guard !area.isNull, !area.isEmpty else { return Raster(width: 1, height: 1, format: format) }
        var result = Raster(width: Int(area.width), height: Int(area.height), format: format)
        result.storage = TileGrid(width: result.width, height: result.height, channels: stride, data: storage.read(area))
        result.storage.profile = format.profile; result.resolution = resolution
        return result
    }

    func translated(dx: Int, dy: Int, selection: CGRect?) -> Raster {
        let area = (selection ?? bounds).integral.intersection(bounds)
        var result = self
        result.fill(color: .clear, rect: area)
        guard !area.isNull, !area.isEmpty else { return result }
        let source = bytes
        var destination = result.bytes
        destination.withUnsafeMutableBytes { raw in
            source.withUnsafeBytes { old in
                let dst = RGBSamples(raw: raw, depth: depth), src = RGBSamples(raw: UnsafeMutableRawBufferPointer(mutating: old), depth: depth)
                for y in Int(area.minY)..<Int(area.maxY) { for x in Int(area.minX)..<Int(area.maxX) {
                    let tx = x + dx, ty = y + dy
                    guard tx >= 0, tx < width, ty >= 0, ty < height else { continue }
                    let i = (y * width + x) * 4, j = (ty * width + tx) * 4
                    let alpha = src[i + 3] / src.maximum
                    for c in 0..<4 { dst[j + c] = src[i + c] + dst[j + c] * (1 - alpha) }
                } }
            }
        }
        result.bytes = destination
        return result
    }

    /// Interpolate edited premultiplied pixels by mask coverage, preserving holes
    /// and feathering for filters and any future raster operations.
    func blending(_ edited: Raster, selection: SelectionMask?) -> Raster {
        guard let selection else { return edited }
        precondition(width == selection.width && height == selection.height && width == edited.width && height == edited.height)
        var result = self
        result.bytes.withUnsafeMutableBytes { dstRaw in
            edited.bytes.withUnsafeBytes { srcRaw in
                selection.coverage.withUnsafeBytes { maskRaw in
                    let dst = RGBSamples(raw: dstRaw, depth: depth), src = RGBSamples(raw: UnsafeMutableRawBufferPointer(mutating: srcRaw), depth: depth)
                    let mask = maskRaw.bindMemory(to: UInt8.self)
                    for i in 0..<mask.count where mask[i] > 0 {
                        let a = Int(mask[i])
                        for c in 0..<4 { dst[i * 4 + c] = (src[i * 4 + c] * Double(a) + dst[i * 4 + c] * Double(255 - a)) / 255 }
                    }
                }
            }
        }
        return result
    }

    func masked(using selection: SelectionMask) -> Raster {
        precondition(width == selection.width && height == selection.height)
        var result = self
        result.bytes.withUnsafeMutableBytes { raw in
            selection.coverage.withUnsafeBytes { maskRaw in
                let p = RGBSamples(raw: raw, depth: depth), mask = maskRaw.bindMemory(to: UInt8.self)
                for i in 0..<mask.count {
                    let a = Int(mask[i])
                    for c in 0..<4 { p[i * 4 + c] = p[i * 4 + c] * Double(a) / 255 }
                }
            }
        }
        return result
    }

    mutating func erase(selection: SelectionMask?) {
        guard let selection else { fill(color: .clear); return }
        self = masked(using: selection.inverted())
    }

    func moved(dx: Int, dy: Int, selection: SelectionMask?) -> Raster {
        guard dx != 0 || dy != 0 else { return self }
        guard let selection else { return translated(dx: dx, dy: dy, selection: nil) }
        guard !selection.isEmpty else { return self }
        var result = self
        result.erase(selection: selection)
        let source = masked(using: selection)
        let area = selection.bounds
        result.bytes.withUnsafeMutableBytes { dstRaw in
            source.bytes.withUnsafeBytes { srcRaw in
                let dst = RGBSamples(raw: dstRaw, depth: depth), src = RGBSamples(raw: UnsafeMutableRawBufferPointer(mutating: srcRaw), depth: depth)
                for y in Int(area.minY)..<Int(area.maxY) {
                    for x in Int(area.minX)..<Int(area.maxX) {
                        let tx = x + dx, ty = y + dy
                        guard tx >= 0, tx < width, ty >= 0, ty < height else { continue }
                        let i = (y * width + x) * 4, j = (ty * width + tx) * 4, a = src[i + 3] / src.maximum
                        for c in 0..<4 { dst[j + c] = src[i + c] + dst[j + c] * (1 - a) }
                    }
                }
            }
        }
        return result
    }

    func resizedCanvas(width newWidth: Int, height newHeight: Int, offsetX: Int, offsetY: Int) -> Raster {
        var result = Raster(width: newWidth, height: newHeight, format: format)
        result.resolution = resolution
        let x0 = max(0, -offsetX), x1 = min(width, newWidth - offsetX)
        let y0 = max(0, -offsetY), y1 = min(height, newHeight - offsetY)
        guard x0 < x1, y0 < y1 else { return result }
        let source = bytes
        var destination = result.bytes
        for y in y0..<y1 {
            let sourceOffset = (y * width + x0) * stride
            let target = ((y + offsetY) * newWidth + x0 + offsetX) * stride
            let count = (x1 - x0) * stride
            destination.replaceSubrange(target..<target + count, with: source[sourceOffset..<sourceOffset + count])
        }
        result.bytes = destination
        return result
    }

    func scaled(width newWidth: Int, height newHeight: Int, smooth: Bool) throws -> Raster {
        var result = Raster(width: newWidth, height: newHeight, format: format)
        result.resolution = resolution
        let image = cgImage, format = format
        let success = result.bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: newWidth, height: newHeight,
                                      bitsPerComponent: format.depth.rawValue, bytesPerRow: newWidth * format.depth.bytesPerPixel, space: format.profile.space,
                                      bitmapInfo: format.depth.bitmapInfo) else { return false }
            ctx.interpolationQuality = smooth ? .high : .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
            return true
        }
        guard success else { throw PaintError.invalidImage }
        return result
    }

    mutating func drawText(_ text: String, at point: CGPoint, font: NSFont, color: PixelColor,
                           opacity: Double, antialias: Bool, selection: SelectionMask?) {
        drawText(text, in: CGRect(x: floor(point.x), y: floor(point.y), width: CGFloat(width) - floor(point.x), height: CGFloat(height) - floor(point.y)),
                 font: font, color: color, opacity: opacity, antialias: antialias, selection: selection)
    }

    mutating func drawText(_ text: String, in box: CGRect, font: NSFont, color: PixelColor,
                           opacity: Double, antialias: Bool, selection: SelectionMask?, horizontalScale: Double = 1) {
        guard !text.isEmpty, box.width > 0, box.height > 0 else { return }
        let format = format
        let layout = TextRasterLayout(text: text, font: font, color: color, width: box.width / horizontalScale)
        editPixels(in: box.integral.intersection(bounds).intersection(selection?.bounds ?? bounds), selection: selection) { raw, region in
            let w = Int(region.width), h = Int(region.height)
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: format.depth.rawValue,
                                      bytesPerRow: w * format.depth.bytesPerPixel, space: format.profile.space,
                                      bitmapInfo: format.depth.bitmapInfo) else { return }
            ctx.setAllowsAntialiasing(antialias); ctx.setShouldAntialias(antialias)
            ctx.setAllowsFontSmoothing(false); ctx.setShouldSmoothFonts(false)
            ctx.translateBy(x: -region.minX, y: region.maxY); ctx.scaleBy(x: 1, y: -1)
            ctx.clip(to: box)
            ctx.translateBy(x: box.minX, y: box.minY)
            ctx.scaleBy(x: horizontalScale, y: 1)
            ctx.setAlpha(opacity)
            NSGraphicsContext.saveGraphicsState()
            let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
            graphics.shouldAntialias = antialias
            NSGraphicsContext.current = graphics
            layout.manager.drawGlyphs(forGlyphRange: layout.manager.glyphRange(for: layout.container), at: .zero)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

enum PaintError: LocalizedError {
    case invalidImage, invalidProject, imageTooLarge, tooManyLayers, invalidResolution
    var errorDescription: String? {
        switch self {
        case .invalidResolution: return "Resolution must be between 1 and 100,000 pixels per inch."
        case .invalidImage: return "This image could not be opened."
        case .invalidProject: return "This Paint.MAC project is damaged or uses an unsupported format."
        case .imageTooLarge: return "Use an image up to 8,192 pixels per side and 32 million pixels in total."
        case .tooManyLayers: return "This version supports up to 32 layers and groups in total."
        }
    }
}

final class ImageRenderer {
    let device: MTLDevice?
    let context: CIContext
    init() {
        device = MTLCreateSystemDefaultDevice()
        if let device { context = CIContext(mtlDevice: device, options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!, .workingFormat: CIFormat.RGBAf]) }
        else { context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!, .workingFormat: CIFormat.RGBAf]) }
    }

    private func opacity(_ image: CIImage, _ value: Double) -> CIImage {
        value == 1 ? image : image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: value)
        ])
    }
    private func coverageImage(_ mask: SelectionMask?, opacity: Double, bounds: CGRect) -> CIImage {
        guard let mask else { return CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: opacity)).cropped(to: bounds) }
        return self.opacity(mask.storage.ciImage, opacity)
    }

    private func masked(_ image: CIImage, using mask: SelectionMask) -> CIImage {
        image.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: coverageImage(mask, opacity: 1, bounds: image.extent)])
    }
    private func adjusted(_ image: CIImage, layer: PaintLayer, bounds: CGRect, clipped: Bool) -> CIImage {
        guard layer.visible, layer.opacity > 0, let effect = layer.effect else { return image }
        var filtered = effect.filtered(image, bounds: bounds)
        if clipped {
            // Restore the base alpha after filtering; a clipped blur must not
            // enlarge the silhouette, and translucent colors must not fade twice.
            filtered = filtered.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
                .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: image])
        }
        let mask = coverageImage(layer.maskEnabled ? layer.mask : nil, opacity: layer.opacity, bounds: bounds)
        return filtered.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask]).cropped(to: bounds)
    }
    private struct LayerImages {
        let renderer: ImageRenderer
        let bounds: CGRect
        let nodes: [UUID: PaintLayer]
        let children: [UUID?: [PaintLayer]]
        var clear: CIImage { CIImage(color: .clear).cropped(to: bounds) }
        init(renderer: ImageRenderer, layers: [PaintLayer], bounds: CGRect) {
            self.renderer = renderer; self.bounds = bounds
            nodes = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) })
            children = Dictionary(grouping: layers, by: \.parentID)
        }
        func content(_ id: UUID) -> CIImage {
            guard let node = nodes[id] else { return clear }
            if !node.isGroup {
                let image = node.raster.ciImage
                return node.maskEnabled ? node.mask.map { renderer.masked(image, using: $0) } ?? image : image
            }
            let image = siblings(id)
            if node.maskEnabled, let mask = node.mask { return renderer.masked(image, using: mask) }
            return image
        }
        func siblings(_ parent: UUID?) -> CIImage {
            let list = children[parent] ?? []
            var result = clear, index = 0
            while index < list.count {
                let base = list[index]
                if base.effect != nil {
                    result = renderer.adjusted(result, layer: base, bounds: bounds, clipped: false)
                    index += 1; continue
                }
                // A clipping stack is one isolated composite. Source-atop keeps
                // the base alpha fixed, even at translucent/feathered edges.
                var chain = base.visible ? content(base.id) : clear
                index += 1
                while index < list.count, list[index].isClipped {
                    let upper = list[index]
                    if upper.visible && upper.opacity > 0 {
                        if upper.effect != nil { chain = renderer.adjusted(chain, layer: upper, bounds: bounds, clipped: true) }
                        else { chain = renderer.opacity(content(upper.id), upper.opacity).applyingFilter("CISourceAtopCompositing", parameters: [kCIInputBackgroundImageKey: chain]) }
                    }
                    index += 1
                }
                if base.visible && base.opacity > 0 { result = renderer.opacity(chain, base.opacity).composited(over: result) }
            }
            return result.cropped(to: bounds)
        }
    }
    func contentImage(of id: UUID, layers: [PaintLayer], width: Int, height: Int) -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let image = LayerImages(renderer: self, layers: layers, bounds: bounds).content(id)
        return cgImage(image, format: layers.first?.raster.format ?? .standard)
    }
    /// Keep the compositing graph on the GPU path until an export or CPU pixel
    /// operation explicitly needs a CGImage. The canvas renders this graph directly.
    func compositeImage(_ layers: [PaintLayer], width: Int, height: Int, whiteBackground: Bool = false) -> CIImage {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var image = LayerImages(renderer: self, layers: layers, bounds: bounds).siblings(nil)
        if whiteBackground { image = image.composited(over: CIImage(color: .white).cropped(to: bounds)) }
        return image
    }
    func cgImage(_ image: CIImage, format: RGBFormat = .standard) -> CGImage {
        context.createCGImage(image, from: image.extent, format: format.depth.ciFormat, colorSpace: format.profile.space)!
    }
    func composite(_ layers: [PaintLayer], width: Int, height: Int, whiteBackground: Bool = false) -> CGImage {
        cgImage(compositeImage(layers, width: width, height: height, whiteBackground: whiteBackground), format: layers.first?.raster.format ?? .standard)
    }
}
