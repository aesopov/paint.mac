import XCTest
import AppKit
@testable import PaintMac

final class PaintingAndSizingTests: XCTestCase {
    let red = PixelColor(r: 255, g: 0, b: 0)
    let blue = PixelColor(r: 0, g: 0, b: 255)

    private func alphas(_ raster: Raster) -> [UInt8] {
        stride(from: 3, to: raster.bytes.count, by: 4).map { raster.bytes[$0] }
    }
    func testSharpBrushLineAndShapesDisableAntialiasingAndOnePixelBrushWorks() {
        var sharp = Raster(width: 50, height: 40), smooth = sharp
        sharp.stroke(from: CGPoint(x: 4.2, y: 3.7), to: CGPoint(x: 34.8, y: 25.3), size: 9,
                     color: red, opacity: 1, erase: false, clip: nil, antialias: false)
        smooth.stroke(from: CGPoint(x: 4.2, y: 3.7), to: CGPoint(x: 34.8, y: 25.3), size: 9,
                      color: red, opacity: 1, erase: false, clip: nil, antialias: true)
        XCTAssertTrue(alphas(sharp).allSatisfy { $0 == 0 || $0 == 255 })
        XCTAssertTrue(alphas(smooth).contains { $0 > 0 && $0 < 255 })
        var dot = Raster(width: 10, height: 10)
        dot.stroke(from: CGPoint(x: 4, y: 4), to: CGPoint(x: 4, y: 4), size: 1,
                   color: red, opacity: 1, erase: false, clip: nil, antialias: false)
        XCTAssertEqual(dot.pixel(x: 4, y: 4), red)
        for ellipse in [false, true] {
            var outline = Raster(width: 50, height: 40)
            outline.strokeShape(in: CGRect(x: 4.3, y: 5.6, width: 35.4, height: 25.2), ellipse: ellipse,
                                size: 7, color: red, opacity: 1, clip: nil, antialias: false)
            XCTAssertTrue(alphas(outline).allSatisfy { $0 == 0 || $0 == 255 })
            XCTAssertTrue(alphas(outline).contains(255))
        }
        sharp.stroke(from: CGPoint(x: 4, y: 4), to: CGPoint(x: 34, y: 25), size: 5,
                     color: .black, opacity: 1, erase: true, clip: nil, antialias: false)
        XCTAssertTrue(alphas(sharp).allSatisfy { $0 == 0 || $0 == 255 })
        let mask = SelectionMask.ellipse(CGRect(x: 2.2, y: 3.5, width: 24, height: 19), width: 50, height: 40, antialias: false)
        XCTAssertTrue(mask.coverage.allSatisfy { $0 == 0 || $0 == 255 })
    }

    func testSharpModePreservesIntentionalOpacityAndFeathering() {
        let mask = SelectionMask(width: 1, height: 1, coverage: Data([128]))
        var raster = Raster(width: 1, height: 1)
        raster.stroke(from: .zero, to: .zero, size: 3, color: red, opacity: 0.5,
                      erase: false, clip: nil, selection: mask, antialias: false)
        XCTAssertEqual(raster.pixel(x: 0, y: 0).a, 64)
    }

    func testTextRendersMultilineUnicodeAtClickedTopLeftAndSharpGlyphsHaveBinaryAlpha() {
        _ = NSApplication.shared
        let font = NSFont.systemFont(ofSize: 28)
        var smooth = Raster(width: 360, height: 180)
        smooth.drawText("Paint.MAC\nПривет!", at: CGPoint(x: 20, y: 15), font: font, color: blue,
                        opacity: 1, antialias: true, selection: nil)
        let pixels = alphas(smooth)
        XCTAssertTrue(pixels.contains { $0 > 0 && $0 < 255 })
        let occupied = pixels.enumerated().filter { $0.element > 0 }.map(\.offset)
        XCTAssertFalse(occupied.isEmpty)
        XCTAssertGreaterThanOrEqual(occupied.map { $0 / 360 }.min()!, 15)
        XCTAssertLessThan(occupied.map { $0 / 360 }.max()!, 110)
        XCTAssertGreaterThanOrEqual(occupied.map { $0 % 360 }.min()!, 20)
        var sharp = Raster(width: 180, height: 80)
        sharp.drawText("Ag", at: CGPoint(x: 5, y: 5), font: font, color: red,
                       opacity: 1, antialias: false, selection: nil)
        XCTAssertTrue(alphas(sharp).allSatisfy { $0 == 0 || $0 == 255 })
        XCTAssertTrue(alphas(sharp).contains(255))
    }

    func testTextRespectsSelectionAndUndo() {
        _ = NSApplication.shared
        let document = PaintDocument()
        document.state = DocumentState(width: 180, height: 90)
        document.makeWindowControllers()
        defer { document.close() }
        let editor = document.windowControllers[0] as! EditorWindowController
        let mask = SelectionMask.rectangle(CGRect(x: 15, y: 10, width: 45, height: 35), width: 180, height: 90)
        editor.canvas.selection = mask
        document.undoManager?.groupsByEvent = false
        document.undoManager?.beginUndoGrouping()
        editor.paintText("Text text", at: CGPoint(x: 5, y: 5), font: .systemFont(ofSize: 30), color: red, opacity: 1, antialias: true)
        document.undoManager?.endUndoGrouping()
        let painted = document.state.activeLayer.raster
        XCTAssertTrue(alphas(painted).contains { $0 > 0 })
        for (index, alpha) in alphas(painted).enumerated() where alpha > 0 {
            XCTAssertGreaterThan(mask.value(x: index % 180, y: index / 180), 0)
        }
        document.undoManager?.undo()
        XCTAssertEqual(document.state.activeLayer.raster, Raster(width: 180, height: 90))
        document.undoManager?.redo()
        XCTAssertEqual(document.state.activeLayer.raster, painted)
    }

    func testCanvasDimensionsUnitsAnchorsAndEdges() throws {
        let percent = try CanvasSizePlan.dimensions(width: 200, height: 50, unit: .percent,
                                                   originalWidth: 100, originalHeight: 80, anchor: .center)
        XCTAssertEqual(percent, CanvasSizePlan(width: 200, height: 40, offsetX: 50, offsetY: -20))
        for anchor in CanvasAnchor.allCases {
            let plan = try CanvasSizePlan.dimensions(width: 8, height: 7, unit: .pixels, originalWidth: 4, originalHeight: 3, anchor: anchor)
            XCTAssertEqual(plan.offsetX, anchor.column * 2)
            XCTAssertEqual(plan.offsetY, anchor.row * 2)
        }
        let edges = try CanvasSizePlan.edges(left: 10, top: 25, right: -20, bottom: 0, unit: .percent, originalWidth: 100, originalHeight: 80)
        XCTAssertEqual(edges, CanvasSizePlan(width: 90, height: 100, offsetX: 10, offsetY: 20))
        let odd = try CanvasSizePlan.dimensions(width: 3, height: 3, unit: .pixels, originalWidth: 6, originalHeight: 6, anchor: .center)
        XCTAssertEqual(odd.offsetX, -2); XCTAssertEqual(odd.offsetY, -2)
    }

    func testCanvasResizePadsAndCropsWithoutScalingAndScalePreservesOrientation() throws {
        var image = Raster(width: 4, height: 3)
        image.fill(color: red, rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        image.fill(color: blue, rect: CGRect(x: 3, y: 2, width: 1, height: 1))
        let padded = image.resizedCanvas(width: 8, height: 7, offsetX: 4, offsetY: 4)
        XCTAssertEqual(padded.pixel(x: 4, y: 4), red)
        XCTAssertEqual(padded.pixel(x: 7, y: 6), blue)
        XCTAssertEqual(padded.pixel(x: 0, y: 0), .clear)
        let cropped = image.resizedCanvas(width: 6, height: 5, offsetX: -1, offsetY: 1)
        XCTAssertEqual(cropped.pixel(x: 2, y: 3), blue)
        XCTAssertEqual(cropped.pixel(x: 0, y: 1), .clear)
        let scaled = try image.scaled(width: 8, height: 6, smooth: false)
        XCTAssertEqual(scaled.pixel(x: 0, y: 0), red)
        XCTAssertEqual(scaled.pixel(x: 1, y: 1), red)
        XCTAssertEqual(scaled.pixel(x: 7, y: 5), blue)
        let mask = SelectionMask.rectangle(CGRect(x: 0, y: 0, width: 1, height: 1), width: 4, height: 3).scaled(width: 8, height: 6, smooth: false)
        XCTAssertEqual(mask.value(x: 1, y: 1), 255)
        XCTAssertEqual(mask.value(x: 1, y: 5), 0)
    }

    func testScaleResizeAndCropToolPreserveLayerStateAndUndo() throws {
        _ = NSApplication.shared
        let document = PaintDocument()
        document.state = DocumentState(width: 4, height: 3)
        document.state.layers[1].name = "Artwork"; document.state.layers[1].opacity = 0.4
        document.state.layers[1].raster.fill(color: blue)
        document.state.selection = .rectangle(CGRect(x: 0, y: 0, width: 2, height: 2), width: 4, height: 3)
        let original = document.state
        document.makeWindowControllers()
        defer { document.close() }
        let editor = document.windowControllers[0] as! EditorWindowController
        document.undoManager?.groupsByEvent = false
        document.undoManager?.beginUndoGrouping()
        try document.applySize(.dimensions(width: 200, height: 200, unit: .percent, originalWidth: 4, originalHeight: 3, anchor: .center), mode: .scale, smooth: false)
        document.undoManager?.endUndoGrouping()
        XCTAssertEqual(document.state.selection?.value(x: 3, y: 3), 255)
        XCTAssertEqual(document.state.layers[1].name, "Artwork"); XCTAssertEqual(document.state.layers[1].opacity, 0.4)
        let scaled = document.state
        document.undoManager?.beginUndoGrouping()
        try document.applySize(.edges(left: 2, top: 1, right: 0, bottom: 0, unit: .pixels, originalWidth: 8, originalHeight: 6), mode: .resize, smooth: true)
        document.undoManager?.endUndoGrouping()
        XCTAssertEqual(document.state.selection?.value(x: 2, y: 1), 255)
        XCTAssertEqual(document.state.layers[1].raster.pixel(x: 0, y: 0), .clear)
        document.undoManager?.undo(); XCTAssertEqual(document.state, scaled)
        document.undoManager?.undo(); XCTAssertEqual(document.state, original)
        document.undoManager?.beginUndoGrouping()
        editor.selectTool(.crop)
        document.undoManager?.endUndoGrouping()
        XCTAssertEqual(document.state.width, 2); XCTAssertEqual(document.state.height, 2)
        XCTAssertNil(document.state.selection)
        document.undoManager?.undo(); XCTAssertEqual(document.state, original)
    }

    func testInvalidCanvasSizesFailBeforeMutation() throws {
        XCTAssertThrowsError(try CanvasSizePlan.dimensions(width: .infinity, height: 100, unit: .pixels, originalWidth: 4, originalHeight: 4, anchor: .center))
        XCTAssertThrowsError(try CanvasSizePlan.edges(left: -100, top: 0, right: 0, bottom: 0, unit: .percent, originalWidth: 4, originalHeight: 4))
        XCTAssertThrowsError(try CanvasSizePlan.validate(width: 8192, height: 8192))
        let document = PaintDocument(); let before = document.state
        XCTAssertThrowsError(try document.applySize(CanvasSizePlan(width: 0, height: 20, offsetX: 0, offsetY: 0), mode: .resize, smooth: false))
        XCTAssertEqual(document.state, before)
    }

    func testSizeDialogPercentAndEdgeInputsStaySynchronized() {
        _ = NSApplication.shared
        let dialog = CanvasSizeDialog(width: 100, height: 80, mode: .resize, smooth: true)
        func subviews(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + subviews($0) } }
        let views = subviews(dialog.formView)
        let fields = views.compactMap { $0 as? NSTextField }.filter(\.isEditable)
        let units = views.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("Percent") }!
        units.selectItem(at: 1); _ = units.sendAction(units.action, to: units.target)
        let left = fields.first { $0.tag == 2 }!, width = fields.first { $0.tag == 0 }!
        left.stringValue = "10"
        dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: left))
        XCTAssertEqual(width.doubleValue, 110, accuracy: 0.001)
        let anchor = views.compactMap { $0 as? NSButton }.first { $0.title == "↖" }!
        anchor.performClick(nil)
        XCTAssertEqual(left.doubleValue, 0)
        let right = fields.first { $0.tag == 4 }!
        XCTAssertEqual(right.doubleValue, 10)
    }

    func testNewToolAndDialogLayouts() throws {
        _ = NSApplication.shared
        func views(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + views($0) } }
        func checkAndRender(_ form: NSView, name: String) throws {
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: form.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = form; form.layoutSubtreeIfNeeded()
            defer { window.close() }
            XCTAssertGreaterThan(form.bounds.width, 300)
            XCTAssertGreaterThan(form.bounds.height, 150)
            for control in views(form).compactMap({ $0 as? NSControl }) where !control.isHiddenOrHasHiddenAncestor {
                // Ignore NSTextView's scroll internals; all dialog form controls must fit.
                let rect = control.convert(control.bounds, to: form)
                XCTAssertTrue(form.bounds.insetBy(dx: -1, dy: -1).contains(rect), "\(name): \((control as? NSTextField)?.stringValue ?? "control") \(rect), form \(form.bounds)")
            }
            if let folder = ProcessInfo.processInfo.environment["PAINTMAC_UI_PREVIEW_DIR"],
               let bitmap = form.bitmapImageRepForCachingDisplay(in: form.bounds) {
                form.cacheDisplay(in: form.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
            }
        }
        let size = CanvasSizeDialog(width: 1200, height: 800, mode: .resize, smooth: true)
        try checkAndRender(size.formView, name: "size-dialog")

        let document = PaintDocument()
        document.makeWindowControllers()
        defer { document.close() }
        let editor = document.windowControllers[0] as! EditorWindowController
        editor.window!.setContentSize(CGSize(width: 960, height: 580))
        for tool in [PaintTool.brush, .ellipse, .ellipseSelect, .text] {
            editor.selectTool(tool)
            let root = editor.window!.contentView!
            root.layoutSubtreeIfNeeded()
            let edge = views(root).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 2 }!
            XCTAssertFalse(edge.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(root.bounds.contains(edge.convert(edge.bounds, to: root)))
            edge.selectedSegment = 1; _ = edge.sendAction(edge.action, to: edge.target)
            XCTAssertFalse(editor.canvas.smooth)
        }
    }
}
