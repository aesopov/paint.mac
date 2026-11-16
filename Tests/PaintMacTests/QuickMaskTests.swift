import XCTest
import AppKit
@testable import PaintMac

final class QuickMaskTests: XCTestCase {
    private func setup() -> (PaintDocument, CanvasView, NSWindow) {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 80, height: 60)
        doc.undoManager!.groupsByEvent = false
        let canvas = CanvasView(document: doc, useMetal: false)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas; canvas.setZoom(1)
        canvas.color = .white; canvas.alternateColor = .maskBlack; canvas.brushSize = 8; canvas.smooth = false
        return (doc, canvas, window)
    }
    private func transaction(_ doc: PaintDocument, _ body: () throws -> Void) rethrows {
        doc.undoManager!.beginUndoGrouping(); defer { doc.undoManager!.endUndoGrouping() }; try body()
    }
    private func mouse(_ type: NSEvent.EventType, _ p: CGPoint, _ canvas: CanvasView, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let point = CGPoint(x: canvas.imageRect.minX + p.x * canvas.zoom, y: canvas.imageRect.minY + p.y * canvas.zoom)
        return NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: flags,
                                 timestamp: 0, windowNumber: canvas.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    private func drag(_ canvas: CanvasView, _ tool: PaintTool, _ points: [CGPoint], right: Bool = false, flags: NSEvent.ModifierFlags = []) {
        canvas.tool = tool
        canvas.mouseDown(with: mouse(right ? .rightMouseDown : .leftMouseDown, points[0], canvas, flags))
        for p in points.dropFirst() { canvas.mouseDragged(with: mouse(right ? .rightMouseDragged : .leftMouseDragged, p, canvas, flags)) }
        canvas.mouseUp(with: mouse(right ? .rightMouseUp : .leftMouseUp, points.last!, canvas, flags))
    }

    func testOffImageDrawingAndSelectionKeepAnchorAndClipAcrossEdges() {
        let (doc, canvas, window) = setup(); defer { window.close(); doc.close() }
        for zoom: CGFloat in [0.5, 1, 1.5] {
            canvas.setZoom(zoom); canvas.selection = nil
            transaction(doc) { drag(canvas, .selection, [CGPoint(x: -10, y: -8), CGPoint(x: 25, y: 20)]) }
            XCTAssertEqual(canvas.selection?.bounds, CGRect(x: 0, y: 0, width: 25, height: 20))
            transaction(doc) { drag(canvas, .ellipseSelect, [CGPoint(x: -20, y: 5), CGPoint(x: 20, y: 45)]) }
            XCTAssertEqual(canvas.selection?.value(x: 0, y: 25), 255)
            XCTAssertEqual(canvas.selection?.value(x: 19, y: 6), 0)
        }
        canvas.setZoom(1); canvas.selection = nil
        transaction(doc) { drag(canvas, .brush, [CGPoint(x: -15, y: 12), CGPoint(x: 20, y: 12)]) }
        XCTAssertEqual(doc.state.activeLayer.raster.pixel(x: 0, y: 12), .white)
        canvas.fillShapes = true
        transaction(doc) { drag(canvas, .rectangle, [CGPoint(x: -10, y: -10), CGPoint(x: 25, y: 25)]) }
        XCTAssertEqual(doc.state.activeLayer.raster.pixel(x: 0, y: 0), .maskBlack)
        XCTAssertEqual(doc.state.activeLayer.raster.pixel(x: 24, y: 10), .white)
        let before = doc.state
        transaction(doc) { drag(canvas, .brush, [CGPoint(x: -20, y: -20), CGPoint(x: -15, y: -15)]) }
        XCTAssertEqual(doc.state, before)
        var picked = false; canvas.onColorPick = { _, _ in picked = true }
        drag(canvas, .eyedropper, [CGPoint(x: -0.2, y: 0)])
        XCTAssertFalse(picked)
    }

    func testModeRoundTripRetainsFeatheredSelectionAndDoesNotTouchPixelsOrLayerMasks() throws {
        let (doc, canvas, window) = setup(); defer { window.close(); doc.close() }
        let soft = SelectionMask.ellipse(CGRect(x: 10, y: 10, width: 30, height: 25), width: 80, height: 60).feathered(radius: 2, context: doc.renderer.context)
        doc.state.selection = soft; doc.state.layers[1].mask = .all(width: 80, height: 60); doc.state.editingMask = true
        let layers = doc.state.layers
        transaction(doc) { canvas.toggleQuickMask() }
        XCTAssertTrue(doc.state.isQuickMask); XCTAssertNil(canvas.selection); XCTAssertEqual(doc.state.quickMask, soft)
        transaction(doc) { canvas.toggleQuickMask() }
        XCTAssertFalse(doc.state.isQuickMask); XCTAssertEqual(canvas.selection, soft); XCTAssertTrue(doc.state.isEditingMask)
        XCTAssertEqual(doc.state.layers, layers)
        doc.undoManager!.undo(); XCTAssertTrue(doc.state.isQuickMask); XCTAssertEqual(doc.state.quickMask, soft)
        doc.undoManager!.undo(); XCTAssertFalse(doc.state.isQuickMask); XCTAssertEqual(canvas.selection, soft)
        doc.undoManager!.redo(); XCTAssertTrue(doc.state.isQuickMask)
        let decoded = try ProjectCodec.decode(ProjectCodec.encode(doc.state))
        XCTAssertNil(decoded.quickMask); XCTAssertNil(decoded.selection); XCTAssertEqual(decoded.layers, layers)
    }

    func testBrushBothColorsShapesBucketEraserAndSoftEdgesTargetOnlyQuickMaskOnLockedHiddenLayer() {
        let (doc, canvas, window) = setup(); defer { window.close(); doc.close() }
        doc.state.layers[1].isLocked = true; doc.state.layers[1].visible = false
        doc.state.selection = .empty(width: 80, height: 60)
        let layers = doc.state.layers
        transaction(doc) { canvas.toggleQuickMask() }
        transaction(doc) { drag(canvas, .brush, [CGPoint(x: -8, y: 10), CGPoint(x: 40, y: 10)]) }
        XCTAssertEqual(doc.state.quickMask?.value(x: 0, y: 10), 255)
        transaction(doc) { drag(canvas, .brush, [CGPoint(x: 20, y: 10)], right: true) }
        XCTAssertEqual(doc.state.quickMask?.value(x: 20, y: 10), 0)
        transaction(doc) { drag(canvas, .eraser, [CGPoint(x: 10, y: 10)]) }
        XCTAssertEqual(doc.state.quickMask?.value(x: 10, y: 10), 0)
        canvas.fillShapes = true; canvas.alternateColor = .white
        transaction(doc) { drag(canvas, .ellipse, [CGPoint(x: 45, y: 20), CGPoint(x: 70, y: 45)]) }
        XCTAssertEqual(doc.state.quickMask?.value(x: 55, y: 30), 255)
        canvas.brushHardness = 0; canvas.brushSize = 20; canvas.brushOpacity = 0.5
        transaction(doc) { drag(canvas, .brush, [CGPoint(x: 25, y: 40)]) }
        let coverage = doc.state.quickMask!.value(x: 25, y: 40)
        XCTAssertGreaterThan(coverage, 0); XCTAssertLessThan(coverage, 140)
        canvas.brushOpacity = 1
        transaction(doc) { drag(canvas, .fill, [CGPoint(x: 79, y: 59)]) }
        XCTAssertEqual(doc.state.quickMask?.value(x: 79, y: 59), 255)
        XCTAssertEqual(doc.state.layers, layers)
    }

    func testLocalMarqueeConstrainsPaintingAndMovesMaskPixelsAndUndoTogether() {
        let (doc, canvas, window) = setup(); defer { window.close(); doc.close() }
        doc.state.selection = .rectangle(CGRect(x: 5, y: 5, width: 15, height: 15), width: 80, height: 60)
        let layers = doc.state.layers
        transaction(doc) { canvas.toggleQuickMask() }
        transaction(doc) { drag(canvas, .selection, [CGPoint(x: 5, y: 5), CGPoint(x: 20, y: 20)]) }
        let before = doc.state
        transaction(doc) { drag(canvas, .move, [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 30)]) }
        XCTAssertEqual(doc.state.quickMask?.value(x: 10, y: 10), 0)
        XCTAssertEqual(doc.state.quickMask?.value(x: 40, y: 30), 255)
        XCTAssertEqual(canvas.selection?.bounds, CGRect(x: 35, y: 25, width: 15, height: 15))
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, before)
        doc.undoManager!.redo()
        transaction(doc) { drag(canvas, .brush, [CGPoint(x: -10, y: 30), CGPoint(x: 70, y: 30)], right: true) }
        XCTAssertEqual(doc.state.quickMask?.value(x: 40, y: 30), 0)
        XCTAssertEqual(doc.state.quickMask?.value(x: 40, y: 25), 255)
        XCTAssertEqual(doc.state.layers, layers)
        transaction(doc) { canvas.toggleQuickMask() }
        XCTAssertEqual(canvas.selection?.value(x: 40, y: 30), 0)
        XCTAssertEqual(canvas.selection?.value(x: 40, y: 25), 255)
    }

    func testOppositeButtonCancellationRestoresMaskAndKeepsRedo() {
        let (doc, canvas, window) = setup(); defer { window.close(); doc.close() }
        transaction(doc) { canvas.toggleQuickMask() }
        transaction(doc) { drag(canvas, .eraser, [CGPoint(x: 10, y: 10)]) }
        doc.undoManager!.undo(); let before = doc.state
        canvas.tool = .eraser
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: -2, y: 10), canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 30, y: 10), canvas))
        XCTAssertNotEqual(doc.state, before)
        canvas.mouseDown(with: mouse(.rightMouseDown, CGPoint(x: 30, y: 10), canvas))
        XCTAssertEqual(doc.state, before); XCTAssertTrue(doc.undoManager!.canRedo)
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 30, y: 10), canvas))
        canvas.mouseUp(with: mouse(.rightMouseUp, CGPoint(x: 30, y: 10), canvas))
        XCTAssertEqual(doc.state, before)
    }

    func testInlineTextPreviewMatchesMaskCommitAndCancelDoesNotCreateLayers() throws {
        let (doc, canvas, window) = setup(); defer { window.close(); doc.close() }
        doc.state.selection = .empty(width: 80, height: 60)
        transaction(doc) { canvas.toggleQuickMask() }
        let before = doc.state
        canvas.textStyle.size = 32
        canvas.beginText(in: CGRect(x: -5, y: 3, width: 60, height: 25), color: .white)
        canvas.textEditor!.textView.string = "MASK"; canvas.refreshTextPreview()
        let preview = try XCTUnwrap(canvas.textPreviewRaster)
        XCTAssertFalse(SelectionMask(editingRaster: preview).isEmpty)
        XCTAssertEqual(doc.state, before)
        transaction(doc) { canvas.finishText() }
        XCTAssertEqual(doc.state.quickMask, SelectionMask(editingRaster: preview)); XCTAssertEqual(doc.state.layers, before.layers)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, before)
        canvas.beginText(in: CGRect(x: 0, y: 0, width: 40, height: 20), color: .white)
        canvas.textEditor!.textView.string = "cancel"; canvas.finishText(apply: false)
        XCTAssertEqual(doc.state, before); XCTAssertTrue(doc.undoManager!.canRedo)
    }

    func testRedOverlayRespectsCoverageAndOrientationWithoutEnteringArtwork() throws {
        let (doc, canvas, window) = setup(); defer { window.close(); doc.close() }
        var coverage = Data(repeating: 0, count: 80 * 60)
        coverage[2 * 80 + 3] = 255; coverage[2 * 80 + 4] = 128
        doc.state.selection = SelectionMask(width: 80, height: 60, coverage: coverage)
        transaction(doc) { canvas.toggleQuickMask() }
        let displayed = try Raster(image: canvas.displayedComposite)
        XCTAssertEqual(displayed.pixel(x: 3, y: 2).r, 255)
        XCTAssertLessThan(displayed.pixel(x: 3, y: 2).g, 180)
        XCTAssertGreaterThan(displayed.pixel(x: 4, y: 2).g, displayed.pixel(x: 3, y: 2).g)
        XCTAssertEqual(displayed.pixel(x: 3, y: 57), .white)
        XCTAssertEqual(try Raster(image: doc.composite).pixel(x: 3, y: 2), .white)
    }

    func testColdHistoryStoresQuickMaskAndLocalMarqueeAndRestoresMode() throws {
        let (doc, canvas, window) = setup(); defer { window.close(); doc.close() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        doc.historyCache = HistoryTileCache(memoryBudget: 0, root: root)
        transaction(doc) { canvas.toggleQuickMask() }
        transaction(doc) { drag(canvas, .eraser, [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 10)]) }
        transaction(doc) { drag(canvas, .selection, [CGPoint(x: -10, y: -10), CGPoint(x: 40, y: 30)]) }
        let expected = doc.state
        transaction(doc) { canvas.toggleQuickMask() }
        doc.historyCache.flush(); XCTAssertEqual(doc.historyCache.statistics.residentBytes, 0)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, expected)
        doc.undoManager!.redo(); XCTAssertNil(doc.state.quickMask); XCTAssertEqual(doc.state.selection, expected.quickMask)
    }

    func testResizeScaleCropAndResolutionResamplingTransformBothMasks() throws {
        let (doc, canvas, window) = setup(); defer { window.close(); doc.close() }
        doc.state.selection = .rectangle(CGRect(x: 10, y: 10, width: 20, height: 15), width: 80, height: 60)
        transaction(doc) { canvas.toggleQuickMask() }
        doc.state.selection = .rectangle(CGRect(x: 5, y: 5, width: 35, height: 30), width: 80, height: 60)
        let before = doc.state
        try transaction(doc) { try doc.applySize(CanvasSizePlan(width: 100, height: 80, offsetX: 5, offsetY: 10), mode: .resize, smooth: false) }
        XCTAssertEqual(doc.state.quickMask?.bounds, CGRect(x: 15, y: 20, width: 20, height: 15))
        XCTAssertEqual(doc.state.selection?.bounds, CGRect(x: 10, y: 15, width: 35, height: 30))
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, before)
        try transaction(doc) { try doc.applySize(CanvasSizePlan(width: 160, height: 120, offsetX: 0, offsetY: 0), mode: .scale, smooth: false) }
        XCTAssertEqual(doc.state.quickMask?.bounds, CGRect(x: 20, y: 20, width: 40, height: 30))
        doc.undoManager!.undo()
        try transaction(doc) { try doc.applyColorSettings(.standard, resolution: ImageResolution(x: 144, y: 144), pixelSize: CGSize(width: 160, height: 120), smooth: false) }
        XCTAssertEqual(doc.state.quickMask?.width, 160); XCTAssertEqual(doc.state.selection?.width, 160)
        doc.undoManager!.undo()
        let editor = EditorWindowController(document: doc); defer { editor.window?.close() }
        transaction(doc) { editor.cropToSelection() }
        XCTAssertEqual(doc.state.quickMask?.bounds, CGRect(x: 5, y: 5, width: 20, height: 15))
        XCTAssertEqual(doc.state.quickMask?.width, 35); XCTAssertNil(doc.state.selection)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, before)
    }

    func testPasteAndDeleteOnlyEditMaskInsideLocalSelection() throws {
        let (doc, canvas, window) = setup(); defer { window.close(); doc.close() }
        transaction(doc) { canvas.toggleQuickMask() }; let layers = doc.state.layers
        doc.state.selection = .rectangle(CGRect(x: 30, y: 20, width: 10, height: 10), width: 80, height: 60)
        try transaction(doc) { try doc.pasteQuickMask(Raster(width: 40, height: 40, color: .maskBlack)) }
        XCTAssertEqual(doc.state.quickMask?.value(x: 35, y: 25), 0)
        XCTAssertEqual(doc.state.quickMask?.value(x: 45, y: 25), 255)
        transaction(doc) { canvas.changeSelection(nil, name: "Deselect") }
        transaction(doc) { canvas.deletePixels() }
        XCTAssertTrue(doc.state.quickMask!.isEmpty); XCTAssertEqual(doc.state.layers, layers)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state.quickMask?.value(x: 45, y: 25), 255)
    }

    func testKeyboardShortcutPaletteAndRailTrackModeAndRestoreColors() throws {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 80, height: 60); doc.undoManager!.groupsByEvent = false
        let editor = EditorWindowController(document: doc); defer { editor.window?.close(); doc.close() }
        let original = editor.canvas.color
        let q = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: editor.window!.windowNumber,
                                 context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12)!
        transaction(doc) { editor.canvas.keyDown(with: q) }
        XCTAssertTrue(doc.state.isQuickMask); XCTAssertEqual(editor.canvas.color, .maskBlack)
        transaction(doc) { editor.canvas.keyDown(with: q) }
        XCTAssertFalse(doc.state.isQuickMask); XCTAssertEqual(editor.canvas.color, original)
        XCTAssertEqual(PaintTool.lasso.key, "a")
        XCTAssertFalse(PaintTool.allCases.contains { $0.key == "q" })
    }
}
