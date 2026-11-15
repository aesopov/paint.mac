import XCTest
import AppKit
@testable import PaintMac

final class GroupPaintingTests: XCTestCase {
    private let blue = PixelColor(r: 20, g: 80, b: 230)
    private let red = PixelColor(r: 230, g: 40, b: 30)
    private func editor() -> (PaintDocument, CanvasView) {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 80, height: 60)
        var group = PaintLayer(name: "Folder", raster: Raster(width: 80, height: 60, color: .white))
        group.isGroup = true; group.expanded = false; group.opacity = 0.5
        var child = PaintLayer(name: "Existing", raster: Raster(width: 80, height: 60))
        child.parentID = group.id
        doc.state.layers = [doc.state.layers[0], child, group]; doc.state.activeID = group.id
        doc.makeWindowControllers()
        let editor = doc.windowControllers[0] as! EditorWindowController
        editor.window!.contentView!.layoutSubtreeIfNeeded(); editor.canvas.setZoom(2)
        editor.canvas.color = blue; editor.canvas.alternateColor = red
        editor.canvas.brushSize = 4; editor.canvas.smooth = false
        doc.undoManager!.groupsByEvent = false
        return (doc, editor.canvas)
    }
    private func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, canvas: CanvasView) -> NSEvent {
        let point = CGPoint(x: canvas.imageRect.minX + x * canvas.zoom, y: canvas.imageRect.minY + y * canvas.zoom)
        return NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                 windowNumber: canvas.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    private func transaction(_ doc: PaintDocument, _ body: () -> Void) {
        doc.undoManager!.beginUndoGrouping(); body(); doc.undoManager!.endUndoGrouping()
    }
    private func draw(_ canvas: CanvasView, right: Bool = false) {
        canvas.mouseDown(with: event(right ? .rightMouseDown : .leftMouseDown, 12, 10, canvas: canvas))
        canvas.mouseDragged(with: event(right ? .rightMouseDragged : .leftMouseDragged, 60, 42, canvas: canvas))
        canvas.mouseUp(with: event(right ? .rightMouseUp : .leftMouseUp, 60, 42, canvas: canvas))
    }
    func testPaintingGroupCreatesChildWithStableShapePreviewsAndOneUndo() throws {
        for tool in [PaintTool.brush, .fill, .line, .rectangle, .ellipse] {
            for right in [false, true] {
                let (doc, canvas) = editor(); defer { doc.close() }
                let before = doc.state, groupID = before.activeID
                canvas.tool = tool; canvas.fillShapes = true
                transaction(doc) {
                    canvas.mouseDown(with: event(right ? .rightMouseDown : .leftMouseDown, 12, 10, canvas: canvas))
                    canvas.mouseDragged(with: event(right ? .rightMouseDragged : .leftMouseDragged, 60, 42, canvas: canvas))
                    let preview = doc.state
                    if [.line, .rectangle, .ellipse].contains(tool) {
                        canvas.mouseDragged(with: event(right ? .rightMouseDragged : .leftMouseDragged, 60, 42, canvas: canvas))
                        XCTAssertEqual(doc.state, preview)
                    }
                    canvas.mouseUp(with: event(right ? .rightMouseUp : .leftMouseUp, 60, 42, canvas: canvas))
                }
                let after = doc.state
                XCTAssertEqual(after.layers.count, before.layers.count + 1)
                XCTAssertEqual(after.activeLayer.parentID, groupID); XCTAssertTrue(after.activeLayer.isPixelLayer)
                XCTAssertEqual(after.layers.filter { $0.id != after.activeID }.map(\.raster), before.layers.map(\.raster))
                XCTAssertTrue(after.layers.first { $0.id == groupID }!.expanded)
                XCTAssertTrue(stride(from: 3, to: after.activeLayer.raster.bytes.count, by: 4).contains { after.activeLayer.raster.bytes[$0] != 0 })
                if tool != .fill { XCTAssertEqual(after.activeLayer.raster.pixel(x: 1, y: 1).a, 0, "Never copy the group's placeholder pixels") }
                let ink = after.activeLayer.raster.pixel(x: tool == .fill ? 0 : 12, y: tool == .fill ? 0 : 10)
                if tool == .brush || tool == .fill || tool == .line { XCTAssertEqual(ink, right ? red : blue) }
                try after.validateLayerTree()
                doc.undoManager!.undo(); XCTAssertEqual(doc.state, before); XCTAssertFalse(doc.undoManager!.canUndo)
                doc.undoManager!.redo(); XCTAssertEqual(doc.state, after)
            }
        }
    }
    func testCancellationAndEmptyGesturesRestoreGroupAndPreserveRedo() {
        for tool in [PaintTool.brush, .fill, .line, .rectangle, .ellipse] {
            let (doc, canvas) = editor(); defer { doc.close() }
            canvas.tool = tool
            let before = doc.state
            transaction(doc) { draw(canvas) }; doc.undoManager!.undo(); XCTAssertTrue(doc.undoManager!.canRedo)
            canvas.mouseDown(with: event(.leftMouseDown, 12, 10, canvas: canvas))
            canvas.mouseDragged(with: event(.leftMouseDragged, 60, 42, canvas: canvas))
            canvas.mouseDown(with: event(.rightMouseDown, 40, 30, canvas: canvas))
            canvas.mouseUp(with: event(.leftMouseUp, 60, 42, canvas: canvas))
            canvas.mouseUp(with: event(.rightMouseUp, 40, 30, canvas: canvas))
            XCTAssertEqual(doc.state, before); XCTAssertTrue(doc.undoManager!.canRedo); XCTAssertFalse(doc.undoManager!.canUndo)
            doc.state.selection = .empty(width: 80, height: 60)
            let empty = doc.state
            draw(canvas)
            XCTAssertEqual(doc.state, empty); XCTAssertTrue(doc.undoManager!.canRedo); XCTAssertFalse(doc.undoManager!.canUndo)
        }
        let (doc, canvas) = editor(); defer { doc.close() }
        let before = doc.state
        canvas.tool = .rectangle
        canvas.mouseDown(with: event(.leftMouseDown, 12, 10, canvas: canvas))
        canvas.mouseUp(with: event(.leftMouseUp, 12, 10, canvas: canvas))
        XCTAssertEqual(doc.state, before); XCTAssertFalse(doc.undoManager!.canUndo)
    }
    func testGroupMaskRemainsDirectPaintTargetAndOtherToolsDoNotCreateLayers() throws {
        let (doc, canvas) = editor(); defer { doc.close() }
        var message = ""; canvas.onStatus = { message = $0 }
        canvas.tool = .eraser; let before = doc.state
        draw(canvas); XCTAssertEqual(doc.state, before); XCTAssertTrue(message.contains("Select an image layer"))
        canvas.tool = .selection
        transaction(doc) { draw(canvas) }
        XCTAssertEqual(doc.state.layers, before.layers)
        doc.state.selection = nil; doc.state.layers[doc.state.activeIndex].mask = .all(width: 80, height: 60); doc.state.editingMask = true
        let masked = doc.state
        canvas.tool = .brush; canvas.color = .maskBlack
        transaction(doc) { draw(canvas) }
        XCTAssertEqual(doc.state.layers.count, masked.layers.count); XCTAssertEqual(doc.state.activeID, masked.activeID)
        XCTAssertNotEqual(doc.state.activeLayer.mask, masked.activeLayer.mask)
        XCTAssertEqual(doc.state.activeLayer.raster, masked.activeLayer.raster)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, masked)
    }
    func testLockedHiddenAndFullGroupsRejectPaintingWithoutChanges() {
        for mode in 0..<3 {
            let (doc, canvas) = editor(); defer { doc.close() }
            if mode == 0 { doc.state.layers[doc.state.activeIndex].isLocked = true }
            if mode == 1 { doc.state.layers[doc.state.activeIndex].visible = false }
            if mode == 2 {
                for i in doc.state.layers.count..<32 {
                    doc.state.layers.insert(PaintLayer(name: "Extra \(i)", raster: Raster(width: 80, height: 60)), at: 0)
                }
            }
            let before = doc.state; canvas.tool = .brush
            draw(canvas); XCTAssertEqual(doc.state, before); XCTAssertFalse(doc.undoManager!.canUndo)
        }
    }
    func testThumbnailShowsTransparencyCheckerButOpaquePixelsCoverIt() throws {
        _ = NSApplication.shared
        func snapshot(_ raster: Raster) throws -> Raster {
            let layer = PaintLayer(name: "Preview", raster: raster)
            let button = LayerThumbnailButton(layer: layer, mask: false, selected: false, target: self, action: #selector(NSObject.description))
            button.frame = NSRect(x: 0, y: 0, width: 44, height: 36)
            let window = NSWindow(contentRect: button.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = button; defer { window.close() }
            let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: bitmap)
            return try Raster(image: XCTUnwrap(bitmap.cgImage))
        }
        let clear = try snapshot(Raster(width: 40, height: 32))
        let opaque = try snapshot(Raster(width: 40, height: 32, color: blue))
        let sx = clear.width / 44, sy = clear.height / 36
        XCTAssertNotEqual(clear.pixel(x: 12 * sx, y: 16 * sy), clear.pixel(x: 16 * sx, y: 16 * sy))
        let covered = opaque.pixel(x: 12 * sx, y: 16 * sy)
        XCTAssertEqual(covered, opaque.pixel(x: 16 * sx, y: 16 * sy), "Opaque image pixels must cover both checker shades")
        XCTAssertEqual(covered.a, 255)
        // AppKit color management can round a rendered thumbnail by one level.
        XCTAssertLessThanOrEqual(abs(Int(covered.r) - Int(blue.r)), 1)
        XCTAssertLessThanOrEqual(abs(Int(covered.g) - Int(blue.g)), 1)
        XCTAssertLessThanOrEqual(abs(Int(covered.b) - Int(blue.b)), 1)
    }
}
