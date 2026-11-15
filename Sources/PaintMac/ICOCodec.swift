import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Built-in ICO container and pixel codec. No AppKit interaction or document state.
/// Untouched entries retain their original payload and directory metadata on export.
struct ICOFile {
    struct Entry {
        let width: Int
        let height: Int
        let bitDepth: Int
        let directory: Data // first eight bytes, excluding length and offset
        let payload: Data
        var isPNG: Bool { payload.starts(with: ICOCodec.pngSignature) }
        var title: String { "\(width) × \(height) · \(isPNG ? "PNG" : "\(bitDepth)-bit")" }
    }
    let entries: [Entry]
}

struct IconSource {
    let file: ICOFile
    let index: Int
    let name: String
}

enum ICOError: LocalizedError {
    case invalidFile, unsupportedBitmap, invalidSize, invalidEntry
    var errorDescription: String? {
        switch self {
        case .invalidFile: return "This ICO file is damaged or has invalid image data."
        case .unsupportedBitmap: return "This icon uses an unsupported bitmap encoding. Uncompressed 1, 4, 8, 16, 24 and 32-bit icons, RGB bitfields, and PNG images are supported."
        case .invalidSize: return "ICO images must be between 1 and 256 pixels on each side. Choose Windows size set to export a larger canvas as an icon."
        case .invalidEntry: return "This image is not present in the ICO file."
        }
    }
}

enum ICOCodec {
    static let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])
    static let standardSizes = [16, 24, 32, 48, 64, 128, 256]

    static func isICO(_ data: Data) -> Bool { data.starts(with: [0, 0, 1, 0]) }

    static func read(_ data: Data) throws -> ICOFile {
        let data = Data(data) // normalize Data slice indices
        guard data.count >= 6, data.count <= 64 * 1024 * 1024,
              data.le16(0) == 0, data.le16(2) == 1 else { throw ICOError.invalidFile }
        let count = data.le16(4), directoryEnd = 6 + count * 16
        guard (1...256).contains(count), directoryEnd <= data.count else { throw ICOError.invalidFile }
        var entries: [ICOFile.Entry] = []
        var totalPayloadBytes = 0
        for i in 0..<count {
            let offset = 6 + i * 16
            let width = data[offset] == 0 ? 256 : Int(data[offset])
            let height = data[offset + 1] == 0 ? 256 : Int(data[offset + 1])
            let length = data.le32(offset + 8), start = data.le32(offset + 12)
            guard data[offset + 3] == 0, length > 0, start >= directoryEnd,
                  start <= data.count, length <= data.count - start else { throw ICOError.invalidFile }
            totalPayloadBytes += length
            guard totalPayloadBytes <= 64 * 1024 * 1024 else { throw ICOError.invalidFile }
            let entry = ICOFile.Entry(width: width, height: height, bitDepth: data.le16(offset + 6),
                                      directory: data.subdata(in: offset..<offset + 8), payload: data.subdata(in: start..<start + length))
            // Validate payload dimensions before ImageIO or bitmap allocation.
            if entry.isPNG {
                guard let source = CGImageSourceCreateWithData(entry.payload as CFData, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      props[kCGImagePropertyPixelWidth] as? Int == width,
                      props[kCGImagePropertyPixelHeight] as? Int == height else { throw ICOError.invalidFile }
            } else { _ = try BitmapLayout(entry) }
            entries.append(entry)
        }
        return ICOFile(entries: entries)
    }

    static func decode(_ file: ICOFile, index: Int) throws -> Raster {
        guard file.entries.indices.contains(index) else { throw ICOError.invalidEntry }
        let entry = file.entries[index]
        if entry.isPNG { return try ProjectCodec.decodeImage(entry.payload) }
        return try decodeBitmap(entry)
    }

    static func encode(_ images: [Raster]) throws -> Data {
        try pack(images.map { try makeEntry($0) })
    }

    static func replacing(_ source: IconSource, with raster: Raster) throws -> Data {
        guard source.file.entries.indices.contains(source.index) else { throw ICOError.invalidEntry }
        var entries = source.file.entries
        entries[source.index] = try makeEntry(raster)
        return try pack(entries)
    }

    static func sizeSet(from raster: Raster, smooth: Bool) throws -> Data {
        let images = try standardSizes.map { size -> Raster in
            let factor = min(Double(size) / Double(raster.width), Double(size) / Double(raster.height))
            let w = max(1, min(size, Int((Double(raster.width) * factor).rounded())))
            let h = max(1, min(size, Int((Double(raster.height) * factor).rounded())))
            let image = w == raster.width && h == raster.height ? raster : try raster.scaled(width: w, height: h, smooth: smooth)
            return image.resizedCanvas(width: size, height: size, offsetX: (size - w) / 2, offsetY: (size - h) / 2)
        }
        return try encode(images)
    }

    private static func pack(_ entries: [ICOFile.Entry]) throws -> Data {
        guard (1...256).contains(entries.count) else { throw ICOError.invalidFile }
        var result = Data(); result.appendLE16(0); result.appendLE16(1); result.appendLE16(entries.count)
        var offset = 6 + entries.count * 16
        for entry in entries {
            guard entry.directory.count == 8, entry.payload.count <= 64 * 1024 * 1024,
                  offset + entry.payload.count <= 64 * 1024 * 1024 else { throw ICOError.invalidFile }
            result.append(entry.directory); result.appendLE32(entry.payload.count); result.appendLE32(offset)
            offset += entry.payload.count
        }
        for entry in entries { result.append(entry.payload) }
        return result
    }

    private static func makeEntry(_ raster: Raster) throws -> ICOFile.Entry {
        guard (1...256).contains(raster.width), (1...256).contains(raster.height) else { throw ICOError.invalidSize }
        let png = raster.width == 256 || raster.height == 256
        let payload = try png ? ProjectCodec.imageData(raster.cgImage, type: UTType.png.identifier) : encodeBitmap(raster)
        var directory = Data([UInt8(raster.width % 256), UInt8(raster.height % 256), 0, 0])
        directory.appendLE16(1); directory.appendLE16(32)
        return .init(width: raster.width, height: raster.height, bitDepth: 32, directory: directory, payload: payload)
    }

    private static func encodeBitmap(_ raster: Raster) -> Data {
        let w = raster.width, h = raster.height, maskStride = ((w + 31) / 32) * 4
        var data = Data()
        data.appendLE32(40); data.appendLE32(w); data.appendLE32(h * 2)
        data.appendLE16(1); data.appendLE16(32); data.appendLE32(0)
        data.appendLE32((w * 4 + maskStride) * h)
        for _ in 0..<4 { data.appendLE32(0) }
        var mask = Data(count: maskStride * h)
        for row in 0..<h {
            for x in 0..<w {
                let color = raster.pixel(x: x, y: h - 1 - row)
                data.append(contentsOf: [color.b, color.g, color.r, color.a])
                if color.a == 0 { mask[row * maskStride + x / 8] |= UInt8(0x80 >> (x % 8)) }
            }
        }
        data.append(mask)
        return data
    }

    private struct BitmapLayout {
        let width: Int, height: Int, bits: Int, topDown: Bool
        let pixelOffset: Int, stride: Int, maskOffset: Int, maskStride: Int, hasMask: Bool
        let palette: [(UInt8, UInt8, UInt8)]
        let red: UInt32, green: UInt32, blue: UInt32, alpha: UInt32
        init(_ entry: ICOFile.Entry) throws {
            let d = entry.payload
            guard d.count >= 40 else { throw ICOError.invalidFile }
            let header = d.le32(0)
            guard [40, 52, 56, 108, 124].contains(header), header <= d.count else { throw ICOError.unsupportedBitmap }
            let w = Int(Int32(bitPattern: UInt32(d.le32(4)))), signedHeight = Int(Int32(bitPattern: UInt32(d.le32(8))))
            guard w == entry.width, abs(signedHeight) == entry.height * 2, d.le16(12) == 1 else { throw ICOError.invalidFile }
            width = w; height = entry.height; topDown = signedHeight < 0; bits = d.le16(14)
            let compression = d.le32(16)
            guard [1, 4, 8, 16, 24, 32].contains(bits), compression == 0 || (compression == 3 && (bits == 16 || bits == 32)) else { throw ICOError.unsupportedBitmap }
            var offset = header
            if compression == 3 {
                guard d.count >= 52 else { throw ICOError.invalidFile }
                red = UInt32(d.le32(40)); green = UInt32(d.le32(44)); blue = UInt32(d.le32(48))
                alpha = header >= 56 ? UInt32(d.le32(52)) : 0
                if header == 40 { offset += 12 }
                let rgb = red | green | blue
                func valid(_ mask: UInt32) -> Bool {
                    if mask == 0 { return false }
                    let shifted = mask >> mask.trailingZeroBitCount
                    return (shifted & (shifted &+ 1)) == 0
                }
                guard valid(red), valid(green), valid(blue), alpha == 0 || valid(alpha),
                      red & green == 0, red & blue == 0, green & blue == 0, rgb & alpha == 0,
                      bits == 32 || (rgb | alpha) <= 0xffff else { throw ICOError.invalidFile }
            } else {
                red = bits == 16 ? 0x7c00 : 0xff0000
                green = bits == 16 ? 0x03e0 : 0x00ff00
                blue = bits == 16 ? 0x001f : 0x0000ff
                alpha = bits == 32 ? 0xff000000 : 0
            }
            let used = d.le32(32)
            let colors = bits <= 8 ? (used == 0 ? 1 << bits : used) : used
            guard colors <= (bits <= 8 ? 1 << bits : 256), offset + colors * 4 <= d.count else { throw ICOError.invalidFile }
            palette = (0..<colors).map { i in (d[offset + i * 4 + 2], d[offset + i * 4 + 1], d[offset + i * 4]) }
            offset += colors * 4
            pixelOffset = offset; stride = ((w * bits + 31) / 32) * 4
            maskOffset = offset + stride * height; maskStride = ((w + 31) / 32) * 4
            guard maskOffset <= d.count else { throw ICOError.invalidFile }
            hasMask = maskStride * height <= d.count - maskOffset
            guard hasMask || bits == 32 else { throw ICOError.invalidFile }
            // A partly truncated mask is never valid, including for 32-bit icons.
            guard hasMask || d.count == maskOffset else { throw ICOError.invalidFile }
        }
    }

    private static func decodeBitmap(_ entry: ICOFile.Entry) throws -> Raster {
        let l = try BitmapLayout(entry), d = entry.payload
        func channel(_ value: UInt32, _ mask: UInt32) -> UInt8 {
            guard mask != 0 else { return 0 }
            let shift = mask.trailingZeroBitCount, maxValue = UInt64(mask >> shift)
            return UInt8((UInt64((value & mask) >> shift) * 255 + maxValue / 2) / maxValue)
        }
        // Legacy 32-bit icons often leave every alpha byte zero and use only the AND mask.
        var usesAlpha = false
        if l.bits == 32 && l.alpha != 0 {
            for row in 0..<l.height {
                for x in 0..<l.width where UInt32(d.le32(l.pixelOffset + row * l.stride + x * 4)) & l.alpha != 0 { usesAlpha = true }
            }
        }
        var result = Raster(width: l.width, height: l.height)
        var pixels = result.bytes
        for y in 0..<l.height {
            let row = l.topDown ? y : l.height - 1 - y, start = l.pixelOffset + row * l.stride
            for x in 0..<l.width {
                var r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0, a: UInt8 = 255
                if l.bits <= 8 {
                    let value = d[start + x * l.bits / 8]
                    let index = Int((value >> (8 - l.bits - (x * l.bits % 8))) & UInt8((1 << l.bits) - 1))
                    guard index < l.palette.count else { throw ICOError.invalidFile }
                    (r, g, b) = l.palette[index]
                } else if l.bits == 24 {
                    b = d[start + x * 3]; g = d[start + x * 3 + 1]; r = d[start + x * 3 + 2]
                } else {
                    let value = UInt32(l.bits == 16 ? d.le16(start + x * 2) : d.le32(start + x * 4))
                    r = channel(value, l.red); g = channel(value, l.green); b = channel(value, l.blue)
                    if usesAlpha { a = channel(value, l.alpha) }
                }
                if !usesAlpha && l.hasMask && d[l.maskOffset + row * l.maskStride + x / 8] & UInt8(0x80 >> (x % 8)) != 0 { a = 0 }
                let i = (y * l.width + x) * 4
                pixels[i] = UInt8((Int(r) * Int(a) + 127) / 255)
                pixels[i + 1] = UInt8((Int(g) * Int(a) + 127) / 255)
                pixels[i + 2] = UInt8((Int(b) * Int(a) + 127) / 255)
                pixels[i + 3] = a
            }
        }
        result.bytes = pixels
        return result
    }
}

extension Data {
    // Callers validate bounds before reading. Byte access avoids alignment assumptions.
    fileprivate func le16(_ offset: Int) -> Int { Int(self[offset]) | Int(self[offset + 1]) << 8 }
    fileprivate func le32(_ offset: Int) -> Int { le16(offset) | le16(offset + 2) << 16 }
    fileprivate mutating func appendLE16(_ value: Int) { append(UInt8(value & 255)); append(UInt8((value >> 8) & 255)) }
    fileprivate mutating func appendLE32(_ value: Int) { appendLE16(value & 0xffff); appendLE16((value >> 16) & 0xffff) }
}
