import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A slot describes display size as well as pixels. Equal pixel dimensions do
/// not make a 16 pt @2x icon interchangeable with a 32 pt @1x icon.
struct ICNSSlot: Equatable {
    let type: String
    let points: Int
    let scale: Int
    let maskType: String?
    let canReplace: Bool
    var pixels: Int { points * scale }
    var title: String { "\(points) × \(points) @\(scale)x · \(pixels) × \(pixels) px" }

    init(_ type: String, _ points: Int, _ scale: Int = 1, mask: String? = nil, replaceable: Bool = true) {
        self.type = type; self.points = points; self.scale = scale; maskType = mask; canReplace = replaceable
    }
    static let standard: [ICNSSlot] = [
        .init("ic04", 16), .init("ic11", 16, 2), .init("ic05", 32), .init("ic12", 32, 2),
        .init("ic07", 128), .init("ic13", 128, 2), .init("ic08", 256), .init("ic14", 256, 2),
        .init("ic09", 512), .init("ic10", 512, 2)
    ]
    static let readable: [ICNSSlot] = standard + [
        .init("icp4", 16), .init("icp5", 32), .init("icp6", 64),
        .init("is32", 16, mask: "s8mk"), .init("il32", 32, mask: "l8mk"),
        .init("ih32", 48, mask: "h8mk"), .init("it32", 128, mask: "t8mk"),
        .init("ics#", 16, replaceable: false), .init("ICN#", 32, replaceable: false), .init("ich#", 48, replaceable: false),
        .init("ics4", 16, mask: "ics#", replaceable: false), .init("ics8", 16, mask: "ics#", replaceable: false),
        .init("icl4", 32, mask: "ICN#", replaceable: false), .init("icl8", 32, mask: "ICN#", replaceable: false),
        .init("ich4", 48, mask: "ich#", replaceable: false), .init("ich8", 48, mask: "ich#", replaceable: false)
    ]
    static func choices(width: Int, height: Int) -> [ICNSSlot] {
        guard width == height else { return [] }
        return (standard + [.init("icp6", 64), .init("ih32", 48, mask: "h8mk")]).filter { $0.pixels == width }
    }
}

struct ICNSFile {
    struct Element: Equatable { let type: String; let payload: Data }
    struct Representation {
        let elementIndex: Int
        let slot: ICNSSlot
        var title: String { slot.title + (slot.canReplace ? "" : " · Legacy indexed/monochrome") }
    }
    let elements: [Element]
    let representations: [Representation]
}
struct ICNSSource {
    let file: ICNSFile
    let index: Int // index in representations, not elements
    let name: String
}

enum ICNSError: LocalizedError {
    case invalidFile, noImages, invalidSlot, wrongDimensions, legacyReplacement
    var errorDescription: String? {
        switch self {
        case .invalidFile: return "This ICNS file is damaged or contains invalid image data."
        case .noImages: return "This ICNS file has no supported image representations."
        case .invalidSlot: return "Choose a supported square ICNS size, or export a complete macOS icon set."
        case .wrongDimensions: return "The canvas must match the original ICNS slot's pixel dimensions to update it. Resize the image back, or export a complete macOS icon set."
        case .legacyReplacement: return "This legacy indexed or monochrome slot can be opened but cannot be replaced in place. Export a complete macOS icon set instead."
        }
    }
}

/// Bounded ICNS resource parsing. ImageIO decodes an isolated representation
/// with its companion mask, so it cannot substitute another same-size slot.
enum ICNSCodec {
    static func isICNS(_ data: Data) -> Bool { data.starts(with: Data("icns".utf8)) }
    static func read(_ data: Data) throws -> ICNSFile {
        guard data.count >= 8, data.count <= 128 * 1024 * 1024, isICNS(data), data.icnsBE32(4) == data.count else { throw ICNSError.invalidFile }
        var offset = 8
        var elements: [ICNSFile.Element] = []
        var reps: [ICNSFile.Representation] = []
        while offset < data.count {
            guard data.count - offset >= 8, elements.count < 512 else { throw ICNSError.invalidFile }
            let size = data.icnsBE32(offset + 4)
            guard size >= 8, size <= data.count - offset else { throw ICNSError.invalidFile }
            // FourCCs are arbitrary bytes. Latin-1 preserves unknown resource IDs.
            let type = String(data: data.subdata(in: offset..<offset + 4), encoding: .isoLatin1)!
            let payload = data.subdata(in: offset + 8..<offset + size)
            if let slot = ICNSSlot.readable.first(where: { $0.type == type }) {
                if !slot.canReplace {
                    let bits = type.hasSuffix("4") ? 4 : (type.hasSuffix("8") ? 8 : 2)
                    guard payload.count == slot.pixels * slot.pixels * bits / 8 else { throw ICNSError.invalidFile }
                }
                if payload.starts(with: ICOCodec.pngSignature) || payload.starts(with: [0, 0, 0, 12, 106, 80, 32, 32]) || payload.starts(with: [255, 79, 255, 81]) {
                    guard let source = CGImageSourceCreateWithData(payload as CFData, nil),
                          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          props[kCGImagePropertyPixelWidth] as? Int == slot.pixels,
                          props[kCGImagePropertyPixelHeight] as? Int == slot.pixels else { throw ICNSError.invalidFile }
                }
                reps.append(.init(elementIndex: elements.count, slot: slot))
            }
            elements.append(.init(type: type, payload: payload)); offset += size
        }
        guard !reps.isEmpty else { throw ICNSError.noImages }
        return ICNSFile(elements: elements, representations: reps)
    }

    static func decode(_ file: ICNSFile, index: Int) throws -> Raster {
        guard file.representations.indices.contains(index) else { throw ICNSError.invalidSlot }
        let rep = file.representations[index], element = file.elements[rep.elementIndex]
        if element.payload.starts(with: ICOCodec.pngSignature) || element.payload.starts(with: [0, 0, 0, 12, 106, 80, 32, 32]) || element.payload.starts(with: [255, 79, 255, 81]) {
            return try ProjectCodec.decodeImage(element.payload)
        }
        var isolated = [element]
        if let mask = rep.slot.maskType, let companion = file.elements.first(where: { $0.type == mask }) {
            if mask.hasSuffix("8mk") && companion.payload.count != rep.slot.pixels * rep.slot.pixels { throw ICNSError.invalidFile }
            isolated.append(companion)
        }
        let data = try pack(isolated, rebuildTOC: false)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              props[kCGImagePropertyPixelWidth] as? Int == rep.slot.pixels,
              props[kCGImagePropertyPixelHeight] as? Int == rep.slot.pixels,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ICNSError.invalidFile }
        var raster = try Raster(image: image)
        if !rep.slot.canReplace {
            // ImageIO can ignore a legacy 1-bit mask on indexed resources.
            // Monochrome resources store image bits followed by mask bits;
            // indexed resources use that monochrome family's mask plane.
            let maskElement = rep.slot.maskType.flatMap { type in file.elements.first { $0.type == type } }
                ?? (element.type.hasSuffix("#") ? element : nil)
            if let maskElement {
                let planeBytes = rep.slot.pixels * rep.slot.pixels / 8
                guard maskElement.payload.count == planeBytes * 2 else { throw ICNSError.invalidFile }
                for i in 0..<rep.slot.pixels * rep.slot.pixels {
                    if maskElement.payload[planeBytes + i / 8] & UInt8(0x80 >> (i % 8)) == 0 {
                        raster.bytes.replaceSubrange(i * 4..<i * 4 + 4, with: [0, 0, 0, 0])
                    }
                }
            }
        }
        return raster
    }

    static func encode(_ raster: Raster, slot: ICNSSlot) throws -> Data {
        try pack(makeElements(raster, slot: slot))
    }
    static func sizeSet(from raster: Raster, smooth: Bool) throws -> Data {
        var elements: [ICNSFile.Element] = []
        var scaled: [Int: Raster] = [:]
        for slot in ICNSSlot.standard {
            let size = slot.pixels
            let image: Raster
            if let cached = scaled[size] { image = cached }
            else {
                let factor = Double(size) / Double(max(raster.width, raster.height))
                let w = max(1, min(size, Int((Double(raster.width) * factor).rounded())))
                let h = max(1, min(size, Int((Double(raster.height) * factor).rounded())))
                let resized = w == raster.width && h == raster.height ? raster : try raster.scaled(width: w, height: h, smooth: smooth)
                image = resized.resizedCanvas(width: size, height: size, offsetX: (size - w) / 2, offsetY: (size - h) / 2)
                scaled[size] = image
            }
            elements += try makeElements(image, slot: slot)
        }
        return try pack(elements)
    }
    static func validateReplacement(_ source: ICNSSource, width: Int, height: Int) throws {
        guard source.file.representations.indices.contains(source.index) else { throw ICNSError.invalidSlot }
        let slot = source.file.representations[source.index].slot
        guard slot.canReplace else { throw ICNSError.legacyReplacement }
        guard width == slot.pixels, height == slot.pixels else { throw ICNSError.wrongDimensions }
    }
    static func replacing(_ source: ICNSSource, with raster: Raster) throws -> Data {
        try validateReplacement(source, width: raster.width, height: raster.height)
        let rep = source.file.representations[source.index]
        let replacement = try makeElements(raster, slot: rep.slot)
        var elements = source.file.elements
        elements[rep.elementIndex] = replacement[0]
        for companion in replacement.dropFirst() {
            if let i = elements.firstIndex(where: { $0.type == companion.type }) { elements[i] = companion }
            else { elements.append(companion) }
        }
        return try pack(elements)
    }

    private static func makeElements(_ raster: Raster, slot: ICNSSlot) throws -> [ICNSFile.Element] {
        guard slot.canReplace, ICNSSlot.readable.contains(slot), raster.width == slot.pixels, raster.height == slot.pixels else { throw ICNSError.invalidSlot }
        if slot.type == "ic04" || slot.type == "ic05" || slot.maskType != nil {
            var channels = [[UInt8]](repeating: [], count: 4)
            for y in 0..<raster.height {
                for x in 0..<raster.width {
                    let c = raster.pixel(x: x, y: y)
                    channels[0].append(c.a); channels[1].append(c.r); channels[2].append(c.g); channels[3].append(c.b)
                }
            }
            let argb = slot.maskType == nil
            var payload = argb ? Data("ARGB".utf8) : (slot.type == "it32" ? Data(count: 4) : Data())
            // Literal packets are valid ICNS RLE; no cross-channel ambiguity.
            for channel in channels[(argb ? 0 : 1)...3] {
                var i = 0
                while i < channel.count {
                    let count = min(128, channel.count - i)
                    payload.append(UInt8(count - 1)); payload.append(contentsOf: channel[i..<i + count]); i += count
                }
            }
            var result = [ICNSFile.Element(type: slot.type, payload: payload)]
            if let mask = slot.maskType { result.append(.init(type: mask, payload: Data(channels[0]))) }
            return result
        }
        return [.init(type: slot.type, payload: try ProjectCodec.imageData(raster.cgImage, type: UTType.png.identifier))]
    }

    static func pack(_ input: [ICNSFile.Element], rebuildTOC: Bool = true) throws -> Data {
        guard input.count <= 512 else { throw ICNSError.invalidFile }
        var elements = input
        if rebuildTOC && elements.contains(where: { $0.type == "TOC " }) {
            var table = Data()
            for element in elements where element.type != "TOC " {
                guard let type = element.type.data(using: .isoLatin1), type.count == 4 else { throw ICNSError.invalidFile }
                table.append(type); table.appendICNS32(element.payload.count + 8)
            }
            for i in elements.indices where elements[i].type == "TOC " { elements[i] = .init(type: "TOC ", payload: table) }
        }
        var body = Data()
        for element in elements {
            guard let type = element.type.data(using: .isoLatin1), type.count == 4,
                  element.payload.count <= 128 * 1024 * 1024 - 8,
                  body.count <= 128 * 1024 * 1024 - 16 - element.payload.count else { throw ICNSError.invalidFile }
            body.append(type); body.appendICNS32(element.payload.count + 8); body.append(element.payload)
        }
        var result = Data("icns".utf8); result.appendICNS32(body.count + 8); result.append(body)
        return result
    }
}

private extension Data {
    func icnsBE32(_ offset: Int) -> Int {
        Int(self[offset]) << 24 | Int(self[offset + 1]) << 16 | Int(self[offset + 2]) << 8 | Int(self[offset + 3])
    }
    mutating func appendICNS32(_ value: Int) {
        append(contentsOf: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
    }
}
