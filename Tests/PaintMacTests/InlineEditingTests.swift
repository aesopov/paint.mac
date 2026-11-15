import XCTest
import AppKit
@testable import PaintMac

final class InlineEditingTests: XCTestCase {
    private func editor(width: Int = 400, height: Int = 300) -> (PaintDocument, EditorWindowController) {
        _ = NSApplication.shared
        let doc = PaintDocument()
        doc.state = DocumentState(width: width, height: height)
        doc.makeWindowControllers()
        let editor = doc.windowControllers[0] as! EditorWindowController
        editor.window!.contentView!.layoutSubtreeIfNeeded()
        editor.canvas.setZoom(1)
        return (doc, editor)
    }
    private func mouse(_ type: NSEvent.EventType, _ point: CGPoint, canvas: CanvasView, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let p = CGPoint(x: canvas.imageRect.minX + point.x * canvas.zoom, y: canvas.imageRect.minY + point.y * canvas.zoom)
        return NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: flags,
                                 timestamp: 0, windowNumber: canvas.window!.windowNumber, context: nil,
                                 eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    private func bounds(of raster: Raster) -> CGRect {
        var result = CGRect.null
        for y in 0..<raster.height {
            for x in 0..<raster.width where raster.pixel(x: x, y: y).a > 0 {
                result = result.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return result
    }

    func testClickDeselectsEverySelectionToolAndCanBeUndone() {
        let (doc, editor) = editor()
        defer { doc.close() }
        let canvas = editor.canvas
        doc.undoManager?.groupsByEvent = false
        let original = SelectionMask.rectangle(CGRect(x: 10, y: 10, width: 60, height: 40), width: 400, height: 300)
        for tool in [PaintTool.selection, .ellipseSelect, .lasso] {
            for mode in SelectionMode.allCases {
                canvas.tool = tool; canvas.selectionMode = mode; canvas.selection = original
                doc.undoManager?.beginUndoGrouping()
                // Noninteger coordinates exposed the previous integral zero-size rectangle bug.
                let p = CGPoint(x: 25.37, y: 30.81)
                canvas.mouseDown(with: mouse(.leftMouseDown, p, canvas: canvas))
                canvas.mouseUp(with: mouse(.leftMouseUp, p, canvas: canvas))
                doc.undoManager?.endUndoGrouping()
                XCTAssertNil(canvas.selection, "\(tool) \(mode)")
                doc.undoManager?.undo(); XCTAssertEqual(canvas.selection, original)
            }
        }
    }

    func testSharpConstrainedShapesHaveEqualPixelBoundsInAllQuadrants() {
        let (doc, editor) = editor()
        defer { doc.close() }
        let canvas = editor.canvas
        canvas.smooth = false; canvas.color = .black
        for tool in [PaintTool.rectangle, .ellipse, .line] {
            canvas.tool = tool
            for thickness in [1.0, 2, 9, 10] {
                canvas.brushSize = thickness
                for sx in [-1.0, 1] {
                    for sy in [-1.0, 1] {
                        doc.state.layers[doc.state.activeIndex].raster = Raster(width: 400, height: 300)
                        let a = CGPoint(x: 180.22, y: 150.87)
                        let b = CGPoint(x: a.x + sx * 99.7, y: a.y + sy * 98.9)
                        canvas.mouseDown(with: mouse(.leftMouseDown, a, canvas: canvas))
                        canvas.mouseDragged(with: mouse(.leftMouseDragged, b, canvas: canvas, flags: .shift))
                        canvas.mouseUp(with: mouse(.leftMouseUp, b, canvas: canvas, flags: .shift))
                        let drawn = bounds(of: doc.state.activeLayer.raster)
                        XCTAssertFalse(drawn.isNull)
                        XCTAssertEqual(drawn.width, drawn.height, "\(tool) \(thickness) \(sx),\(sy): \(drawn)")
                    }
                }
            }
        }
        canvas.tool = .selection
        let a = CGPoint(x: 40.2, y: 30.8), b = CGPoint(x: 139.9, y: 129.1)
        canvas.mouseDown(with: mouse(.leftMouseDown, a, canvas: canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, b, canvas: canvas, flags: .control))
        canvas.mouseUp(with: mouse(.leftMouseUp, b, canvas: canvas, flags: .control))
        XCTAssertEqual(canvas.selection?.bounds.width, canvas.selection?.bounds.height)
    }

    func testInlineTextDragTypeMoveResizeZoomApplyUndoAndCancel() throws {
        let (doc, editor) = editor()
        defer { doc.close() }
        let canvas = editor.canvas
        editor.selectTool(.text)
        canvas.textStyle.size = 24; canvas.smooth = false
        let a = CGPoint(x: 30, y: 50), b = CGPoint(x: 220, y: 160)
        canvas.mouseDown(with: mouse(.leftMouseDown, a, canvas: canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, b, canvas: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, b, canvas: canvas))
        let draft = try XCTUnwrap(canvas.textEditor)
        XCTAssertEqual(draft.imageBounds, CGRect(x: 30, y: 50, width: 190, height: 110))
        XCTAssertTrue(editor.window!.firstResponder === draft.textView)
        draft.textView.insertText("Hello\nПривет!", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(doc.isDocumentEdited, "Native close/quit must recognize a pending editor")
        XCTAssertThrowsError(try canvas.commitEditingWithoutPresentingError())
        XCTAssertNotNil(canvas.textEditor, "Autosave must leave the text editor open")
        XCTAssertEqual(doc.state.activeLayer.raster, Raster(width: 400, height: 300))
        // Exercise the actual move bar and resize grip rather than only the rectangle model.
        func dragHandle(_ label: String, dx: CGFloat, dy: CGFloat) throws {
            let handle = try XCTUnwrap(draft.subviews.first { $0.accessibilityLabel() == label })
            let start = handle.convert(CGPoint(x: 5, y: 5), to: nil)
            func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                                   windowNumber: editor.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            }
            handle.mouseDown(with: event(.leftMouseDown, start))
            handle.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: start.x + dx, y: start.y - dy)))
            handle.mouseUp(with: event(.leftMouseUp, CGPoint(x: start.x + dx, y: start.y - dy)))
        }
        try dragHandle("Move text box", dx: 40, dy: 30)
        XCTAssertEqual(draft.imageBounds.origin, CGPoint(x: 70, y: 80))
        try dragHandle("Resize text box", dx: 30, dy: 20)
        XCTAssertEqual(draft.imageBounds.size, CGSize(width: 220, height: 130))
        let box = draft.imageBounds
        let wheel = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 10, wheel2: 0, wheel3: 0)!)!
        draft.textView.scrollWheel(with: wheel)
        XCTAssertNotEqual(canvas.zoom, 1, "Wheel over a text box must still zoom the canvas")
        XCTAssertNotNil(canvas.textEditor)
        canvas.setZoom(1.7)
        XCTAssertEqual(draft.imageBounds, box)
        XCTAssertEqual(draft.textView.font!.pointSize, 24, accuracy: 0.01)
        canvas.setZoom(1)
        if let path = ProcessInfo.processInfo.environment["PAINTMAC_INLINE_PREVIEW_PATH"] {
            let root = editor.window!.contentView!; root.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(canvas.snapshot(of: root))
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
        doc.undoManager?.groupsByEvent = false
        doc.undoManager?.beginUndoGrouping()
        let apply = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                     windowNumber: editor.window!.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        draft.textView.keyDown(with: apply)
        doc.undoManager?.endUndoGrouping()
        XCTAssertNil(canvas.textEditor)
        let painted = doc.state.activeLayer.raster
        let ink = bounds(of: painted)
        XCTAssertFalse(ink.isNull); XCTAssertTrue(box.contains(ink))
        let paintedBytes = painted.bytes
        XCTAssertTrue(stride(from: 3, to: paintedBytes.count, by: 4).allSatisfy { paintedBytes[$0] == 0 || paintedBytes[$0] == 255 })
        doc.undoManager?.undo(); XCTAssertEqual(doc.state.activeLayer.raster, Raster(width: 400, height: 300))
        doc.undoManager?.redo(); XCTAssertEqual(doc.state.activeLayer.raster, painted)
        canvas.beginText(in: box, color: .black)
        canvas.textEditor!.textView.insertText("cancel", replacementRange: NSRange(location: NSNotFound, length: 0))
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: editor.window!.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        canvas.textEditor!.textView.keyDown(with: escape)
        XCTAssertNil(canvas.textEditor); XCTAssertEqual(doc.state.activeLayer.raster, painted)
    }

    func testNativeCloseCommitsAndSavesPendingText() throws {
        let (doc, editor) = editor()
        defer { doc.close() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("close-test.paintmac")
        try doc.write(to: url, ofType: PaintDocument.typeName)
        doc.fileURL = url; doc.updateChangeCount(.changeCleared)
        editor.canvas.beginText(in: CGRect(x: 20, y: 25, width: 160, height: 90), color: .black)
        editor.canvas.textEditor!.textView.insertText("Close test", replacementRange: NSRange(location: NSNotFound, length: 0))
        let closed = expectation(description: "Native close check")
        let delegate = CloseProbe { accepted in
            XCTAssertTrue(accepted); closed.fulfill()
        }
        doc.canClose(withDelegate: delegate, shouldClose: #selector(CloseProbe.document(_:shouldClose:contextInfo:)), contextInfo: nil)
        wait(for: [closed], timeout: 5)
        XCTAssertNil(editor.canvas.textEditor)
        XCTAssertFalse(bounds(of: doc.state.activeLayer.raster).isNull)
        let saved = try PaintDocument(contentsOf: url, ofType: PaintDocument.typeName)
        XCTAssertEqual(saved.state.activeLayer.raster, doc.state.activeLayer.raster)
    }

    func testTextWrapsAndClipsToRectangleAndPendingTextSurvivesLayerChangesAndExport() throws {
        let (doc, editor) = editor()
        defer { doc.close() }
        let canvas = editor.canvas
        var raster = Raster(width: 400, height: 300)
        let box = CGRect(x: 20, y: 25, width: 90, height: 70)
        raster.drawText("Wrapped text with more words\nand lines", in: box, font: .systemFont(ofSize: 24), color: .black, opacity: 1, antialias: true, selection: nil)
        let ink = bounds(of: raster)
        XCTAssertFalse(ink.isNull); XCTAssertTrue(box.contains(ink)); XCTAssertGreaterThan(ink.height, 30)
        let originalID = doc.state.activeID
        canvas.beginText(in: box, color: .black)
        canvas.textEditor!.textView.insertText("Layer", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.addLayer()
        XCTAssertNil(canvas.textEditor)
        XCTAssertNotEqual(doc.state.activeID, originalID)
        XCTAssertFalse(bounds(of: doc.state.layers.first { $0.id == originalID }!.raster).isNull)
        XCTAssertTrue(bounds(of: doc.state.activeLayer.raster).isNull)
        canvas.beginText(in: box, color: .black)
        canvas.textEditor!.textView.insertText("Export", replacementRange: NSRange(location: NSNotFound, length: 0))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try doc.export(to: url, jpeg: false)
        XCTAssertNil(canvas.textEditor); XCTAssertFalse(bounds(of: doc.state.activeLayer.raster).isNull)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}

private final class CloseProbe: NSObject {
    let callback: (Bool) -> Void
    init(_ callback: @escaping (Bool) -> Void) { self.callback = callback }
    @objc func document(_ doc: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) { callback(shouldClose) }
}
