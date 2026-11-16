import AppKit
import CoreImage
import ImageIO

/// Profiles describe RGB numbers; conversion preserves appearance within the
/// destination gamut. Embedded ICC data is retained for custom RGB profiles.
struct RGBProfile: Codable, Hashable {
    var name: String
    var icc: Data
    var space: CGColorSpace { CGColorSpace(iccData: icc as CFData)! }
    init(_ space: CGColorSpace, name: String? = nil) {
        self.name = name ?? (space.name as String?) ?? "Embedded RGB"
        icc = space.copyICCData()! as Data
    }
    static let sRGB = RGBProfile(CGColorSpace(name: CGColorSpace.sRGB)!, name: "sRGB")
    static let displayP3 = RGBProfile(CGColorSpace(name: CGColorSpace.displayP3)!, name: "Display P3")
    static let adobeRGB = RGBProfile(CGColorSpace(name: CGColorSpace.adobeRGB1998)!, name: "Adobe RGB (1998)")
    static let standard: [RGBProfile] = [.sRGB, .displayP3, .adobeRGB]
    static func imported(_ space: CGColorSpace?) -> RGBProfile {
        guard let space, space.model == .rgb, space.copyICCData() != nil else { return .sRGB }
        let profile = RGBProfile(space)
        return standard.first { $0.icc == profile.icc || $0.space.name == space.name } ?? profile
    }
    func validate() throws {
        guard !icc.isEmpty, icc.count <= 4 * 1024 * 1024, name.utf8.count <= 512,
              let space = CGColorSpace(iccData: icc as CFData), space.model == .rgb else { throw PaintError.invalidProject }
    }
}

enum RGBDepth: Int, Codable, CaseIterable {
    case eight = 8, sixteen = 16
    var bytesPerPixel: Int { rawValue / 8 * 4 }
    var maximum: Double { self == .eight ? 255 : 65535 }
    var title: String { "\(rawValue) bits/channel" }
    var bitmapInfo: UInt32 {
        CGImageAlphaInfo.premultipliedLast.rawValue | (self == .sixteen ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
    }
    var ciFormat: CIFormat { self == .eight ? .RGBA8 : .RGBA16 }
}

struct RGBFormat: Codable, Equatable {
    var profile: RGBProfile = .sRGB
    var depth: RGBDepth = .eight
    static let standard = RGBFormat()
    func validate() throws { try profile.validate() }
}

/// Resolution affects physical/print dimensions, independently of pixel size.
struct ImageResolution: Codable, Equatable {
    var x: Double = 72
    var y: Double = 72
    static let standard = ImageResolution()
    func validate() throws {
        guard x.isFinite, y.isFinite, (1...100000).contains(x), (1...100000).contains(y) else { throw PaintError.invalidResolution }
    }
    var properties: [CFString: Any] { [kCGImagePropertyDPIWidth: x, kCGImagePropertyDPIHeight: y] }
}

/// Access premultiplied integer samples without reducing a 16-bit surface to
/// 8 bits. UInt16 storage is explicitly little-endian, including cache files.
struct RGBSamples {
    let raw: UnsafeMutableRawBufferPointer
    let depth: RGBDepth
    var maximum: Double { depth.maximum }
    subscript(_ index: Int) -> Double {
        get { depth == .eight ? Double(raw[index]) : Double(UInt16(raw[index * 2]) | UInt16(raw[index * 2 + 1]) << 8) }
        nonmutating set {
            let n = UInt16(max(0, min(maximum, newValue.rounded())))
            if depth == .eight { raw[index] = UInt8(n) }
            else { raw[index * 2] = UInt8(truncatingIfNeeded: n); raw[index * 2 + 1] = UInt8(n >> 8) }
        }
    }
}

extension PixelColor {
    /// Tool colors are color managed into the destination surface before
    /// blending. Native text uses tagged NSColor and Quartz does the conversion.
    func components(in profile: RGBProfile) -> [Double] {
        if profile == .sRGB && extendedRGB == nil { return [Double(r) / 255, Double(g) / 255, Double(b) / 255] }
        let cg = nsColor.cgColor.converted(to: profile.space, intent: .defaultIntent, options: nil)!
        return Array(cg.components!.prefix(3)).map { Double(max(0, min(1, $0))) }
    }
}

extension PaintDocument {
    func applyColorSettings(_ format: RGBFormat, resolution: ImageResolution, pixelSize: CGSize? = nil, smooth: Bool = true) throws {
        try format.validate(); try resolution.validate()
        if let pixelSize {
            guard pixelSize.width.isFinite, pixelSize.height.isFinite, pixelSize.width >= 1, pixelSize.height >= 1,
                  pixelSize.width <= 8192, pixelSize.height <= 8192 else { throw PaintError.imageTooLarge }
            try CanvasSizePlan.validate(width: Int(pixelSize.width), height: Int(pixelSize.height))
        }
        finishPendingEdits?()
        var next = state
        for i in next.layers.indices {
            var raster = try state.layers[i].raster.converted(to: format)
            if let size = pixelSize, Int(size.width) != state.width || Int(size.height) != state.height {
                raster = try raster.scaled(width: Int(size.width), height: Int(size.height), smooth: smooth)
                if var text = next.layers[i].text {
                    text.transform(sx: size.width / Double(state.width), sy: size.height / Double(state.height))
                    next.layers[i].text = text
                }
                next.layers[i].textClip = next.layers[i].textClip?.scaled(width: Int(size.width), height: Int(size.height), smooth: smooth)
                next.layers[i].mask = next.layers[i].mask?.scaled(width: Int(size.width), height: Int(size.height), smooth: smooth)
            }
            raster.resolution = resolution; next.layers[i].raster = raster
        }
        if let size = pixelSize {
            next.width = Int(size.width); next.height = Int(size.height)
            next.selection = next.selection?.scaled(width: next.width, height: next.height, smooth: smooth)
        }
        next.format = format; next.resolution = resolution
        let previous = state; state = next; commit(previous, name: "Color & Resolution")
    }
}
