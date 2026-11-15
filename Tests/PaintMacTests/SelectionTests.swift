import XCTest
import AppKit
@testable import PaintMac

final class SelectionTests: XCTestCase {
    let red = PixelColor(r: 255, g: 0, b: 0)
    let blue = PixelColor(r: 0, g: 0, b: 255)

    func testSelectionShapesAndCombinationPreserveDisconnectedRegionsAndHoles() {
        let left = SelectionMask.rectangle(CGRect(x: 2, y: 3, width: 10, height: 12), width: 40, height: 30)
        let right = SelectionMask.ellipse(CGRect(x: 22, y: 3, width: 12, height: 12), width: 40, height: 30)
        let both = left.combined(with: right, mode: .add)
        XCTAssertEqual(both.value(x: 5, y: 5), 255)
        XCTAssertEqual(both.value(x: 28, y: 9), 255)
        XCTAssertEqual(both.value(x: 18, y: 9), 0)
        XCTAssertEqual(both.value(x: 22, y: 3), 0)
        let hole = SelectionMask.rectangle(CGRect(x: 5, y: 6, width: 3, height: 3), width: 40, height: 30)
        let cut = both.combined(with: hole, mode: .subtract)
        XCTAssertEqual(cut.value(x: 6, y: 7), 0)
        XCTAssertEqual(cut.value(x: 3, y: 7), 255)
        XCTAssertEqual(cut.value(x: 28, y: 9), 255)
        var contours = 0, closed = 0
        cut.outline().applyWithBlock { element in
            if element.pointee.type == .moveToPoint { contours += 1 }
            if element.pointee.type == .closeSubpath { closed += 1 }
        }
        XCTAssertEqual(contours, 3) // two islands and an interior hole
        XCTAssertEqual(closed, 3)
        XCTAssertEqual(both.combined(with: left, mode: .intersect), left)
        let empty = left.combined(with: left, mode: .subtract)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(empty.inverted() == .all(width: 40, height: 30))
        let lasso = SelectionMask.lasso([CGPoint(x: 2, y: 2), CGPoint(x: 18, y: 2), CGPoint(x: 2, y: 18)], width: 40, height: 30)
        XCTAssertEqual(lasso.value(x: 4, y: 4), 255)
        XCTAssertEqual(lasso.value(x: 16, y: 16), 0)
        XCTAssertEqual(lasso.value(x: 4, y: 25), 0)
    }

    func testFeatherProducesSoftCoverageInCorrectCoordinatesAndClampsCanvasEdges() {
        let renderer = ImageRenderer()
        let hard = SelectionMask.rectangle(CGRect(x: 10, y: 8, width: 25, height: 18), width: 80, height: 60)
        let soft = hard.feathered(radius: 3, context: renderer.context)
        XCTAssertGreaterThan(soft.value(x: 22, y: 8), 40)
        XCTAssertLessThan(soft.value(x: 22, y: 8), 220)
        XCTAssertGreaterThan(soft.value(x: 22, y: 5), 0)
        XCTAssertGreaterThan(soft.value(x: 22, y: 17), 240)
        XCTAssertEqual(soft.value(x: 22, y: 50), 0)
        XCTAssertLessThan(soft.bounds.minX, hard.bounds.minX)
        XCTAssertEqual(SelectionMask.all(width: 8, height: 8).feathered(radius: 4, context: renderer.context), .all(width: 8, height: 8))
        XCTAssertEqual(hard.feathered(radius: 0, context: renderer.context), hard)
    }

    func testBrushShapeFillDeleteAndAdjustmentsRespectMaskHolesAndPartialCoverage() {
        let full = SelectionMask.rectangle(CGRect(x: 2, y: 2, width: 20, height: 20), width: 30, height: 30)
        let hole = SelectionMask.rectangle(CGRect(x: 8, y: 8, width: 6, height: 6), width: 30, height: 30)
        let mask = full.combined(with: hole, mode: .subtract)
        var brush = Raster(width: 30, height: 30)
        brush.stroke(from: CGPoint(x: 0, y: 10), to: CGPoint(x: 29, y: 10), size: 6, color: red, opacity: 1, erase: false, clip: nil, selection: mask)
        XCTAssertEqual(brush.pixel(x: 5, y: 10), red)
        XCTAssertEqual(brush.pixel(x: 10, y: 10), .clear)
        XCTAssertEqual(brush.pixel(x: 25, y: 10), .clear)

        var shape = Raster(width: 30, height: 30)
        shape.strokeShape(in: CGRect(x: 1, y: 4, width: 25, height: 6), ellipse: false, size: 10,
                          color: blue, opacity: 1, clip: nil, selection: mask)
        XCTAssertEqual(shape.pixel(x: 5, y: 4), blue)
        XCTAssertEqual(shape.pixel(x: 10, y: 10), .clear)
        XCTAssertEqual(shape.pixel(x: 5, y: 25), .clear)

        var fill = Raster(width: 30, height: 30)
        fill.floodFill(at: CGPoint(x: 3, y: 3), color: red, tolerance: 0, clip: nil, selection: mask)
        XCTAssertEqual(fill.pixel(x: 5, y: 5), red)
        XCTAssertEqual(fill.pixel(x: 10, y: 10), .clear)
        XCTAssertEqual(fill.pixel(x: 28, y: 28), .clear)

        var solid = Raster(width: 30, height: 30, color: red)
        solid.erase(selection: mask)
        XCTAssertEqual(solid.pixel(x: 5, y: 5), .clear)
        XCTAssertEqual(solid.pixel(x: 10, y: 10), red)
        let adjusted = Raster(width: 30, height: 30, color: red).blending(Raster(width: 30, height: 30, color: blue), selection: mask)
        XCTAssertEqual(adjusted.pixel(x: 5, y: 5), blue)
        XCTAssertEqual(adjusted.pixel(x: 10, y: 10), red)

        let partial = SelectionMask(width: 1, height: 1, coverage: Data([128]))
        var pixel = Raster(width: 1, height: 1)
        pixel.stroke(from: .zero, to: CGPoint(x: 1, y: 1), size: 10, color: red, opacity: 1, erase: false, clip: nil, selection: partial)
        XCTAssertEqual(pixel.pixel(x: 0, y: 0).a, 128)
        var erased = Raster(width: 1, height: 1, color: red)
        erased.erase(selection: partial)
        XCTAssertEqual(erased.pixel(x: 0, y: 0).a, 127)
        var partialShape = Raster(width: 1, height: 1)
        partialShape.strokeShape(in: CGRect(x: 0, y: 0, width: 1, height: 1), ellipse: false, size: 10, color: red, opacity: 1, clip: nil, selection: partial)
        XCTAssertEqual(partialShape.pixel(x: 0, y: 0).a, 128)
    }

    func testCopyAndMoveKeepHolesAndFeatherCoverage() {
        let left = SelectionMask.rectangle(CGRect(x: 1, y: 1, width: 4, height: 5), width: 20, height: 15)
        let hole = SelectionMask.rectangle(CGRect(x: 2, y: 2, width: 1, height: 2), width: 20, height: 15)
        let mask = left.combined(with: hole, mode: .subtract)
        let source = Raster(width: 20, height: 15, color: red)
        let copied = source.masked(using: mask).cropped(to: mask.bounds)
        XCTAssertEqual(copied.pixel(x: 0, y: 0), red)
        XCTAssertEqual(copied.pixel(x: 1, y: 1), .clear)
        let moved = source.moved(dx: 10, dy: 2, selection: mask)
        XCTAssertEqual(moved.pixel(x: 1, y: 1), .clear)
        XCTAssertEqual(moved.pixel(x: 2, y: 2), red)
        XCTAssertEqual(moved.pixel(x: 11, y: 3), red)
        XCTAssertEqual(source.moved(dx: 0, dy: 0, selection: mask), source)
        let shifted = mask.translated(dx: 10, dy: 2)
        XCTAssertEqual(shifted.value(x: 11, y: 3), 255)
        XCTAssertEqual(shifted.value(x: 12, y: 4), 0)
        let half = SelectionMask(width: 1, height: 1, coverage: Data([128]))
        XCTAssertEqual(Raster(width: 1, height: 1, color: red).masked(using: half).pixel(x: 0, y: 0).a, 128)
        let empty = SelectionMask.empty(width: 20, height: 15)
        var unchanged = source
        unchanged.erase(selection: empty)
        XCTAssertEqual(unchanged, source)
    }

    func testSelectionHistoryAndFeatherUndoRestorePixelsAndSelectionTogether() {
        _ = NSApplication.shared
        let document = PaintDocument()
        document.state = DocumentState(width: 40, height: 30)
        document.state.layers[document.state.activeIndex].raster.fill(color: red)
        let canvas = CanvasView(document: document)
        let hard = SelectionMask.ellipse(CGRect(x: 5, y: 5, width: 20, height: 15), width: 40, height: 30)
        document.undoManager?.groupsByEvent = false
        document.undoManager?.beginUndoGrouping()
        canvas.changeSelection(hard, name: "Ellipse Select")
        document.undoManager?.endUndoGrouping()
        document.undoManager?.beginUndoGrouping()
        let soft = hard.feathered(radius: 2, context: document.renderer.context)
        canvas.changeSelection(soft, name: "Feather Selection")
        document.undoManager?.endUndoGrouping()
        XCTAssertEqual(canvas.selection, soft)
        document.undoManager?.undo()
        XCTAssertEqual(canvas.selection, hard)
        document.undoManager?.undo()
        XCTAssertNil(canvas.selection)
        document.undoManager?.redo()
        XCTAssertEqual(canvas.selection, hard)
        document.undoManager?.beginUndoGrouping()
        canvas.deletePixels()
        document.undoManager?.endUndoGrouping()
        XCTAssertEqual(canvas.selection, hard)
        XCTAssertEqual(document.state.activeLayer.raster.pixel(x: 15, y: 12), .clear)
        XCTAssertEqual(document.state.activeLayer.raster.pixel(x: 0, y: 0), red)
        document.undoManager?.undo()
        XCTAssertEqual(document.state.activeLayer.raster, Raster(width: 40, height: 30, color: red))
    }

    func testModifierModes() {
        XCTAssertEqual(SelectionMode.resolve(.shift, fallback: .replace), .add)
        XCTAssertEqual(SelectionMode.resolve(.option, fallback: .replace), .subtract)
        XCTAssertEqual(SelectionMode.resolve([.shift, .option], fallback: .replace), .intersect)
        XCTAssertEqual(SelectionMode.resolve([], fallback: .subtract), .subtract)
    }

    func testCanvasGesturesCombineRectangleEllipseAndLassoWithoutInvokingColorPicker() {
        _ = NSApplication.shared
        let document = PaintDocument()
        document.state = DocumentState(width: 100, height: 100)
        let canvas = CanvasView(document: document)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas; canvas.setZoom(1)
        defer { window.close() }
        var sampled = false
        canvas.onColorPick = { _, _ in sampled = true }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
            let p = CGPoint(x: canvas.imageRect.minX + point.x * canvas.zoom, y: canvas.imageRect.minY + point.y * canvas.zoom)
            return NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: modifiers,
                                     timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func drag(_ tool: PaintTool, _ points: [CGPoint], _ modifiers: NSEvent.ModifierFlags = []) {
            canvas.tool = tool
            canvas.mouseDown(with: mouse(.leftMouseDown, points[0], modifiers))
            for p in points.dropFirst() { canvas.mouseDragged(with: mouse(.leftMouseDragged, p, modifiers)) }
            canvas.mouseUp(with: mouse(.leftMouseUp, points.last!, modifiers))
        }
        drag(.selection, [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 40)])
        drag(.ellipseSelect, [CGPoint(x: 60, y: 10), CGPoint(x: 90, y: 40)], .shift)
        XCTAssertEqual(canvas.selection?.value(x: 20, y: 20), 255)
        XCTAssertEqual(canvas.selection?.value(x: 75, y: 25), 255)
        XCTAssertEqual(canvas.selection?.value(x: 50, y: 20), 0)
        drag(.selection, [CGPoint(x: 15, y: 15), CGPoint(x: 25, y: 25)], .option)
        XCTAssertFalse(sampled)
        XCTAssertEqual(canvas.selection?.value(x: 20, y: 20), 0)
        XCTAssertEqual(canvas.selection?.value(x: 30, y: 30), 255)
        drag(.selection, [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 40)], [.shift, .option])
        XCTAssertEqual(canvas.selection?.value(x: 75, y: 25), 0)
        XCTAssertEqual(canvas.selection?.value(x: 30, y: 30), 255)
        drag(.lasso, [CGPoint(x: 10, y: 60), CGPoint(x: 40, y: 60), CGPoint(x: 10, y: 90)], .shift)
        XCTAssertEqual(canvas.selection?.value(x: 15, y: 65), 255)
        XCTAssertEqual(canvas.selection?.value(x: 35, y: 85), 0)
        canvas.color = red; canvas.brushSize = 6
        drag(.brush, [CGPoint(x: 10, y: 30), CGPoint(x: 60, y: 30)])
        XCTAssertEqual(document.state.activeLayer.raster.pixel(x: 30, y: 30), red)
        XCTAssertEqual(document.state.activeLayer.raster.pixel(x: 50, y: 30), .clear)
    }

    func testCropUndoRestoresOriginalSelectionAndAdjustmentsUseIt() throws {
        _ = NSApplication.shared
        let document = PaintDocument()
        document.state = DocumentState(width: 40, height: 30)
        document.state.layers[document.state.activeIndex].raster.fill(color: red)
        document.makeWindowControllers()
        defer { document.close() }
        let editor = document.windowControllers[0] as! EditorWindowController
        let mask = SelectionMask.ellipse(CGRect(x: 4, y: 3, width: 20, height: 12), width: 40, height: 30)
        editor.canvas.selection = mask
        document.undoManager?.groupsByEvent = false
        document.undoManager?.beginUndoGrouping()
        editor.applyAdjustment("CIColorInvert", name: "Invert Colors")
        document.undoManager?.endUndoGrouping()
        XCTAssertNotEqual(document.state.activeLayer.raster.pixel(x: 14, y: 9), red)
        XCTAssertEqual(document.state.activeLayer.raster.pixel(x: 4, y: 3), red)
        document.undoManager?.beginUndoGrouping()
        editor.cropToSelection()
        document.undoManager?.endUndoGrouping()
        XCTAssertLessThan(document.state.width, 40)
        XCTAssertNil(editor.canvas.selection)
        document.undoManager?.undo()
        XCTAssertEqual(document.state.width, 40)
        XCTAssertEqual(editor.canvas.selection, mask)
        // Selection state participates in history but remains session-only in v1 project packages.
        let saved = try ProjectCodec.decode(ProjectCodec.encode(document.state))
        XCTAssertNil(saved.selection)
        XCTAssertEqual(saved.layers, document.state.layers)
    }

    func testSelectionEditorLayoutAtMinimumSize() throws {
        _ = NSApplication.shared
        let document = PaintDocument()
        document.makeWindowControllers()
        defer { document.close() }
        let editor = document.windowControllers[0] as! EditorWindowController
        let window = editor.window!
        editor.selectTool(.ellipseSelect)
        let circle = SelectionMask.ellipse(CGRect(x: 260, y: 160, width: 600, height: 440), width: 1200, height: 800)
        let hole = SelectionMask.ellipse(CGRect(x: 420, y: 290, width: 210, height: 170), width: 1200, height: 800)
        editor.canvas.selection = circle.combined(with: hole, mode: .subtract).feathered(radius: 8, context: document.renderer.context)
        for size in [CGSize(width: 1320, height: 800), CGSize(width: 960, height: 580)] {
            window.setContentSize(size)
            let root = window.contentView!
            root.layoutSubtreeIfNeeded()
            func allSubviews(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + allSubviews($0) } }
            let views = allSubviews(root)
            let feather = views.compactMap { $0 as? NSButton }.first { $0.title == "Feather…" }!
            XCTAssertTrue(root.bounds.contains(feather.convert(feather.bounds, to: root)))
            XCTAssertFalse(feather.isHiddenOrHasHiddenAncestor)
            let hand = views.compactMap { $0 as? NSButton }.first { $0.toolTip == "Hand (H)" }!
            XCTAssertNotNil(hand.enclosingScrollView)
            hand.scrollToVisible(hand.bounds)
            XCTAssertTrue(root.bounds.contains(hand.convert(hand.bounds, to: root)))
            if size.width == 1320, let path = ProcessInfo.processInfo.environment["PAINTMAC_SELECTION_PREVIEW_PATH"],
               let bitmap = editor.canvas.snapshot(of: root) {
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
