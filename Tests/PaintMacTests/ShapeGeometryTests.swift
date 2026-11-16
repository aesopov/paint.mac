import AppKit
import XCTest
@testable import PaintMac

final class ShapeGeometryTests: XCTestCase {
    let red = PixelColor(r: 255, g: 0, b: 0), blue = PixelColor(r: 0, g: 0, b: 255)
    private func bounds(_ raster: Raster) -> CGRect {
        var result = CGRect.null
        let bytes = raster.bytes, stride = raster.stride
        for y in 0..<raster.height { for x in 0..<raster.width {
            let i = (y * raster.width + x) * stride
            if bytes[i + stride - 1] > 0 || (stride == 8 && bytes[i + 6] > 0) {
                result = result.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        } }
        return result
    }
    private func setup() -> (PaintDocument, CanvasView, NSWindow) {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 120, height: 100)
        doc.undoManager!.groupsByEvent = false
        let canvas = CanvasView(document: doc, useMetal: false)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 220), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas; canvas.setZoom(1)
        canvas.color = red; canvas.alternateColor = blue; canvas.smooth = false
        return (doc, canvas, window)
    }
    private func mouse(_ type: NSEvent.EventType, _ p: CGPoint, _ canvas: CanvasView, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let v = CGPoint(x: canvas.imageRect.minX + p.x * canvas.zoom, y: canvas.imageRect.minY + p.y * canvas.zoom)
        return NSEvent.mouseEvent(with: type, location: canvas.convert(v, to: nil), modifierFlags: flags, timestamp: 0,
                                 windowNumber: canvas.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    private func flags(_ flags: NSEvent.ModifierFlags, _ canvas: CanvasView) -> NSEvent {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: canvas.window!.windowNumber,
                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!
    }
    private func transaction(_ doc: PaintDocument, _ body: () -> Void) {
        doc.undoManager!.beginUndoGrouping(); body(); doc.undoManager!.endUndoGrouping()
    }

    func testCenteredGeometryPreservesAnchorAndEqualSidesInEveryQuadrant() {
        for snapped in [false, true] { for sx: CGFloat in [-1, 1] { for sy: CGFloat in [-1, 1] {
            let start = CGPoint(x: 100.2, y: 90.8), end = CGPoint(x: start.x + sx * 21.7, y: start.y + sy * 19.6)
            let rect = DragGeometry.rect(from: start, to: end, square: true, snap: snapped, fromCenter: true)
            XCTAssertEqual(rect.width, rect.height)
            XCTAssertEqual(rect.midX, snapped ? 100 : start.x, accuracy: 0.00001)
            XCTAssertEqual(rect.midY, snapped ? 90 : start.y, accuracy: 0.00001)
            XCTAssertEqual(rect.width, snapped ? 44 : 43.4, accuracy: 0.00001)
        } } }
    }

    func testHardOutlineBoundsAndThicknessMatchInsideCenterOutsideForRectanglesAndEllipses() {
        let rect = CGRect(x: 20, y: 20, width: 60, height: 40)
        for ellipse in [false, true] { for alignment in ShapeOutlineAlignment.allCases {
            var raster = Raster(width: 100, height: 90)
            raster.strokeShape(in: rect, ellipse: ellipse, size: 10, color: red, opacity: 1, clip: nil, antialias: false, alignment: alignment)
            let expansion = alignment.expansion(for: 10)
            XCTAssertEqual(bounds(raster), rect.insetBy(dx: -expansion, dy: -expansion), "\(ellipse) \(alignment)")
            let start = alignment == .inside ? 20 : alignment == .center ? 15 : 10
            for y in start..<start + 10 { XCTAssertEqual(raster.pixel(x: 50, y: y), red, "\(ellipse) \(alignment) y=\(y)") }
            XCTAssertEqual(raster.pixel(x: 50, y: start - 1), .clear)
            XCTAssertEqual(raster.pixel(x: 50, y: start + (ellipse && alignment != .outside ? 11 : 10)), .clear, "\(ellipse) \(alignment) first inner pixel")
            XCTAssertEqual(raster.pixel(x: 50, y: 40), .clear)
        } }
    }

    func testInsideStrokeCanExceedShapeDimensionsWithoutCollapsingOrExpanding() {
        let rect = CGRect(x: 20, y: 25, width: 8, height: 6)
        for ellipse in [false, true] { for smooth in [false, true] {
            var raster = Raster(width: 60, height: 60)
            raster.strokeShape(in: rect, ellipse: ellipse, size: 100, color: red, opacity: 1, clip: nil, antialias: smooth, alignment: .inside)
            XCTAssertEqual(bounds(raster), rect, "\(ellipse) smooth=\(smooth)")
            XCTAssertEqual(raster.pixel(x: 24, y: 28), red, "\(ellipse) smooth=\(smooth)")
            XCTAssertEqual(raster.pixel(x: 19, y: 28), .clear)
        } }
    }

    func testAlignedFillOpacityAndFeatheredSelectionApplyOnce() {
        let mask = SelectionMask(width: 100, height: 90, coverage: Data(repeating: 128, count: 9000))
        for ellipse in [false, true] { for alignment in ShapeOutlineAlignment.allCases { for hardness in [0.0, 1] {
            var raster = Raster(width: 100, height: 90)
            raster.strokeShape(in: CGRect(x: 20, y: 20, width: 60, height: 40), ellipse: ellipse, size: 10, color: red,
                               opacity: 0.5, clip: nil, selection: mask, antialias: false, fillColor: blue, hardness: hardness, alignment: alignment)
            XCTAssertEqual(raster.pixel(x: 50, y: 40).a, 64)
            let pixels = raster.bytes
            XCTAssertLessThanOrEqual(stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }.max()!, 64)
            XCTAssertEqual(raster.pixel(x: 50, y: 40).b, 255)
            if alignment == .inside { XCTAssertEqual(raster.pixel(x: 50, y: 19).a, 0) }
        } } }
    }

    func testSoftAlignmentRetainsPartialCoverageAndStaysOnTheCorrectSide() {
        for ellipse in [false, true] { for alignment in [ShapeOutlineAlignment.inside, .outside] {
            var raster = Raster(width: 100, height: 90)
            raster.strokeShape(in: CGRect(x: 20, y: 20, width: 60, height: 40), ellipse: ellipse, size: 10, color: red,
                               opacity: 1, clip: nil, antialias: false, hardness: 0, alignment: alignment)
            let near = raster.pixel(x: 50, y: alignment == .inside ? 20 : 19).a
            let far = raster.pixel(x: 50, y: alignment == .inside ? 27 : 12).a
            XCTAssertGreaterThan(near, far); XCTAssertGreaterThan(far, 0)
            XCTAssertEqual(raster.pixel(x: 50, y: alignment == .inside ? 19 : 20).a, 0, "\(ellipse) \(alignment)")
            XCTAssertTrue(raster.bytes.enumerated().contains { $0.offset % 4 == 3 && $0.element > 0 && $0.element < 255 })
        } }
    }

    func testOptionStartsShapesWithoutSamplingAndWorksForBothButtonsAndLine() {
        let (doc, canvas, window) = setup(); defer { window.close(); doc.close() }
        var picked = false; canvas.onColorPick = { _, _ in picked = true }
        let a = CGPoint(x: 60, y: 50), b = CGPoint(x: 80, y: 65)
        canvas.brushSize = 10; canvas.shapeAlignment = .inside
        for tool in [PaintTool.rectangle, .ellipse, .line] { for right in [false, true] {
            doc.state.layers[1].raster = Raster(width: 120, height: 100); canvas.tool = tool
            transaction(doc) {
                canvas.mouseDown(with: mouse(right ? .rightMouseDown : .leftMouseDown, a, canvas, .option))
                canvas.mouseDragged(with: mouse(right ? .rightMouseDragged : .leftMouseDragged, b, canvas, .option))
                canvas.mouseUp(with: mouse(right ? .rightMouseUp : .leftMouseUp, b, canvas, .option))
            }
            let drawn = bounds(doc.state.activeLayer.raster)
            XCTAssertEqual(drawn.midX, 60, accuracy: tool == .line ? 0.5 : 0)
            XCTAssertEqual(drawn.midY, 50, accuracy: tool == .line ? 0.5 : 0)
            if tool != .line { XCTAssertEqual(drawn, CGRect(x: 40, y: 35, width: 40, height: 30)) }
            XCTAssertTrue(doc.state.activeLayer.raster.bytes.contains { $0 > 0 })
        } }
        XCTAssertFalse(picked)
        canvas.tool = .brush
        canvas.mouseDown(with: mouse(.leftMouseDown, a, canvas, .option))
        XCTAssertTrue(picked, "Brush Option-click remains the color picker")
    }

    func testLiveModifierPreviewIsReversibleAndCommitsExactlyOneUndo() {
        let (doc, canvas, window) = setup(); defer { window.close(); doc.close() }
        canvas.tool = .rectangle; canvas.brushSize = 10; canvas.shapeAlignment = .inside
        let a = CGPoint(x: 60, y: 50), b = CGPoint(x: 80, y: 65), original = doc.state
        transaction(doc) {
            canvas.mouseDown(with: mouse(.leftMouseDown, a, canvas))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, b, canvas))
            let corner = doc.state.activeLayer.raster
            XCTAssertEqual(bounds(corner), CGRect(x: 60, y: 50, width: 20, height: 15))
            canvas.flagsChanged(with: flags(.option, canvas))
            XCTAssertEqual(bounds(doc.state.activeLayer.raster), CGRect(x: 40, y: 35, width: 40, height: 30))
            canvas.flagsChanged(with: flags([], canvas)); XCTAssertEqual(doc.state.activeLayer.raster, corner)
            canvas.flagsChanged(with: flags([.option, .shift], canvas))
            XCTAssertEqual(bounds(doc.state.activeLayer.raster), CGRect(x: 40, y: 30, width: 40, height: 40))
            let preview = doc.state.activeLayer.raster
            canvas.mouseUp(with: mouse(.leftMouseUp, b, canvas, [.option, .shift]))
            XCTAssertEqual(doc.state.activeLayer.raster, preview)
        }
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, original); XCTAssertFalse(doc.undoManager!.canUndo)
        doc.undoManager!.redo(); XCTAssertEqual(bounds(doc.state.activeLayer.raster), CGRect(x: 40, y: 30, width: 40, height: 40))
    }

    func testCenteredMarqueesUseExactBoundsAndKeepInitialCombineMode() {
        let (doc, canvas, window) = setup(); defer { window.close(); doc.close() }
        let original = SelectionMask.rectangle(CGRect(x: 5, y: 5, width: 10, height: 10), width: 120, height: 100)
        let a = CGPoint(x: 60, y: 50), b = CGPoint(x: 80, y: 65)
        for tool in [PaintTool.selection, .ellipseSelect] {
            canvas.tool = tool; canvas.selection = original
            transaction(doc) {
                canvas.mouseDown(with: mouse(.leftMouseDown, a, canvas, .shift))
                canvas.mouseDragged(with: mouse(.leftMouseDragged, b, canvas))
                canvas.flagsChanged(with: flags(.option, canvas))
                XCTAssertEqual(canvas.selection?.value(x: 10, y: 10), 255, "Add was latched at mouse-down")
                XCTAssertEqual(canvas.selection?.value(x: 60, y: 36), 255)
                canvas.flagsChanged(with: flags([], canvas))
                XCTAssertEqual(canvas.selection?.value(x: 60, y: 36), 0)
                canvas.flagsChanged(with: flags([.option, .control], canvas))
                canvas.mouseUp(with: mouse(.leftMouseUp, b, canvas, [.option, .control]))
            }
            XCTAssertEqual(canvas.selection?.value(x: 60, y: 31), 255)
            XCTAssertEqual(canvas.selection?.value(x: 60, y: 29), 0)
            XCTAssertEqual(canvas.selection?.value(x: 10, y: 10), 255)
        }
        canvas.tool = .selection; canvas.selection = .all(width: 120, height: 100)
        transaction(doc) {
            canvas.mouseDown(with: mouse(.leftMouseDown, a, canvas, .option))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, b, canvas, .option))
            canvas.mouseUp(with: mouse(.leftMouseUp, b, canvas, .option))
        }
        XCTAssertEqual(canvas.selection?.value(x: 65, y: 55), 0)
        XCTAssertEqual(canvas.selection?.value(x: 50, y: 40), 255, "Option before drag keeps corner-based Subtract")
    }

    func testCenteredSharpSquarePixelBoundsMatchForOddAndEvenWidthsAndEveryAlignment() {
        let (doc, canvas, window) = setup(); defer { window.close(); doc.close() }
        doc.undoManager!.disableUndoRegistration()
        for tool in [PaintTool.rectangle, .ellipse] { for alignment in ShapeOutlineAlignment.allCases { for thickness in [1.0, 2, 9, 10] {
            for sx: CGFloat in [-1, 1] { for sy: CGFloat in [-1, 1] {
                doc.state.layers[1].raster = Raster(width: 120, height: 100)
                canvas.tool = tool; canvas.shapeAlignment = alignment; canvas.brushSize = thickness
                let a = CGPoint(x: 60.2, y: 50.8), b = CGPoint(x: a.x + sx * 14.7, y: a.y + sy * 12.6)
                canvas.mouseDown(with: mouse(.leftMouseDown, a, canvas, .option))
                canvas.mouseDragged(with: mouse(.leftMouseDragged, b, canvas, [.shift, .option]))
                canvas.mouseUp(with: mouse(.leftMouseUp, b, canvas, [.shift, .option]))
                let drawn = bounds(doc.state.activeLayer.raster)
                XCTAssertEqual(drawn.width, drawn.height, "\(tool) \(alignment) \(thickness) \(sx),\(sy)")
            } }
        } } }
    }

    func testAlignedShapesOnMasksAndHighPrecisionRGBKeepTheirFormatAndCancelSafely() {
        let (doc, canvas, window) = setup(); defer { window.close(); doc.close() }
        doc.state = DocumentState(width: 120, height: 100, format: RGBFormat(profile: .displayP3, depth: .sixteen))
        canvas.shapeAlignment = .inside; canvas.brushSize = 10; canvas.tool = .rectangle
        let a = CGPoint(x: 20, y: 20), b = CGPoint(x: 80, y: 60)
        let before = doc.state
        canvas.mouseDown(with: mouse(.leftMouseDown, a, canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, b, canvas))
        XCTAssertEqual(doc.state.editingRaster.format, doc.state.format)
        XCTAssertEqual(bounds(doc.state.editingRaster), CGRect(x: 20, y: 20, width: 60, height: 40))
        canvas.mouseDown(with: mouse(.rightMouseDown, b, canvas)); XCTAssertEqual(doc.state, before)
        canvas.mouseUp(with: mouse(.rightMouseUp, b, canvas)); canvas.mouseUp(with: mouse(.leftMouseUp, b, canvas))
        doc.state.layers[1].mask = .empty(width: 120, height: 100); doc.state.editingMask = true; canvas.color = .white
        for quickMask in [false, true] {
            if quickMask { doc.state.quickMask = .empty(width: 120, height: 100) }
            transaction(doc) {
                canvas.mouseDown(with: mouse(.leftMouseDown, a, canvas))
                canvas.mouseDragged(with: mouse(.leftMouseDragged, b, canvas))
                canvas.mouseUp(with: mouse(.leftMouseUp, b, canvas))
            }
            let mask = quickMask ? doc.state.quickMask : doc.state.activeLayer.mask
            XCTAssertEqual(mask?.bounds, CGRect(x: 20, y: 20, width: 60, height: 40))
            XCTAssertEqual(mask?.value(x: 19, y: 40), 0); XCTAssertEqual(mask?.value(x: 20, y: 40), 255)
        }
    }

    func testVeryThickOutsideAndSoftInsideEllipsesRemainVisible() {
        let rect = CGRect(x: 140, y: 145, width: 8, height: 6)
        for ellipse in [false, true] {
            var outside = Raster(width: 300, height: 300)
            outside.strokeShape(in: rect, ellipse: ellipse, size: 100, color: red, opacity: 1, clip: nil, antialias: false, alignment: .outside)
            XCTAssertEqual(bounds(outside), rect.insetBy(dx: -100, dy: -100))
            XCTAssertEqual(outside.pixel(x: 144, y: 148), .clear)
            XCTAssertEqual(outside.pixel(x: 144, y: 100), red)
            var inside = Raster(width: 300, height: 300)
            inside.strokeShape(in: rect, ellipse: ellipse, size: 100, color: red, opacity: 1, clip: nil, antialias: false, hardness: 0, alignment: .inside)
            XCTAssertEqual(bounds(inside), rect)
            XCTAssertGreaterThan(inside.pixel(x: 144, y: 148).a, 245)
        }
    }

    func testOutsideClipKeepsTopLeftOrientationInAsymmetricScratchRegions() {
        let clip = CGRect(x: 0, y: 10, width: 100, height: 35)
        for hardness in [0.0, 1] {
            var raster = Raster(width: 100, height: 90)
            raster.strokeShape(in: CGRect(x: 20, y: 20, width: 60, height: 40), ellipse: true, size: 10, color: red,
                               opacity: 1, clip: clip, antialias: false, hardness: hardness, alignment: .outside)
            XCTAssertGreaterThan(raster.pixel(x: 50, y: 15).a, 0)
            XCTAssertEqual(raster.pixel(x: 50, y: 20).a, 0)
            XCTAssertEqual(raster.pixel(x: 50, y: 35).a, 0)
            XCTAssertEqual(raster.pixel(x: 50, y: 65).a, 0)
        }
    }

    func testOptionCenteredShapesCanStartOutsideImage() {
        let (doc, canvas, window) = setup(); defer { window.close(); doc.close() }
        canvas.brushSize = 10; canvas.shapeAlignment = .inside
        for tool in [PaintTool.rectangle, .ellipse] {
            doc.state.layers[1].raster = Raster(width: 120, height: 100); canvas.tool = tool
            transaction(doc) {
                canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: -8, y: 20), canvas, .option))
                canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 25, y: 45), canvas, .option))
                canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 25, y: 45), canvas, .option))
            }
            XCTAssertGreaterThan(doc.state.activeLayer.raster.pixel(x: 20, y: 20).a, 0)
            XCTAssertEqual(doc.state.activeLayer.raster.pixel(x: 35, y: 20).a, 0)
        }
    }

    func testOutlineUIIsReachableAndChangesOnlyToolSettings() throws {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.makeWindowControllers(); defer { doc.close() }
        let editor = doc.windowControllers[0] as! EditorWindowController, root = editor.window!.contentView!
        func views(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + views($0) } }
        let popup = try XCTUnwrap(views(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Shape outline alignment" })
        let original = doc.state
        for size in [CGSize(width: 1320, height: 800), CGSize(width: 960, height: 580)] {
            editor.window!.setContentSize(size)
            editor.selectTool(.rectangle); root.layoutSubtreeIfNeeded()
            XCTAssertFalse(popup.isHiddenOrHasHiddenAncestor)
            XCTAssertEqual(popup.itemTitles, ["Inside", "Center", "Outside"])
            popup.scrollToVisible(popup.bounds); root.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(popup.enclosingScrollView)
            XCTAssertTrue(scroll.contentView.bounds.contains(popup.convert(popup.bounds, to: scroll.contentView)))
            popup.selectItem(withTitle: "Inside"); _ = NSApp.sendAction(popup.action!, to: popup.target, from: popup)
            XCTAssertEqual(editor.canvas.shapeAlignment, .inside)
            editor.selectTool(.ellipse); root.layoutSubtreeIfNeeded(); XCTAssertEqual(popup.titleOfSelectedItem, "Inside")
            for tool in [PaintTool.brush, .selection, .line, .text] { editor.selectTool(tool); XCTAssertTrue(popup.isHiddenOrHasHiddenAncestor) }
        }
        XCTAssertEqual(doc.state, original); XCTAssertFalse(doc.undoManager!.canUndo)
    }
}
