import CoreImage

/// Selected coverage is tinted red, including feathered/partially selected
/// pixels. The tiled overlay is display-only and never enters the composite
/// used for exports, thumbnails, or project pixels.
enum QuickMaskOverlay {
    static func image(_ mask: SelectionMask, over image: CIImage) -> CIImage {
        let bounds = mask.canvasBounds
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 0.45)).cropped(to: bounds)
        let clear = CIImage(color: .clear).cropped(to: bounds)
        return red.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: mask.storage.ciImage
        ]).composited(over: image)
    }
}

extension PaintDocument {
    /// Paste grayscale pixels into the temporary mask using normal source-over.
    /// Transparent clipboard pixels preserve the existing selection coverage.
    func pasteQuickMask(_ source: Raster) throws {
        guard state.isQuickMask else { return }
        let source = try source.converted(to: .standard)
        let dx = max(0, (state.width - source.width) / 2), dy = max(0, (state.height - source.height) / 2)
        let area = CGRect(x: dx, y: dy, width: source.width, height: source.height)
            .intersection(CGRect(x: 0, y: 0, width: state.width, height: state.height))
        guard !area.isEmpty else { return }
        let samples = source.storage.read(area.offsetBy(dx: -CGFloat(dx), dy: -CGFloat(dy)))
        edit("Paste into Quick Mask") { state in
            let selection = state.selection
            state.editRaster { raster in
                raster.editPixels(in: area, selection: selection) { raw, region in
                    samples.withUnsafeBytes { sourceRaw in
                        let dst = raw.bindMemory(to: UInt8.self), src = sourceRaw.bindMemory(to: UInt8.self)
                        for y in 0..<Int(region.height) { for x in 0..<Int(region.width) {
                            let i = (y * Int(region.width) + x) * 4
                            let j = ((y + Int(region.minY - area.minY)) * Int(area.width) + x + Int(region.minX - area.minX)) * 4
                            let gray = (Int(src[j]) * 54 + Int(src[j + 1]) * 183 + Int(src[j + 2]) * 19 + 128) / 256
                            let value = min(255, gray + (Int(dst[i]) * (255 - Int(src[j + 3])) + 127) / 255)
                            for c in 0..<3 { dst[i + c] = UInt8(value) }; dst[i + 3] = 255
                        } }
                    }
                }
            }
        }
    }
}
