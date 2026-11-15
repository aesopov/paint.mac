import AppKit

private func maskLuminance(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt8 {
    let red = Int(r) * 54, green = Int(g) * 183, blue = Int(b) * 19
    return UInt8((red + green + blue + 128) / 256)
}

extension PixelColor {
    static let maskBlack = PixelColor(r: 0, g: 0, b: 0)
    /// Encoded grayscale values represent direct mask coverage, without a gamma
    /// conversion. Keep source alpha for ordinary paint-opacity behavior.
    var maskColor: PixelColor {
        let gray = maskLuminance(r, g, b)
        return PixelColor(r: gray, g: gray, b: gray, a: a)
    }
}

extension SelectionMask {
    /// An opaque grayscale working surface lets all raster tools share their
    /// existing antialiasing, brush-opacity, and selection-coverage behavior.
    var editingRaster: Raster {
        var result = Raster(width: width, height: height)
        result.bytes.withUnsafeMutableBytes { raw in
            coverage.withUnsafeBytes { maskRaw in
                let dst = raw.bindMemory(to: UInt8.self), src = maskRaw.bindMemory(to: UInt8.self)
                for i in 0..<src.count {
                    dst[i * 4] = src[i]; dst[i * 4 + 1] = src[i]; dst[i * 4 + 2] = src[i]; dst[i * 4 + 3] = 255
                }
            }
        }
        return result
    }
    init(editingRaster raster: Raster) {
        var coverage = Data(count: raster.width * raster.height)
        coverage.withUnsafeMutableBytes { raw in
            raster.bytes.withUnsafeBytes { imageRaw in
                let dst = raw.bindMemory(to: UInt8.self), src = imageRaw.bindMemory(to: UInt8.self)
                for i in 0..<dst.count {
                    // Premultiplied values composite erased/transparent pixels
                    // over black, making eraser and Delete hide mask regions.
                    dst[i] = maskLuminance(src[i * 4], src[i * 4 + 1], src[i * 4 + 2])
                }
            }
        }
        self.init(width: raster.width, height: raster.height, coverage: coverage)
    }
    func resizedLayerMask(width newWidth: Int, height newHeight: Int, offsetX: Int, offsetY: Int) -> Self {
        var result = Data(repeating: 255, count: newWidth * newHeight)
        let x0 = max(0, -offsetX), x1 = min(width, newWidth - offsetX)
        let y0 = max(0, -offsetY), y1 = min(height, newHeight - offsetY)
        if x0 < x1 && y0 < y1 {
            for y in y0..<y1 {
                let source = y * width + x0, target = (y + offsetY) * newWidth + x0 + offsetX
                result.replaceSubrange(target..<target + x1 - x0, with: coverage[source..<source + x1 - x0])
            }
        }
        return Self(width: newWidth, height: newHeight, coverage: result)
    }
}

enum LayerMaskSource { case revealAll, hideAll, selection }

extension PaintDocument {
    func addLayerMask(_ source: LayerMaskSource) {
        finishPendingEdits?()
        guard state.activeLayer.mask == nil, source != .selection || state.selection != nil else { return }
        edit("Add Layer Mask") { state in
            let mask: SelectionMask
            switch source {
            case .revealAll: mask = .all(width: state.width, height: state.height)
            case .hideAll: mask = .empty(width: state.width, height: state.height)
            case .selection: mask = state.selection!
            }
            state.layers[state.activeIndex].mask = mask
            state.layers[state.activeIndex].maskEnabled = true
            state.editingMask = true
            if source == .selection { state.selection = nil }
        }
    }
    func invertLayerMask() {
        edit("Invert Layer Mask") { state in
            state.layers[state.activeIndex].mask = state.activeLayer.mask?.inverted()
        }
    }
    func featherLayerMask(radius: Double) {
        edit("Feather Layer Mask") { state in
            state.layers[state.activeIndex].mask = state.activeLayer.mask?.feathered(radius: radius, context: renderer.context)
        }
    }
    func toggleLayerMask() {
        guard state.activeLayer.mask != nil else { return }
        edit(state.activeLayer.maskEnabled ? "Disable Layer Mask" : "Enable Layer Mask") { state in
            state.layers[state.activeIndex].maskEnabled.toggle()
        }
    }
    func deleteLayerMask(apply: Bool) {
        finishPendingEdits?()
        guard state.activeLayer.mask != nil else { return }
        if apply && state.activeLayer.effect != nil { mergeActiveDown(forceMask: true); return }
        if apply && state.activeLayer.isGroup { mergeActiveGroup(forceMask: true); return }
        edit(apply ? "Apply Layer Mask" : "Delete Layer Mask") { state in
            let index = state.activeIndex
            guard let mask = state.layers[index].mask else { return }
            // Apply explicitly bakes even a temporarily disabled mask.
            if apply { state.layers[index].raster = state.layers[index].raster.masked(using: mask); state.layers[index].rasterizeText() }
            state.layers[index].mask = nil; state.layers[index].maskEnabled = true; state.editingMask = false
        }
    }
}
