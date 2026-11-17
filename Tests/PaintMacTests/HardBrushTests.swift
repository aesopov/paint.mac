import AppKit
import XCTest
@testable import PaintMac

final class HardBrushTests: XCTestCase {
    private func painted(segments: Int, tool: PaintTool = .brush, smooth: Bool = true, source: Raster? = nil) -> Raster {
        _ = NSApplication.shared
        let original = source ?? Raster(width: 220, height: 100)
        let doc = PaintDocument(); doc.state = DocumentState(width: original.width, height: original.height)
        doc.state.activeLayer.raster = original; doc.undoManager!.groupsByEvent = false
        let canvas = CanvasView(document: doc, useMetal: false)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.close(); doc.close() }
        canvas.setZoom(1); canvas.tool = tool; canvas.brushSize = 24
        canvas.brushHardness = 1; canvas.brushOpacity = 0.25; canvas.color = .maskBlack; canvas.smooth = smooth
        func event(_ type: NSEvent.EventType, _ x: Double) -> NSEvent {
            let p = CGPoint(x: canvas.imageRect.minX + x, y: canvas.imageRect.minY + 50.5)
            return NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        doc.undoManager!.beginUndoGrouping()
        canvas.mouseDown(with: event(.leftMouseDown, 20.5))
        for i in 1...segments { canvas.mouseDragged(with: event(.leftMouseDragged, 20.5 + 180 * Double(i) / Double(segments))) }
        canvas.mouseUp(with: event(.leftMouseUp, 200.5)); doc.undoManager!.endUndoGrouping()
        return doc.state.activeLayer.raster
    }

    func testHardBrushAndEraserKeepUniformOpacityAtSegmentJoints() throws {
        for smooth in [false, true] {
            let brush = painted(segments: 4, smooth: smooth)
            let original = Raster(width: 220, height: 100, color: PixelColor(r: 20, g: 90, b: 230, a: 200))
            let eraser = painted(segments: 4, tool: .eraser, smooth: smooth, source: original)
            for x in [20, 42, 65, 87, 110, 132, 155, 177, 200] {
                XCTAssertEqual(brush.pixel(x: x, y: 50).a, 64, "A hard brush must not darken its round segment caps at x=\(x)")
                XCTAssertEqual(eraser.pixel(x: x, y: 50).a, 150, "An eraser must apply opacity once at x=\(x)")
            }
        }
        if let folder = ProcessInfo.processInfo.environment["PAINTMAC_HARD_BRUSH_PREVIEW_DIR"] {
            let result = painted(segments: 4, source: Raster(width: 220, height: 100, color: .white))
            try ProjectCodec.imageData(result.cgImage, type: "public.png").write(to: URL(fileURLWithPath: folder).appendingPathComponent("hard-joints.png"))
        }
    }

    func testHardBrushCoverageDoesNotDependOnMouseEventDensity() {
        for smooth in [false, true] {
            XCTAssertEqual(painted(segments: 4, smooth: smooth), painted(segments: 90, smooth: smooth))
        }
    }

    func testRetracingKeepsColorAlphaFeatheringAndSixteenBitPrecisionWithoutTouchingDistantTiles() {
        let format = RGBFormat(profile: .displayP3, depth: .sixteen)
        var original = Raster(width: 520, height: 80, color: PixelColor(r: 30, g: 90, b: 230, a: 180), format: format)
        original.editPixels(in: original.bounds) { raw, _ in
            let p = RGBSamples(raw: raw, depth: .sixteen)
            for i in 0..<(520 * 80) { p[i * 4] += Double(i % 17) }
        }
        var selected = Data(repeating: 128, count: 520 * 80)
        for y in 0..<80 { for x in 254..<259 { selected[y * 520 + x] = 0 } }
        let selection = SelectionMask(width: 520, height: 80, coverage: selected)
        let color = PixelColor(NSColor(displayP3Red: 0.7312, green: 0.1223, blue: 0.9123, alpha: 0.5))
        let a = CGPoint(x: 243.5, y: 40.5), b = CGPoint(x: 278.5, y: 40.5)
        for erase in [false, true] { for smooth in [false, true] {
            var result = original, expected = original, brush = HardBrushStroke(original: original)
            expected.stroke(from: a, to: b, size: 24, color: color, opacity: 0.4, erase: erase, clip: nil,
                            selection: selection, antialias: smooth)
            for (start, end) in [(a, a), (a, b), (b, a), (a, a)] {
                brush.paint(on: &result, from: start, to: end, size: 24, color: color, opacity: 0.4,
                            erase: erase, selection: selection, antialias: smooth)
            }
            XCTAssertEqual(result.format, format); XCTAssertNotEqual(result, original)
            XCTAssertTrue(result.storage.tiles[2] === original.storage.tiles[2])
            let area = CGRect(x: 225, y: 20, width: 80, height: 42)
            let actual = result.storage.read(area), reference = expected.storage.read(area)
            actual.withUnsafeBytes { raw in reference.withUnsafeBytes { target in
                let p = RGBSamples(raw: UnsafeMutableRawBufferPointer(mutating: raw), depth: .sixteen)
                let q = RGBSamples(raw: UnsafeMutableRawBufferPointer(mutating: target), depth: .sixteen)
                for i in 0..<(80 * 42 * 4) { XCTAssertEqual(p[i], q[i], accuracy: 1) }
            } }
            XCTAssertEqual(result.pixel(x: 256, y: 40), original.pixel(x: 256, y: 40))
            let before = result
            brush.paint(on: &result, from: a, to: b, size: 24, color: color, opacity: 0.4, erase: erase, selection: selection, antialias: smooth)
            XCTAssertEqual(result, before)
            XCTAssertTrue(result.storage.tiles[0] === before.storage.tiles[0])
            var second = HardBrushStroke(original: result)
            second.paint(on: &result, from: a, to: b, size: 24, color: color, opacity: 0.4, erase: erase, selection: selection, antialias: smooth)
            XCTAssertNotEqual(result, before, "Separate strokes must still build paint/erasure")
        } }
    }

    func testHardBrushImageLayerMaskAndQuickMaskKeepSingleUndoAndCancelPreservesRedo() {
        _ = NSApplication.shared
        for target in 0..<3 { for tool in [PaintTool.brush, .eraser] {
            let doc = PaintDocument(); doc.state = DocumentState(width: 160, height: 100)
            doc.undoManager!.groupsByEvent = false
            if target == 0, tool == .eraser { doc.state.activeLayer.raster.fill(color: .white) }
            if target == 1 { doc.state.activeLayer.mask = .all(width: 160, height: 100); doc.state.editingMask = true }
            if target == 2 { doc.state.quickMask = .all(width: 160, height: 100) }
            let canvas = CanvasView(document: doc, useMetal: false)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = canvas
            defer { window.close(); doc.close() }
            canvas.setZoom(1); canvas.tool = tool; canvas.color = .maskBlack
            canvas.brushSize = 24; canvas.brushHardness = 1; canvas.brushOpacity = 0.25
            func event(_ type: NSEvent.EventType, _ x: Double) -> NSEvent {
                let p = CGPoint(x: canvas.imageRect.minX + x, y: canvas.imageRect.minY + 50.5)
                return NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            }
            let before = doc.state
            doc.undoManager!.beginUndoGrouping()
            canvas.mouseDown(with: event(.leftMouseDown, 20.5))
            for x in [60.5, 100.5, 140.5, 140.5] { canvas.mouseDragged(with: event(.leftMouseDragged, x)) }
            canvas.mouseUp(with: event(.leftMouseUp, 140.5)); doc.undoManager!.endUndoGrouping()
            let after = doc.state
            if target == 0 { XCTAssertEqual(after.activeLayer.raster.pixel(x: 60, y: 50).a, tool == .eraser ? 191 : 64) }
            else {
                XCTAssertEqual((after.quickMask ?? after.activeLayer.mask)!.value(x: 60, y: 50), 191)
                XCTAssertEqual(after.layers.map(\.raster), before.layers.map(\.raster))
            }
            doc.undoManager!.undo(); XCTAssertEqual(doc.state, before); XCTAssertFalse(doc.undoManager!.canUndo)
            canvas.mouseDown(with: event(.leftMouseDown, 20.5)); canvas.mouseDragged(with: event(.leftMouseDragged, 140.5))
            canvas.rightMouseDown(with: event(.rightMouseDown, 140.5))
            canvas.mouseUp(with: event(.leftMouseUp, 140.5)); canvas.rightMouseUp(with: event(.rightMouseUp, 140.5))
            XCTAssertEqual(doc.state, before); XCTAssertTrue(doc.undoManager!.canRedo)
            doc.undoManager!.redo(); XCTAssertEqual(doc.state, after)
        } }
    }

    func testLargeHardBrushUsesBoundedTilesAndStaysInteractive() {
        let original = Raster(width: 3840, height: 2160)
        var result = original, brush = HardBrushStroke(original: original)
        let start = ProcessInfo.processInfo.systemUptime
        for i in 0..<20 {
            brush.paint(on: &result, from: CGPoint(x: 400 + i * 40, y: 400), to: CGPoint(x: 440 + i * 40, y: 400),
                        size: 300, color: .black, opacity: 0.5, erase: false, selection: nil, antialias: true)
        }
        let average = (ProcessInfo.processInfo.systemUptime - start) / 20
        print(String(format: "300 px hard brush on 4K: %.2f ms per 40 px input segment", average * 1000))
        XCTAssertLessThan(average, 0.1)
        XCTAssertEqual(result.pixel(x: 800, y: 400).a, 128)
        XCTAssertTrue(result.storage.tiles[0] === original.storage.tiles[0])
    }
}
