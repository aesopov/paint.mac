import AppKit
import XCTest
@testable import PaintMac

final class RetouchTests: XCTestCase {
    private let kinds: [RetouchStroke.Kind] = [.blur, .sharpen, .smudge]
    private let tools: [PaintTool] = [.blur, .sharpen, .smudge]
    private func edge(width: Int = 64, height: Int = 48, format: RGBFormat = .standard) -> Raster {
        var raster = Raster(width: width, height: height, color: PixelColor(r: 80, g: 80, b: 80), format: format)
        raster.fill(color: PixelColor(r: 170, g: 170, b: 170), rect: CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return raster
    }
    func testBlurSoftensAndSharpenIncreasesLocalContrastWithoutEditingOutsideFootprint() {
        let original = edge()
        var blurred = original, sharpened = original
        var blur = RetouchStroke(kind: .blur, size: 18, hardness: 1, strength: 1, antialias: false)
        var sharpen = RetouchStroke(kind: .sharpen, size: 18, hardness: 1, strength: 1, antialias: false)
        blur.paint(on: &blurred, to: CGPoint(x: 31.5, y: 24.5), selection: nil)
        sharpen.paint(on: &sharpened, to: CGPoint(x: 31.5, y: 24.5), selection: nil)
        XCTAssertGreaterThan(blurred.pixel(x: 31, y: 24).r, 80); XCTAssertLessThan(blurred.pixel(x: 32, y: 24).r, 170)
        XCTAssertLessThan(sharpened.pixel(x: 31, y: 24).r, 80); XCTAssertGreaterThan(sharpened.pixel(x: 32, y: 24).r, 170)
        for result in [blurred, sharpened] {
            XCTAssertEqual(result.pixel(x: 31, y: 2), original.pixel(x: 31, y: 2))
            XCTAssertEqual(result.pixel(x: 2, y: 24), original.pixel(x: 2, y: 24))
            XCTAssertEqual(result.pixel(x: 31, y: 24).a, 255)
        }
    }
    func testSmudgeCarriesColorAndAlphaRatherThanPaintingTheCurrentColorAndClickDoesNothing() {
        var raster = Raster(width: 64, height: 48)
        raster.fill(color: PixelColor(r: 20, g: 90, b: 240), rect: CGRect(x: 8, y: 10, width: 14, height: 28))
        let original = raster
        var smudge = RetouchStroke(kind: .smudge, size: 12, hardness: 1, strength: 1, antialias: true)
        smudge.paint(on: &raster, to: CGPoint(x: 17.5, y: 24.5), selection: nil)
        XCTAssertEqual(raster, original)
        smudge.paint(on: &raster, to: CGPoint(x: 40.5, y: 24.5), selection: nil)
        XCTAssertGreaterThan(raster.pixel(x: 30, y: 24).a, 0)
        XCTAssertGreaterThan(raster.pixel(x: 30, y: 24).b, 200)
        XCTAssertEqual(raster.pixel(x: 30, y: 4), .clear)
    }
    func testDabSpacingIsIndependentOfEventFrequencyAndStationaryEventsDoNotBuildUp() {
        for kind in kinds {
            var a = edge(), b = a
            var coarse = RetouchStroke(kind: kind, size: 16, hardness: 0.4, strength: 0.6, antialias: true)
            var fine = coarse
            coarse.paint(on: &a, to: CGPoint(x: 20.5, y: 24.5), selection: nil)
            fine.paint(on: &b, to: CGPoint(x: 20.5, y: 24.5), selection: nil)
            coarse.paint(on: &a, to: CGPoint(x: 44.5, y: 24.5), selection: nil)
            for i in 1...24 { fine.paint(on: &b, to: CGPoint(x: 20.5 + Double(i), y: 24.5), selection: nil) }
            XCTAssertEqual(a, b)
            let before = b
            for _ in 0..<5 { fine.paint(on: &b, to: CGPoint(x: 44.5, y: 24.5), selection: nil) }
            XCTAssertEqual(b, before)
        }
    }
    func testSelectionsHolesAndFeatheringRestrictEveryToolAndZeroStrengthIsANoOp() {
        var coverage = Data(repeating: 0, count: 64 * 48)
        for y in 10..<38 { for x in 22..<43 where !(29..<32).contains(x) { coverage[y * 64 + x] = 128 } }
        let selection = SelectionMask(width: 64, height: 48, coverage: coverage)
        for kind in kinds {
            let original = edge(); var selected = original, unrestricted = original, zero = original
            var a = RetouchStroke(kind: kind, size: 24, hardness: 1, strength: 0.5, antialias: false), b = a
            var c = RetouchStroke(kind: kind, size: 24, hardness: 1, strength: 0, antialias: false)
            for point in [CGPoint(x: 25.5, y: 24.5), CGPoint(x: 39.5, y: 24.5)] {
                a.paint(on: &selected, to: point, selection: selection)
                b.paint(on: &unrestricted, to: point, selection: nil)
                c.paint(on: &zero, to: point, selection: nil)
            }
            XCTAssertEqual(zero, original); XCTAssertNotEqual(selected, original)
            for y in 0..<48 { for x in 0..<64 where coverage[y * 64 + x] == 0 {
                XCTAssertEqual(selected.pixel(x: x, y: y), original.pixel(x: x, y: y))
            } }
            let selectedChange = abs(Int(selected.pixel(x: 33, y: 24).r) - Int(original.pixel(x: 33, y: 24).r))
            let fullChange = abs(Int(unrestricted.pixel(x: 33, y: 24).r) - Int(original.pixel(x: 33, y: 24).r))
            XCTAssertLessThanOrEqual(selectedChange, fullChange)
        }
    }
    func testSixteenBitProfileLowBitsPremultiplicationAndTileBoundariesArePreserved() {
        let format = RGBFormat(profile: .displayP3, depth: .sixteen)
        var original = edge(width: 520, height: 96, format: format)
        original.editPixels(in: original.bounds) { raw, _ in
            let p = RGBSamples(raw: raw, depth: .sixteen)
            for i in 0..<(520 * 96) { p[i * 4] += Double(i % 137) }
        }
        for kind in kinds {
            var raster = original
            var stroke = RetouchStroke(kind: kind, size: 32, hardness: 0, strength: 0.7, antialias: true)
            stroke.paint(on: &raster, to: CGPoint(x: 253.5, y: 48.5), selection: nil)
            stroke.paint(on: &raster, to: CGPoint(x: 270.5, y: 48.5), selection: nil)
            XCTAssertEqual(raster.format, format); XCTAssertNotEqual(raster, original)
            XCTAssertTrue(raster.storage.tiles[0] !== original.storage.tiles[0])
            XCTAssertTrue(raster.storage.tiles[1] !== original.storage.tiles[1])
            XCTAssertTrue(raster.storage.tiles[2] === original.storage.tiles[2])
            let data = raster.storage.read(CGRect(x: 240, y: 32, width: 48, height: 32))
            data.withUnsafeBytes { raw in
                let p = RGBSamples(raw: UnsafeMutableRawBufferPointer(mutating: raw), depth: .sixteen)
                XCTAssertTrue((0..<(48 * 32)).contains { Int(p[$0 * 4]) % 257 != 0 })
                for i in 0..<(48 * 32) { for c in 0..<3 { XCTAssertLessThanOrEqual(p[i * 4 + c], p[i * 4 + 3]) } }
            }
        }
    }
    func testTransparentEdgesHaveNoDarkFringesOrInvalidPremultiplicationAndCanvasEdgesClamp() {
        let blue = PixelColor(r: 0, g: 0, b: 255)
        var original = Raster(width: 64, height: 48)
        original.fill(color: blue, rect: CGRect(x: 0, y: 10, width: 32, height: 28))
        for kind in kinds {
            var raster = original
            var stroke = RetouchStroke(kind: kind, size: 18, hardness: 0.3, strength: 1, antialias: true)
            for point in [CGPoint(x: -5, y: 24.5), CGPoint(x: 40.5, y: 24.5)] { stroke.paint(on: &raster, to: point, selection: nil) }
            let bytes = raster.bytes
            for i in stride(from: 0, to: bytes.count, by: 4) {
                for c in 0..<3 { XCTAssertLessThanOrEqual(bytes[i + c], bytes[i + 3]) }
                if bytes[i + 3] > 0 { XCTAssertEqual(bytes[i + 2], bytes[i + 3], "Blue must stay saturated through transparent edges") }
            }
        }
        for kind in kinds {
            var solid = Raster(width: 64, height: 48, color: blue), stroke = RetouchStroke(kind: kind, size: 18, hardness: 1, strength: 1, antialias: true)
            let before = solid
            stroke.paint(on: &solid, to: CGPoint(x: 0.5, y: 0.5), selection: nil)
            if kind != .smudge { XCTAssertEqual(solid, before, "Blur and Sharpen must not create transparency at canvas edges") }
        }
    }
    func testLargeBrushStaysInteractiveAndDoesNotTouchDistantTiles() {
        for kind in kinds {
            var raster = edge(width: 1200, height: 800)
            let original = raster
            var stroke = RetouchStroke(kind: kind, size: 300, hardness: 0.5, strength: 0.5, antialias: true)
            let start = CFAbsoluteTimeGetCurrent()
            for i in 0..<6 { stroke.paint(on: &raster, to: CGPoint(x: 500 + i * 45, y: 400), selection: nil) }
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) / 6
            print("300 px \(kind) brush: \(String(format: "%.2f", elapsed * 1000)) ms per 45 px input segment")
            XCTAssertLessThan(elapsed, 0.15)
            XCTAssertTrue(raster.storage.tiles[0] === original.storage.tiles[0])
        }
    }
    private func fixture() -> (PaintDocument, CanvasView, NSWindow) {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 64, height: 48)
        doc.state.activeLayer.raster = edge(); doc.undoManager!.groupsByEvent = false
        let canvas = CanvasView(document: doc, useMetal: false)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        canvas.setZoom(2)
        return (doc, canvas, window)
    }
    private func mouse(_ type: NSEvent.EventType, _ point: CGPoint, _ canvas: CanvasView, option: Bool = false) -> NSEvent {
        let view = CGPoint(x: canvas.imageRect.minX + point.x * canvas.zoom, y: canvas.imageRect.minY + point.y * canvas.zoom)
        return NSEvent.mouseEvent(with: type, location: canvas.convert(view, to: nil), modifierFlags: option ? [.option] : [], timestamp: 0,
                                 windowNumber: canvas.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    func testImageMasksAndQuickMaskKeepOneUndoStepStablePreviewAndOppositeButtonCancellation() {
        for target in 0..<3 { for tool in tools {
            let (doc, canvas, window) = fixture(); defer { window.close(); doc.close() }
            if target > 0 {
                let mask = SelectionMask(editingRaster: edge())
                if target == 1 { doc.state.activeLayer.mask = mask; doc.state.editingMask = true }
                else { doc.state.quickMask = mask }
            }
            canvas.tool = tool; canvas.brushSize = 18; canvas.retouchStrength = 1; canvas.brushHardness = 1
            let a = CGPoint(x: 27.5, y: 24.5), b = CGPoint(x: 38.5, y: 24.5), before = doc.state
            doc.undoManager!.beginUndoGrouping()
            canvas.mouseDown(with: mouse(.leftMouseDown, a, canvas)); canvas.mouseDragged(with: mouse(.leftMouseDragged, b, canvas))
            let preview = doc.state
            canvas.mouseDragged(with: mouse(.leftMouseDragged, b, canvas)); XCTAssertEqual(doc.state, preview)
            canvas.mouseUp(with: mouse(.leftMouseUp, b, canvas)); doc.undoManager!.endUndoGrouping()
            XCTAssertNotEqual(doc.state, before); XCTAssertEqual(doc.state, preview)
            if target > 0 { XCTAssertEqual(doc.state.layers.map(\.raster), before.layers.map(\.raster)) }
            doc.undoManager!.undo(); XCTAssertEqual(doc.state, before); XCTAssertFalse(doc.undoManager!.canUndo)
            canvas.mouseDown(with: mouse(.leftMouseDown, a, canvas)); canvas.mouseDragged(with: mouse(.leftMouseDragged, b, canvas))
            canvas.rightMouseDown(with: mouse(.rightMouseDown, b, canvas))
            canvas.mouseUp(with: mouse(.leftMouseUp, b, canvas)); canvas.rightMouseUp(with: mouse(.rightMouseUp, b, canvas))
            XCTAssertEqual(doc.state, before); XCTAssertTrue(doc.undoManager!.canRedo)
            doc.undoManager!.redo(); XCTAssertEqual(doc.state, preview)
        } }
    }
    func testRetouchFlyoutShortcutsStrengthAndLockedOrNonPixelTargets() throws {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 64, height: 48)
        doc.state.activeLayer.raster = edge(); doc.undoManager!.groupsByEvent = false
        doc.makeWindowControllers(); defer { doc.close() }
        let editor = doc.windowControllers[0] as! EditorWindowController
        editor.window!.contentView!.layoutSubtreeIfNeeded(); editor.canvas.setZoom(2)
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let root = editor.window!.contentView!
        let group = try XCTUnwrap(views(root).compactMap { $0 as? ToolGroupButton }.first { $0.group == .retouch })
        let slider = try XCTUnwrap(views(root).compactMap { $0 as? NSSlider }.first { $0.accessibilityLabel() == "Retouch strength" })
        XCTAssertEqual(Set(PaintTool.allCases.map(\.key)).count, PaintTool.allCases.count)
        let before = doc.state
        for tool in tools {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: editor.window!.windowNumber,
                                        context: nil, characters: tool.key, charactersIgnoringModifiers: tool.key, isARepeat: false, keyCode: 0)!
            editor.canvas.keyDown(with: event)
            XCTAssertEqual(editor.canvas.tool, tool); XCTAssertEqual(group.currentTool, tool); XCTAssertTrue(group.selected)
            XCTAssertFalse(slider.isHiddenOrHasHiddenAncestor); XCTAssertNotNil(tool.icon)
            slider.doubleValue = 25; _ = NSApp.sendAction(slider.action!, to: slider.target, from: slider)
            XCTAssertEqual(editor.canvas.retouchStrength, 0.25)
        }
        XCTAssertEqual(doc.state, before); XCTAssertFalse(doc.undoManager!.canUndo)
        doc.state.activeLayer.isLocked = true
        let locked = doc.state, canvas = editor.canvas, p = CGPoint(x: 31, y: 24)
        canvas.mouseDown(with: mouse(.leftMouseDown, p, canvas)); canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 40, y: 24), canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, p, canvas)); XCTAssertEqual(doc.state, locked)
    }
}
