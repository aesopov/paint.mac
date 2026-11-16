import AppKit
import XCTest
@testable import PaintMac

final class ShapePaintModeTests: XCTestCase {
    private let gray = PixelColor(r: 160, g: 160, b: 160)
    private let pink = PixelColor(r: 255, g: 80, b: 130)

    func testOpaqueInsideOutlineDoesNotLeakFillColorAtAntialiasedOuterEdge() {
        for ellipse in [false, true] { for offset in [0.0, 0.3] {
            let rect = CGRect(x: 10 + offset, y: 9 + offset, width: 19, height: 19)
            var transparent = Raster(width: 40, height: 40)
            transparent.strokeShape(in: rect, ellipse: ellipse, size: 3, color: gray, opacity: 1,
                                    clip: nil, fillColor: pink, alignment: .inside)
            let edge = ellipse ? SelectionMask.ellipse(rect, width: 40, height: 40) : SelectionMask.rectangle(rect, width: 40, height: 40)
            let mask = edge.coverage
            let image = transparent.bytes
            var tintedEdges = 0
            for i in 0..<1600 where mask[i] > 0 && mask[i] < 255 {
                if Int(image[i * 4]) - Int(image[i * 4 + 1]) > 1 { tintedEdges += 1 }
                XCTAssertEqual(Int(image[i * 4 + 3]), Int(mask[i]), accuracy: 1, "Fixing the color must preserve edge coverage")
            }
            XCTAssertEqual(tintedEdges, 0, "An opaque gray outline must cover the pink fill at the outer edge: ellipse=\(ellipse), offset=\(offset)")
        } }
    }

    private func fixture() -> (PaintDocument, CanvasView, NSWindow) {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 64, height: 64)
        doc.undoManager!.groupsByEvent = false
        let canvas = CanvasView(document: doc, useMetal: false)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 128, height: 128), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        canvas.setZoom(1); canvas.color = gray; canvas.alternateColor = pink
        canvas.shapePaintMode = .fill; canvas.brushSize = 100; canvas.brushHardness = 0; canvas.shapeAlignment = .outside
        return (doc, canvas, window)
    }
    private func mouse(_ type: NSEvent.EventType, _ p: CGPoint, _ canvas: CanvasView) -> NSEvent {
        let point = CGPoint(x: canvas.imageRect.minX + p.x, y: canvas.imageRect.minY + p.y)
        return NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                 windowNumber: canvas.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    private func gesture(_ canvas: CanvasView, right: Bool = false) {
        canvas.mouseDown(with: mouse(right ? .rightMouseDown : .leftMouseDown, CGPoint(x: 10, y: 10), canvas))
        canvas.mouseDragged(with: mouse(right ? .rightMouseDragged : .leftMouseDragged, CGPoint(x: 40, y: 40), canvas))
        canvas.mouseUp(with: mouse(right ? .rightMouseUp : .leftMouseUp, CGPoint(x: 40, y: 40), canvas))
    }

    func testFillOnlyBothButtonsExactBoundsPreviewUndoAndCancellation() {
        for tool in [PaintTool.rectangle, .ellipse] { for right in [false, true] {
            let (doc, canvas, window) = fixture(); defer { window.close(); doc.close() }
            canvas.tool = tool; canvas.smooth = false
            let before = doc.state
            let down: NSEvent.EventType = right ? .rightMouseDown : .leftMouseDown
            let drag: NSEvent.EventType = right ? .rightMouseDragged : .leftMouseDragged
            let up: NSEvent.EventType = right ? .rightMouseUp : .leftMouseUp
            doc.undoManager!.beginUndoGrouping()
            canvas.mouseDown(with: mouse(down, CGPoint(x: 10, y: 10), canvas))
            canvas.mouseDragged(with: mouse(drag, CGPoint(x: 40, y: 40), canvas))
            let preview = doc.state
            canvas.mouseDragged(with: mouse(drag, CGPoint(x: 40, y: 40), canvas))
            XCTAssertEqual(doc.state, preview)
            canvas.mouseUp(with: mouse(up, CGPoint(x: 40, y: 40), canvas))
            doc.undoManager!.endUndoGrouping()
            XCTAssertEqual(doc.state, preview)
            let image = doc.state.activeLayer.raster
            XCTAssertEqual(image.pixel(x: 25, y: 25), right ? pink : gray)
            XCTAssertEqual(image.pixel(x: 25, y: 10), right ? pink : gray)
            XCTAssertEqual(image.pixel(x: 25, y: 9), .clear)
            XCTAssertEqual(image.pixel(x: 25, y: 40), .clear)
            doc.undoManager!.undo(); XCTAssertEqual(doc.state, before); XCTAssertFalse(doc.undoManager!.canUndo)
            canvas.mouseDown(with: mouse(down, CGPoint(x: 10, y: 10), canvas))
            canvas.mouseDragged(with: mouse(drag, CGPoint(x: 40, y: 40), canvas))
            canvas.mouseDown(with: mouse(right ? .leftMouseDown : .rightMouseDown, CGPoint(x: 25, y: 25), canvas))
            canvas.mouseUp(with: mouse(up, CGPoint(x: 40, y: 40), canvas))
            canvas.mouseUp(with: mouse(right ? .leftMouseUp : .rightMouseUp, CGPoint(x: 25, y: 25), canvas))
            XCTAssertEqual(doc.state, before); XCTAssertFalse(doc.undoManager!.canUndo); XCTAssertTrue(doc.undoManager!.canRedo)
            doc.undoManager!.redo(); XCTAssertEqual(doc.state, preview)
        } }
    }

    func testFillOnlyTargetsLayerMasksAndQuickMaskWithoutChangingImage() {
        for quick in [false, true] {
            let (doc, canvas, window) = fixture(); defer { window.close(); doc.close() }
            canvas.tool = .ellipse; canvas.color = .white; canvas.smooth = false
            if quick { doc.state.quickMask = .empty(width: 64, height: 64) }
            else { doc.state.activeLayer.mask = .empty(width: 64, height: 64); doc.state.editingMask = true }
            let before = doc.state
            doc.undoManager!.beginUndoGrouping(); gesture(canvas); doc.undoManager!.endUndoGrouping()
            let result = quick ? doc.state.quickMask! : doc.state.activeLayer.mask!
            XCTAssertEqual(result.value(x: 25, y: 25), 255); XCTAssertEqual(result.value(x: 25, y: 9), 0)
            XCTAssertEqual(doc.state.layers.map(\.raster), before.layers.map(\.raster))
            doc.undoManager!.undo(); XCTAssertEqual(doc.state, before)
        }
    }

    func testFillOnlyRespectsSharpSmoothSelectionHolesColorAlphaAndHighPrecision() {
        let rect = CGRect(x: 10.3, y: 9.7, width: 30, height: 30)
        let clip = SelectionMask(width: 64, height: 64, coverage: Data(repeating: 128, count: 4096))
            .combined(with: .rectangle(CGRect(x: 22, y: 22, width: 6, height: 6), width: 64, height: 64), mode: .subtract)
        let color = PixelColor(NSColor(srgbRed: 0.12345, green: 0.4321, blue: 0.76543, alpha: 0.5))
        for depth in RGBDepth.allCases { for smooth in [false, true] {
            let format = RGBFormat(profile: .displayP3, depth: depth)
            var image = Raster(width: 64, height: 64, format: format)
            image.strokeShape(in: rect, ellipse: true, size: 100, color: pink, opacity: 0.5, clip: nil,
                              selection: clip, antialias: smooth, fillColor: color, hardness: 0, alignment: .outside, drawOutline: false)
            XCTAssertEqual(image.format, format)
            XCTAssertEqual(image.pixel(x: 25, y: 25), .clear)
            XCTAssertEqual(image.pixel(x: 25, y: 8), .clear)
            XCTAssertEqual(Int(image.pixel(x: 18, y: 25).a), 32, accuracy: 1)
            let data = image.bytes
            if depth == .sixteen {
                let i = (25 * 64 + 18) * 8
                XCTAssertNotEqual(data[i], data[i + 1], "16-bit color samples must retain low bits")
            }
            var opaque = Raster(width: 64, height: 64)
            opaque.strokeShape(in: rect, ellipse: true, size: 1, color: gray, opacity: 1, clip: nil,
                               antialias: smooth, fillColor: gray, drawOutline: false)
            let bytes = opaque.bytes
            XCTAssertEqual(stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 && bytes[$0] < 255 }, smooth)
        } }
    }

    private func views(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + views($0) } }
    private func iconPixels(_ image: NSImage) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 144, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(x: 0, y: 0, width: 36, height: 36))
        NSGraphicsContext.restoreGraphicsState()
        return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
    }

    func testStylePopupAndRailIconsTrackThreeModesAndRememberThemAcrossTools() throws {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.makeWindowControllers(); defer { doc.close() }
        let editor = doc.windowControllers[0] as! EditorWindowController, root = editor.window!.contentView!
        let popup = try XCTUnwrap(views(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Shape paint style" })
        let button = try XCTUnwrap(views(root).compactMap { $0 as? ToolGroupButton }.first { $0.group == .shapes })
        let alignment = try XCTUnwrap(views(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Shape outline alignment" })
        XCTAssertEqual(popup.itemTitles, ["Outline Only", "Outline & Fill", "Fill Only"])
        let before = doc.state
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            editor.window!.appearance = NSAppearance(named: theme)
            editor.window!.setContentSize(CGSize(width: 960, height: 580))
            for tool in [PaintTool.rectangle, .ellipse] {
                editor.selectTool(tool)
                var icons: [Data] = []
                for mode in ShapePaintMode.allCases {
                    popup.selectItem(withTitle: mode.rawValue); _ = NSApp.sendAction(popup.action!, to: popup.target, from: popup)
                    root.layoutSubtreeIfNeeded(); popup.scrollToVisible(popup.bounds); root.layoutSubtreeIfNeeded()
                    let clip = try XCTUnwrap(popup.enclosingScrollView?.contentView)
                    XCTAssertTrue(clip.bounds.contains(popup.convert(popup.bounds, to: clip)))
                    XCTAssertEqual(editor.canvas.shapePaintMode, mode)
                    XCTAssertEqual(button.accessibilityValue() as? String, mode.rawValue)
                    XCTAssertEqual(alignment.isHiddenOrHasHiddenAncestor, mode == .fill)
                    XCTAssertTrue(button.image!.isTemplate)
                    icons.append(iconPixels(button.image!))
                    editor.selectTool(.brush); button.performClick(nil)
                    XCTAssertEqual(editor.canvas.tool, tool); XCTAssertEqual(editor.canvas.shapePaintMode, mode)
                }
                XCTAssertNotEqual(icons[0], icons[1]); XCTAssertNotEqual(icons[1], icons[2]); XCTAssertNotEqual(icons[0], icons[2])
            }
        }
        let line = iconPixels(PaintTool.line.icon)
        editor.selectTool(.line)
        XCTAssertTrue(popup.isHidden); XCTAssertEqual(iconPixels(button.image!), line)
        editor.selectTool(.ellipse); XCTAssertEqual(popup.titleOfSelectedItem, "Fill Only")
        XCTAssertEqual(doc.state, before); XCTAssertFalse(doc.undoManager!.canUndo)
    }
}
