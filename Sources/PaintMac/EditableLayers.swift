import AppKit
import CoreImage

/// The raster is a lossless display cache. Editable text and its geometry are
/// kept separately; painting never silently discards this source information.
struct TextLayerContent: Equatable, Codable {
    var string: String
    var style: TextStyle
    var rect: CGRect
    var color: PixelColor
    var opacity: Double
    var antialias: Bool
    var horizontalScale: Double = 1

    func validate() throws {
        guard string.utf8.count <= 1_000_000, style.family.utf8.count <= 512,
              style.size.isFinite, style.size > 0, style.size <= 16384,
              opacity.isFinite, (0...1).contains(opacity), horizontalScale.isFinite,
              (1.0 / 1_000_000_000...1_000_000_000).contains(horizontalScale),
              [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              abs(rect.minX) <= 131072, abs(rect.minY) <= 131072,
              rect.width > 0, rect.height > 0, rect.width <= 32768, rect.height <= 32768 else { throw PaintError.invalidProject }
    }
    func rendered(width: Int, height: Int, clip: SelectionMask?, format: RGBFormat = .standard) -> Raster {
        var raster = Raster(width: width, height: height, format: format)
        raster.drawText(string, in: rect, font: style.font, color: color, opacity: opacity,
                        antialias: antialias, selection: clip, horizontalScale: horizontalScale)
        return raster
    }
    mutating func transform(sx: Double = 1, sy: Double = 1, dx: Double = 0, dy: Double = 0) {
        rect = CGRect(x: rect.minX * sx + dx, y: rect.minY * sy + dy, width: rect.width * sx, height: rect.height * sy)
        style.size *= sy; horizontalScale *= sx / sy
    }
}

enum EffectKind: String, Codable, CaseIterable {
    case blur, brightnessContrast, hueSaturation, grayscale, invert
    var title: String {
        switch self {
        case .blur: return "Gaussian Blur"
        case .brightnessContrast: return "Brightness & Contrast"
        case .hueSaturation: return "Hue & Saturation"
        case .grayscale: return "Grayscale"
        case .invert: return "Invert Colors"
        }
    }
}

struct EffectSettings: Equatable, Codable {
    var kind: EffectKind
    var radius: Double = 8
    var brightness: Double = 0
    var contrast: Double = 1
    var hue: Double = 0
    var saturation: Double = 1
    func validate() throws {
        guard radius.isFinite, (0...200).contains(radius), brightness.isFinite, (-1...1).contains(brightness),
              contrast.isFinite, (0...4).contains(contrast), hue.isFinite, (-180...180).contains(hue),
              saturation.isFinite, (0...2).contains(saturation) else { throw PaintError.invalidProject }
    }
    func filtered(_ image: CIImage, bounds: CGRect) -> CIImage {
        switch kind {
        case .blur:
            return radius == 0 ? image : image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: bounds)
        case .brightnessContrast:
            return image.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: brightness, kCIInputContrastKey: contrast])
        case .hueSaturation:
            return image.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: hue * .pi / 180])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: saturation])
        case .grayscale: return image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        case .invert: return image.applyingFilter("CIColorInvert")
        }
    }
}

extension PaintLayer {
    var isPixelLayer: Bool { !isGroup && text == nil && effect == nil }
    mutating func rasterizeText() { text = nil; textClip = nil }
    mutating func renderText() { if let text { raster = text.rendered(width: raster.width, height: raster.height, clip: textClip, format: raster.format) } }
}

extension PaintDocument {
    func rasterizeActiveText() {
        finishPendingEdits?()
        guard state.activeLayer.text != nil else { return }
        edit("Rasterize Text Layer") { $0.layers[$0.activeIndex].rasterizeText() }
    }
    func addEffect(_ settings: EffectSettings) throws {
        finishPendingEdits?(); try settings.validate()
        guard state.layers.count < 32 else { throw PaintError.tooManyLayers }
        edit("Add Effect Layer") { state in
            var layer = PaintLayer(name: settings.kind.title, raster: Raster(width: state.width, height: state.height, format: state.format))
            layer.effect = settings; layer.mask = state.selection
            state.insertLayer(layer); state.selection = nil
        }
    }
    func setEffect(_ settings: EffectSettings, on id: UUID) throws {
        try settings.validate()
        edit("Edit Effect Layer") { state in
            guard let index = state.layers.firstIndex(where: { $0.id == id }), state.layers[index].effect != nil else { return }
            state.layers[index].effect = settings
        }
    }
}
