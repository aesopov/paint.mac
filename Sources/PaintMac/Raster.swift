import AppKit
import CoreImage
import Metal

struct PixelColor: Equatable, Codable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8 = 255

    static let black = PixelColor(r: 29, g: 32, b: 39)
    static let white = PixelColor(r: 255, g: 255, b: 255)
    static let clear = PixelColor(r: 0, g: 0, b: 0, a: 0)

    init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        r = UInt8((c.redComponent * 255).rounded())
        g = UInt8((c.greenComponent * 255).rounded())
        b = UInt8((c.blueComponent * 255).rounded())
        a = UInt8((c.alphaComponent * 255).rounded())
    }

    var nsColor: NSColor {
        NSColor(srgbRed: Double(r) / 255, green: Double(g) / 255,
                blue: Double(b) / 255, alpha: Double(a) / 255)
    }
    var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
}

/// RGBA8, premultiplied sRGB, with the first row at the top of the image.
struct Raster: Equatable {
    let width: Int
    let height: Int
    var bytes: Data
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init(width: Int, height: Int, color: PixelColor = .clear) {
        self.width = width; self.height = height
        bytes = Data(count: width * height * 4)
        if color.a != 0 { fill(color: color) }
    }

    init(image: CGImage) throws {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 32_000_000 else { throw PaintError.imageTooLarge }
        self.width = width; self.height = height
        bytes = Data(count: width * height * 4)
        let rendered = bytes.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: Self.colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw PaintError.invalidImage }
    }

    var cgImage: CGImage {
        let provider = CGDataProvider(data: bytes as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8,
                       bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: Self.colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    func pixel(x: Int, y: Int) -> PixelColor {
        guard x >= 0, y >= 0, x < width, y < height else { return .clear }
        let i = (y * width + x) * 4
        let a = Int(bytes[i + 3])
        guard a > 0 else { return .clear }
        return PixelColor(r: UInt8(min(255, Int(bytes[i]) * 255 / a)),
                          g: UInt8(min(255, Int(bytes[i + 1]) * 255 / a)),
                          b: UInt8(min(255, Int(bytes[i + 2]) * 255 / a)), a: UInt8(a))
    }

    mutating func fill(color: PixelColor, rect: CGRect? = nil) {
        let area = (rect ?? bounds).integral.intersection(bounds)
        guard !area.isNull, !area.isEmpty else { return }
        let a = Int(color.a)
        let rgba = [UInt8(Int(color.r) * a / 255), UInt8(Int(color.g) * a / 255),
                    UInt8(Int(color.b) * a / 255), color.a]
        let w = width
        bytes.withUnsafeMutableBytes { ptr in
            let p = ptr.bindMemory(to: UInt8.self)
            for y in Int(area.minY)..<Int(area.maxY) {
                for x in Int(area.minX)..<Int(area.maxX) {
                    let i = (y * w + x) * 4
                    for c in 0..<4 { p[i + c] = rgba[c] }
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
        let lengthSquared = dx * dx + dy * dy, w = width
        func render() {
            bytes.withUnsafeMutableBytes { ptr in
                let p = ptr.bindMemory(to: UInt8.self)
                for y in Int(region.minY)..<Int(region.maxY) {
                    for x in Int(region.minX)..<Int(region.maxX) {
                        let px = Double(x) + 0.5, py = Double(y) + 0.5, position = y * w + x
                        let t = lengthSquared == 0 ? 0 : max(0, min(1, ((px - start.x) * dx + (py - start.y) * dy) / lengthSquared))
                        let distance = hypot(px - start.x - t * dx, py - start.y - t * dy)
                        let coverage = profile.coverage(at: distance)
                        let selectionAlpha = selection.map { Double($0.coverage[position]) / 255 } ?? 1
                        let alpha = coverage * opacity * Double(color.a) / 255 * selectionAlpha
                        guard alpha > 0 else { continue }
                        let i = position * 4
                        if erase {
                            for c in 0..<4 { p[i + c] = UInt8((Double(p[i + c]) * (1 - alpha)).rounded()) }
                        } else {
                            for (c, value) in [color.r, color.g, color.b].enumerated() {
                                p[i + c] = UInt8(min(255, (Double(value) * alpha + Double(p[i + c]) * (1 - alpha)).rounded()))
                            }
                            p[i + 3] = UInt8(min(255, (255 * alpha + Double(p[i + 3]) * (1 - alpha)).rounded()))
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
                              antialias: Bool = true, fillColor: PixelColor? = nil, hardness: Double = 1) {
        guard rect.width > 0, rect.height > 0 else { return }
        if BrushProfile(radius: 1, hardness: hardness, antialias: antialias).hardness < 1 {
            strokeSoftShape(in: rect, ellipse: ellipse, size: size, color: color, opacity: opacity, clip: clip,
                            selection: selection, antialias: antialias, fillColor: fillColor, hardness: hardness)
            return
        }
        let w = width, h = height
        let area = (clip ?? bounds).intersection(bounds).intersection(selection?.bounds ?? bounds)
        guard !area.isNull, !area.isEmpty else { return }
        bytes.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: Self.colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            if let selection { ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: h), mask: selection.cgImage) }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.clip(to: area)
            ctx.setShouldAntialias(antialias)
            ctx.setLineWidth(max(1, size))
            ctx.setLineJoin(.round)
            // Composite fill and outline together so tool opacity is applied once,
            // including where the stroke covers the inside edge of the fill.
            if fillColor != nil {
                ctx.setAlpha(opacity)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            ctx.setStrokeColor(red: Double(color.r) / 255, green: Double(color.g) / 255,
                               blue: Double(color.b) / 255, alpha: Double(color.a) / 255 * (fillColor == nil ? opacity : 1))
            if let fillColor {
                ctx.setFillColor(red: Double(fillColor.r) / 255, green: Double(fillColor.g) / 255,
                                 blue: Double(fillColor.b) / 255, alpha: Double(fillColor.a) / 255)
            }
            if ellipse { ctx.addEllipse(in: rect) } else { ctx.addRect(rect) }
            if fillColor != nil {
                ctx.drawPath(using: .fillStroke)
                ctx.endTransparencyLayer()
            } else {
                ctx.strokePath()
            }
        }
    }

    mutating func floodFill(at point: CGPoint, color: PixelColor, tolerance: Int, clip: CGRect?, selection: SelectionMask? = nil) {
        let x = Int(floor(point.x)), y = Int(floor(point.y))
        let area = (clip ?? bounds).integral.intersection(bounds).intersection(selection?.bounds ?? bounds)
        guard area.contains(CGPoint(x: x, y: y)) else { return }
        let target = pixel(x: x, y: y)
        if target == color { return }
        let w = width, h = height
        var visited = [Bool](repeating: false, count: w * h)
        var stack = [y * w + x]
        bytes.withUnsafeMutableBytes { ptr in
            let p = ptr.bindMemory(to: UInt8.self)
            while let index = stack.popLast() {
                guard !visited[index] else { continue }
                visited[index] = true
                let px = index % w, py = index / w, i = index * 4
                guard area.contains(CGPoint(x: px, y: py)) else { continue }
                let coverage = Int(selection?.coverage[index] ?? 255)
                guard coverage > 0 else { continue }
                let a = Int(p[i + 3])
                let r = a == 0 ? 0 : min(255, Int(p[i]) * 255 / a)
                let g = a == 0 ? 0 : min(255, Int(p[i + 1]) * 255 / a)
                let b = a == 0 ? 0 : min(255, Int(p[i + 2]) * 255 / a)
                guard max(abs(r - Int(target.r)), abs(g - Int(target.g)),
                          abs(b - Int(target.b)), abs(a - Int(target.a))) <= tolerance else { continue }
                let replacement = [Int(color.r) * Int(color.a) / 255, Int(color.g) * Int(color.a) / 255,
                                   Int(color.b) * Int(color.a) / 255, Int(color.a)]
                for c in 0..<4 { p[i + c] = UInt8((replacement[c] * coverage + Int(p[i + c]) * (255 - coverage) + 127) / 255) }
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
        guard !area.isNull, !area.isEmpty else { return Raster(width: 1, height: 1) }
        var result = Raster(width: Int(area.width), height: Int(area.height))
        for y in 0..<result.height {
            let start = ((y + Int(area.minY)) * width + Int(area.minX)) * 4
            result.bytes.replaceSubrange(y * result.width * 4..<(y + 1) * result.width * 4,
                                         with: bytes[start..<start + result.width * 4])
        }
        return result
    }

    func translated(dx: Int, dy: Int, selection: CGRect?) -> Raster {
        let area = (selection ?? bounds).integral.intersection(bounds)
        var result = self
        result.fill(color: .clear, rect: area)
        guard !area.isNull, !area.isEmpty else { return result }
        for y in Int(area.minY)..<Int(area.maxY) {
            for x in Int(area.minX)..<Int(area.maxX) {
                let tx = x + dx, ty = y + dy
                guard tx >= 0, tx < width, ty >= 0, ty < height else { continue }
                let src = (y * width + x) * 4, dst = (ty * width + tx) * 4
                // Composite moved pixels over content that was outside the selection.
                let alpha = Double(bytes[src + 3]) / 255
                for c in 0..<4 {
                    result.bytes[dst + c] = UInt8(min(255, (Double(bytes[src + c]) + Double(result.bytes[dst + c]) * (1 - alpha)).rounded()))
                }
            }
        }
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
                    let dst = dstRaw.bindMemory(to: UInt8.self), src = srcRaw.bindMemory(to: UInt8.self)
                    let mask = maskRaw.bindMemory(to: UInt8.self)
                    for i in 0..<mask.count where mask[i] > 0 {
                        let a = Int(mask[i])
                        for c in 0..<4 { dst[i * 4 + c] = UInt8((Int(src[i * 4 + c]) * a + Int(dst[i * 4 + c]) * (255 - a) + 127) / 255) }
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
                let p = raw.bindMemory(to: UInt8.self), mask = maskRaw.bindMemory(to: UInt8.self)
                for i in 0..<mask.count {
                    let a = Int(mask[i])
                    for c in 0..<4 { p[i * 4 + c] = UInt8((Int(p[i * 4 + c]) * a + 127) / 255) }
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
                let dst = dstRaw.bindMemory(to: UInt8.self), src = srcRaw.bindMemory(to: UInt8.self)
                for y in Int(area.minY)..<Int(area.maxY) {
                    for x in Int(area.minX)..<Int(area.maxX) {
                        let tx = x + dx, ty = y + dy
                        guard tx >= 0, tx < width, ty >= 0, ty < height else { continue }
                        let i = (y * width + x) * 4, j = (ty * width + tx) * 4, a = Int(src[i + 3])
                        for c in 0..<4 { dst[j + c] = UInt8(min(255, Int(src[i + c]) + (Int(dst[j + c]) * (255 - a) + 127) / 255)) }
                    }
                }
            }
        }
        return result
    }

    func resizedCanvas(width newWidth: Int, height newHeight: Int, offsetX: Int, offsetY: Int) -> Raster {
        var result = Raster(width: newWidth, height: newHeight)
        let x0 = max(0, -offsetX), x1 = min(width, newWidth - offsetX)
        let y0 = max(0, -offsetY), y1 = min(height, newHeight - offsetY)
        guard x0 < x1, y0 < y1 else { return result }
        for y in y0..<y1 {
            let source = (y * width + x0) * 4
            let target = ((y + offsetY) * newWidth + x0 + offsetX) * 4
            let count = (x1 - x0) * 4
            result.bytes.replaceSubrange(target..<target + count, with: bytes[source..<source + count])
        }
        return result
    }

    func scaled(width newWidth: Int, height newHeight: Int, smooth: Bool) throws -> Raster {
        var result = Raster(width: newWidth, height: newHeight)
        let image = cgImage
        let success = result.bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: newWidth, height: newHeight,
                                      bitsPerComponent: 8, bytesPerRow: newWidth * 4, space: Self.colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
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
        let w = width, h = height
        let layout = TextRasterLayout(text: text, font: font, color: color, width: box.width / horizontalScale)
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: Self.colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            if let selection { ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: h), mask: selection.cgImage) }
            ctx.setAllowsAntialiasing(antialias); ctx.setShouldAntialias(antialias)
            ctx.setAllowsFontSmoothing(false); ctx.setShouldSmoothFonts(false)
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
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
    case invalidImage, invalidProject, imageTooLarge, tooManyLayers
    var errorDescription: String? {
        switch self {
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
        if let device { context = CIContext(mtlDevice: device, options: [.workingColorSpace: Raster.colorSpace]) }
        else { context = CIContext(options: [.workingColorSpace: Raster.colorSpace]) }
    }

    private func opacity(_ image: CIImage, _ value: Double) -> CIImage {
        value == 1 ? image : image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: value)
        ])
    }
    private func coverageImage(_ mask: SelectionMask?, opacity: Double, bounds: CGRect) -> CIImage {
        guard let mask else { return CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: opacity)).cropped(to: bounds) }
        var alpha = Raster(width: mask.width, height: mask.height)
        alpha.bytes.withUnsafeMutableBytes { raw in
            mask.coverage.withUnsafeBytes { coverage in
                let dst = raw.bindMemory(to: UInt8.self), src = coverage.bindMemory(to: UInt8.self)
                for i in 0..<src.count {
                    let value = UInt8((Double(src[i]) * opacity).rounded())
                    for c in 0..<4 { dst[i * 4 + c] = value }
                }
            }
        }
        return CIImage(cgImage: alpha.cgImage)
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
            if !node.isGroup { return CIImage(cgImage: node.displayRaster.cgImage) }
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
        return context.createCGImage(image, from: bounds, format: .RGBA8, colorSpace: Raster.colorSpace)!
    }
    /// Keep the compositing graph on the GPU path until an export or CPU pixel
    /// operation explicitly needs a CGImage. The canvas renders this graph directly.
    func compositeImage(_ layers: [PaintLayer], width: Int, height: Int, whiteBackground: Bool = false) -> CIImage {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var image = LayerImages(renderer: self, layers: layers, bounds: bounds).siblings(nil)
        if whiteBackground { image = image.composited(over: CIImage(color: .white).cropped(to: bounds)) }
        return image
    }
    func cgImage(_ image: CIImage) -> CGImage {
        context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: Raster.colorSpace)!
    }
    func composite(_ layers: [PaintLayer], width: Int, height: Int, whiteBackground: Bool = false) -> CGImage {
        cgImage(compositeImage(layers, width: width, height: height, whiteBackground: whiteBackground))
    }
}
