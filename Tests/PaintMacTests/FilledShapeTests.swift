import XCTest
import AppKit
@testable import PaintMac

final class FilledShapeTests: XCTestCase {
    private let red = PixelColor(r: 255, g: 0, b: 0)
    private let blue = PixelColor(r: 0, g: 0, b: 255)
    private let rect = CGRect(x: 20, y: 15, width: 60, height: 40)

    private func alphas(_ raster: Raster) -> [UInt8] {
        { let pixels = raster.bytes; return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] } }()
    }

    func testFilledRectangleAndEllipseKeepOutlineFillAndTopLeftCoordinates() {
        for ellipse in [false, true] {
            var raster = Raster(width: 100, height: 100)
            raster.strokeShape(in: rect, ellipse: ellipse, size: 6, color: red, opacity: 1,
                               clip: nil, antialias: false, fillColor: blue)
            XCTAssertEqual(raster.pixel(x: 50, y: 15), red)
            XCTAssertEqual(raster.pixel(x: 50, y: 35), blue)
            XCTAssertEqual(raster.pixel(x: 10, y: 35), .clear)
            XCTAssertEqual(raster.pixel(x: 50, y: 75), .clear)
            XCTAssertTrue(alphas(raster).allSatisfy { $0 == 0 || $0 == 255 })
            if ellipse { XCTAssertEqual(raster.pixel(x: 20, y: 15), .clear) }
            var outline = Raster(width: 100, height: 100)
            outline.strokeShape(in: rect, ellipse: ellipse, size: 6, color: red, opacity: 1, clip: nil)
            XCTAssertEqual(outline.pixel(x: 50, y: 35), .clear)
        }
    }

    func testOpacityAppliesOnceAcrossFillOutlineAndFeatheredSelection() {
        for ellipse in [false, true] {
            for coverage: UInt8 in [128, 255] {
                let selection = SelectionMask(width: 100, height: 100, coverage: Data(repeating: coverage, count: 10_000))
                var raster = Raster(width: 100, height: 100)
                raster.strokeShape(in: rect, ellipse: ellipse, size: 6, color: red, opacity: 0.5,
                                   clip: nil, selection: selection, antialias: false, fillColor: blue)
                let expected: UInt8 = coverage == 255 ? 128 : 64
                XCTAssertEqual(raster.pixel(x: 50, y: 15).a, expected)
                XCTAssertEqual(raster.pixel(x: 50, y: 17).a, expected, "Stroke over fill must not accumulate opacity")
                XCTAssertEqual(raster.pixel(x: 50, y: 35).a, expected)
                XCTAssertLessThanOrEqual(alphas(raster).max()!, expected)
            }
        }
    }

    func testSmoothEdgesColorAlphaAndSelectionHoles() {
        let selection = SelectionMask.all(width: 100, height: 100).combined(with:
            .rectangle(CGRect(x: 45, y: 30, width: 10, height: 10), width: 100, height: 100), mode: .subtract)
        var raster = Raster(width: 100, height: 100)
        raster.strokeShape(in: rect, ellipse: true, size: 6, color: red, opacity: 1,
                           clip: CGRect(x: 0, y: 0, width: 65, height: 100), selection: selection,
                           fillColor: PixelColor(r: 0, g: 0, b: 255, a: 128))
        XCTAssertEqual(raster.pixel(x: 40, y: 35).a, 128)
        XCTAssertEqual(raster.pixel(x: 50, y: 15), red)
        XCTAssertEqual(raster.pixel(x: 50, y: 35), .clear)
        XCTAssertEqual(raster.pixel(x: 70, y: 35), .clear)
        XCTAssertTrue(alphas(raster).contains { $0 > 0 && $0 < 128 })
    }

    private func canvas() -> (PaintDocument, CanvasView, NSWindow) {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 100, height: 100)
        let canvas = CanvasView(document: doc)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        canvas.setZoom(1); canvas.color = red; canvas.alternateColor = blue
        canvas.brushSize = 6; canvas.smooth = false; canvas.fillShapes = true
        doc.undoManager!.groupsByEvent = false
        return (doc, canvas, window)
    }

    private func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, canvas: CanvasView) -> NSEvent {
        let point = CGPoint(x: canvas.imageRect.minX + x * canvas.zoom, y: canvas.imageRect.minY + y * canvas.zoom)
        return NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                                 timestamp: 0, windowNumber: canvas.window!.windowNumber, context: nil,
                                 eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    func testBothButtonsSwapColorsWithStablePreviewSingleUndoAndCancellation() {
        for tool in [PaintTool.rectangle, .ellipse] {
            for right in [false, true] {
                let (doc, canvas, window) = canvas(); defer { window.close() }
                canvas.tool = tool; canvas.brushOpacity = 0.5
                let before = doc.state
                let down: NSEvent.EventType = right ? .rightMouseDown : .leftMouseDown
                let drag: NSEvent.EventType = right ? .rightMouseDragged : .leftMouseDragged
                let up: NSEvent.EventType = right ? .rightMouseUp : .leftMouseUp
                doc.undoManager!.beginUndoGrouping()
                canvas.mouseDown(with: event(down, 20, 15, canvas: canvas))
                canvas.mouseDragged(with: event(drag, 80, 55, canvas: canvas))
                let preview = doc.state
                canvas.mouseDragged(with: event(drag, 80, 55, canvas: canvas))
                XCTAssertEqual(doc.state, preview)
                canvas.mouseUp(with: event(up, 80, 55, canvas: canvas))
                doc.undoManager!.endUndoGrouping()
                let image = doc.state.activeLayer.raster
                XCTAssertEqual(image.pixel(x: 50, y: 15).r, right ? 0 : 255)
                XCTAssertEqual(image.pixel(x: 50, y: 35).b, right ? 0 : 255)
                XCTAssertEqual(image.pixel(x: 50, y: 35).a, 128)
                doc.undoManager!.undo(); XCTAssertEqual(doc.state, before)
                XCTAssertFalse(doc.undoManager!.canUndo); XCTAssertTrue(doc.undoManager!.canRedo)
                // A canceled filled preview must leave the existing redo entry intact.
                canvas.mouseDown(with: event(down, 20, 15, canvas: canvas))
                canvas.mouseDragged(with: event(drag, 80, 55, canvas: canvas))
                canvas.mouseDown(with: event(right ? .leftMouseDown : .rightMouseDown, 50, 35, canvas: canvas))
                canvas.mouseUp(with: event(up, 80, 55, canvas: canvas))
                canvas.mouseUp(with: event(right ? .leftMouseUp : .rightMouseUp, 50, 35, canvas: canvas))
                XCTAssertEqual(doc.state, before); XCTAssertFalse(doc.undoManager!.canUndo)
                XCTAssertTrue(doc.undoManager!.canRedo)
                doc.undoManager!.redo(); XCTAssertEqual(doc.state, preview)
            }
        }
    }

    func testFilledShapesPaintMaskWithoutChangingLayerImage() {
        let (doc, canvas, window) = canvas(); defer { window.close() }
        doc.state.layers[doc.state.activeIndex].raster.fill(color: red)
        doc.state.layers[doc.state.activeIndex].mask = .all(width: 100, height: 100)
        doc.state.editingMask = true; canvas.tool = .rectangle
        canvas.color = .maskBlack; canvas.alternateColor = .white
        let original = doc.state
        doc.undoManager!.beginUndoGrouping()
        canvas.mouseDown(with: event(.leftMouseDown, 20, 15, canvas: canvas))
        canvas.mouseDragged(with: event(.leftMouseDragged, 80, 55, canvas: canvas))
        canvas.mouseUp(with: event(.leftMouseUp, 80, 55, canvas: canvas))
        doc.undoManager!.endUndoGrouping()
        XCTAssertEqual(doc.state.activeLayer.mask!.value(x: 50, y: 15), 0)
        XCTAssertEqual(doc.state.activeLayer.mask!.value(x: 50, y: 35), 255)
        XCTAssertEqual(doc.state.activeLayer.raster, original.activeLayer.raster)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, original)
    }

    private func views(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + views($0) } }

    func testFillOptionVisibilityPersistenceAndMinimumWindowLayoutInBothThemes() throws {
        let app = NSApplication.shared, oldAppearance = app.appearance
        defer { app.appearance = oldAppearance }
        let doc = PaintDocument(); doc.makeWindowControllers(); defer { doc.close() }
        let editor = doc.windowControllers[0] as! EditorWindowController
        let root = editor.window!.contentView!
        let popup = try XCTUnwrap(views(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Shape paint style" })
        XCTAssertFalse(editor.canvas.fillShapes); XCTAssertTrue(popup.isHidden)
        editor.selectTool(.rectangle); XCTAssertFalse(popup.isHidden)
        popup.selectItem(withTitle: "Outline & Fill"); _ = app.sendAction(popup.action!, to: popup.target, from: popup)
        XCTAssertTrue(editor.canvas.fillShapes)
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            app.appearance = NSAppearance(named: theme)
            editor.window!.setContentSize(CGSize(width: 960, height: 640))
            for tool in [PaintTool.ellipse, .rectangle, .line, .brush, .text, .selection] {
                editor.selectTool(tool); root.layoutSubtreeIfNeeded()
                XCTAssertEqual(popup.isHidden, tool != .rectangle && tool != .ellipse)
                XCTAssertTrue(editor.canvas.fillShapes); XCTAssertEqual(popup.titleOfSelectedItem, "Outline & Fill")
                if !popup.isHidden {
                    popup.scrollToVisible(popup.bounds); root.layoutSubtreeIfNeeded()
                    let clip = try XCTUnwrap(popup.enclosingScrollView?.contentView)
                    XCTAssertTrue(clip.bounds.contains(popup.convert(popup.bounds, to: clip)))
                }
            }
        }
        popup.selectItem(withTitle: "Outline Only"); _ = app.sendAction(popup.action!, to: popup.target, from: popup)
        XCTAssertFalse(editor.canvas.fillShapes)
        XCTAssertFalse(doc.undoManager!.canUndo)
    }

    func testThickFilledEllipsePreviewRemainsFast() {
        let original = Raster(width: 1200, height: 800)
        var output = original
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<20 {
            output = original
            output.strokeShape(in: CGRect(x: 250, y: 200, width: 700, height: 400), ellipse: true,
                               size: 300, color: red, opacity: 0.5, clip: nil, fillColor: blue)
        }
        let average = (ProcessInfo.processInfo.systemUptime - start) / 20
        print(String(format: "300 px filled ellipse preview: %.2f ms average", average * 1000))
        XCTAssertEqual(output.pixel(x: 600, y: 400).a, 128)
        XCTAssertLessThan(average, 0.2)
    }
}
