import AppKit
import XCTest
@testable import PaintMac

final class PixelAlignmentTests: XCTestCase {
    private let blue = PixelColor(r: 40, g: 100, b: 240)
    private let a = CGPoint(x: 20.23, y: 18.19), b = CGPoint(x: 104.76, y: 77.84)
    private func fixture() -> (PaintDocument, CanvasView, NSWindow) {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 128, height: 112)
        doc.undoManager!.groupsByEvent = false
        let canvas = CanvasView(document: doc, useMetal: false)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 260), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        canvas.setZoom(1); canvas.color = blue; canvas.alternateColor = blue
        canvas.rectangleCorners = RectangleCorners(style: .round, radius: 12)
        canvas.smooth = true
        return (doc, canvas, window)
    }
    private func event(_ type: NSEvent.EventType, _ p: CGPoint, _ canvas: CanvasView, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let v = CGPoint(x: canvas.imageRect.minX + p.x * canvas.zoom, y: canvas.imageRect.minY + p.y * canvas.zoom)
        return NSEvent.mouseEvent(with: type, location: canvas.convert(v, to: nil), modifierFlags: flags, timestamp: 0,
                                 windowNumber: canvas.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    private func draw(_ canvas: CanvasView, from start: CGPoint? = nil, to end: CGPoint? = nil, flags: NSEvent.ModifierFlags = []) {
        canvas.paintDocument.undoManager!.beginUndoGrouping()
        canvas.mouseDown(with: event(.leftMouseDown, start ?? a, canvas, flags: flags))
        canvas.mouseDragged(with: event(.leftMouseDragged, end ?? b, canvas, flags: flags))
        canvas.mouseUp(with: event(.leftMouseUp, end ?? b, canvas, flags: flags))
        canvas.paintDocument.undoManager!.endUndoGrouping()
    }
    private func partial(_ data: Data, stride: Int = 4, alpha: Int = 3, straightOnly: Bool = false) -> Int {
        var count = 0
        for y in 0..<112 { for x in 0..<128 {
            if straightOnly && !(45..<75).contains(x) && !(40..<55).contains(y) { continue }
            let value = data[(y * 128 + x) * stride + alpha]
            if value > 0 && value < 255 { count += 1 }
        } }
        return count
    }

    func testRoundedRectanglesKeepSmoothCornersAndCrispStraightSidesForEveryPaintModeAndAlignment() {
        let (doc, canvas, window) = fixture(); defer { window.close(); doc.close() }
        canvas.tool = .rectangle; canvas.alignGeometryToPixels = true
        for mode in ShapePaintMode.allCases { for alignment in ShapeOutlineAlignment.allCases { for width in [1.0, 2, 5.7] {
            canvas.shapePaintMode = mode; canvas.shapeAlignment = alignment; canvas.brushSize = width
            var previous: Raster?
            for zoom: CGFloat in [1, 1.37] {
                canvas.setZoom(zoom); draw(canvas)
                let result = doc.state.activeLayer.raster, data = result.bytes
                XCTAssertEqual(partial(data, straightOnly: true), 0, "\(mode), \(alignment), width \(width)")
                XCTAssertGreaterThan(partial(data), 0, "Curved corners must retain antialiasing")
                if let previous { XCTAssertEqual(result, previous, "Alignment is in image pixels, independent of viewport zoom") }
                previous = result
                doc.undoManager!.undo()
            }
        } } }
    }

    func testBoundsExpandOutwardInEveryDragDirectionAndLeaveAlignedEdgesUnchanged() {
        let pairs: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 10.8, y: 20.8), CGPoint(x: 30.2, y: 40.2)),
            (CGPoint(x: -10.2, y: -20.2), CGPoint(x: -1.8, y: -2.8)),
            (CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 40)),
            (CGPoint(x: 10.5, y: 20.5), CGPoint(x: 30.5, y: 40.5))
        ]
        for phase: CGFloat in [0, 0.5] { for (low, high) in pairs {
            let expected = CGRect(x: floor(low.x - phase) + phase, y: floor(low.y - phase) + phase,
                                  width: ceil(high.x - phase) - floor(low.x - phase),
                                  height: ceil(high.y - phase) - floor(low.y - phase))
            for reversedX in [false, true] { for reversedY in [false, true] {
                let start = CGPoint(x: reversedX ? high.x : low.x, y: reversedY ? high.y : low.y)
                let end = CGPoint(x: reversedX ? low.x : high.x, y: reversedY ? low.y : high.y)
                let result = DragGeometry.pixelAlignedRect(from: start, to: end, square: false, phase: phase)
                XCTAssertEqual(result, expected)
                XCTAssertLessThanOrEqual(result.minX, low.x); XCTAssertLessThanOrEqual(result.minY, low.y)
                XCTAssertGreaterThanOrEqual(result.maxX, high.x); XCTAssertGreaterThanOrEqual(result.maxY, high.y)
                let square = DragGeometry.pixelAlignedRect(from: start, to: end, square: true, phase: phase)
                XCTAssertEqual(square.width, square.height)
                XCTAssertTrue(square.contains(expected))
            } }
        } }
    }

    func testOutwardBoundsReachPaintedPixelsAndSelectionCoverageAtFractionalZoom() {
        let (doc, canvas, window) = fixture(); defer { window.close(); doc.close() }
        let low = CGPoint(x: 20.8, y: 18.8), high = CGPoint(x: 104.2, y: 77.2)
        let bounds = CGRect(x: 20, y: 18, width: 85, height: 60)
        canvas.setZoom(1.37); canvas.rectangleCorners = .square
        for tool in [PaintTool.rectangle, .ellipse, .selection, .ellipseSelect] {
            canvas.tool = tool; canvas.alignGeometryToPixels = true; canvas.shapePaintMode = .fill
            let expected = tool == .ellipse || tool == .ellipseSelect
                ? SelectionMask.ellipse(bounds, width: 128, height: 112, antialias: true)
                : SelectionMask.rectangle(bounds, width: 128, height: 112, antialias: true)
            for reverse in [false, true] {
                draw(canvas, from: reverse ? high : low, to: reverse ? low : high)
                if tool.isSelection { XCTAssertEqual(doc.state.selection, expected) }
                else {
                    let bytes = doc.state.activeLayer.raster.bytes, coverage = expected.coverage
                    for pixel in 0..<(128 * 112) {
                        XCTAssertEqual(bytes[pixel * 4 + 3], coverage[pixel], "\(tool), pixel \(pixel)")
                    }
                }
                doc.undoManager!.undo()
            }
        }
    }

    func testAlignedEdgesDoNotExpandFromCoordinateRoundoffAtFractionalZooms() {
        let (doc, canvas, window) = fixture(); defer { window.close(); doc.close() }
        canvas.tool = .rectangle; canvas.alignGeometryToPixels = true
        for mode in ShapePaintMode.allCases { for width in [1.0, 2] {
            canvas.shapePaintMode = mode; canvas.brushSize = width
            let phase: CGFloat = mode.drawsOutline && width == 1 ? 0.5 : 0
            let start = CGPoint(x: 20 + phase, y: 18 + phase), end = CGPoint(x: 104 + phase, y: 78 + phase)
            for flags: NSEvent.ModifierFlags in [[], [.shift], [.option], [.shift, .option]] {
                var baseline: Raster?
                for zoom: CGFloat in [1, 1.37, 0.83, 1.1] {
                    canvas.setZoom(zoom); draw(canvas, from: start, to: end, flags: flags)
                    let raster = doc.state.activeLayer.raster
                    if let baseline { XCTAssertEqual(raster, baseline, "Already aligned edges must not expand at zoom \(zoom)") }
                    baseline = raster
                    doc.undoManager!.undo()
                }
            }
        } }
        canvas.tool = .selection; canvas.rectangleCorners = .square
        let expected = SelectionMask.rectangle(CGRect(x: 20, y: 18, width: 85, height: 60), width: 128, height: 112)
        for zoom: CGFloat in [1, 1.37, 0.83, 1.1] {
            canvas.setZoom(zoom)
            draw(canvas, from: CGPoint(x: 20, y: 18), to: CGPoint(x: 105, y: 78))
            XCTAssertEqual(doc.state.selection, expected)
            doc.undoManager!.undo()
        }
    }

    func testAlignmentOffRetainsFreeSmoothShapesAndAllowsFreeSmoothMarquees() {
        let (doc, canvas, window) = fixture(); defer { window.close(); doc.close() }
        canvas.tool = .rectangle; canvas.shapePaintMode = .fill
        XCTAssertFalse(canvas.alignGeometryToPixels)
        draw(canvas)
        XCTAssertGreaterThan(partial(doc.state.activeLayer.raster.bytes, straightOnly: true), 0)
        doc.undoManager!.undo()
        for tool in [PaintTool.selection, .ellipseSelect] {
            canvas.tool = tool; XCTAssertTrue(canvas.alignGeometryToPixels)
            draw(canvas)
            let aligned = doc.state.selection!
            if tool == .selection {
                XCTAssertEqual(partial(aligned.coverage, stride: 1, alpha: 0, straightOnly: true), 0)
                XCTAssertGreaterThan(partial(aligned.coverage, stride: 1, alpha: 0), 0)
            }
            doc.undoManager!.undo()
            canvas.alignGeometryToPixels = false; draw(canvas)
            XCTAssertNotEqual(doc.state.selection, aligned)
            doc.undoManager!.undo()
            canvas.alignGeometryToPixels = true
        }
        canvas.tool = .rectangle; XCTAssertFalse(canvas.alignGeometryToPixels, "Shape and selection preferences are remembered independently")
    }

    func testPixelGeometryKeepsEqualSidesAndCenterOriginIncludingOffImageAnchors() {
        for phase: CGFloat in [0, 0.5] { for x: CGFloat in [-1, 1] { for y: CGFloat in [-1, 1] {
            let start = CGPoint(x: -5.2, y: 8.8), end = CGPoint(x: start.x + x * 20.9, y: start.y + y * 19.2)
            let rect = DragGeometry.pixelAlignedRect(from: start, to: end, square: true, phase: phase, fromCenter: true)
            let original = DragGeometry.rect(from: start, to: end, square: true, snap: false, fromCenter: true)
            XCTAssertTrue(rect.contains(original), "Centered snapping must expand rather than clip any side")
            XCTAssertEqual(rect.width, rect.height)
            XCTAssertEqual(rect.width, rect.width.rounded())
            XCTAssertEqual(CGPoint(x: rect.midX, y: rect.midY), DragGeometry.pixelAlignedPoint(start, phase: phase))
            XCTAssertEqual(rect.minX - phase, (rect.minX - phase).rounded())
            XCTAssertEqual(rect.maxY - phase, (rect.maxY - phase).rounded())
        } } }
        for width in [1.0, 2, 7] {
            let (start, end) = DragGeometry.pixelAlignedLine(from: a, to: b, width: width, constrained: true, fromCenter: true)
            XCTAssertEqual(abs(end.x - start.x), abs(end.y - start.y), "45-degree constraint must survive endpoint snapping")
            let phase: CGFloat = Int(width) % 2 == 1 ? 0.5 : 0
            XCTAssertEqual(CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), DragGeometry.pixelAlignedPoint(a, phase: phase))
        }
    }

    func testAlignedSmoothLinesKeepStraightSidesCrispAndDiagonalEdgesSmooth() {
        let (doc, canvas, window) = fixture(); defer { window.close(); doc.close() }
        canvas.tool = .line; canvas.alignGeometryToPixels = true
        for size in [1.0, 2, 5.7] {
            canvas.brushSize = size
            draw(canvas, from: CGPoint(x: 15.2, y: 35.3), to: CGPoint(x: 105.8, y: 35.4))
            let data = doc.state.activeLayer.raster.bytes
            for y in 0..<112 { for x in 40..<80 {
                let alpha = data[(y * 128 + x) * 4 + 3]
                XCTAssertTrue(alpha == 0 || alpha == 255)
            } }
            doc.undoManager!.undo()
            draw(canvas, flags: [.shift, .option])
            XCTAssertGreaterThan(partial(doc.state.activeLayer.raster.bytes), 0)
            doc.undoManager!.undo()
        }
    }

    func testPixelAlignedMasksKeepCoveragePrecisionPreviewUndoAndCancellation() {
        for target in 0..<3 {
            let (doc, canvas, window) = fixture(); defer { window.close(); doc.close() }
            doc.state = DocumentState(width: 128, height: 112, format: RGBFormat(profile: .displayP3, depth: .sixteen))
            if target == 1 { doc.state.activeLayer.mask = .all(width: 128, height: 112); doc.state.editingMask = true }
            if target == 2 { doc.state.quickMask = .empty(width: 128, height: 112) }
            canvas.tool = .rectangle; canvas.alignGeometryToPixels = true; canvas.shapePaintMode = .fill
            canvas.color = .maskBlack; canvas.brushOpacity = 0.5
            if target == 2 { canvas.color = .white }
            let before = doc.state
            doc.undoManager!.beginUndoGrouping()
            canvas.mouseDown(with: event(.leftMouseDown, a, canvas))
            canvas.mouseDragged(with: event(.leftMouseDragged, b, canvas))
            let preview = doc.state
            canvas.mouseDragged(with: event(.leftMouseDragged, b, canvas))
            XCTAssertEqual(doc.state, preview)
            canvas.mouseUp(with: event(.leftMouseUp, b, canvas))
            doc.undoManager!.endUndoGrouping()
            XCTAssertEqual(doc.state, preview); XCTAssertEqual(doc.state.format, before.format)
            if target > 0 { XCTAssertEqual(doc.state.layers.map(\.raster), before.layers.map(\.raster)) }
            doc.undoManager!.undo(); XCTAssertEqual(doc.state, before)
            canvas.mouseDown(with: event(.leftMouseDown, a, canvas))
            canvas.mouseDragged(with: event(.leftMouseDragged, b, canvas))
            canvas.mouseDown(with: event(.rightMouseDown, b, canvas))
            canvas.mouseUp(with: event(.leftMouseUp, b, canvas)); canvas.mouseUp(with: event(.rightMouseUp, b, canvas))
            XCTAssertEqual(doc.state, before); XCTAssertFalse(doc.undoManager!.canUndo); XCTAssertTrue(doc.undoManager!.canRedo)
        }
    }

    func testAlignmentControlVisibilitySharpModeAndIndependentPreferencesDoNotEditArtwork() throws {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.makeWindowControllers(); defer { doc.close() }
        let editor = doc.windowControllers[0] as! EditorWindowController, root = editor.window!.contentView!
        func views(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + views($0) } }
        let checkbox = try XCTUnwrap(views(root).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Align geometry to pixels" })
        let edge = try XCTUnwrap(views(root).compactMap { $0 as? NSSegmentedControl }.first { $0.accessibilityLabel() == "Painting edge mode" })
        let before = doc.state
        editor.selectTool(.rectangle); XCTAssertEqual(checkbox.state, .off)
        checkbox.performClick(nil); XCTAssertTrue(editor.canvas.alignGeometryToPixels)
        edge.selectedSegment = 1; _ = NSApp.sendAction(edge.action!, to: edge.target, from: edge)
        XCTAssertFalse(checkbox.isEnabled); XCTAssertEqual(checkbox.state, .on)
        edge.selectedSegment = 0; _ = NSApp.sendAction(edge.action!, to: edge.target, from: edge)
        XCTAssertTrue(checkbox.isEnabled); XCTAssertTrue(editor.canvas.smooth)
        editor.selectTool(.selection); XCTAssertEqual(checkbox.state, .on)
        checkbox.performClick(nil); XCTAssertFalse(editor.canvas.alignGeometryToPixels)
        editor.selectTool(.rectangle); XCTAssertEqual(checkbox.state, .on)
        for tool in PaintTool.allCases where tool != .crop {
            editor.selectTool(tool)
            XCTAssertEqual(checkbox.isHidden, !tool.isGeometry && tool != .selection && tool != .ellipseSelect)
        }
        XCTAssertEqual(doc.state, before); XCTAssertFalse(doc.undoManager!.canUndo)
    }
}
