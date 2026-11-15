import AppKit
import CoreImage

enum SelectionMode: String, CaseIterable {
    case replace = "Replace", add = "Add", subtract = "Subtract", intersect = "Intersect"

    static func resolve(_ modifiers: NSEvent.ModifierFlags, fallback: SelectionMode) -> SelectionMode {
        if modifiers.contains([.shift, .option]) { return .intersect }
        if modifiers.contains(.option) { return .subtract }
        if modifiers.contains(.shift) { return .add }
        return fallback
    }
}

/// Immutable, top-left, linear 8-bit coverage. Nil means unrestricted editing;
/// a non-nil, empty mask deliberately selects nothing.
struct SelectionMask: Equatable {
    let id = UUID()
    let width: Int
    let height: Int
    let storage: TileGrid
    var coverage: Data { storage.read() }
    let bounds: CGRect
    static let colorSpace = CGColorSpace(name: CGColorSpace.linearGray)!

    init(width: Int, height: Int, coverage: Data) {
        precondition(width > 0 && height > 0 && coverage.count == width * height)
        self.width = width; self.height = height; storage = TileGrid(width: width, height: height, channels: 1, data: coverage)
        var minX = width, minY = height, maxX = -1, maxY = -1
        coverage.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width where p[y * width + x] > 0 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        bounds = maxX < 0 ? .null : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id || (lhs.width == rhs.width && lhs.height == rhs.height && lhs.storage == rhs.storage)
    }
    var isEmpty: Bool { bounds.isNull }
    var canvasBounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
    var cgImage: CGImage {
        CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: Self.colorSpace, bitmapInfo: [], provider: CGDataProvider(data: coverage as CFData)!,
                decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
    func value(x: Int, y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return storage.value(x: x, y: y)
    }
    init(storage: TileGrid, bounds: CGRect) {
        precondition(storage.channels == 1)
        self.storage = storage; width = storage.width; height = storage.height; self.bounds = bounds
    }
    static func empty(width: Int, height: Int) -> Self { Self(storage: TileGrid(width: width, height: height, channels: 1), bounds: .null) }
    static func all(width: Int, height: Int) -> Self {
        Self(storage: TileGrid(width: width, height: height, channels: 1, base: [255]), bounds: CGRect(x: 0, y: 0, width: width, height: height))
    }

    static func rectangle(_ rect: CGRect, width: Int, height: Int) -> Self {
        let path = CGPath(rect: rect, transform: nil)
        return shape(path, width: width, height: height, antialias: false)
    }
    static func ellipse(_ rect: CGRect, width: Int, height: Int, antialias: Bool = true) -> Self {
        shape(CGPath(ellipseIn: rect, transform: nil), width: width, height: height, antialias: antialias)
    }
    static func lasso(_ points: [CGPoint], width: Int, height: Int, antialias: Bool = true) -> Self {
        guard points.count >= 3 else { return .empty(width: width, height: height) }
        let path = CGMutablePath(); path.addLines(between: points); path.closeSubpath()
        return shape(path, width: width, height: height, antialias: antialias)
    }
    private static func shape(_ path: CGPath, width: Int, height: Int, antialias: Bool = true) -> Self {
        var data = Data(count: width * height)
        data.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
            ctx.setShouldAntialias(antialias); ctx.setFillColor(gray: 1, alpha: 1)
            ctx.addPath(path); ctx.fillPath(using: .evenOdd)
        }
        return Self(width: width, height: height, coverage: data)
    }

    func combined(with other: Self, mode: SelectionMode) -> Self {
        precondition(width == other.width && height == other.height)
        if mode == .replace { return other }
        var result = coverage
        result.withUnsafeMutableBytes { raw in
            other.coverage.withUnsafeBytes { otherRaw in
                let a = raw.bindMemory(to: UInt8.self), b = otherRaw.bindMemory(to: UInt8.self)
                for i in 0..<a.count {
                    switch mode {
                    case .replace: break
                    case .add: a[i] = max(a[i], b[i])
                    case .subtract: a[i] = UInt8((Int(a[i]) * (255 - Int(b[i])) + 127) / 255)
                    case .intersect: a[i] = min(a[i], b[i])
                    }
                }
            }
        }
        return Self(width: width, height: height, coverage: result)
    }
    func inverted() -> Self {
        var data = coverage
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<p.count { p[i] = 255 - p[i] }
        }
        return Self(width: width, height: height, coverage: data)
    }
    func translated(dx: Int, dy: Int, width newWidth: Int? = nil, height newHeight: Int? = nil) -> Self {
        let w = newWidth ?? width, h = newHeight ?? height
        var result = Data(count: w * h)
        let startX = max(0, -dx), endX = min(width, w - dx)
        let startY = max(0, -dy), endY = min(height, h - dy)
        let coverage = self.coverage
        if startX < endX && startY < endY {
            for y in startY..<endY {
                let source = y * width + startX, target = (y + dy) * w + startX + dx
                result.replaceSubrange(target..<target + endX - startX, with: coverage[source..<source + endX - startX])
            }
        }
        return Self(width: w, height: h, coverage: result)
    }

    func scaled(width newWidth: Int, height newHeight: Int, smooth: Bool) -> Self {
        var result = Data(count: newWidth * newHeight)
        let image = cgImage
        result.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: newWidth, height: newHeight,
                                      bitsPerComponent: 8, bytesPerRow: newWidth, space: Self.colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = smooth ? .high : .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        }
        return Self(width: newWidth, height: newHeight, coverage: result)
    }

    /// Selection processing is independent of image pixels. More mask operations
    /// (grow/shrink, border, smooth) can be added here without changing tool code.
    func feathered(radius: Double, context: CIContext) -> Self {
        guard radius.isFinite, radius > 0, !isEmpty else { return self }
        let image = CIImage(cgImage: cgImage).clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: canvasBounds)
        var data = Data(count: width * height)
        data.withUnsafeMutableBytes { ptr in
            context.render(image, toBitmap: ptr.baseAddress!, rowBytes: width, bounds: canvasBounds,
                           format: .L8, colorSpace: Self.colorSpace)
        }
        return Self(width: width, height: height, coverage: data)
    }

    /// Pixel-edge contour at 50% coverage. Cached by CanvasView, never rebuilt on mouse hover.
    func outline() -> CGPath {
        let path = CGMutablePath()
        guard !isEmpty else { return path }
        var edges: [Int: [Int]] = [:]
        let stride = width + 1
        func edge(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) {
            edges[y1 * stride + x1, default: []].append(y2 * stride + x2)
        }
        coverage.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            func selected(_ x: Int, _ y: Int) -> Bool {
                x >= 0 && y >= 0 && x < width && y < height && p[y * width + x] >= 128
            }
            for y in Int(bounds.minY)..<Int(bounds.maxY) {
                for x in Int(bounds.minX)..<Int(bounds.maxX) where selected(x, y) {
                    if !selected(x, y - 1) { edge(x, y, x + 1, y) }
                    if !selected(x, y + 1) { edge(x + 1, y + 1, x, y + 1) }
                    if !selected(x - 1, y) { edge(x, y + 1, x, y) }
                    if !selected(x + 1, y) { edge(x + 1, y, x + 1, y + 1) }
                }
            }
        }
        func point(_ vertex: Int) -> CGPoint { CGPoint(x: vertex % stride, y: vertex / stride) }
        // Join neighboring pixel edges into contours so dash lengths continue
        // across edges instead of restarting at every individual pixel.
        while let start = edges.keys.first {
            path.move(to: point(start))
            var current = start
            while let next = edges[current]?.popLast() {
                if edges[current]?.isEmpty == true { edges.removeValue(forKey: current) }
                path.addLine(to: point(next))
                current = next
                if current == start { path.closeSubpath(); break }
            }
        }
        return path
    }
}
