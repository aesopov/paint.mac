import XCTest
import AppKit
@testable import PaintMac

final class SoftBrushTests: XCTestCase {
    private let blue = PixelColor(r: 30, g: 90, b: 230)
    private let red = PixelColor(r: 230, g: 40, b: 20)
    private func alpha(_ raster: Raster, _ x: Int, _ y: Int) -> Int { Int(raster.pixel(x: x, y: y).a) }
    private func alphas(_ raster: Raster) -> [UInt8] { { let pixels = raster.bytes; return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] } }() }
    func testRadialFalloffHasOpaqueCoreAndMonotonicSymmetricEdgesEvenInSharpMode() {
        for smooth in [false, true] {
            var soft = Raster(width: 90, height: 90), medium = soft, hard = soft
            let point = CGPoint(x: 40.5, y: 40.5)
            soft.stroke(from: point, to: point, size: 40, color: blue, opacity: 0.5, erase: false, clip: nil, antialias: smooth, hardness: 0)
            medium.stroke(from: point, to: point, size: 40, color: blue, opacity: 0.5, erase: false, clip: nil, antialias: smooth, hardness: 0.5)
            hard.stroke(from: point, to: point, size: 40, color: blue, opacity: 0.5, erase: false, clip: nil, antialias: smooth)
            XCTAssertEqual(alpha(soft, 40, 40), 128); XCTAssertEqual(alpha(soft, 60, 40), 0)
            XCTAssertEqual(alpha(medium, 49, 40), 128)
            XCTAssertLessThan(alpha(soft, 50, 40), alpha(medium, 50, 40))
            XCTAssertLessThan(alpha(medium, 55, 40), alpha(hard, 55, 40))
            for offset in 1...20 {
                XCTAssertLessThanOrEqual(alpha(soft, 40 + offset, 40), alpha(soft, 39 + offset, 40))
                XCTAssertEqual(alpha(soft, 40 + offset, 40), alpha(soft, 40 - offset, 40))
            }
            XCTAssertTrue(alphas(soft).contains { $0 > 0 && $0 < 128 })
        }
    }
    func testSoftStrokeCoverageIsIndependentOfEventDensityAndDoesNotBuildDarkJoints() {
        let original = Raster(width: 120, height: 80)
        func painted(segments: Int) -> Raster {
            var result = original, stroke = SoftBrushStroke(original: original)
            for i in 0..<segments {
                let a = CGPoint(x: 20.5 + Double(i) * 80 / Double(segments), y: 40.5)
                let b = CGPoint(x: 20.5 + Double(i + 1) * 80 / Double(segments), y: 40.5)
                stroke.paint(on: &result, from: a, to: b, size: 30, color: blue, opacity: 0.5, erase: false, selection: nil, antialias: false, hardness: 0)
                stroke.paint(on: &result, from: a, to: b, size: 30, color: blue, opacity: 0.5, erase: false, selection: nil, antialias: false, hardness: 0)
            }
            return result
        }
        let single = painted(segments: 1)
        XCTAssertEqual(painted(segments: 40), single)
        XCTAssertEqual(alpha(single, 60, 40), 128, accuracy: 1); XCTAssertLessThanOrEqual(alphas(single).max()!, 128)
        var second = single, stroke = SoftBrushStroke(original: single)
        stroke.paint(on: &second, from: CGPoint(x: 20.5, y: 40.5), to: CGPoint(x: 100.5, y: 40.5), size: 30, color: blue,
                     opacity: 0.5, erase: false, selection: nil, antialias: false, hardness: 0)
        XCTAssertGreaterThan(alpha(second, 60, 40), alpha(single, 60, 40), "Separate gestures still build paint")
    }
    func testCrossingSoftPathsBlendFalloffsInsteadOfTakingTheirMaximum() throws {
        let horizontal = [CGPoint(x: -79.5, y: 128.5), CGPoint(x: 336.5, y: 128.5)]
        let vertical = [CGPoint(x: 128.5, y: -79.5), CGPoint(x: 128.5, y: 336.5)]
        // Connect outside the canvas, with lengths divisible by dab spacing.
        let crossing = horizontal + [CGPoint(x: 336.5, y: -79.5)] + vertical
        func paint(_ points: [CGPoint], color: PixelColor = .white, opacity: Double = 1,
                   erase: Bool = false, selection: SelectionMask? = nil) -> Raster {
            let original = Raster(width: 256, height: 256, color: erase ? blue : .clear)
            var raster = original, stroke = SoftBrushStroke(original: original)
            for i in 1..<points.count {
                stroke.paint(on: &raster, from: points[i - 1], to: points[i], size: 80, color: color,
                             opacity: opacity, erase: erase, selection: selection, antialias: false, hardness: 0)
            }
            return raster
        }
        let h = paint(horizontal), v = paint(vertical), crossed = paint(crossing)
        for y in 96...160 { for x in 96...160 {
            let a = Double(alpha(h, x, y)) / 255, b = Double(alpha(v, x, y)) / 255
            let expected = Int(((a + b - a * b) * 255).rounded())
            XCTAssertEqual(alpha(crossed, x, y), expected, accuracy: 2, "Crossing at \(x),\(y) must blend smoothly")
        } }
        XCTAssertGreaterThan(alpha(crossed, 152, 152), max(alpha(h, 152, 152), alpha(v, 152, 152)) + 35)
        var coverage = Data(repeating: 128, count: 256 * 256)
        coverage[152 * 256 + 152] = 0
        let selection = SelectionMask(width: 256, height: 256, coverage: coverage)
        for erase in [false, true] {
            let result = paint(crossing, color: PixelColor(r: 40, g: 100, b: 220, a: 128), opacity: 0.5, erase: erase, selection: selection)
            for y in 0..<256 { for x in 0..<256 {
                let strength = Double(alpha(crossed, x, y)) / 255 * 0.5 * 128 / 255 * Double(coverage[y * 256 + x]) / 255
                XCTAssertEqual(alpha(result, x, y), Int((255 * (erase ? 1 - strength : strength)).rounded()), accuracy: 1)
            } }
        }
        if let directory = ProcessInfo.processInfo.environment["PAINTMAC_SOFT_PREVIEW_DIR"] {
            // Same path before/after, composited over white for visual QA.
            var before = Raster(width: 256, height: 256, color: .white)
            var after = before
            var oldH = Raster(width: 256, height: 256), oldV = oldH
            oldH.stroke(from: horizontal[0], to: horizontal[1], size: 80, color: .white, opacity: 1, erase: false, clip: nil, antialias: false, hardness: 0)
            oldV.stroke(from: vertical[0], to: vertical[1], size: 80, color: .white, opacity: 1, erase: false, clip: nil, antialias: false, hardness: 0)
            var beforeBytes = before.bytes, afterBytes = after.bytes
            for y in 0..<256 { for x in 0..<256 {
                let oldAlpha = Double(max(alpha(oldH, x, y), alpha(oldV, x, y))) / 255
                let newAlpha = Double(alpha(crossed, x, y)) / 255
                for (index, value) in [blue.r, blue.g, blue.b].enumerated() {
                    beforeBytes[(y * 256 + x) * 4 + index] = UInt8((Double(value) * oldAlpha + 255 * (1 - oldAlpha)).rounded())
                    afterBytes[(y * 256 + x) * 4 + index] = UInt8((Double(value) * newAlpha + 255 * (1 - newAlpha)).rounded())
                }
            } }
            before.bytes = beforeBytes; after.bytes = afterBytes
            for (name, image) in [("crossing-max.png", before), ("crossing-blended.png", after)] {
                try ProjectCodec.imageData(image.cgImage, type: "public.png").write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
            }
        }
    }
    func testCrossingAndCurvedStrokeIsStableAcrossEventDensityAndStationaryInput() {
        let path = [CGPoint(x: 20.5, y: 40.5), CGPoint(x: 180.5, y: 130.5), CGPoint(x: 50.5, y: 170.5),
                    CGPoint(x: 60.5, y: 20.5), CGPoint(x: 140.5, y: 180.5)]
        func paint(subdivisions: Int) -> Raster {
            let original = Raster(width: 200, height: 200)
            var raster = original, stroke = SoftBrushStroke(original: original)
            for i in 1..<path.count {
                let a = path[i - 1], b = path[i]
                for j in 0..<subdivisions {
                    func point(_ k: Int) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * Double(k) / Double(subdivisions), y: a.y + (b.y - a.y) * Double(k) / Double(subdivisions)) }
                    stroke.paint(on: &raster, from: point(j), to: point(j + 1), size: 60, color: blue,
                                 opacity: 0.4, erase: false, selection: nil, antialias: true, hardness: 0)
                    let prior = raster
                    stroke.paint(on: &raster, from: point(j + 1), to: point(j + 1), size: 60, color: blue,
                                 opacity: 0.4, erase: false, selection: nil, antialias: true, hardness: 0)
                    XCTAssertEqual(raster, prior)
                }
            }
            return raster
        }
        XCTAssertEqual(paint(subdivisions: 1), paint(subdivisions: 37))
    }
    func testLargeSoftBrushRemainsResponsive() {
        let original = Raster(width: 1200, height: 800)
        var raster = original, stroke = SoftBrushStroke(original: original)
        let start = ProcessInfo.processInfo.systemUptime
        for i in 0..<20 {
            stroke.paint(on: &raster, from: CGPoint(x: 200 + i * 40, y: 300), to: CGPoint(x: 240 + i * 40, y: 300),
                         size: 300, color: blue, opacity: 0.5, erase: false, selection: nil, antialias: true, hardness: 0)
        }
        let average = (ProcessInfo.processInfo.systemUptime - start) / 20
        print(String(format: "300 px soft brush: %.2f ms per 40 px input segment", average * 1000))
        XCTAssertLessThan(average, 0.1)
        XCTAssertEqual(alpha(raster, 600, 300), 128, accuracy: 1)
    }
    func testSoftEraserSelectionCoverageAndPremultipliedAlpha() {
        let original = Raster(width: 90, height: 90, color: blue)
        var erased = original, stroke = SoftBrushStroke(original: original)
        var selection = SelectionMask(width: 90, height: 90, coverage: Data(repeating: 128, count: 8100))
        selection = selection.combined(with: .rectangle(CGRect(x: 30, y: 30, width: 8, height: 8), width: 90, height: 90), mode: .subtract)
        for _ in 0..<5 {
            stroke.paint(on: &erased, from: CGPoint(x: 40.5, y: 40.5), to: CGPoint(x: 40.5, y: 40.5), size: 40, color: .white,
                         opacity: 0.5, erase: true, selection: selection, antialias: false, hardness: 0)
        }
        XCTAssertEqual(alpha(erased, 40, 40), 191); XCTAssertGreaterThan(alpha(erased, 55, 40), 191)
        XCTAssertEqual(erased.pixel(x: 34, y: 34), original.pixel(x: 34, y: 34))
        let erasedBytes = erased.bytes
        for i in stride(from: 0, to: erasedBytes.count, by: 4) {
            XCTAssertLessThanOrEqual(erasedBytes[i], erasedBytes[i + 3]); XCTAssertLessThanOrEqual(erasedBytes[i + 2], erasedBytes[i + 3])
        }
    }
    func testSoftShapesFadeBothSidesOfOutlineAndKeepFillSolidWithOpacityAppliedOnce() {
        let rect = CGRect(x: 40.5, y: 30.5, width: 100, height: 80)
        for ellipse in [false, true] {
            for smooth in [false, true] {
                var outline = Raster(width: 180, height: 140), filled = outline
                outline.strokeShape(in: rect, ellipse: ellipse, size: 24, color: red, opacity: 0.5, clip: nil, antialias: smooth, hardness: 0.25)
                filled.strokeShape(in: rect, ellipse: ellipse, size: 24, color: red, opacity: 0.5, clip: nil, antialias: smooth, fillColor: blue, hardness: 0.25)
                XCTAssertGreaterThan(alpha(outline, 90, 30), 120)
                XCTAssertGreaterThan(alpha(outline, 90, 22), 0); XCTAssertLessThan(alpha(outline, 90, 22), 100)
                XCTAssertEqual(alpha(outline, 90, 16), 0); XCTAssertEqual(alpha(outline, 90, 70), 0)
                XCTAssertEqual(alpha(filled, 90, 70), 128)
                XCTAssertGreaterThan(filled.pixel(x: 90, y: 70).b, 220)
                XCTAssertLessThanOrEqual(alphas(filled).max()!, 128)
                XCTAssertGreaterThan(alpha(filled, 90, 22), 0)
                XCTAssertLessThan(alpha(filled, 90, 22), 100)
            }
        }
    }
    func testSoftShapesHonorClipSelectionHolesColorAlphaAndThinEllipses() {
        let size = 180 * 140
        var coverage = Data(repeating: 128, count: size)
        for y in 25..<36 { for x in 84..<97 { coverage[y * 180 + x] = 0 } }
        let selection = SelectionMask(width: 180, height: 140, coverage: coverage)
        for ellipse in [false, true] {
            var raster = Raster(width: 180, height: 140)
            raster.strokeShape(in: CGRect(x: 40.5, y: 30.5, width: 100, height: 80), ellipse: ellipse, size: 24,
                               color: PixelColor(r: 255, g: 0, b: 0, a: 128), opacity: 0.5,
                               clip: CGRect(x: 0, y: 0, width: 100, height: 140), selection: selection,
                               antialias: false, fillColor: blue, hardness: 0.25)
            XCTAssertEqual(alpha(raster, 90, 30), 0); XCTAssertEqual(alpha(raster, 120, 70), 0)
            XCTAssertEqual(alpha(raster, 90, 70), 64); XCTAssertLessThanOrEqual(alphas(raster).max()!, 64)
        }
        var thin = Raster(width: 180, height: 140)
        thin.strokeShape(in: CGRect(x: 80, y: 15, width: 2, height: 110), ellipse: true, size: 30,
                         color: red, opacity: 1, clip: nil, antialias: false, hardness: 0)
        XCTAssertGreaterThan(alpha(thin, 80, 70), 200); XCTAssertEqual(alpha(thin, 50, 70), 0)
    }
    private func editor() -> (PaintDocument, EditorWindowController) {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 160, height: 120); doc.makeWindowControllers()
        let editor = doc.windowControllers[0] as! EditorWindowController
        editor.window!.contentView!.layoutSubtreeIfNeeded(); editor.canvas.setZoom(2)
        editor.canvas.brushSize = 30; editor.canvas.brushOpacity = 0.5; editor.canvas.brushHardness = 0.25
        editor.canvas.color = red; editor.canvas.alternateColor = blue; editor.canvas.smooth = false
        doc.undoManager!.groupsByEvent = false; return (doc, editor)
    }
    private func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, canvas: CanvasView) -> NSEvent {
        let p = CGPoint(x: canvas.imageRect.minX + x * canvas.zoom, y: canvas.imageRect.minY + y * canvas.zoom)
        return NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                                 windowNumber: canvas.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    private func transaction(_ doc: PaintDocument, _ body: () -> Void) { doc.undoManager!.beginUndoGrouping(); body(); doc.undoManager!.endUndoGrouping() }
    func testCanvasSoftToolsCommitStablePreviewsAndCancellationPreservesUndoRedo() {
        for tool in [PaintTool.brush, .eraser, .line, .rectangle, .ellipse] {
            let (doc, editor) = editor(); defer { doc.close() }
            let canvas = editor.canvas; canvas.tool = tool; canvas.fillShapes = true
            if tool == .eraser { doc.state.layers[doc.state.activeIndex].raster.fill(color: red) }
            let original = doc.state
            transaction(doc) {
                canvas.mouseDown(with: event(.rightMouseDown, 40, 30, canvas: canvas))
                canvas.mouseDragged(with: event(.rightMouseDragged, 120, 90, canvas: canvas))
                let preview = doc.state
                canvas.mouseDragged(with: event(.rightMouseDragged, 120, 90, canvas: canvas))
                XCTAssertEqual(doc.state, preview)
                canvas.mouseUp(with: event(.rightMouseUp, 120, 90, canvas: canvas))
            }
            let painted = doc.state
            XCTAssertNotEqual(painted, original)
            doc.undoManager!.undo(); XCTAssertEqual(doc.state, original); XCTAssertFalse(doc.undoManager!.canUndo)
            canvas.mouseDown(with: event(.leftMouseDown, 40, 30, canvas: canvas))
            canvas.mouseDragged(with: event(.leftMouseDragged, 120, 90, canvas: canvas))
            canvas.mouseDown(with: event(.rightMouseDown, 80, 60, canvas: canvas))
            canvas.mouseUp(with: event(.leftMouseUp, 120, 90, canvas: canvas))
            canvas.mouseUp(with: event(.rightMouseUp, 80, 60, canvas: canvas))
            XCTAssertEqual(doc.state, original); XCTAssertTrue(doc.undoManager!.canRedo)
            doc.undoManager!.redo(); XCTAssertEqual(doc.state, painted)
        }
    }
    func testSoftBrushAndEraserEditMaskCoverageWithoutChangingImage() {
        let (doc, editor) = editor(); defer { doc.close() }
        let canvas = editor.canvas
        doc.state.layers[doc.state.activeIndex].raster.fill(color: red)
        doc.state.layers[doc.state.activeIndex].mask = .all(width: 160, height: 120); doc.state.editingMask = true
        canvas.color = .maskBlack; canvas.tool = .brush
        let original = doc.state
        transaction(doc) {
            canvas.mouseDown(with: event(.leftMouseDown, 80, 60, canvas: canvas))
            for _ in 0..<5 { canvas.mouseDragged(with: event(.leftMouseDragged, 80, 60, canvas: canvas)) }
            canvas.mouseUp(with: event(.leftMouseUp, 80, 60, canvas: canvas))
        }
        XCTAssertEqual(doc.state.activeLayer.raster, original.activeLayer.raster)
        let mask = doc.state.activeLayer.mask!
        XCTAssertEqual(mask.value(x: 80, y: 60), 128); XCTAssertGreaterThan(mask.value(x: 90, y: 60), 128)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, original)
        canvas.tool = .eraser
        transaction(doc) {
            canvas.mouseDown(with: event(.leftMouseDown, 80, 60, canvas: canvas))
            canvas.mouseUp(with: event(.leftMouseUp, 80, 60, canvas: canvas))
        }
        XCTAssertEqual(doc.state.activeLayer.mask!.value(x: 80, y: 60), 128)
        XCTAssertEqual(doc.state.activeLayer.raster, original.activeLayer.raster)
    }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    func testHardnessControlPersistsAcrossToolsAndFitsMinimumWindowInBothThemes() throws {
        let app = NSApplication.shared, old = app.appearance; defer { app.appearance = old }
        let (doc, editor) = editor(); defer { doc.close() }
        let root = editor.window!.contentView!
        let slider = try XCTUnwrap(views(root).compactMap { $0 as? NSSlider }.first { $0.accessibilityLabel() == "Brush hardness" })
        slider.doubleValue = 25; XCTAssertTrue(slider.sendAction(slider.action, to: slider.target)); XCTAssertEqual(editor.canvas.brushHardness, 0.25)
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            app.appearance = NSAppearance(named: theme); editor.window!.setContentSize(CGSize(width: 960, height: 640))
            for tool in [PaintTool.brush, .eraser, .line, .rectangle, .ellipse, .text, .fill, .selection] {
                editor.selectTool(tool); root.layoutSubtreeIfNeeded()
                let visible = [.brush, .eraser, .line, .rectangle, .ellipse].contains(tool)
                XCTAssertEqual(slider.superview!.isHidden, !visible); XCTAssertEqual(editor.canvas.brushHardness, 0.25)
                if visible { XCTAssertTrue(root.bounds.contains(slider.convert(slider.bounds, to: root))) }
                let fill = try XCTUnwrap(views(root).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Fill shapes" })
                if !fill.isHidden { XCTAssertTrue(root.bounds.contains(fill.convert(fill.bounds, to: root))) }
                if tool == .ellipse, let directory = ProcessInfo.processInfo.environment["PAINTMAC_SOFT_PREVIEW_DIR"] {
                    editor.window!.orderFront(nil); root.displayIfNeeded()
                    let bitmap = try XCTUnwrap(editor.canvas.snapshot(of: root))
                    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent(theme == .aqua ? "hardness-ui-light.png" : "hardness-ui-dark.png"))
                }
            }
        }
        XCTAssertFalse(editor.canvas.smooth); XCTAssertFalse(doc.undoManager!.canUndo)
    }
    func testLargeSoftShapePreviewRemainsResponsiveAndWritesOptionalPreview() throws {
        let original = Raster(width: 1200, height: 800)
        var output = original
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<5 {
            output = original
            output.strokeShape(in: CGRect(x: 250, y: 200, width: 700, height: 400), ellipse: true, size: 300,
                               color: blue, opacity: 0.5, clip: nil, fillColor: red, hardness: 0)
        }
        let average = (ProcessInfo.processInfo.systemUptime - start) / 5
        print(String(format: "300 px soft filled ellipse preview: %.2f ms average", average * 1000))
        XCTAssertLessThan(average, 0.25); XCTAssertEqual(alpha(output, 600, 400), 128)
        if let directory = ProcessInfo.processInfo.environment["PAINTMAC_SOFT_PREVIEW_DIR"] {
            var preview = Raster(width: 760, height: 420, color: .white)
            for (i, hardness) in [1.0, 0.5, 0.0].enumerated() {
                let point = CGPoint(x: 110 + i * 250, y: 100)
                preview.stroke(from: point, to: point, size: 130, color: blue, opacity: 1, erase: false, clip: nil, hardness: hardness)
                preview.strokeShape(in: CGRect(x: 40 + i * 250, y: 240, width: 140, height: 110), ellipse: true, size: 50,
                                    color: blue, opacity: 1, clip: nil, fillColor: red, hardness: hardness)
            }
            try ProjectCodec.imageData(preview.cgImage, type: "public.png").write(to: URL(fileURLWithPath: directory).appendingPathComponent("hardness-comparison.png"))
        }
    }
}
