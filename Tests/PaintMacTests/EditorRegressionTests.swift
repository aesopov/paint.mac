import XCTest
import AppKit
@testable import PaintMac

final class EditorRegressionTests: XCTestCase {
    private let red = PixelColor(r: 255, g: 0, b: 0)
    private let blue = PixelColor(r: 0, g: 0, b: 255)

    func testNativeShapeStrokePreservesCoordinatesClippingAndUniformOpacity() {
        var ellipse = Raster(width: 80, height: 60)
        ellipse.strokeShape(in: CGRect(x: 10, y: 8, width: 40, height: 20), ellipse: true,
                            size: 8, color: red, opacity: 0.5, clip: nil)
        XCTAssertEqual(ellipse.pixel(x: 30, y: 8).a, 128)
        XCTAssertEqual(ellipse.pixel(x: 10, y: 18).a, 128)
        XCTAssertEqual(ellipse.pixel(x: 30, y: 18), .clear)
        XCTAssertEqual(ellipse.pixel(x: 30, y: 52), .clear)
        XCTAssertLessThanOrEqual(ellipse.bytes.enumerated().filter { $0.offset % 4 == 3 }.map(\.element).max()!, 128)

        var rectangle = Raster(width: 80, height: 60)
        rectangle.strokeShape(in: CGRect(x: 10, y: 8, width: 40, height: 20), ellipse: false,
                              size: 8, color: blue, opacity: 1, clip: CGRect(x: 0, y: 0, width: 30, height: 15))
        XCTAssertEqual(rectangle.pixel(x: 20, y: 8), blue)
        XCTAssertEqual(rectangle.pixel(x: 40, y: 8), .clear)
        XCTAssertEqual(rectangle.pixel(x: 10, y: 28), .clear)
    }

    func testThickEllipsePreviewPerformance() {
        let original = Raster(width: 1200, height: 800)
        let rect = CGRect(x: 250, y: 200, width: 700, height: 400)
        var output = original
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<20 {
            output = original
            output.strokeShape(in: rect, ellipse: true, size: 300, color: blue, opacity: 0.5, clip: nil)
        }
        let average = (ProcessInfo.processInfo.systemUptime - start) / 20
        print(String(format: "300 px ellipse preview: %.2f ms average (1200 × 800)", average * 1000))
        XCTAssertGreaterThan(output.pixel(x: 600, y: 200).a, 0)
        // A broad regression ceiling, rather than an assertion tied to one machine's frame rate.
        XCTAssertLessThan(average, 0.2)

        if ProcessInfo.processInfo.environment["PAINTMAC_BENCHMARK_LEGACY"] == "1" {
            var legacy = original
            let points = (0...720).map { i in
                let angle = Double(i) / 720 * .pi * 2
                return CGPoint(x: rect.midX + cos(angle) * rect.width / 2,
                               y: rect.midY + sin(angle) * rect.height / 2)
            }
            let legacyStart = ProcessInfo.processInfo.systemUptime
            for i in 1..<points.count {
                legacy.stroke(from: points[i - 1], to: points[i], size: 300, color: blue, opacity: 0.5, erase: false, clip: nil)
            }
            let duration = ProcessInfo.processInfo.systemUptime - legacyStart
            print(String(format: "Legacy preview: %.2f ms; native path: %.2f ms; speedup: %.1f×", duration * 1000, average * 1000, duration / average))
            XCTAssertGreaterThan(legacy.pixel(x: 600, y: 200).a, 0)
        }
    }

    private func makeCanvas() -> (PaintDocument, CanvasView, NSWindow) {
        _ = NSApplication.shared
        let document = PaintDocument()
        document.state = DocumentState(width: 100, height: 100)
        let canvas = CanvasView(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        canvas.setZoom(1)
        canvas.color = red; canvas.alternateColor = blue; canvas.brushSize = 6
        return (document, canvas, window)
    }

    private func event(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat, canvas: CanvasView) -> NSEvent {
        let point = CGPoint(x: canvas.imageRect.minX + x * canvas.zoom, y: canvas.imageRect.minY + y * canvas.zoom)
        return NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                                 timestamp: 0, windowNumber: canvas.window!.windowNumber, context: nil,
                                 eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    func testLeftAndRightBrushGesturesUseIndependentColorsAndUndo() {
        let (document, canvas, window) = makeCanvas()
        defer { window.close() }
        document.undoManager?.groupsByEvent = false
        document.undoManager?.beginUndoGrouping()
        canvas.mouseDown(with: event(.leftMouseDown, x: 10, y: 10, canvas: canvas))
        canvas.mouseDragged(with: event(.leftMouseDragged, x: 30, y: 10, canvas: canvas))
        canvas.mouseUp(with: event(.leftMouseUp, x: 30, y: 10, canvas: canvas))
        document.undoManager?.endUndoGrouping()
        document.undoManager?.beginUndoGrouping()
        canvas.rightMouseDown(with: event(.rightMouseDown, x: 10, y: 30, canvas: canvas))
        canvas.rightMouseDragged(with: event(.rightMouseDragged, x: 30, y: 30, canvas: canvas))
        canvas.rightMouseUp(with: event(.rightMouseUp, x: 30, y: 30, canvas: canvas))
        document.undoManager?.endUndoGrouping()
        XCTAssertEqual(document.state.activeLayer.raster.pixel(x: 20, y: 10), red)
        XCTAssertEqual(document.state.activeLayer.raster.pixel(x: 20, y: 30), blue)
        document.undoManager?.undo()
        XCTAssertEqual(document.state.activeLayer.raster.pixel(x: 20, y: 10), red)
        XCTAssertEqual(document.state.activeLayer.raster.pixel(x: 20, y: 30), .clear)
        document.undoManager?.redo()
        XCTAssertEqual(document.state.activeLayer.raster.pixel(x: 20, y: 30), blue)
    }

    func testOppositeButtonCancelsGestureInBothDirectionsAndReleaseOrders() throws {
        let tools: [PaintTool] = [.brush, .eraser, .line, .rectangle, .ellipse, .fill, .move,
                                 .selection, .ellipseSelect, .lasso, .text, .hand]
        for tool in tools {
            for rightFirst in [false, true] {
                for releaseOriginalFirst in [false, true] {
                    let (document, canvas, window) = makeCanvas()
                    defer { window.close() }
                    document.state.layers[document.state.activeIndex].raster.fill(color: PixelColor(r: 40, g: 200, b: 80), rect: CGRect(x: 10, y: 10, width: 70, height: 70))
                    canvas.selection = .rectangle(CGRect(x: 5, y: 5, width: 80, height: 80), width: 100, height: 100)
                    document.invalidate()
                    canvas.tool = tool
                    let original = document.state, composite = try Raster(image: document.composite), imageRect = canvas.imageRect
                    document.undoManager?.groupsByEvent = false
                    let wasEdited = document.isDocumentEdited
                    func send(_ right: Bool, _ phase: Int, _ x: CGFloat = 50) {
                        let types: [NSEvent.EventType] = right ? [.rightMouseDown, .rightMouseDragged, .rightMouseUp] : [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
                        let e = event(types[phase], x: x, y: phase == 0 ? 20 : 50, canvas: canvas)
                        if right {
                            switch phase { case 0: canvas.rightMouseDown(with: e); case 1: canvas.rightMouseDragged(with: e); default: canvas.rightMouseUp(with: e) }
                        } else {
                            switch phase { case 0: canvas.mouseDown(with: e); case 1: canvas.mouseDragged(with: e); default: canvas.mouseUp(with: e) }
                        }
                    }
                    send(rightFirst, 0, 20); send(rightFirst, 1)
                    if tool == .hand { XCTAssertNotEqual(canvas.imageRect, imageRect) }
                    else if tool != .text { XCTAssertNotEqual(document.state, original, "Expected a live \(tool) preview") }
                    send(!rightFirst, 0)
                    XCTAssertEqual(document.state, original, "Cancel \(tool), right first: \(rightFirst)")
                    XCTAssertEqual(try Raster(image: document.composite), composite)
                    XCTAssertEqual(canvas.imageRect, imageRect)
                    // Neither held button can resume the canceled gesture.
                    send(rightFirst, 1, 70); send(!rightFirst, 1, 70)
                    let releasedFirst = releaseOriginalFirst ? rightFirst : !rightFirst
                    send(releasedFirst, 2)
                    send(!releasedFirst, 1, 80)
                    // Clicking the released button again while the other is
                    // held must stay canceled, including fill/text operations.
                    send(releasedFirst, 0, 60); send(releasedFirst, 2)
                    send(!releasedFirst, 2)
                    XCTAssertEqual(document.state, original)
                    XCTAssertNil(canvas.textEditor)
                    XCTAssertFalse(document.undoManager!.canUndo)
                    XCTAssertEqual(document.isDocumentEdited, wasEdited)
                    // Once both buttons are released, a fresh gesture works.
                    canvas.tool = .brush
                    canvas.selection = nil
                    document.undoManager?.beginUndoGrouping()
                    send(false, 0, 90); send(false, 2, 90)
                    document.undoManager?.endUndoGrouping()
                    XCTAssertEqual(document.state.activeLayer.raster.pixel(x: 90, y: 20), red)
                    XCTAssertTrue(document.undoManager!.canUndo)
                }
            }
        }
    }

    func testCanceledStrokePreservesExistingRedoHistory() {
        let (document, canvas, window) = makeCanvas()
        defer { window.close() }
        document.undoManager?.groupsByEvent = false
        document.undoManager?.beginUndoGrouping()
        document.edit("Earlier edit") { state in state.layers[state.activeIndex].raster.fill(color: blue) }
        document.undoManager?.endUndoGrouping()
        document.undoManager?.undo()
        let original = document.state
        XCTAssertTrue(document.undoManager!.canRedo)
        canvas.mouseDown(with: event(.leftMouseDown, x: 20, y: 20, canvas: canvas))
        canvas.mouseDragged(with: event(.leftMouseDragged, x: 50, y: 50, canvas: canvas))
        canvas.rightMouseDown(with: event(.rightMouseDown, x: 50, y: 50, canvas: canvas))
        canvas.rightMouseUp(with: event(.rightMouseUp, x: 50, y: 50, canvas: canvas))
        canvas.mouseUp(with: event(.leftMouseUp, x: 50, y: 50, canvas: canvas))
        XCTAssertEqual(document.state, original)
        XCTAssertFalse(document.undoManager!.canUndo)
        XCTAssertTrue(document.undoManager!.canRedo)
        document.undoManager?.redo()
        XCTAssertEqual(document.state.activeLayer.raster.pixel(x: 20, y: 20), blue)
    }

    func testRightButtonAppliesToFillShapesAndColorPicker() {
        let (document, canvas, window) = makeCanvas()
        defer { window.close() }
        canvas.tool = .fill
        canvas.rightMouseDown(with: event(.rightMouseDown, x: 5, y: 5, canvas: canvas))
        canvas.rightMouseUp(with: event(.rightMouseUp, x: 5, y: 5, canvas: canvas))
        XCTAssertEqual(document.state.activeLayer.raster.pixel(x: 50, y: 50), blue)
        document.state.layers[document.state.activeIndex].raster.fill(color: .clear)
        canvas.tool = .ellipse
        canvas.rightMouseDown(with: event(.rightMouseDown, x: 20, y: 20, canvas: canvas))
        canvas.rightMouseDragged(with: event(.rightMouseDragged, x: 80, y: 60, canvas: canvas))
        canvas.rightMouseUp(with: event(.rightMouseUp, x: 80, y: 60, canvas: canvas))
        XCTAssertEqual(document.state.activeLayer.raster.pixel(x: 50, y: 20), blue)
        canvas.tool = .eyedropper
        var sample: PixelColor?, alternate = false
        canvas.onColorPick = { sample = $0; alternate = $1 }
        canvas.rightMouseDown(with: event(.rightMouseDown, x: 50, y: 20, canvas: canvas))
        XCTAssertEqual(sample, blue); XCTAssertTrue(alternate)
        XCTAssertEqual(canvas.color, red)
    }

    func testZoomedCanvasClipsDrawingAtItsViewport() {
        let (_, canvas, window) = makeCanvas()
        defer { window.close() }
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView = parent
        canvas.frame = CGRect(x: 50, y: 50, width: 100, height: 100)
        parent.addSubview(canvas)
        canvas.setZoom(8)
        XCTAssertTrue(canvas.clipsToBounds)
        XCTAssertTrue(canvas.layer?.masksToBounds == true)
        // Render into a larger offscreen target: no white canvas pixels may leak
        // into the area representing neighboring editor controls.
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 200,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.magenta.setFill(); CGRect(x: 0, y: 0, width: 200, height: 200).fill()
        NSGraphicsContext.current!.cgContext.translateBy(x: 50, y: 50)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let outside = bitmap.colorAt(x: 20, y: 100)!.usingColorSpace(.sRGB)!
        XCTAssertGreaterThan(outside.redComponent, 0.9)
        XCTAssertGreaterThan(outside.blueComponent, 0.9)
        XCTAssertLessThan(outside.greenComponent, 0.1)
        let inside = bitmap.colorAt(x: 100, y: 100)!.usingColorSpace(.sRGB)!
        XCTAssertGreaterThan(inside.greenComponent, 0.9)
    }

    func testWheelZoomAnchorsPointerAndModifiersPanWithoutChangingZoom() {
        let (_, canvas, window) = makeCanvas()
        defer { window.close() }
        func scrollEvent(_ flags: CGEventFlags) -> NSEvent {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                             wheel1: 20, wheel2: 4, wheel3: 0)!
            cg.flags = flags
            return NSEvent(cgEvent: cg)!
        }
        let wheel = scrollEvent([])
        let pointer = canvas.convert(wheel.locationInWindow, from: nil)
        let before = canvas.toImage(pointer)
        let oldZoom = canvas.zoom
        canvas.scrollWheel(with: wheel)
        XCTAssertNotEqual(canvas.zoom, oldZoom)
        let after = canvas.toImage(pointer)
        XCTAssertEqual(after.x, before.x, accuracy: 0.0001)
        XCTAssertEqual(after.y, before.y, accuracy: 0.0001)

        let zoom = canvas.zoom
        let origin = canvas.imageRect.origin
        let optionWheel = scrollEvent(.maskAlternate)
        canvas.scrollWheel(with: optionWheel)
        XCTAssertEqual(canvas.zoom, zoom)
        XCTAssertEqual(canvas.imageRect.minX, origin.x - optionWheel.scrollingDeltaX, accuracy: 0.0001)
        XCTAssertEqual(canvas.imageRect.minY, origin.y - optionWheel.scrollingDeltaY, accuracy: 0.0001)

        let panned = canvas.imageRect.origin
        canvas.scrollWheel(with: scrollEvent(.maskShift))
        XCTAssertEqual(canvas.zoom, zoom)
        XCTAssertNotEqual(canvas.imageRect.minX, panned.x)
        XCTAssertEqual(canvas.imageRect.minY, panned.y, accuracy: 0.0001)
    }

    func testPhysicalWheelDirectionZoomsConsistentlyWithNaturalScrollingOnAndOff() {
        let (_, canvas, window) = makeCanvas()
        defer { window.close() }
        for inverted in [false, true] {
            let up = DirectedScrollEvent()
            up.inverted = inverted; up.verticalDelta = inverted ? -20 : 20
            up.pointer = CGPoint(x: 120, y: 100)
            canvas.setZoom(1)
            let anchor = canvas.convert(up.locationInWindow, from: nil)
            let before = canvas.toImage(anchor)
            canvas.scrollWheel(with: up)
            XCTAssertGreaterThan(canvas.zoom, 1, "Wheel up must enlarge, Natural Scrolling: \(inverted)")
            XCTAssertEqual(canvas.toImage(anchor).x, before.x, accuracy: 0.0001)
            XCTAssertEqual(canvas.toImage(anchor).y, before.y, accuracy: 0.0001)

            let down = DirectedScrollEvent()
            down.inverted = inverted; down.verticalDelta = -up.verticalDelta; down.pointer = up.pointer
            canvas.setZoom(1)
            canvas.scrollWheel(with: down)
            XCTAssertLessThan(canvas.zoom, 1, "Wheel down must reduce, Natural Scrolling: \(inverted)")

            // Modifiers still pan using the OS-adjusted direction.
            for flags: NSEvent.ModifierFlags in [.option, .shift] {
                up.flags = flags
                let zoom = canvas.zoom, origin = canvas.imageRect.origin
                canvas.scrollWheel(with: up)
                XCTAssertEqual(canvas.zoom, zoom)
                if flags == .option {
                    XCTAssertEqual(canvas.imageRect.minY, origin.y - up.verticalDelta, accuracy: 0.0001)
                } else {
                    XCTAssertEqual(canvas.imageRect.minX, origin.x - up.verticalDelta, accuracy: 0.0001)
                }
            }
        }
    }
}

/// Supply both documented AppKit direction states without changing system settings.
private final class DirectedScrollEvent: NSEvent {
    var inverted = false
    var verticalDelta: CGFloat = 0
    var flags: NSEvent.ModifierFlags = []
    var pointer = CGPoint.zero
    override var type: NSEvent.EventType { .scrollWheel }
    override var scrollingDeltaY: CGFloat { verticalDelta }
    override var scrollingDeltaX: CGFloat { 0 }
    override var isDirectionInvertedFromDevice: Bool { inverted }
    override var modifierFlags: NSEvent.ModifierFlags { flags }
    override var locationInWindow: NSPoint { pointer }
}
