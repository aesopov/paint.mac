import AppKit
import XCTest
@testable import PaintMac

final class CornerBorderTests: XCTestCase {
    private let blue = PixelColor(r: 50, g: 110, b: 240)
    private let pink = PixelColor(r: 255, g: 80, b: 130)
    private let rect = CGRect(x: 20, y: 20, width: 80, height: 60)

    func testSixCornerStylesHaveDistinctGeometryAndSelectionMatchesPaintedShape() throws {
        var areas: [RectangleCornerStyle: Int] = [:]
        for style in RectangleCornerStyle.allCases {
            let corners = RectangleCorners(style: style, radius: 20)
            let mask = SelectionMask.rectangle(rect, width: 120, height: 100, corners: corners)
            var raster = Raster(width: 120, height: 100)
            raster.strokeShape(in: rect, ellipse: false, size: 100, color: pink, opacity: 1, clip: nil,
                               antialias: false, fillColor: blue, hardness: 0, alignment: .outside, drawOutline: false, corners: corners)
            let bytes = raster.bytes, coverage = mask.coverage
            XCTAssertEqual(mask.bounds, rect)
            XCTAssertEqual(mask.value(x: 60, y: 50), 255)
            XCTAssertEqual(mask.value(x: 21, y: 21), style == .square ? 255 : 0)
            for i in 0..<coverage.count { XCTAssertEqual(bytes[i * 4 + 3], coverage[i], "\(style) at \(i)") }
            areas[style] = coverage.reduce(0) { $0 + Int($1) }
        }
        let ordered: [RectangleCornerStyle] = [.square, .squircle, .round, .bevel, .scoop, .notch]
        for pair in zip(ordered, ordered.dropFirst()) { XCTAssertGreaterThan(areas[pair.0]!, areas[pair.1]!) }
        if let directory = ProcessInfo.processInfo.environment["PAINTMAC_GEOMETRY_PREVIEW_DIR"] {
            var preview = Raster(width: 900, height: 390, color: .white)
            for (row, border) in ShapeBorderStyle.allCases.enumerated() {
                for (column, style) in RectangleCornerStyle.allCases.enumerated() {
                    preview.strokeShape(in: CGRect(x: column * 150 + 20, y: row * 130 + 20, width: 110, height: 90), ellipse: false,
                                        size: 5, color: blue, opacity: 1, clip: nil, fillColor: pink,
                                        corners: RectangleCorners(style: style, radius: 24), border: ShapeBorder(style: border, dashLength: 14, gap: 8))
                }
            }
            let rep = NSBitmapImageRep(cgImage: preview.cgImage)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("corners-borders.png"))
        }
    }

    func testRadiusZeroClampingAntialiasingAndOffImageCorners() {
        let rectangle = SelectionMask.rectangle(rect, width: 120, height: 100)
        for style in RectangleCornerStyle.allCases {
            XCTAssertEqual(SelectionMask.rectangle(rect, width: 120, height: 100, corners: RectangleCorners(style: style, radius: 0)), rectangle)
            XCTAssertEqual(SelectionMask.rectangle(rect, width: 120, height: 100, corners: RectangleCorners(style: style, radius: 9999)),
                           SelectionMask.rectangle(rect, width: 120, height: 100, corners: RectangleCorners(style: style, radius: 30)))
        }
        for smooth in [false, true] {
            let mask = SelectionMask.rectangle(CGRect(x: -10, y: -10, width: 80, height: 60), width: 120, height: 100,
                                               corners: RectangleCorners(style: .round, radius: 19.5), antialias: smooth)
            XCTAssertEqual(mask.value(x: 30, y: 0), 255)
            XCTAssertEqual(mask.value(x: 100, y: 0), 0)
            XCTAssertEqual(mask.coverage.contains { $0 > 0 && $0 < 255 }, smooth)
        }
    }

    func testDottedDashedAndDashLengthGapHavePredictablePixelsOnLines() {
        func line(_ style: ShapeBorderStyle, length: Double = 10, gap: Double = 6, smooth: Bool = false, hardness: Double = 1) -> Raster {
            var raster = Raster(width: 180, height: 60)
            raster.strokeLine(from: CGPoint(x: 10, y: 30), to: CGPoint(x: 160, y: 30), size: 6, color: blue,
                              opacity: 0.5, selection: nil, antialias: smooth, hardness: hardness,
                              border: ShapeBorder(style: style, dashLength: length, gap: gap))
            return raster
        }
        let solid = line(.solid), dashed = line(.dashed), longer = line(.dashed, length: 20), dots = line(.dotted, gap: 4)
        XCTAssertEqual(solid.pixel(x: 23, y: 30).a, 128)
        XCTAssertEqual(dashed.pixel(x: 12, y: 30).a, 128)
        XCTAssertEqual(dashed.pixel(x: 23, y: 30), .clear)
        XCTAssertEqual(longer.pixel(x: 23, y: 30).a, 128)
        XCTAssertEqual(dots.pixel(x: 10, y: 30).a, 128)
        XCTAssertEqual(dots.pixel(x: 15, y: 30), .clear)
        XCTAssertEqual(dots.pixel(x: 20, y: 30).a, 128)
        for style in [ShapeBorderStyle.dashed, .dotted] {
            let soft = line(style, smooth: true, hardness: 0)
            let bytes = soft.bytes
            XCTAssertTrue(stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 && bytes[$0] < 120 })
            XCTAssertLessThanOrEqual(stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }.max()!, 128)
        }
    }

    func testPatternedCornersRespectAlignmentOpacitySelectionAndFill() {
        let selection = SelectionMask(width: 120, height: 100, coverage: Data(repeating: 128, count: 12000))
        for corner in RectangleCornerStyle.allCases { for style in [ShapeBorderStyle.dashed, .dotted] {
            for alignment in ShapeOutlineAlignment.allCases { for hardness in [0.0, 1] {
                var raster = Raster(width: 120, height: 100)
                raster.strokeShape(in: rect, ellipse: false, size: 6, color: blue, opacity: 0.5, clip: nil, selection: selection,
                                   antialias: false, fillColor: pink, hardness: hardness, alignment: alignment,
                                   corners: RectangleCorners(style: corner, radius: 15), border: ShapeBorder(style: style, dashLength: 10, gap: 8))
                XCTAssertEqual(raster.pixel(x: 60, y: 50).a, 64)
                XCTAssertEqual(raster.pixel(x: 60, y: 50).r, 255)
                let data = raster.bytes
                XCTAssertLessThanOrEqual(stride(from: 3, to: data.count, by: 4).map { data[$0] }.max()!, 64)
                XCTAssertEqual(raster.pixel(x: 5, y: 5), .clear)
                if alignment == .inside { XCTAssertEqual(raster.pixel(x: 60, y: 19), .clear) }
            } }
        } }
    }

    func testWidePatternedInsideOutlineKeepsGapsAndFillOnlyIgnoresBorder() {
        let area = CGRect(x: 20, y: 20, width: 80, height: 20)
        for style in [ShapeBorderStyle.dotted, .dashed] {
            var raster = Raster(width: 120, height: 80)
            raster.strokeShape(in: area, ellipse: false, size: 25, color: blue, opacity: 1, clip: nil, antialias: false,
                               alignment: .inside, border: ShapeBorder(style: style, dashLength: 10, gap: 300))
            XCTAssertEqual(raster.pixel(x: 60, y: 20), .clear, "Wide dashed outlines must not take the solid-fill shortcut")
            var fill = Raster(width: 120, height: 80)
            fill.strokeShape(in: area, ellipse: false, size: 25, color: blue, opacity: 1, clip: nil, antialias: false,
                             fillColor: pink, alignment: .inside, drawOutline: false, border: ShapeBorder(style: style))
            XCTAssertEqual(fill.pixel(x: 60, y: 20), pink)
        }
    }

    private func fixture() -> (PaintDocument, EditorWindowController) {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 120, height: 100)
        doc.makeWindowControllers(); doc.undoManager!.groupsByEvent = false
        return (doc, doc.windowControllers[0] as! EditorWindowController)
    }
    private func views(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + views($0) } }
    private func mouse(_ type: NSEvent.EventType, _ point: CGPoint, _ canvas: CanvasView, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let point = CGPoint(x: canvas.imageRect.minX + point.x * canvas.zoom, y: canvas.imageRect.minY + point.y * canvas.zoom)
        return NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
                                 windowNumber: canvas.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    func testCornerSelectionGesturesCombineUndoAndCancelWithoutChangingArtwork() {
        let (doc, editor) = fixture(); defer { doc.close() }
        let canvas = editor.canvas
        editor.window!.contentView!.layoutSubtreeIfNeeded(); canvas.setZoom(1)
        canvas.rectangleCorners = RectangleCorners(style: .scoop, radius: 15); editor.selectTool(.selection)
        let before = doc.state
        doc.undoManager!.beginUndoGrouping()
        canvas.mouseDown(with: mouse(.leftMouseDown, rect.origin, canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: rect.maxX, y: rect.maxY), canvas))
        let preview = doc.state
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: rect.maxX, y: rect.maxY), canvas))
        doc.undoManager!.endUndoGrouping()
        XCTAssertEqual(doc.state.selection, .rectangle(rect, width: 120, height: 100, corners: canvas.rectangleCorners, antialias: true))
        XCTAssertEqual(doc.state.layers, before.layers)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, before)
        canvas.mouseDown(with: mouse(.leftMouseDown, rect.origin, canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: rect.maxX, y: rect.maxY), canvas))
        canvas.mouseDown(with: mouse(.rightMouseDown, CGPoint(x: 50, y: 50), canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 100, y: 80), canvas))
        canvas.mouseUp(with: mouse(.rightMouseUp, CGPoint(x: 50, y: 50), canvas))
        XCTAssertEqual(doc.state, before); XCTAssertTrue(doc.undoManager!.canRedo)
        doc.undoManager!.redo(); XCTAssertEqual(doc.state, preview)
        doc.undoManager!.beginUndoGrouping()
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 40, y: 30), canvas, flags: .option))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 80, y: 70), canvas, flags: .option))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 80, y: 70), canvas, flags: .option))
        doc.undoManager!.endUndoGrouping()
        XCTAssertEqual(doc.state.selection!.value(x: 60, y: 50), 0)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, preview)
    }

    func testPatternedCornerGesturesKeepPreviewsStableAndUndoOnImageAndMasks() {
        for target in 0..<3 { for tool in [PaintTool.rectangle, .line] {
            let (doc, editor) = fixture(); defer { doc.close() }
            doc.state = DocumentState(width: 120, height: 100, format: RGBFormat(profile: .displayP3, depth: .sixteen))
            if target == 1 { doc.state.activeLayer.mask = .all(width: 120, height: 100); doc.state.editingMask = true }
            if target == 2 { doc.state.quickMask = .empty(width: 120, height: 100) }
            let canvas = editor.canvas
            editor.window!.contentView!.layoutSubtreeIfNeeded(); canvas.setZoom(1)
            canvas.rectangleCorners = RectangleCorners(style: .scoop, radius: 12)
            canvas.shapeBorder = ShapeBorder(style: .dotted, dashLength: 10, gap: 8)
            canvas.shapePaintMode = .outlineAndFill; canvas.brushSize = 5; canvas.brushHardness = 0.3; canvas.brushOpacity = 0.5
            canvas.color = blue; canvas.alternateColor = pink; canvas.shapeAlignment = .inside; editor.selectTool(tool)
            let before = doc.state
            doc.undoManager!.beginUndoGrouping()
            canvas.rightMouseDown(with: mouse(.rightMouseDown, rect.origin, canvas))
            canvas.rightMouseDragged(with: mouse(.rightMouseDragged, CGPoint(x: rect.maxX, y: rect.maxY), canvas))
            let preview = doc.state
            canvas.rightMouseDragged(with: mouse(.rightMouseDragged, CGPoint(x: rect.maxX, y: rect.maxY), canvas))
            XCTAssertEqual(doc.state, preview)
            canvas.rightMouseUp(with: mouse(.rightMouseUp, CGPoint(x: rect.maxX, y: rect.maxY), canvas))
            doc.undoManager!.endUndoGrouping()
            XCTAssertNotEqual(doc.state, before)
            XCTAssertEqual(doc.state, preview)
            XCTAssertEqual(doc.state.format, before.format)
            if target == 0 { XCTAssertEqual(doc.state.activeLayer.raster.format.depth, .sixteen) }
            else { XCTAssertEqual(doc.state.layers.map(\.raster), before.layers.map(\.raster)) }
            doc.undoManager!.undo(); XCTAssertEqual(doc.state, before)
            XCTAssertFalse(doc.undoManager!.canUndo)
            doc.undoManager!.redo(); XCTAssertEqual(doc.state, preview)
        } }
    }

    func testSettingsControlsReachableAtMinimumSizeAndDoNotEditDocument() throws {
        let (doc, editor) = fixture(); defer { doc.close() }
        let root = editor.window!.contentView!, canvas = editor.canvas
        let controls = views(root)
        func popup(_ title: String) throws -> NSPopUpButton { try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == title }) }
        func field(_ title: String) throws -> NSTextField { try XCTUnwrap(controls.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == title }) }
        let corners = try popup("Rectangle corner style"), border = try popup("Shape border style")
        let radius = try field("Rectangle corner radius in pixels"), dash = try field("Border dash length in pixels"), gap = try field("Border gap in pixels")
        let before = doc.state
        editor.selectTool(.rectangle)
        corners.selectItem(withTitle: "Squircle"); _ = NSApp.sendAction(corners.action!, to: corners.target, from: corners)
        radius.stringValue = "12"; _ = NSApp.sendAction(radius.action!, to: radius.target, from: radius)
        border.selectItem(withTitle: "Dashed"); _ = NSApp.sendAction(border.action!, to: border.target, from: border)
        dash.stringValue = "17"; _ = NSApp.sendAction(dash.action!, to: dash.target, from: dash)
        gap.stringValue = "5"; _ = NSApp.sendAction(gap.action!, to: gap.target, from: gap)
        XCTAssertEqual(canvas.rectangleCorners, RectangleCorners(style: .squircle, radius: 12))
        XCTAssertEqual(canvas.shapeBorder, ShapeBorder(style: .dashed, dashLength: 17, gap: 5))
        radius.stringValue = "13"
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: radius))
        XCTAssertEqual(canvas.rectangleCorners.radius, 13, "Leaving the field must apply its value")
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            editor.window!.appearance = NSAppearance(named: theme)
            editor.window!.setContentSize(CGSize(width: 960, height: 580))
            for control in [corners, radius, border, dash, gap] {
                root.layoutSubtreeIfNeeded(); control.scrollToVisible(control.bounds); root.layoutSubtreeIfNeeded()
                let clip = try XCTUnwrap(control.enclosingScrollView?.contentView)
                XCTAssertTrue(clip.bounds.contains(control.convert(control.bounds, to: clip)))
            }
        }
        editor.selectTool(.selection)
        XCTAssertFalse(corners.isHiddenOrHasHiddenAncestor); XCTAssertTrue(border.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(corners.titleOfSelectedItem, "Squircle")
        editor.selectTool(.ellipse)
        XCTAssertTrue(corners.isHiddenOrHasHiddenAncestor); XCTAssertFalse(border.isHiddenOrHasHiddenAncestor)
        editor.selectTool(.rectangle); canvas.shapePaintMode = .fill
        XCTAssertTrue(border.isHiddenOrHasHiddenAncestor); XCTAssertFalse(corners.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(doc.state, before); XCTAssertFalse(doc.undoManager!.canUndo)
    }

    private func pixels(_ image: NSImage) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 72, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 288, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(x: 0, y: 0, width: 72, height: 72)); NSGraphicsContext.restoreGraphicsState()
        return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
    }
    func testIconsReflectCornerGeometryRadiusBorderAndPaintMode() {
        _ = NSApplication.shared
        let button = ToolGroupButton(group: .shapes), selections = ToolGroupButton(group: .selections)
        var cornerIcons: [Data] = [], selectionIcons: [Data] = []
        for style in RectangleCornerStyle.allCases {
            let corners = RectangleCorners(style: style, radius: 20)
            button.rectangleCorners = corners; selections.rectangleCorners = corners
            cornerIcons.append(pixels(button.image!)); selectionIcons.append(pixels(selections.image!))
        }
        XCTAssertEqual(Set(cornerIcons).count, 6); XCTAssertEqual(Set(selectionIcons).count, 6)
        button.rectangleCorners = RectangleCorners(style: .round, radius: 4)
        let smallRadius = pixels(button.image!)
        button.rectangleCorners.radius = 20; XCTAssertNotEqual(pixels(button.image!), smallRadius)
        var patterns: [Data] = []
        for style in ShapeBorderStyle.allCases {
            button.shapeBorder.style = style; patterns.append(pixels(button.image!))
        }
        XCTAssertEqual(Set(patterns).count, 3)
        button.shapeBorder.style = .dashed; button.shapeBorder.dashLength = 3
        let short = pixels(button.image!)
        button.shapeBorder.dashLength = 18; XCTAssertNotEqual(pixels(button.image!), short)
        button.shapePaintMode = .fill
        let fill = pixels(button.image!); button.shapeBorder.style = .solid
        XCTAssertEqual(pixels(button.image!), fill, "A fill-only icon has no border pattern")
    }
}
