import AppKit
import CoreImage

/// Immutable versions can be shared by documents, GPU frames, and snapshots.
final class PixelTile {
    let id: UUID
    let data: Data
    let channels: Int
    let side: Int
    private let lock = NSLock()
    private var imageCache: CGImage?
    private var conversion: PixelTile?
    private weak var origin: PixelTile?
    init(_ data: Data, channels: Int, id: UUID = UUID()) {
        side = Int(sqrt(Double(data.count / channels)))
        precondition(side > 0 && side <= TileGrid.side && data.count == side * side * channels)
        self.id = id; self.data = data; self.channels = channels
    }
    func converted(channels target: Int) -> PixelTile {
        if target == channels { return self }
        lock.lock(); defer { lock.unlock() }
        if let origin, origin.channels == target { return origin }
        if let conversion { return conversion }
        var output = Data(count: side * side * target)
        output.withUnsafeMutableBytes { raw in
            data.withUnsafeBytes { source in
                let p = raw.bindMemory(to: UInt8.self), s = source.bindMemory(to: UInt8.self)
                for i in 0..<side * side {
                    if target == 4 { p[i * 4] = s[i]; p[i * 4 + 1] = s[i]; p[i * 4 + 2] = s[i]; p[i * 4 + 3] = 255 }
                    else {
                        let r = Int(s[i * 4]) * 54, g = Int(s[i * 4 + 1]) * 183, b = Int(s[i * 4 + 2]) * 19
                        p[i] = UInt8((r + g + b + 128) / 256)
                    }
                }
            }
        }
        let result = PixelTile(output, channels: target); result.origin = self
        conversion = result; return result
    }
    var image: CGImage {
        lock.lock(); defer { lock.unlock() }
        if let imageCache { return imageCache }
        let rgba: Data
        if channels == 4 { rgba = data }
        else {
            var expanded = Data(count: data.count * 4)
            expanded.withUnsafeMutableBytes { raw in
                data.withUnsafeBytes { source in
                    let p = raw.bindMemory(to: UInt8.self), s = source.bindMemory(to: UInt8.self)
                    for i in 0..<s.count { for c in 0..<4 { p[i * 4 + c] = s[i] } }
                }
            }
            rgba = expanded
        }
        let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: side * 4, space: Raster.colorSpace,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: CGDataProvider(data: rgba as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        imageCache = image; return image
    }
}

/// Absent tiles have a uniform value, including entirely empty/solid layers.
/// Coordinates and bytes remain top-left, independent of Core Image's origin.
struct TileGrid: Equatable {
    static let side = 256
    let width: Int
    let height: Int
    let channels: Int
    var base: [UInt8]
    var tiles: [Int: PixelTile] = [:]
    var tileSide: Int { min(Self.side, max(width, height)) }
    var columns: Int { (width + tileSide - 1) / tileSide }
    var rows: Int { (height + tileSide - 1) / tileSide }
    var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
    init(width: Int, height: Int, channels: Int, base: [UInt8]? = nil) {
        self.width = width; self.height = height; self.channels = channels
        self.base = base ?? [UInt8](repeating: 0, count: channels)
        precondition(width > 0 && height > 0 && self.base.count == channels)
    }
    init(width: Int, height: Int, channels: Int, data: Data) {
        self.init(width: width, height: height, channels: channels)
        precondition(data.count == width * height * channels)
        // Uniform images/masks need no allocated tile at all.
        let first = Array(data.prefix(channels))
        let uniform = data.withUnsafeBytes { raw -> Bool in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<p.count where p[i] != first[i % channels] { return false }; return true
        }
        if uniform { base = first } else { write(data, in: bounds) }
    }
    func value(x: Int, y: Int, channel: Int = 0) -> UInt8 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        let key = y / tileSide * columns + x / tileSide
        return tiles[key]?.data[((y % tileSide) * tileSide + x % tileSide) * channels + channel] ?? base[channel]
    }
    func tileData(_ key: Int) -> Data {
        if let tile = tiles[key] { return tile.data }
        if base.allSatisfy({ $0 == base[0] }) { return Data(repeating: base[0], count: tileSide * tileSide * channels) }
        var data = Data(count: tileSide * tileSide * channels)
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<p.count { p[i] = base[i % channels] }
        }; return data
    }
    func read(_ requested: CGRect? = nil) -> Data {
        let region = (requested ?? bounds).integral.intersection(bounds)
        guard !region.isNull, !region.isEmpty else { return Data() }
        let x0 = Int(region.minX), y0 = Int(region.minY), rw = Int(region.width), rh = Int(region.height)
        var output = Data(count: rw * rh * channels)
        output.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt8.self)
            for ty in y0 / tileSide...(y0 + rh - 1) / tileSide {
                for tx in x0 / tileSide...(x0 + rw - 1) / tileSide {
                    let key = ty * columns + tx, a = max(x0, tx * tileSide), b = min(x0 + rw, (tx + 1) * tileSide)
                    let top = max(y0, ty * tileSide), bottom = min(y0 + rh, (ty + 1) * tileSide)
                    if let tile = tiles[key] {
                        tile.data.withUnsafeBytes { source in
                            for y in top..<bottom {
                                let src = ((y - ty * tileSide) * tileSide + a - tx * tileSide) * channels
                                let dst = ((y - y0) * rw + a - x0) * channels
                                memcpy(raw.baseAddress! + dst, source.baseAddress! + src, (b - a) * channels)
                            }
                        }
                    } else {
                        for y in top..<bottom { for x in a..<b { for c in 0..<channels {
                            out[((y - y0) * rw + x - x0) * channels + c] = base[c]
                        } } }
                    }
                }
            }
        }; return output
    }
    mutating func write(_ data: Data, in requested: CGRect) {
        let region = requested.integral.intersection(bounds)
        guard !region.isNull, !region.isEmpty else { return }
        let x0 = Int(region.minX), y0 = Int(region.minY), rw = Int(region.width), rh = Int(region.height)
        precondition(data.count == rw * rh * channels)
        data.withUnsafeBytes { source in
            for ty in y0 / tileSide...(y0 + rh - 1) / tileSide {
                for tx in x0 / tileSide...(x0 + rw - 1) / tileSide {
                    let key = ty * columns + tx
                    var output = tileData(key)
                    output.withUnsafeMutableBytes { raw in
                        let a = max(x0, tx * tileSide), b = min(x0 + rw, (tx + 1) * tileSide)
                        for y in max(y0, ty * tileSide)..<min(y0 + rh, (ty + 1) * tileSide) {
                            let src = ((y - y0) * rw + a - x0) * channels
                            let dst = ((y - ty * tileSide) * tileSide + a - tx * tileSide) * channels
                            memcpy(raw.baseAddress! + dst, source.baseAddress! + src, (b - a) * channels)
                        }
                    }
                    if let existing = tiles[key], existing.data == output { continue }
                    let empty = output.withUnsafeBytes { raw -> Bool in
                        let p = raw.bindMemory(to: UInt8.self)
                        for i in 0..<p.count where p[i] != base[i % channels] { return false }; return true
                    }
                    if empty { tiles.removeValue(forKey: key) } else { tiles[key] = PixelTile(output, channels: channels) }
                }
            }
        }
    }
    mutating func edit(in requested: CGRect, _ body: (inout Data, CGRect) -> Void) {
        let region = requested.integral.intersection(bounds)
        guard !region.isNull, !region.isEmpty else { return }
        var data = read(region); body(&data, region); write(data, in: region)
    }
    static func == (a: Self, b: Self) -> Bool {
        guard a.width == b.width, a.height == b.height, a.channels == b.channels else { return false }
        if a.base != b.base { return a.read() == b.read() }
        for key in Set(a.tiles.keys).union(b.tiles.keys) {
            if a.tiles[key] === b.tiles[key] { continue }
            if a.tileData(key) != b.tileData(key) { return false }
        }; return true
    }
    /// Nonoverlapping source images are assembled on the document pixel grid.
    /// The intermediate prevents fractional viewport filtering at tile edges.
    var ciImage: CIImage {
        let alpha = Double(base[channels == 4 ? 3 : 0]) / 255
        let color = channels == 1 ? CIColor(red: 1, green: 1, blue: 1, alpha: alpha) :
            CIColor(red: alpha > 0 ? Double(base[0]) / 255 / alpha : 0,
                    green: alpha > 0 ? Double(base[1]) / 255 / alpha : 0,
                    blue: alpha > 0 ? Double(base[2]) / 255 / alpha : 0, alpha: alpha)
        let solid = CIImage(color: color)
        guard !tiles.isEmpty else { return solid.cropped(to: bounds) }
        var result = CIImage(color: .clear).cropped(to: bounds)
        for ty in 0..<rows {
            let changed = tiles.keys.filter { $0 / columns == ty }.map { $0 % columns }.sorted()
            var next = 0
            for tx in changed + [columns] {
                if tx > next {
                    let rect = CGRect(x: next * tileSide, y: height - (ty + 1) * tileSide,
                                      width: (tx - next) * tileSide, height: tileSide).intersection(bounds)
                    result = solid.cropped(to: rect).composited(over: result)
                }
                if tx < columns, let tile = tiles[ty * columns + tx] {
                    let image = CIImage(cgImage: tile.image).transformed(by: CGAffineTransform(translationX: CGFloat(tx * tileSide), y: CGFloat(height - (ty + 1) * tileSide))).cropped(to: bounds)
                    result = image.composited(over: result)
                }
                next = tx + 1
            }
        }
        return result.insertingIntermediate()
    }
    var nonzeroBounds: CGRect {
        var result = CGRect.null
        for ty in 0..<rows { for tx in 0..<columns {
            let rect = CGRect(x: tx * tileSide, y: ty * tileSide, width: tileSide, height: tileSide).intersection(bounds)
            guard let tile = tiles[ty * columns + tx] else {
                if base[0] > 0 { result = result.union(rect) }; continue
            }
            var x0 = tileSide, y0 = tileSide, x1 = -1, y1 = -1
            tile.data.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                for y in 0..<Int(rect.height) { for x in 0..<Int(rect.width) where p[(y * tileSide + x) * channels] > 0 {
                    x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                } }
            }
            if x1 >= 0 { result = result.union(CGRect(x: tx * tileSide + x0, y: ty * tileSide + y0, width: x1 - x0 + 1, height: y1 - y0 + 1)) }
        } }
        return result
    }
}
