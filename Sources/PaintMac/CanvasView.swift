import AppKit
import CoreImage

enum PaintTool: String, CaseIterable {
    case brush, eraser, selection, ellipseSelect, lasso, move, fill, eyedropper, line, rectangle, ellipse, text, crop, hand, blur, sharpen, smudge
    var isSelection: Bool { self == .selection || self == .ellipseSelect || self == .lasso }
    var isGeometry: Bool { self == .line || self == .rectangle || self == .ellipse }
    var isRetouch: Bool { self == .blur || self == .sharpen || self == .smudge }
    var isBrush: Bool { self == .brush || self == .eraser || isRetouch }
    var isPainting: Bool { [.brush, .eraser, .fill, .line, .rectangle, .ellipse, .text].contains(self) }
    var title: String {
        switch self {
        case .brush: return "Brush"
        case .eraser: return "Eraser"
        case .blur: return "Blur"
        case .sharpen: return "Sharpen"
        case .smudge: return "Smudge"
        case .selection: return "Rectangle Select"
        case .ellipseSelect: return "Ellipse Select"
        case .lasso: return "Lasso Select"
        case .move: return "Move Pixels"
        case .fill: return "Paint Bucket"
        case .eyedropper: return "Color Picker"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .text: return "Text"
        case .crop: return "Crop to Selection"
        case .hand: return "Hand"
        }
    }
    var symbol: String {
        switch self {
        case .brush: return "paintbrush.pointed"
        case .eraser: return "eraser"
        case .blur: return "drop.halffull"
        case .sharpen: return "triangle"
        case .smudge: return "hand.draw"
        case .selection: return "rectangle.dashed"
        case .ellipseSelect: return "circle.dashed"
        case .lasso: return "lasso"
        case .move: return "arrow.up.left.and.arrow.down.right"
        case .fill: return "drop.fill"
        case .eyedropper: return "eyedropper"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        case .crop: return "crop"
        case .hand: return "hand.draw"
        }
    }
    var key: String {
        switch self {
        case .brush: return "b"
        case .eraser: return "e"
        case .blur: return "u"
        case .sharpen: return "k"
        case .smudge: return "n"
        case .selection: return "s"
        case .ellipseSelect: return "m"
        case .lasso: return "a"
        case .move: return "v"
        case .fill: return "f"
        case .eyedropper: return "i"
        case .line: return "l"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .text: return "t"
        case .crop: return "c"
        case .hand: return "h"
        }
    }
    var help: String {
        switch self {
        case .brush: return "Drag to paint. [ and ] change brush size."
        case .eraser: return "Drag to erase pixels on the selected layer."
        case .blur: return "Drag to soften detail in the selected image or mask. Strength controls buildup. [ and ] change size."
        case .sharpen: return "Drag to sharpen local detail in the selected image or mask. Strength controls buildup."
        case .smudge: return "Drag to pull existing pixels along the brush path. Strength controls the pull; a click leaves pixels unchanged."
        case .selection, .ellipseSelect: return "Drag to select. Hold Option during drag for center origin; Control constrains. Before drag: ⇧ adds · ⌥ subtracts · ⇧⌥ intersects."
        case .lasso: return "Drag to select. ⇧ adds · ⌥ subtracts · ⇧⌥ intersects."
        case .move: return "Drag to move selected pixels, or the entire active layer."
        case .fill: return "Click to fill a connected area. Adjust tolerance in the inspector."
        case .eyedropper: return "Click to sample a color from the visible image."
        case .line: return "Drag to draw a line. Option draws from its center; Shift snaps to 45°."
        case .rectangle, .ellipse: return "Drag to draw. Choose Outline Only, Outline & Fill, or Fill Only. Filled outlines use the alternate color inside; right mouse swaps colors. Shift makes equal sides; Option draws from the center."
        case .text: return "Drag a text box and type. Click outside or ⌘Return to finish; Escape cancels. Drag its bar to move."
        case .crop: return "Crop every layer to the current selection's bounds."
        case .hand: return "Drag to pan. You can also hold Space with any tool."
        }
    }
}

final class CanvasView: NSView, NSEditor {
    let paintDocument: PaintDocument
    var tool: PaintTool = .brush { willSet { if newValue != tool { finishText() } } didSet { window?.invalidateCursorRects(for: self); overlays.needsDisplay = true } }
    var brushSize: Double = 18
    var retouchStrength: Double = 0.5
    var brushHardness: Double = 1
    var brushOpacity: Double = 1 { didSet { updateTextAppearance() } }
    var smooth = true { didSet { updateTextAppearance() } }
    var shapePaintMode: ShapePaintMode = .outline { didSet { onShapePaintModeChange?() } }
    // Convenience for callers that request the original two shape styles.
    var fillShapes: Bool {
        get { shapePaintMode != .outline }
        set { shapePaintMode = newValue ? .outlineAndFill : .outline }
    }
    var onShapePaintModeChange: (() -> Void)?
    var shapeAlignment: ShapeOutlineAlignment = .center
    var rectangleCorners = RectangleCorners.square { didSet { onShapePaintModeChange?() } }
    var shapeBorder = ShapeBorder.solid { didSet { onShapePaintModeChange?() } }
    private var alignedShapes = false
    private var alignedSelections = true
    /// Shapes retain free placement by default; marquees retain pixel bounds.
    var alignGeometryToPixels: Bool {
        get { tool.isSelection ? alignedSelections : alignedShapes }
        set {
            if tool.isSelection { alignedSelections = newValue } else { alignedShapes = newValue }
            onShapePaintModeChange?()
        }
    }
    var color = PixelColor(r: 64, g: 117, b: 245)
    var alternateColor = PixelColor.white
    var tolerance = 32
    var selection: SelectionMask? {
        get { paintDocument.state.selection }
        set { paintDocument.state.selection = newValue; synchronizeSelection() }
    }
    var selectionMode: SelectionMode = .replace
    var onSelectionChange: (() -> Void)?
    var onToolChange: ((PaintTool) -> Void)?
    var onColorPick: ((PixelColor, Bool) -> Void)?
    var onSwapColors: (() -> Void)?
    var onStatus: ((String) -> Void)?
    var onSizeChange: ((Double) -> Void)?
    var onZoomChange: (() -> Void)?
    var textStyle = TextStyle() { didSet { updateTextAppearance() } }
    private(set) var textEditor: CanvasTextEditor?
    private var textLayerID: UUID?
    private var textEditsMask = false
    private var textEditsQuickMask = false
    private var draftTextLayer: PaintLayer?
    private var textAddsLayer = false
    private var textReediting = false
    private var textDraftClip: SelectionMask?
    var onTextSettingsChange: (() -> Void)?
    var effectPreviewImage: CIImage? { didSet { needsDisplay = true } }
    var effectPreviewComposite: CGImage? { effectPreviewImage.map { paintDocument.renderer.cgImage($0, format: paintDocument.state.format) } }
    private(set) var textPreviewRaster: Raster?
    private var textPreviewImage: CIImage?
    var displayedImage: CIImage {
        let image = textPreviewImage ?? effectPreviewImage ?? paintDocument.compositeImage
        guard let mask = paintDocument.state.quickMask else { return image }
        let coverage = textEditsQuickMask ? textPreviewRaster.map { SelectionMask(editingRaster: $0) } ?? mask : mask
        return QuickMaskOverlay.image(coverage, over: image)
    }
    /// CPU pixels are requested only for export, sampling, snapshots, or fallback.
    var displayedComposite: CGImage {
        if paintDocument.state.isQuickMask || textPreviewImage != nil || effectPreviewImage != nil { return paintDocument.renderer.cgImage(displayedImage, format: paintDocument.state.format) }
        return paintDocument.composite
    }
    private var textColor = PixelColor.black
    private var textUsesAlternate = false
    private var gestureTravel: CGFloat = 0
    private var textBoxPreview: CGRect?
    private(set) var zoom: CGFloat = 1
    private var pan = CGPoint.zero
    private var gestureStart = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var gestureState: DocumentState?
    private var gestureSelection: SelectionMask?
    private var gestureSelectionMode: SelectionMode = .replace
    private var selectionOptionStartsCombine = false
    private var geometryPoint = CGPoint.zero
    private var lassoPoints: [CGPoint] = []
    private var cachedSelectionID: UUID?
    private var selectionOutline: CGPath?
    private var selectionImage: CGImage?
    private var panStart = CGPoint.zero
    private var isPanning = false
    private var gestureActive = false
    private var softBrushStroke: SoftBrushStroke?
    private var retouchStroke: RetouchStroke?
    private var gestureHardness: Double = 1
    private var gestureRaster: Raster?
    private var gestureCreatedLayerID: UUID?
    private var gestureButton = 0
    private var cancelledGestureButtons = Set<Int>()
    private var gestureColor = PixelColor.black
    private var gestureFillColor: PixelColor?
    private var gestureDrawsOutline = true
    private var gestureCorners = RectangleCorners.square
    private var gestureBorder = ShapeBorder.solid
    private var gesturePixelAligned = false
    private var gestureShapeSize: Double = 18
    private var spaceDown = false
    private var pointer: CGPoint?
    private var tracking: NSTrackingArea?
    private var didFit = false
    private(set) var metalView: MetalCanvasView?
    private let overlays = CanvasOverlayView()
    private var snapshotRendering = false

    override var needsDisplay: Bool {
        willSet {
            // A layer-backed NSView can report false immediately after accepting
            // an invalidation. Forward the requested value, not that getter.
            if newValue {
                if !snapshotRendering { metalView?.requestRedraw() }
                overlays.needsDisplay = true
            }
        }
    }

    init(document: PaintDocument, useMetal: Bool = true) {
        paintDocument = document
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        if useMetal, let renderer = MetalCanvasRenderer(renderer: document.renderer) {
            let view = MetalCanvasView(renderer: renderer)
            view.imageProvider = { [weak self] size in
                guard let self else { return CIImage.empty() }
                return CanvasViewport.image(self.displayedImage, imageRect: self.imageRect,
                                            viewSize: self.bounds.size, drawableSize: size, nearest: self.zoom >= 1, checkerboard: true)
            }
            view.onFailure = { [weak self] in self?.disableMetal() }
            metalView = view; addSubview(view)
        }
        overlays.canvas = self; overlays.wantsLayer = true; overlays.setAccessibilityElement(false)
        addSubview(overlays)
        updateViewportBorder()
        setAccessibilityLabel("Image canvas")
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func disableMetal() {
        metalView?.removeFromSuperview(); metalView = nil; needsDisplay = true
    }
    /// AppKit's layer-cache snapshots omit Metal drawable contents. Materialize
    /// the image only for the duration of an explicit offscreen snapshot, then
    /// restore the transparent background beneath the live Metal surface.
    func snapshot(of view: NSView? = nil) -> NSBitmapImageRep? {
        let target = view ?? self
        snapshotRendering = true; needsDisplay = true; displayIfNeeded()
        defer { snapshotRendering = false; needsDisplay = true; displayIfNeeded() }
        guard let bitmap = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return nil }
        target.cacheDisplay(in: target.bounds, to: bitmap)
        return bitmap
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateViewportBorder()
        needsDisplay = true
    }
    private func updateViewportBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    var imageRect: CGRect {
        let size = CGSize(width: CGFloat(paintDocument.state.width) * zoom,
                          height: CGFloat(paintDocument.state.height) * zoom)
        return CGRect(x: (bounds.width - size.width) / 2 + pan.x,
                      y: (bounds.height - size.height) / 2 + pan.y, width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        if let metalView, metalView.frame != bounds {
            metalView.frame = bounds; metalView.requestRedraw()
        }
        overlays.frame = bounds
        if !didFit && bounds.width > 100 && bounds.height > 100 { didFit = true; zoomToFit() }
        layoutTextEditor()
    }

    func zoomToFit() {
        pan = .zero
        zoom = max(0.02, min(1, min((bounds.width - 96) / CGFloat(paintDocument.state.width),
                                  (bounds.height - 96) / CGFloat(paintDocument.state.height))))
        layoutTextEditor(); needsDisplay = true; onZoomChange?()
    }

    func setZoom(_ value: CGFloat, anchor: CGPoint? = nil) {
        let point = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let documentPoint = toImage(point)
        zoom = min(32, max(0.02, value))
        let projected = toView(documentPoint)
        pan.x += point.x - projected.x; pan.y += point.y - projected.y
        layoutTextEditor(); needsDisplay = true; onZoomChange?()
    }

    func toImage(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - imageRect.minX) / zoom, y: (point.y - imageRect.minY) / zoom)
    }
    private func toView(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * zoom + imageRect.minX, y: point.y * zoom + imageRect.minY)
    }
    func synchronizeSelection() {
        guard selection?.id != cachedSelectionID else { return }
        cachedSelectionID = selection?.id
        selectionOutline = selection?.outline()
        overlays.hasSelectionOutline = selectionOutline.map { !$0.isEmpty } ?? false
        // An image mask uses zero for opaque and 255 for transparent, allowing
        // us to shade excluded pixels over either a Metal or AppKit background.
        selectionImage = selection.flatMap {
            CGImage(maskWidth: $0.width, height: $0.height, bitsPerComponent: 8, bitsPerPixel: 8,
                    bytesPerRow: $0.width, provider: CGDataProvider(data: $0.coverage as CFData)!,
                    decode: nil, shouldInterpolate: true)
        }
        overlays.needsDisplay = true; onSelectionChange?()
    }

    func toggleQuickMask() {
        guard !gestureActive && !isPanning && cancelledGestureButtons.isEmpty else { return }
        finishText()
        paintDocument.edit(paintDocument.state.isQuickMask ? "Exit Quick Mask" : "Enter Quick Mask") { $0.toggleQuickMask() }
        synchronizeSelection(); needsDisplay = true
        onStatus?(paintDocument.state.isQuickMask ? "Quick Mask · red is selected · white adds · black removes · Q finishes. Select a region and use Move to reposition mask pixels." : tool.help)
    }

    func changeSelection(_ mask: SelectionMask?, name: String) {
        paintDocument.edit(name) { $0.selection = mask }
        synchronizeSelection()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: bounds)
        NSColor.underPageBackgroundColor.setFill(); bounds.fill()
        // The live Metal frame includes the checkerboard and artwork together.
        // Drawing checks here would expose the new viewport beneath an older GPU
        // frame while a zoom/pan is still rendering.
        if !snapshotRendering, metalView != nil, NSGraphicsContext.current?.isDrawingToScreen == true { return }
        let rect = imageRect
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 22, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(rect)
        ctx.restoreGState()
        ctx.saveGState(); ctx.clip(to: rect)
        NSColor(calibratedWhite: 0.91, alpha: 1).setFill(); rect.fill()
        let tile: CGFloat = 10
        let visible = rect.intersection(bounds)
        if !visible.isNull {
            NSColor(calibratedWhite: 0.79, alpha: 1).setFill()
            let firstX = Int(floor((visible.minX - rect.minX) / tile)), firstY = Int(floor((visible.minY - rect.minY) / tile))
            let lastX = Int(ceil((visible.maxX - rect.minX) / tile)), lastY = Int(ceil((visible.maxY - rect.minY) / tile))
            for y in firstY..<lastY {
                for x in firstX..<lastX where (x + y) % 2 == 0 {
                    CGRect(x: rect.minX + CGFloat(x) * tile, y: rect.minY + CGFloat(y) * tile, width: tile, height: tile).fill()
                }
            }
        }
        if snapshotRendering || metalView == nil || NSGraphicsContext.current?.isDrawingToScreen == false {
            ctx.interpolationQuality = zoom >= 1 ? .none : .high
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(displayedComposite, in: CGRect(origin: .zero, size: rect.size))
        }
        ctx.restoreGState()
    }

    func drawOverlays() {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.clip(to: bounds)
        let rect = imageRect
        if let selection {
            synchronizeSelection()
            ctx.saveGState(); ctx.clip(to: rect)
            ctx.translateBy(x: rect.minX, y: rect.maxY); ctx.scaleBy(x: zoom, y: -zoom)
            if let selectionImage {
                ctx.clip(to: selection.canvasBounds, mask: selectionImage)
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.18).cgColor)
                ctx.fill(selection.canvasBounds)
            }
            ctx.restoreGState()
            if let selectionOutline {
                ctx.saveGState(); ctx.clip(to: rect)
                ctx.translateBy(x: rect.minX, y: rect.minY); ctx.scaleBy(x: zoom, y: zoom)
                ctx.setLineWidth(1 / zoom)
                ctx.setStrokeColor(NSColor.white.cgColor); ctx.addPath(selectionOutline); ctx.strokePath()
                ctx.setLineDash(phase: overlays.selectionDashPhase / zoom, lengths: [4 / zoom, 4 / zoom])
                ctx.setStrokeColor(NSColor.black.cgColor); ctx.addPath(selectionOutline); ctx.strokePath()
                ctx.restoreGState()
            }
        }
        if let textBoxPreview {
            let box = CGRect(origin: toView(textBoxPreview.origin), size: CGSize(width: textBoxPreview.width * zoom, height: textBoxPreview.height * zoom))
            NSColor.controlAccentColor.setStroke(); let path = NSBezierPath(rect: box); path.lineWidth = 1; path.stroke()
        }
        if let pointer, tool.isBrush, !spaceDown, bounds.contains(pointer) {
            let diameter = max(3, brushSize * zoom)
            let circle = NSBezierPath(ovalIn: CGRect(x: pointer.x - diameter / 2, y: pointer.y - diameter / 2,
                                                    width: diameter, height: diameter))
            circle.lineWidth = 2; NSColor.white.withAlphaComponent(0.85).setStroke(); circle.stroke()
            circle.lineWidth = 1; NSColor.black.withAlphaComponent(0.7).setStroke(); circle.stroke()
        }
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: spaceDown || tool == .hand ? .openHand : (tool == .text ? .iBeam : .crosshair))
    }
    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        let p = toImage(pointer!)
        if imageRect.contains(pointer!) { onStatus?("x \(Int(floor(p.x)))   y \(Int(floor(p.y)))") }
        else { onStatus?(tool.help) }
        overlays.needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { pointer = nil; overlays.needsDisplay = true; onStatus?(tool.help) }

    override func mouseDown(with event: NSEvent) {
        let button = mouseButton(for: event)
        guard (0...2).contains(button) else { return }
        if !cancelledGestureButtons.isEmpty {
            cancelledGestureButtons.insert(button)
            return
        }
        if gestureActive || isPanning {
            if button != gestureButton, (0...1).contains(button), (0...1).contains(gestureButton) {
                cancelledGestureButtons = [gestureButton, button]
                cancelGesture()
            }
            return
        }
        gestureActive = false
        let shouldPan = button == 2 || spaceDown || tool == .hand
        if !shouldPan { finishText() }
        if !shouldPan || textEditor == nil { window?.makeFirstResponder(self) }
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard bounds.contains(viewPoint) else { return }
        gestureButton = button
        let alternate = gestureButton == 1
        gestureColor = alternate ? alternateColor : color
        gestureDrawsOutline = shapePaintMode.drawsOutline
        gestureCorners = rectangleCorners; gestureBorder = shapeBorder
        gesturePixelAligned = smooth && alignGeometryToPixels && (tool.isGeometry || tool == .selection || tool == .ellipseSelect)
        gestureShapeSize = gesturePixelAligned ? max(1, brushSize.rounded()) : brushSize
        switch shapePaintMode {
        case .outline: gestureFillColor = nil
        case .outlineAndFill: gestureFillColor = alternate ? color : alternateColor
        case .fill: gestureFillColor = gestureColor
        }
        if paintDocument.state.isEditingCoverage {
            gestureColor = gestureColor.maskColor
            gestureFillColor = gestureFillColor?.maskColor
        }
        if shouldPan {
            isPanning = true; panStart = pan; gestureStart = viewPoint; NSCursor.closedHand.push(); return
        }
        // Keep the actual off-image anchor. Raster and mask operations clip at
        // image bounds, allowing shapes/selections/strokes to cross an edge.
        let samplesColor = tool == .eyedropper || (!tool.isSelection && !tool.isGeometry && event.modifierFlags.contains(.option))
        if (tool == .fill || samplesColor), !imageRect.contains(viewPoint) { return }
        gestureActive = true
        let point = toImage(viewPoint)
        gestureStart = point; lastPoint = point; gestureSelection = selection; gestureTravel = 0
        geometryPoint = point
        if tool.isSelection {
            gestureState = paintDocument.state
            gestureSelectionMode = SelectionMode.resolve(event.modifierFlags, fallback: selectionMode)
            selectionOptionStartsCombine = event.modifierFlags.contains(.option)
            lassoPoints = [point]
            return
        }
        if samplesColor {
            if let raster = paintDocument.state.isEditingCoverage ? paintDocument.state.editingRaster : try? Raster(image: paintDocument.composite) {
                onColorPick?(raster.pixel(x: Int(point.x), y: Int(point.y)), alternate)
            }
            gestureActive = false
            return
        }
        guard paintDocument.state.isQuickMask || (!paintDocument.state.isEffectivelyLocked(paintDocument.state.activeID) &&
              (tool != .move || paintDocument.state.isEditingMask || paintDocument.state.canModifySubtree(paintDocument.state.activeID))) else {
            gestureActive = false; onStatus?("Unlock the layer or group before editing it."); NSSound.beep(); return
        }
        guard paintDocument.state.editingTargetVisible else {
            gestureActive = false
            onStatus?("Show the selected layer before editing it."); NSSound.beep(); return
        }
        if !paintDocument.state.isEditingCoverage, let text = paintDocument.state.activeLayer.text,
           text.rect.contains(point), (tool == .text || event.clickCount == 2) {
            gestureActive = false; editTextLayer(); return
        }
        let before = paintDocument.state
        if before.activeLayer.isGroup, !before.isEditingCoverage, [.brush, .fill, .line, .rectangle, .ellipse].contains(tool) {
            guard before.layers.count < 32 else {
                gestureActive = false; onStatus?("The layer limit is 32. Select an existing image layer to paint."); NSSound.beep(); return
            }
            let layer = PaintLayer(name: "Layer \(before.layers.count)", raster: Raster(width: before.width, height: before.height, format: before.format))
            paintDocument.state.insertLayer(layer)
            gestureCreatedLayerID = layer.id
            onStatus?("Painting on a new layer inside \(before.activeLayer.name).")
        }
        guard paintDocument.state.canPaintTarget || tool == .move || tool == .text else {
            gestureActive = false
            onStatus?(tool.isRetouch ? "Retouch needs existing pixels. Select an image layer or a layer/group mask; rasterize text from the Layer menu first." : before.activeLayer.isGroup ? "Groups have no pixels to erase. Select an image layer or the group mask." : "Choose an image layer or mask to paint. Text layers can be rasterized from the Layer menu.")
            return
        }
        if tool == .text { textUsesAlternate = alternate; return }
        gestureState = before
        gestureRaster = paintDocument.state.editingRaster
        gestureHardness = BrushProfile(radius: 1, hardness: brushHardness, antialias: smooth).hardness
        if gestureHardness < 1, tool == .brush || tool == .eraser { softBrushStroke = SoftBrushStroke(original: paintDocument.state.editingRaster) }
        if tool.isRetouch {
            let kind: RetouchStroke.Kind = tool == .blur ? .blur : tool == .sharpen ? .sharpen : .smudge
            retouchStroke = RetouchStroke(kind: kind, size: brushSize, hardness: gestureHardness, strength: retouchStrength, antialias: smooth)
        }
        if gestureCreatedLayerID != nil { paintDocument.invalidate() }
        switch tool {
        case .brush, .eraser, .blur, .sharpen, .smudge: paint(from: point, to: point)
        case .fill:
            let selection = self.selection
            paintDocument.state.editRaster { $0.floodFill(at: point, color: gestureColor, tolerance: tolerance, clip: nil, selection: selection) }
            // Preview immediately, but keep the snapshot until mouse-up so
            // pressing the opposite button can cancel this edit too.
            paintDocument.invalidate()
        default: break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard cancelledGestureButtons.isEmpty else { return }
        guard mouseButton(for: event) == gestureButton else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        pointer = viewPoint
        if isPanning {
            pan = CGPoint(x: panStart.x + viewPoint.x - gestureStart.x, y: panStart.y + viewPoint.y - gestureStart.y)
            layoutTextEditor(); needsDisplay = true; return
        }
        guard gestureActive else { return }
        let point = toImage(viewPoint)
        geometryPoint = point
        if !event.modifierFlags.contains(.option) { selectionOptionStartsCombine = false }
        gestureTravel = max(gestureTravel, hypot(point.x - gestureStart.x, point.y - gestureStart.y) * zoom)
        if tool == .text {
            textBoxPreview = dragRect(to: point, square: false); needsDisplay = true; return
        }
        if tool.isSelection {
            updateSelection(to: point, modifiers: event.modifierFlags)
            return
        }
        guard let before = gestureState else { return }
        switch tool {
        case .brush, .eraser, .blur, .sharpen, .smudge:
            paint(from: lastPoint, to: point); lastPoint = point
        case .move:
            let dx = Int((point.x - gestureStart.x).rounded()), dy = Int((point.y - gestureStart.y).rounded())
            paintDocument.state.moveActive(from: before, dx: dx, dy: dy, selection: gestureSelection)
            if let gestureSelection { selection = gestureSelection.translated(dx: dx, dy: dy) }
            paintDocument.invalidate()
        case .line, .rectangle, .ellipse:
            updateShape(to: point, modifiers: event.modifierFlags)
        default: break
        }
    }

    private func updateShape(to point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard let before = gestureState else { return }
        var point = point
        paintDocument.state.editingRaster = gestureRaster ?? before.editingRaster
        if tool == .line {
            if gesturePixelAligned {
                let endpoints = DragGeometry.pixelAlignedLine(from: gestureStart, to: point, width: gestureShapeSize,
                                                              constrained: modifiers.contains(.shift), fromCenter: modifiers.contains(.option))
                paint(from: endpoints.0, to: endpoints.1)
                return
            }
            if modifiers.contains(.shift) {
                let angle = (atan2(point.y - gestureStart.y, point.x - gestureStart.x) / (.pi / 4)).rounded() * (.pi / 4)
                let length = hypot(point.x - gestureStart.x, point.y - gestureStart.y)
                if smooth {
                    point = CGPoint(x: gestureStart.x + cos(angle) * length, y: gestureStart.y + sin(angle) * length)
                } else {
                    let diagonal = abs(cos(angle)) > 0.5 && abs(sin(angle)) > 0.5
                    let step = (diagonal ? length / sqrt(2) : length).rounded()
                    point = CGPoint(x: floor(gestureStart.x) + 0.5 + cos(angle).rounded() * step,
                                    y: floor(gestureStart.y) + 0.5 + sin(angle).rounded() * step)
                }
            }
            let start = modifiers.contains(.option) ? CGPoint(x: 2 * gestureStart.x - point.x, y: 2 * gestureStart.y - point.y) : gestureStart
            paint(from: start, to: point)
        } else {
            let rect = dragRect(to: point, square: modifiers.contains(.shift), fromCenter: modifiers.contains(.option))
            let selection = self.selection
            paintDocument.state.editRaster { $0.strokeShape(
                in: rect, ellipse: tool == .ellipse, size: gesturePixelAligned ? gestureShapeSize : brushSize,
                color: gestureColor, opacity: brushOpacity, clip: nil, selection: selection,
                antialias: smooth, fillColor: gestureFillColor, hardness: gestureHardness, alignment: shapeAlignment,
                drawOutline: gestureDrawsOutline, corners: gestureCorners, border: gestureBorder) }
            paintDocument.invalidate()
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard gestureActive, !isPanning, cancelledGestureButtons.isEmpty else { super.flagsChanged(with: event); return }
        if !event.modifierFlags.contains(.option) { selectionOptionStartsCombine = false }
        if tool == .selection || tool == .ellipseSelect {
            updateSelection(to: geometryPoint, modifiers: event.modifierFlags)
        } else if tool.isGeometry, gestureTravel >= 2 { updateShape(to: geometryPoint, modifiers: event.modifierFlags) }
    }

    override func mouseUp(with event: NSEvent) {
        if !cancelledGestureButtons.isEmpty {
            cancelledGestureButtons.remove(mouseButton(for: event))
            return
        }
        guard mouseButton(for: event) == gestureButton else { return }
        defer { gestureActive = false }
        if isPanning { isPanning = false; NSCursor.pop(); return }
        if tool.isSelection, gestureActive {
            if gestureTravel < 2 { selection = nil }
            else {
                updateSelection(to: toImage(convert(event.locationInWindow, from: nil)), modifiers: event.modifierFlags)
                if selection?.isEmpty == true && gestureSelectionMode == .replace { selection = nil }
            }
        }
        if tool == .text, gestureActive {
            let point = toImage(convert(event.locationInWindow, from: nil))
            var rect = dragRect(to: point, square: false).integral
            if gestureTravel < 2 { rect = CGRect(x: floor(gestureStart.x), y: floor(gestureStart.y), width: 320, height: 120) }
            textBoxPreview = nil
            beginText(in: rect, color: gestureColor)
        }
        finishGesture()
    }

    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func rightMouseUp(with event: NSEvent) { mouseUp(with: event) }
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { mouseDown(with: event) } }
    override func otherMouseDragged(with event: NSEvent) { if event.buttonNumber == 2 { mouseDragged(with: event) } }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { mouseUp(with: event) } }
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    private func mouseButton(for event: NSEvent) -> Int {
        switch event.type {
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp: return 1
        default: return event.buttonNumber
        }
    }

    private func paint(from a: CGPoint, to b: CGPoint, invalidate: Bool = true) {
        let selection = self.selection
        paintDocument.state.editRaster { raster in
            if tool.isRetouch, retouchStroke != nil {
                retouchStroke!.paint(on: &raster, to: b, selection: selection)
            } else if softBrushStroke != nil, tool == .brush || tool == .eraser {
                softBrushStroke!.paint(on: &raster, from: a, to: b, size: brushSize, color: gestureColor,
                                       opacity: brushOpacity, erase: tool == .eraser, selection: selection, antialias: smooth, hardness: gestureHardness)
            } else if tool == .line {
                raster.strokeLine(from: a, to: b, size: gesturePixelAligned ? gestureShapeSize : brushSize, color: gestureColor, opacity: brushOpacity,
                                  selection: selection, antialias: smooth, hardness: gestureHardness, border: gestureBorder)
            } else {
                raster.stroke(from: a, to: b, size: brushSize, color: gestureColor, opacity: brushOpacity,
                              erase: tool == .eraser, clip: nil, selection: selection, antialias: smooth, hardness: gestureHardness)
            }
        }
        if invalidate { paintDocument.invalidate() }
    }
    private func finishGesture() {
        if let before = gestureState {
            if gestureCreatedLayerID == paintDocument.state.activeID, paintDocument.state.editingRaster == gestureRaster {
                // An empty selection, zero opacity, or a shape click should
                // not leave an empty layer behind or consume the redo stack.
                paintDocument.state = before; paintDocument.invalidate()
            } else { paintDocument.commit(before, name: tool.title) }
        }
        gestureState = nil; gestureRaster = nil; gestureCreatedLayerID = nil; softBrushStroke = nil; retouchStroke = nil
    }
    private func cancelGesture() {
        let before = gestureState
        gestureState = nil; gestureRaster = nil; gestureCreatedLayerID = nil; softBrushStroke = nil; retouchStroke = nil
        gestureSelection = nil; gestureActive = false
        lassoPoints = []; textBoxPreview = nil; gestureTravel = 0
        if isPanning {
            pan = panStart; isPanning = false; NSCursor.pop()
            layoutTextEditor()
        }
        if let before { paintDocument.state = before }
        synchronizeSelection()
        paintDocument.invalidate()
        needsDisplay = true
    }
    private func updateSelection(to point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        let state = paintDocument.state
        let incoming: SelectionMask
        let geometry = dragRect(to: point, square: modifiers.contains(.control),
                                fromCenter: modifiers.contains(.option) && !selectionOptionStartsCombine)
        let rect = !smooth && !gesturePixelAligned ? geometry.integral : geometry
        switch tool {
        case .selection: incoming = .rectangle(rect, width: state.width, height: state.height, corners: gestureCorners, antialias: smooth)
        case .ellipseSelect: incoming = .ellipse(rect, width: state.width, height: state.height, antialias: smooth)
        case .lasso:
            if let last = lassoPoints.last, hypot(point.x - last.x, point.y - last.y) >= 0.5 { lassoPoints.append(point) }
            incoming = .lasso(lassoPoints, width: state.width, height: state.height, antialias: smooth)
        default: return
        }
        if gestureSelectionMode == .replace { selection = incoming }
        else {
            let base = gestureSelection ?? (gestureSelectionMode == .add
                ? .empty(width: state.width, height: state.height) : .all(width: state.width, height: state.height))
            selection = base.combined(with: incoming, mode: gestureSelectionMode)
        }
    }
    private func dragRect(to point: CGPoint, square: Bool, fromCenter: Bool = false) -> CGRect {
        if gesturePixelAligned && (tool.isGeometry || tool == .selection || tool == .ellipseSelect) {
            let centeredOutline = !tool.isSelection && gestureDrawsOutline && shapeAlignment == .center
            let phase: CGFloat = centeredOutline && Int(gestureShapeSize) % 2 == 1 ? 0.5 : 0
            return DragGeometry.pixelAlignedRect(from: gestureStart, to: point, square: square, phase: phase, fromCenter: fromCenter)
        }
        return DragGeometry.rect(from: gestureStart, to: point, square: square,
                          snap: !smooth || tool == .text,
                          centerOnPixel: !smooth && !tool.isSelection && tool != .text && (tool == .line || shapePaintMode.drawsOutline) && shapeAlignment == .center && Int(brushSize.rounded()) % 2 == 1,
                          fromCenter: fromCenter)
    }

    func beginText(in rect: CGRect, color: PixelColor) {
        finishText()
        guard paintDocument.state.isQuickMask || (!paintDocument.state.isEffectivelyLocked(paintDocument.state.activeID) && paintDocument.state.activeEffectivelyVisible) else { return }
        textReediting = false; textAddsLayer = false; draftTextLayer = nil
        textEditsQuickMask = paintDocument.state.isQuickMask
        textEditsMask = paintDocument.state.isEditingCoverage
        textDraftClip = selection
        if textEditsMask { textLayerID = paintDocument.state.activeID }
        else {
            let active = paintDocument.state.activeLayer
            let empty = active.isPixelLayer && active.raster.isTransparent
            guard empty || paintDocument.state.layers.count < 32 else { onStatus?("This version supports up to 32 layers and groups."); NSSound.beep(); return }
            draftTextLayer = empty ? active : PaintLayer(name: "Text", raster: Raster(width: paintDocument.state.width, height: paintDocument.state.height, format: paintDocument.state.format))
            textAddsLayer = !empty; textLayerID = draftTextLayer!.id
        }
        textColor = textEditsMask ? color.maskColor : color
        tool = .text
        installTextEditor(rect: rect)
    }

    func editTextLayer() {
        finishText()
        guard !paintDocument.state.isEffectivelyLocked(paintDocument.state.activeID), paintDocument.state.activeEffectivelyVisible, let value = paintDocument.state.activeLayer.text else { return }
        paintDocument.state.editingMask = false; paintDocument.invalidate()
        tool = .text; textEditsMask = false; textReediting = true; textAddsLayer = false
        textLayerID = paintDocument.state.activeID; draftTextLayer = paintDocument.state.activeLayer
        textDraftClip = paintDocument.state.activeLayer.textClip
        textStyle = value.style; smooth = value.antialias; brushOpacity = value.opacity
        textColor = value.color; color = value.color; textUsesAlternate = false
        installTextEditor(rect: value.rect, existing: value)
    }

    private func installTextEditor(rect: CGRect, existing: TextLayerContent? = nil) {
        let editor = CanvasTextEditor(rect: rect, canvasSize: CGSize(width: paintDocument.state.width, height: paintDocument.state.height), allowsOutsideCanvas: true)
        editor.horizontalScale = existing?.horizontalScale ?? 1
        if let existing { editor.textView.string = existing.string }
        textEditor = editor
        editor.onApply = { [weak self] in self?.finishText() }
        editor.onCancel = { [weak self] in self?.finishText(apply: false) }
        editor.onTextChange = { [weak self] in self?.refreshTextPreview() }
        editor.onGeometryChange = { [weak self] in self?.layoutTextEditor(); self?.refreshTextPreview() }
        editor.onScroll = { [weak self] in self?.scrollWheel(with: $0) }
        editor.onMagnify = { [weak self] in self?.magnify(with: $0) }
        editor.onOtherMouseEvent = { [weak self] event in
            switch event.type {
            case .otherMouseDown: self?.otherMouseDown(with: event)
            case .otherMouseDragged: self?.otherMouseDragged(with: event)
            case .otherMouseUp: self?.otherMouseUp(with: event)
            default: break
            }
        }
        paintDocument.objectDidBeginEditing(self)
        addSubview(editor); layoutTextEditor(); updateTextAppearance()
        onTextSettingsChange?(); editor.focus()
    }

    func updateTextColor(_ color: PixelColor, alternate: Bool) {
        if textEditor != nil && alternate == textUsesAlternate { textColor = color; updateTextAppearance() }
    }
    private func updateTextAppearance() {
        textEditor?.update(style: textStyle)
        refreshTextPreview()
    }
    private func layoutTextEditor() {
        guard let editor = textEditor else { return }
        editor.place(at: toView(editor.imageBounds.origin), zoom: zoom)
    }
    func focusText() { if let textEditor { textEditor.focus() } else { window?.makeFirstResponder(self) } }

    private func currentTextContent() -> TextLayerContent? {
        guard let editor = textEditor else { return nil }
        return TextLayerContent(string: editor.textView.string, style: textStyle, rect: editor.imageBounds,
                                color: textColor, opacity: brushOpacity, antialias: smooth, horizontalScale: editor.horizontalScale)
    }
    func refreshTextPreview() {
        guard let editor = textEditor else { return }
        var layers = paintDocument.state.layers
        let raster: Raster
        if textEditsQuickMask {
            guard let mask = paintDocument.state.quickMask else { return }
            var pixels = mask.editingRaster
            pixels.drawText(editor.textView.string, in: editor.imageBounds, font: textStyle.font, color: textColor,
                            opacity: brushOpacity, antialias: smooth, selection: textDraftClip)
            raster = pixels
        } else if textEditsMask {
            guard let index = layers.firstIndex(where: { $0.id == textLayerID }), let mask = layers[index].mask else { return }
            var pixels = mask.editingRaster
            pixels.drawText(editor.textView.string, in: editor.imageBounds, font: textStyle.font, color: textColor,
                            opacity: brushOpacity, antialias: smooth, selection: selection)
            raster = pixels; layers[index].mask = SelectionMask(editingRaster: pixels)
        } else {
            guard var layer = draftTextLayer, let content = currentTextContent() else { return }
            raster = content.rendered(width: paintDocument.state.width, height: paintDocument.state.height, clip: textDraftClip, format: paintDocument.state.format)
            layer.text = content; layer.raster = raster; layer.textClip = textDraftClip
            if textAddsLayer {
                var preview = paintDocument.state; preview.insertLayer(layer); layers = preview.layers
            } else if let index = layers.firstIndex(where: { $0.id == layer.id }) { layers[index] = layer }
        }
        textPreviewRaster = raster
        textPreviewImage = paintDocument.renderer.compositeImage(layers, width: paintDocument.state.width, height: paintDocument.state.height)
        needsDisplay = true
    }

    func finishText(apply: Bool = true) {
        guard let editor = textEditor else { return }
        editor.textView.unmarkText()
        if apply { refreshTextPreview() }
        let content = currentTextContent(), layerID = textLayerID, raster = textPreviewRaster, editsMask = textEditsMask
        let editsQuickMask = textEditsQuickMask
        let adds = textAddsLayer, reediting = textReediting, draftLayer = draftTextLayer, clip = textDraftClip
        textEditor = nil; textLayerID = nil; textPreviewRaster = nil; textPreviewImage = nil; textEditsQuickMask = false; draftTextLayer = nil; textDraftClip = nil
        window?.makeFirstResponder(self); editor.removeFromSuperview(); needsDisplay = true
        defer { paintDocument.objectDidEndEditing(self) }
        guard apply, let content, (!content.string.isEmpty || reediting), let raster else { return }
        guard (try? content.validate()) != nil else { onStatus?("Text exceeds supported size limits."); NSSound.beep(); return }
        paintDocument.edit(reediting ? "Edit Text Layer" : "Text") { state in
            if editsQuickMask {
                guard state.isQuickMask else { return }
                state.quickMask = SelectionMask(editingRaster: raster)
            } else if editsMask {
                guard let index = state.layers.firstIndex(where: { $0.id == layerID }), state.layers[index].mask != nil else { return }
                state.layers[index].mask = SelectionMask(editingRaster: raster)
            } else if adds, var layer = draftLayer {
                layer.text = content; layer.textClip = clip; layer.raster = raster
                layer.name = "Text · " + content.string.replacingOccurrences(of: "\n", with: " ").prefix(36)
                state.insertLayer(layer)
            } else if let index = state.layers.firstIndex(where: { $0.id == layerID }) {
                state.layers[index].text = content; state.layers[index].textClip = clip; state.layers[index].raster = raster
            }
        }
    }

    // Register the draft with NSDocument so native save/close/quit recognize
    // unapplied text, while periodic autosaving leaves the editor open.
    func discardEditing() { finishText(apply: false) }
    func commitEditing() -> Bool { finishText(); return true }
    func commitEditingWithoutPresentingError() throws {
        // Autosave must not unexpectedly rasterize text while the user types.
        // Explicit save and close finish the draft before reaching this path.
        if textEditor != nil { throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError) }
    }
    func commitEditing(withDelegate delegate: Any?, didCommit didCommitSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        finishText()
        guard let target = delegate as? NSObject, let selector = didCommitSelector, target.responds(to: selector) else { return }
        typealias Callback = @convention(c) (AnyObject, Selector, AnyObject, Bool, UnsafeMutableRawPointer?) -> Void
        let callback = unsafeBitCast(target.method(for: selector), to: Callback.self)
        callback(target, selector, self, true, contextInfo)
    }

    override func scrollWheel(with event: NSEvent) {
        let modifiers = event.modifierFlags
        if modifiers.contains(.option) || modifiers.contains(.shift) || spaceDown {
            if modifiers.contains(.shift) && !modifiers.contains(.option) {
                // macOS may already map Shift-wheel onto the horizontal axis.
                pan.x -= event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
            } else {
                pan.x -= event.scrollingDeltaX
                pan.y -= event.scrollingDeltaY
            }
            layoutTextEditor(); needsDisplay = true
        } else {
            // Zoom follows the physical wheel: up enlarges, down reduces.
            // AppKit already applies Natural Scrolling to its deltas; undo that
            // inversion for zoom only. Panning above keeps the system direction.
            let delta = event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? -1 : 1)
            setZoom(zoom * exp(delta * 0.012), anchor: convert(event.locationInWindow, from: nil))
        }
    }
    override func magnify(with event: NSEvent) { setZoom(zoom * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil)) }

    override func keyDown(with event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return }
        if key == " " { spaceDown = true; window?.invalidateCursorRects(for: self); return }
        if event.keyCode == 53 {
            if textEditor != nil { finishText(apply: false); return }
            if gestureActive && tool.isSelection {
                selection = gestureSelection; gestureState = nil; gestureActive = false; lassoPoints = []
            } else { changeSelection(nil, name: "Deselect") }
            return
        }
        if key == "q", event.modifierFlags.intersection([.command, .control, .option]).isEmpty { toggleQuickMask(); return }
        if key == "x" { onSwapColors?(); return }
        if key == "[" || key == "]" {
            brushSize = max(1, min(300, brushSize + (key == "[" ? -2 : 2))); onSizeChange?(brushSize); needsDisplay = true; return
        }
        if event.keyCode == 51 || event.keyCode == 117 { deletePixels(); return }
        if let tool = PaintTool.allCases.first(where: { $0.key == key }) { onToolChange?(tool); return }
        super.keyDown(with: event)
    }
    override func keyUp(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { spaceDown = false; window?.invalidateCursorRects(for: self); needsDisplay = true }
        else { super.keyUp(with: event) }
    }
    override func resignFirstResponder() -> Bool { spaceDown = false; return super.resignFirstResponder() }

    func deletePixels() {
        guard paintDocument.state.editingTargetVisible, paintDocument.state.canPaintTarget else { NSSound.beep(); return }
        paintDocument.edit(paintDocument.state.isQuickMask ? "Clear Quick Mask" : paintDocument.state.isEditingMask ? "Clear Mask" : "Delete Pixels") { state in
            let selection = state.selection
            state.editRaster { $0.erase(selection: selection) }
        }
    }
}

/// Snap the anchor and a shared side length before rasterization, so equal
/// geometric lengths cannot round to different pixel widths and heights.
enum DragGeometry {
    private static func stableGridCoordinate(_ value: CGFloat) -> CGFloat {
        // View/image conversion at fractional zoom can add a few floating-point
        // ulps to an exact grid edge. Do not expand it by a whole pixel.
        let integer = value.rounded()
        return abs(value - integer) <= 1e-9 ? integer : value
    }
    static func pixelAlignedPoint(_ point: CGPoint, phase: CGFloat = 0) -> CGPoint {
        // Odd-width centered strokes sit at pixel centers; fills, selections,
        // and even-width strokes sit on pixel boundaries.
        func snap(_ value: CGFloat) -> CGFloat { phase == 0 ? value.rounded() : floor(stableGridCoordinate(value)) + phase }
        return CGPoint(x: snap(point.x), y: snap(point.y))
    }
    static func pixelAlignedRect(from start: CGPoint, to end: CGPoint, square: Bool, phase: CGFloat = 0, fromCenter: Bool = false) -> CGRect {
        let bounds = rect(from: start, to: end, square: square, snap: false, fromCenter: fromCenter)
        func lower(_ value: CGFloat) -> CGFloat { floor(stableGridCoordinate(value - phase)) + phase }
        func upper(_ value: CGFloat) -> CGFloat { ceil(stableGridCoordinate(value - phase)) + phase }
        if fromCenter {
            // Keep a grid-aligned center and expand equally in both directions
            // far enough to contain the original bounds, including off-image drags.
            let center = pixelAlignedPoint(start, phase: phase)
            var dx = ceil(stableGridCoordinate(max(center.x - bounds.minX, bounds.maxX - center.x)))
            var dy = ceil(stableGridCoordinate(max(center.y - bounds.minY, bounds.maxY - center.y)))
            if square { dx = max(dx, dy); dy = dx }
            return CGRect(x: center.x - dx, y: center.y - dy, width: 2 * dx, height: 2 * dy)
        }
        let left = lower(bounds.minX), top = lower(bounds.minY)
        let right = upper(bounds.maxX), bottom = upper(bounds.maxY)
        let a = CGPoint(x: end.x < start.x ? right : left, y: end.y < start.y ? bottom : top)
        let b = CGPoint(x: end.x < start.x ? left : right, y: end.y < start.y ? top : bottom)
        return rect(from: a, to: b, square: square, snap: false)
    }
    static func pixelAlignedLine(from start: CGPoint, to end: CGPoint, width: Double,
                                 constrained: Bool, fromCenter: Bool) -> (CGPoint, CGPoint) {
        let phase: CGFloat = Int(width) % 2 == 1 ? 0.5 : 0
        let a = pixelAlignedPoint(start, phase: phase)
        var b = pixelAlignedPoint(end, phase: phase)
        if constrained {
            let angle = (atan2(b.y - a.y, b.x - a.x) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(b.x - a.x, b.y - a.y)
            let diagonal = abs(cos(angle)) > 0.5 && abs(sin(angle)) > 0.5
            let step = (diagonal ? length / sqrt(2) : length).rounded()
            b = CGPoint(x: a.x + cos(angle).rounded() * step, y: a.y + sin(angle).rounded() * step)
        }
        return (fromCenter ? CGPoint(x: 2 * a.x - b.x, y: 2 * a.y - b.y) : a, b)
    }
    static func rect(from start: CGPoint, to end: CGPoint, square: Bool, snap: Bool, centerOnPixel: Bool = false, fromCenter: Bool = false) -> CGRect {
        var origin = start
        var dx = end.x - start.x, dy = end.y - start.y
        if snap {
            let phase: CGFloat = centerOnPixel ? 0.5 : 0
            origin = CGPoint(x: floor(start.x) + phase, y: floor(start.y) + phase)
            dx = dx.rounded(); dy = dy.rounded()
        }
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side; dy = dy < 0 ? -side : side
        }
        if fromCenter { return CGRect(x: origin.x - abs(dx), y: origin.y - abs(dy), width: 2 * abs(dx), height: 2 * abs(dy)) }
        return CGRect(x: min(origin.x, origin.x + dx), y: min(origin.y, origin.y + dy), width: abs(dx), height: abs(dy))
    }
}
