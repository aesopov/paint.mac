import XCTest
import AppKit
@testable import PaintMac

final class MiddleButtonPanTests: XCTestCase {
    private func editor() -> (PaintDocument, EditorWindowController) {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 360, height: 240)
        doc.makeWindowControllers()
        let editor = doc.windowControllers[0] as! EditorWindowController
        editor.window!.contentView!.layoutSubtreeIfNeeded(); editor.canvas.setZoom(1)
        return (doc, editor)
    }
    private func event(_ type: NSEvent.EventType, at point: CGPoint, canvas: CanvasView, button: Int64 = 2) -> NSEvent {
        let location = canvas.convert(point, to: nil)
        let base = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                     windowNumber: 0, context: nil,
                                     eventNumber: 1, clickCount: 1, pressure: 1)!
        // AppKit's mouseEvent factory defaults to button 0 even for otherMouse
        // events. Set the documented CGEvent field to create real middle input.
        let cg = base.cgEvent!
        cg.setIntegerValueField(.mouseEventButtonNumber, value: button)
        let result = NSEvent(cgEvent: cg)!
        XCTAssertEqual(result.buttonNumber, Int(button))
        XCTAssertEqual(result.locationInWindow.x, location.x, accuracy: 0.001)
        XCTAssertEqual(result.locationInWindow.y, location.y, accuracy: 0.001)
        return result
    }

    func testMiddleDragPansWithEveryToolWithoutEditingOrChangingZoom() {
        let (doc, editor) = editor()
        defer { doc.close() }
        let canvas = editor.canvas, original = doc.state
        for tool in PaintTool.allCases where tool != .crop {
            editor.selectTool(tool)
            for zoom in [0.5, 2.0] {
                canvas.setZoom(zoom)
                let before = canvas.imageRect
                // Start in the workspace outside the image, which must pan too.
                let start = CGPoint(x: 5, y: 5), end = CGPoint(x: 42, y: 28)
                canvas.otherMouseDown(with: event(.otherMouseDown, at: start, canvas: canvas))
                canvas.otherMouseDragged(with: event(.otherMouseDragged, at: end, canvas: canvas))
                canvas.otherMouseUp(with: event(.otherMouseUp, at: end, canvas: canvas))
                XCTAssertEqual(canvas.imageRect.minX, before.minX + 37, accuracy: 0.001, "\(tool)")
                XCTAssertEqual(canvas.imageRect.minY, before.minY + 23, accuracy: 0.001, "\(tool)")
                XCTAssertEqual(canvas.zoom, zoom)
                XCTAssertEqual(canvas.tool, tool)
                XCTAssertEqual(doc.state, original)
                XCTAssertNil(canvas.textEditor)
                XCTAssertFalse(doc.undoManager!.canUndo)
            }
        }
        // Side buttons aren't a pan gesture or a painting command.
        let before = canvas.imageRect
        canvas.otherMouseDown(with: event(.otherMouseDown, at: CGPoint(x: 5, y: 5), canvas: canvas, button: 3))
        canvas.otherMouseDragged(with: event(.otherMouseDragged, at: CGPoint(x: 60, y: 50), canvas: canvas, button: 3))
        canvas.otherMouseUp(with: event(.otherMouseUp, at: CGPoint(x: 60, y: 50), canvas: canvas, button: 3))
        XCTAssertEqual(canvas.imageRect, before)
    }

    func testMiddlePanOverTextInputAndHandlePreservesDraftAndFocus() throws {
        let (doc, editor) = editor()
        defer { doc.close() }
        let canvas = editor.canvas, original = doc.state
        editor.selectTool(.text)
        canvas.beginText(in: CGRect(x: 20, y: 20, width: 200, height: 100), color: .black)
        let draft = try XCTUnwrap(canvas.textEditor)
        draft.textView.insertText("Keep editing", replacementRange: NSRange(location: NSNotFound, length: 0))
        let box = draft.imageBounds, preview = canvas.textPreviewRaster
        let moveHandle = try XCTUnwrap(draft.subviews.first { $0 !== draft.textView })
        for target in [draft.textView as NSView, draft, moveHandle] {
            let before = canvas.imageRect
            target.otherMouseDown(with: event(.otherMouseDown, at: CGPoint(x: 100, y: 100), canvas: canvas))
            target.otherMouseDragged(with: event(.otherMouseDragged, at: CGPoint(x: 130, y: 120), canvas: canvas))
            target.otherMouseUp(with: event(.otherMouseUp, at: CGPoint(x: 130, y: 120), canvas: canvas))
            XCTAssertEqual(canvas.imageRect.minX, before.minX + 30, accuracy: 0.001)
            XCTAssertEqual(canvas.imageRect.minY, before.minY + 20, accuracy: 0.001)
            XCTAssertTrue(canvas.textEditor === draft)
            XCTAssertTrue(editor.window!.firstResponder === draft.textView)
            XCTAssertEqual(draft.imageBounds, box)
            XCTAssertEqual(canvas.textPreviewRaster, preview)
            XCTAssertEqual(doc.state, original)
        }
        draft.textView.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(draft.textView.string, "Keep editing!")
        canvas.finishText(apply: false)
    }

    func testMiddleButtonDuringStrokeDoesNotInterruptOrFinishDrawing() {
        let (doc, editor) = editor()
        defer { doc.close() }
        let canvas = editor.canvas
        doc.undoManager?.groupsByEvent = false; doc.undoManager?.beginUndoGrouping()
        let start = CGPoint(x: canvas.imageRect.minX + 20, y: canvas.imageRect.minY + 20)
        canvas.mouseDown(with: event(.leftMouseDown, at: start, canvas: canvas, button: 0))
        let preview = doc.state, rect = canvas.imageRect
        canvas.otherMouseDown(with: event(.otherMouseDown, at: start, canvas: canvas))
        canvas.otherMouseDragged(with: event(.otherMouseDragged, at: CGPoint(x: start.x + 40, y: start.y), canvas: canvas))
        canvas.otherMouseUp(with: event(.otherMouseUp, at: start, canvas: canvas))
        XCTAssertEqual(doc.state, preview); XCTAssertEqual(canvas.imageRect, rect)
        let end = CGPoint(x: start.x + 50, y: start.y)
        canvas.mouseDragged(with: event(.leftMouseDragged, at: end, canvas: canvas, button: 0))
        canvas.mouseUp(with: event(.leftMouseUp, at: end, canvas: canvas, button: 0))
        doc.undoManager?.endUndoGrouping()
        XCTAssertNotEqual(doc.state, preview)
        XCTAssertTrue(doc.undoManager!.canUndo)
        doc.undoManager?.undo()
        XCTAssertEqual(doc.state.activeLayer.raster, Raster(width: 360, height: 240))
    }
}
