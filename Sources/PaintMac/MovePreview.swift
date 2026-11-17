import CoreImage

/// A gesture owns immutable source graphs. Pointer updates change only a
/// translation, without cutting/copying raster pixels or rebuilding selection
/// coverage/contours. The existing pixel transaction runs once at mouse-up.
struct MovePreview {
    struct Pixels {
        let original: CIImage
        let background: CIImage
        let lifted: CIImage
        let bounds: CGRect
        private let sampleSpace: CGColorSpace?
        init(_ raster: Raster, selection: SelectionMask?) {
            original = raster.ciImage; bounds = raster.bounds
            if let selection, !selection.isEmpty {
                // Match the document's encoded RGB arithmetic before lifting
                // and source-over, then return to the renderer's working space.
                // P3/other profiles must not silently blend as encoded sRGB.
                sampleSpace = raster.format.profile.space
                let samples = original.matchedFromWorkingSpace(to: sampleSpace!)!
                let coverage = selection.storage.ciImage
                background = samples.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: coverage]).insertingIntermediate(cache: true)
                let rect = CGRect(x: selection.bounds.minX, y: CGFloat(raster.height) - selection.bounds.maxY,
                                  width: selection.bounds.width, height: selection.bounds.height)
                lifted = samples.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: coverage])
                    .cropped(to: rect).insertingIntermediate(cache: true)
            } else {
                sampleSpace = nil
                background = selection == nil ? CIImage(color: .clear).cropped(to: bounds) : original
                lifted = selection == nil ? original.insertingIntermediate(cache: true) : CIImage(color: .clear).cropped(to: bounds)
            }
        }
        func image(dx: Int, dy: Int) -> CIImage {
            guard dx != 0 || dy != 0 else { return original }
            let moved = lifted.transformed(by: CGAffineTransform(translationX: CGFloat(dx), y: -CGFloat(dy)))
            let result = moved.composited(over: background).cropped(to: bounds)
            return sampleSpace.map { result.matchedToWorkingSpace(from: $0)! } ?? result
        }
        func coverage(dx: Int, dy: Int) -> CIImage {
            // Mask working rasters are opaque encoded grays. After cutting,
            // their premultiplied luminance (including transparent black) is
            // converted back into linear alpha coverage, just like the CPU path.
            image(dx: dx, dy: dy).composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)))
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 54.0 / 256, y: 183.0 / 256, z: 19.0 / 256, w: 0),
                    "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0)
                ]).cropped(to: bounds)
        }
    }
    let state: DocumentState
    private let rasters: [UUID: Pixels]
    private let masks: [UUID: Pixels]
    private let quickMask: Pixels?
    private let stationaryRasters: [UUID: CIImage]
    private let stationaryMasks: [UUID: CIImage]
    private var textLayers: [UUID: PaintLayer] = [:]

    init(state: DocumentState, selection: SelectionMask?) {
        self.state = state
        stationaryRasters = Dictionary(uniqueKeysWithValues: state.layers.filter { !$0.isGroup }.map { ($0.id, $0.raster.ciImage) })
        stationaryMasks = Dictionary(uniqueKeysWithValues: state.layers.compactMap { layer in layer.mask.map { (layer.id, $0.storage.ciImage) } })
        let coverage = selection
        if state.isQuickMask {
            quickMask = Pixels(state.editingRaster, selection: coverage)
            rasters = [:]; masks = [:]
        } else {
            quickMask = nil
            if state.isEditingMask {
                rasters = [:]; masks = [state.activeID: Pixels(state.editingRaster, selection: coverage)]
            } else {
                let ids = state.subtreeIDs(state.activeID)
                var images: [UUID: Pixels] = [:], masks: [UUID: Pixels] = [:]
                for layer in state.layers where ids.contains(layer.id) {
                    if layer.text != nil { textLayers[layer.id] = layer }
                    else if layer.isPixelLayer { images[layer.id] = Pixels(layer.raster, selection: coverage) }
                    if let mask = layer.mask { masks[layer.id] = Pixels(mask.editingRaster, selection: layer.text == nil ? coverage : nil) }
                }
                rasters = images; self.masks = masks
            }
        }
    }
    func image(dx: Int, dy: Int, renderer: ImageRenderer) -> CIImage {
        var images = stationaryRasters, maskImages = stationaryMasks
        for (id, pixels) in rasters { images[id] = pixels.image(dx: dx, dy: dy) }
        for (id, pixels) in masks { maskImages[id] = pixels.coverage(dx: dx, dy: dy) }
        // Editable text can reveal glyphs that were outside the old canvas.
        // Re-layout its bounded cache from metadata rather than losing them by
        // translating an already clipped raster. Pixel layers stay cached.
        for (id, source) in textLayers {
            var layer = source
            if dx != 0 || dy != 0 {
                layer.text!.transform(dx: Double(dx), dy: Double(dy))
                layer.textClip = source.textClip?.translated(dx: dx, dy: dy)
                layer.renderText()
            }
            images[id] = layer.raster.ciImage
        }
        let image = renderer.compositeImage(state.layers, width: state.width, height: state.height,
            rasterOverrides: images,
            maskOverrides: maskImages)
        if let quickMask {
            return QuickMaskOverlay.image(coverage: quickMask.coverage(dx: dx, dy: dy),
                                          bounds: quickMask.bounds, over: image)
        }
        return image
    }
}
