import XCTest
import AppKit
@testable import PaintMac

final class LayerMaskTests: XCTestCase {
    private let red = PixelColor(r: 230, g: 30, b: 40)
    private func editor(width: Int = 64, height: Int = 48) -> (PaintDocument, EditorWindowController) {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: width, height: height)
        doc.makeWindowControllers()
        let editor = doc.windowControllers[0] as! EditorWindowController
        editor.window!.contentView!.layoutSubtreeIfNeeded(); editor.canvas.setZoom(1)
        doc.undoManager?.groupsByEvent = false
        return (doc, editor)
    }
    private func edit(_ doc: PaintDocument, _ work: () -> Void) {
        doc.undoManager!.beginUndoGrouping(); work(); doc.undoManager!.endUndoGrouping()
    }
    private func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, canvas: CanvasView) -> NSEvent {
        let p = CGPoint(x: canvas.imageRect.minX + x * canvas.zoom, y: canvas.imageRect.minY + y * canvas.zoom)
        return NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                                 windowNumber: canvas.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    func testMaskCompositePreservesAlphaOpacityOrientationAndPixels() throws {
        let renderer = ImageRenderer()
        var layer = PaintLayer(name: "Masked", raster: Raster(width: 3, height: 2, color: PixelColor(r: 200, g: 80, b: 40, a: 128)))
        let original = layer.raster
        layer.mask = SelectionMask(width: 3, height: 2, coverage: Data([0, 128, 255, 255, 64, 0])); layer.opacity = 0.5
        let image = try Raster(image: renderer.composite([layer], width: 3, height: 2))
        XCTAssertEqual(image.pixel(x: 0, y: 0).a, 0)
        XCTAssertEqual(image.pixel(x: 2, y: 1).a, 0)
        XCTAssertEqual(Int(image.pixel(x: 1, y: 0).a), 32, accuracy: 1)
        XCTAssertEqual(Int(image.pixel(x: 2, y: 0).a), 64, accuracy: 1)
        XCTAssertEqual(Int(image.pixel(x: 1, y: 1).a), 16, accuracy: 1)
        XCTAssertEqual(layer.raster, original)
        layer.maskEnabled = false
        let disabled = try Raster(image: renderer.composite([layer], width: 3, height: 2))
        XCTAssertEqual(Int(disabled.pixel(x: 0, y: 0).a), 64, accuracy: 1)
        layer.visible = false
        XCTAssertEqual(try Raster(image: renderer.composite([layer], width: 3, height: 2)), Raster(width: 3, height: 2))
    }

    func testMaskCoverageRoundTripsAllByteValuesWithoutGammaOrPremultiplicationLoss() {
        let mask = SelectionMask(width: 256, height: 1, coverage: Data((0...255).map(UInt8.init)))
        XCTAssertEqual(SelectionMask(editingRaster: mask.editingRaster), mask)
        XCTAssertEqual(PixelColor.white.maskColor, .white)
        XCTAssertEqual(PixelColor.maskBlack.maskColor, .maskBlack)
        var raster = mask.editingRaster
        raster.erase(selection: .rectangle(CGRect(x: 250, y: 0, width: 6, height: 1), width: 256, height: 1))
        XCTAssertEqual(SelectionMask(editingRaster: raster).value(x: 255, y: 0), 0)
    }

    func testV1MigrationV2RoundTripAndMalformedMaskRejection() throws {
        var state = DocumentState(width: 3, height: 2)
        let old = try ProjectCodec.encode(state)
        let manifestData = old.fileWrappers!["document.json"]!.regularFileContents!
        XCTAssertEqual(try JSONDecoder().decode(ProjectManifest.self, from: manifestData).version, 1)
        XCTAssertEqual(try ProjectCodec.decode(old), state)
        state.layers[0].mask = SelectionMask(width: 3, height: 2, coverage: Data([0, 1, 128, 254, 255, 42]))
        state.layers[0].maskEnabled = false
        state.layers[1].mask = .all(width: 3, height: 2)
        let wrapper = try ProjectCodec.encode(state)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".paintmac")
        defer { try? FileManager.default.removeItem(at: folder) }
        try wrapper.write(to: folder, options: .atomic, originalContentsURL: nil)
        XCTAssertEqual(try ProjectCodec.decode(FileWrapper(url: folder)), state)
        var manifest = try JSONDecoder().decode(ProjectManifest.self, from: wrapper.fileWrappers!["document.json"]!.regularFileContents!)
        XCTAssertEqual(manifest.version, 2)
        let maskFile = manifest.layers[0].maskFile!
        for invalid: Data? in [nil, Data([255]), Data(count: 7)] {
            var children = wrapper.fileWrappers!
            children[maskFile] = invalid.map { FileWrapper(regularFileWithContents: $0) }
            XCTAssertThrowsError(try ProjectCodec.decode(FileWrapper(directoryWithFileWrappers: children)))
        }
        for version in [1, 99] {
            var children = wrapper.fileWrappers!; manifest.version = version
            children["document.json"] = FileWrapper(regularFileWithContents: try JSONEncoder().encode(manifest))
            XCTAssertThrowsError(try ProjectCodec.decode(FileWrapper(directoryWithFileWrappers: children)))
        }
    }

    func testCreateFromFeatheredSelectionInvertDisableDeleteApplyAndUndo() throws {
        let (doc, editor) = editor()
        defer { doc.close() }
        doc.state.layers[1].raster.fill(color: red)
        let originalPixels = doc.state.activeLayer.raster
        let selection = SelectionMask.rectangle(CGRect(x: 12, y: 10, width: 24, height: 20), width: 64, height: 48)
            .feathered(radius: 2, context: doc.renderer.context)
        doc.state.selection = selection
        edit(doc) { editor.performMaskCommand(.fromSelection) }
        XCTAssertEqual(doc.state.activeLayer.mask, selection); XCTAssertNil(doc.state.selection)
        XCTAssertTrue(doc.state.isEditingMask)
        XCTAssertEqual(editor.canvas.color, .maskBlack); XCTAssertEqual(editor.canvas.alternateColor, .white)
        let created = doc.state
        edit(doc) { doc.invertLayerMask() }
        XCTAssertEqual(doc.state.activeLayer.mask, selection.inverted())
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, created)
        edit(doc) { doc.toggleLayerMask() }; XCTAssertFalse(doc.state.activeLayer.maskEnabled)
        doc.undoManager!.undo(); XCTAssertTrue(doc.state.activeLayer.maskEnabled)
        edit(doc) { doc.featherLayerMask(radius: 3) }
        XCTAssertNotEqual(doc.state.activeLayer.mask, selection)
        XCTAssertEqual(doc.state.activeLayer.raster, originalPixels)
        doc.undoManager!.undo()
        let visible = try Raster(image: doc.composite)
        edit(doc) { doc.deleteLayerMask(apply: true) }
        XCTAssertNil(doc.state.activeLayer.mask); XCTAssertFalse(doc.state.isEditingMask)
        XCTAssertNotEqual(doc.state.activeLayer.raster, originalPixels)
        XCTAssertEqual(try Raster(image: doc.composite), visible)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, created)
        edit(doc) { doc.deleteLayerMask(apply: false) }
        XCTAssertEqual(doc.state.activeLayer.raster, originalPixels)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, created)
        doc.undoManager!.undo(); XCTAssertNil(doc.state.activeLayer.mask); XCTAssertEqual(doc.state.selection, selection)
    }

    func testMaskBrushRightColorSharpOpacitySelectionUndoAndCancellation() {
        let (doc, editor) = editor()
        defer { doc.close() }
        let canvas = editor.canvas
        doc.state.layers[1].raster.fill(color: red)
        edit(doc) { doc.addLayerMask(.revealAll) }
        let pixels = doc.state.activeLayer.raster
        canvas.smooth = false; canvas.brushSize = 1; canvas.brushOpacity = 0.5
        doc.state.selection = .rectangle(CGRect(x: 10, y: 10, width: 10, height: 10), width: 64, height: 48)
        let before = doc.state
        edit(doc) {
            canvas.mouseDown(with: mouse(.leftMouseDown, 5, 15, canvas: canvas))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, 25, 15, canvas: canvas))
            canvas.mouseUp(with: mouse(.leftMouseUp, 25, 15, canvas: canvas))
        }
        XCTAssertEqual(doc.state.activeLayer.raster, pixels)
        XCTAssertEqual(doc.state.activeLayer.mask!.value(x: 15, y: 15), 128)
        XCTAssertEqual(doc.state.activeLayer.mask!.value(x: 5, y: 15), 255)
        XCTAssertEqual(doc.state.activeLayer.mask!.value(x: 15, y: 14), 255)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, before)
        doc.undoManager!.redo()
        canvas.brushOpacity = 1
        edit(doc) {
            canvas.rightMouseDown(with: mouse(.rightMouseDown, 15, 15, canvas: canvas))
            canvas.rightMouseUp(with: mouse(.rightMouseUp, 15, 15, canvas: canvas))
        }
        XCTAssertEqual(doc.state.activeLayer.mask!.value(x: 15, y: 15), 255)
        let canceled = doc.state
        canvas.mouseDown(with: mouse(.leftMouseDown, 15, 15, canvas: canvas))
        canvas.rightMouseDown(with: mouse(.rightMouseDown, 15, 15, canvas: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, 15, 15, canvas: canvas))
        canvas.rightMouseUp(with: mouse(.rightMouseUp, 15, 15, canvas: canvas))
        XCTAssertEqual(doc.state, canceled)
    }

    func testMaskFillShapesEraserDeleteAndAdjustmentsLeaveImageUntouched() {
        let (doc, editor) = editor()
        defer { doc.close() }
        doc.state.layers[1].raster.fill(color: red)
        edit(doc) { doc.addLayerMask(.revealAll) }
        let canvas = editor.canvas, pixels = doc.state.activeLayer.raster
        canvas.smooth = false; canvas.brushSize = 3
        for tool in [PaintTool.line, .rectangle, .ellipse, .eraser, .fill] {
            doc.state.layers[1].mask = .all(width: 64, height: 48)
            canvas.tool = tool
            edit(doc) {
                canvas.mouseDown(with: mouse(.leftMouseDown, 10, 10, canvas: canvas))
                canvas.mouseDragged(with: mouse(.leftMouseDragged, 30, 30, canvas: canvas))
                canvas.mouseUp(with: mouse(.leftMouseUp, 30, 30, canvas: canvas))
            }
            XCTAssertEqual(doc.state.activeLayer.raster, pixels)
            XCTAssertTrue(doc.state.activeLayer.mask!.coverage.contains { $0 < 255 }, "\(tool) must change the mask")
        }
        doc.state.selection = .rectangle(CGRect(x: 5, y: 5, width: 10, height: 10), width: 64, height: 48)
        doc.state.layers[1].mask = .all(width: 64, height: 48)
        edit(doc) { canvas.deletePixels() }
        XCTAssertEqual(doc.state.activeLayer.mask!.value(x: 8, y: 8), 0)
        XCTAssertEqual(doc.state.activeLayer.mask!.value(x: 20, y: 20), 255)
        edit(doc) { editor.applyAdjustment("CIColorInvert", name: "Invert Colors") }
        XCTAssertEqual(doc.state.activeLayer.mask!.value(x: 8, y: 8), 255)
        XCTAssertEqual(doc.state.activeLayer.raster, pixels)
    }

    func testMaskInlineTextPreviewCommitsExactVisiblePixelsAndCancels() throws {
        let (doc, editor) = editor(width: 200, height: 100)
        defer { doc.close() }
        doc.state.layers[1].raster.fill(color: red)
        edit(doc) { doc.addLayerMask(.revealAll) }
        let original = doc.state, canvas = editor.canvas
        canvas.beginText(in: CGRect(x: 10, y: 10, width: 160, height: 22), color: .black)
        canvas.textEditor!.textView.insertText("Mask text", replacementRange: NSRange(location: NSNotFound, length: 0))
        let preview = try Raster(image: canvas.displayedComposite)
        XCTAssertEqual(doc.state, original)
        edit(doc) { canvas.finishText() }
        XCTAssertEqual(doc.state.activeLayer.raster, original.activeLayer.raster)
        XCTAssertNotEqual(doc.state.activeLayer.mask, original.activeLayer.mask)
        XCTAssertEqual(try Raster(image: doc.composite), preview)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, original)
        canvas.beginText(in: CGRect(x: 10, y: 10, width: 160, height: 40), color: .black)
        canvas.textEditor!.textView.insertText("Cancel", replacementRange: NSRange(location: NSNotFound, length: 0))
        canvas.finishText(apply: false)
        XCTAssertEqual(doc.state, original)
    }

    func testThumbnailsSwitchTargetsRestorePixelColorsAndMenuStates() throws {
        let (doc, editor) = editor()
        defer { doc.close() }
        let normalColor = editor.canvas.color, id = doc.state.activeID
        XCTAssertFalse(LayerMaskCommand.fromSelection.isEnabled(in: doc.state))
        edit(doc) { editor.performMaskCommand(.hideAll) }
        XCTAssertTrue(doc.state.activeLayer.mask!.isEmpty)
        XCTAssertFalse(LayerMaskCommand.revealAll.isEnabled(in: doc.state))
        XCTAssertTrue(LayerMaskCommand.apply.isEnabled(in: doc.state))
        editor.window!.contentView!.layoutSubtreeIfNeeded()
        let thumbnails = descendants(editor.window!.contentView!).compactMap { $0 as? LayerThumbnailButton }
        let image = try XCTUnwrap(thumbnails.first { $0.layerID == id && !$0.editsMask })
        image.performClick(nil)
        XCTAssertFalse(doc.state.isEditingMask); XCTAssertEqual(editor.canvas.color, normalColor)
        editor.selectLayerTarget(id, mask: true)
        XCTAssertEqual(editor.canvas.color, .maskBlack)
        editor.setColor(PixelColor(r: 255, g: 0, b: 0))
        XCTAssertEqual(editor.canvas.color.r, editor.canvas.color.g)
        editor.selectLayerTarget(doc.state.layers[0].id, mask: false)
        XCTAssertFalse(doc.state.isEditingMask); XCTAssertEqual(editor.canvas.color, normalColor)
        editor.selectLayerTarget(id, mask: true)
        edit(doc) { editor.performMaskCommand(.toggle) }
        XCTAssertEqual(LayerMaskCommand.toggle.title(in: doc.state), "Enable Mask")
    }

    func testDuplicateMergeAndExportHonorMasks() throws {
        let (doc, editor) = editor()
        defer { doc.close() }
        doc.state.layers[1].raster.fill(color: red)
        doc.state.layers[1].mask = .rectangle(CGRect(x: 10, y: 10, width: 20, height: 15), width: 64, height: 48)
        doc.state.layers[0].mask = .rectangle(CGRect(x: 0, y: 0, width: 45, height: 48), width: 64, height: 48)
        doc.invalidate()
        let original = doc.state, composite = try Raster(image: doc.composite)
        edit(doc) { editor.duplicateLayer() }
        XCTAssertEqual(doc.state.activeLayer.mask, original.activeLayer.mask)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, original)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try doc.export(to: url, jpeg: false)
        XCTAssertEqual(try ProjectCodec.decodeImage(Data(contentsOf: url)), composite)
        edit(doc) { editor.mergeDown() }
        XCTAssertNil(doc.state.activeLayer.mask)
        XCTAssertEqual(try Raster(image: doc.composite), composite)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, original)
    }

    func testScaleResizeCropAndMoveKeepMasksAlignedAndUndo() throws {
        let (doc, editor) = editor(width: 8, height: 6)
        defer { doc.close() }
        doc.state.layers[1].raster.fill(color: red)
        let mask = SelectionMask.rectangle(CGRect(x: 1, y: 1, width: 3, height: 2), width: 8, height: 6)
        doc.state.layers[1].mask = mask; doc.state.layers[1].maskEnabled = false
        let original = doc.state
        edit(doc) { try! doc.applySize(.init(width: 16, height: 12, offsetX: 0, offsetY: 0), mode: .scale, smooth: false) }
        XCTAssertEqual(doc.state.activeLayer.mask, mask.scaled(width: 16, height: 12, smooth: false))
        XCTAssertFalse(doc.state.activeLayer.maskEnabled)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, original)
        edit(doc) { try! doc.applySize(.init(width: 10, height: 8, offsetX: 1, offsetY: 1), mode: .resize, smooth: false) }
        XCTAssertEqual(doc.state.activeLayer.mask!.value(x: 2, y: 2), 255)
        XCTAssertEqual(doc.state.activeLayer.mask!.value(x: 1, y: 1), 0)
        XCTAssertEqual(doc.state.activeLayer.mask!.value(x: 0, y: 0), 255)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, original)
        doc.state.selection = .rectangle(CGRect(x: 1, y: 1, width: 4, height: 3), width: 8, height: 6)
        let beforeCrop = doc.state
        edit(doc) { editor.cropToSelection() }
        XCTAssertEqual(doc.state.activeLayer.mask!.width, 4)
        XCTAssertEqual(doc.state.activeLayer.mask!.value(x: 0, y: 0), 255)
        XCTAssertEqual(doc.state.activeLayer.mask!.value(x: 3, y: 0), 0)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, beforeCrop)
        doc.state.selection = nil
        editor.canvas.tool = .move
        edit(doc) {
            editor.canvas.mouseDown(with: mouse(.leftMouseDown, 2, 2, canvas: editor.canvas))
            editor.canvas.mouseDragged(with: mouse(.leftMouseDragged, 4, 3, canvas: editor.canvas))
            editor.canvas.mouseUp(with: mouse(.leftMouseUp, 4, 3, canvas: editor.canvas))
        }
        XCTAssertEqual(doc.state.activeLayer.mask!.value(x: 3, y: 2), 255)
        XCTAssertEqual(doc.state.activeLayer.mask!.value(x: 1, y: 1), 0)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, original)
        editor.selectLayerTarget(doc.state.activeID, mask: true)
        let sourcePixels = doc.state.activeLayer.raster
        edit(doc) {
            editor.canvas.mouseDown(with: mouse(.leftMouseDown, 2, 2, canvas: editor.canvas))
            editor.canvas.mouseDragged(with: mouse(.leftMouseDragged, 4, 3, canvas: editor.canvas))
            editor.canvas.mouseUp(with: mouse(.leftMouseUp, 4, 3, canvas: editor.canvas))
        }
        XCTAssertEqual(doc.state.activeLayer.raster, sourcePixels)
        XCTAssertEqual(doc.state.activeLayer.mask!.value(x: 3, y: 2), 255)
    }

    func testMaskControlsFitMinimumWindowAndBothAppearances() throws {
        let app = NSApplication.shared, previous = NSApplication.shared.appearance
        defer { app.appearance = previous }
        let (doc, editor) = editor(width: 320, height: 240)
        defer { doc.close() }
        doc.state.layers[1].raster.fill(color: PixelColor(r: 64, g: 117, b: 245))
        doc.state.layers[1].raster.drawText("MASK", in: CGRect(x: 40, y: 60, width: 250, height: 100), font: .boldSystemFont(ofSize: 60),
                                          color: .white, opacity: 1, antialias: true, selection: nil)
        doc.state.layers[1].name = "A long masked layer name"
        doc.state.selection = SelectionMask.ellipse(CGRect(x: 20, y: 20, width: 280, height: 200), width: 320, height: 240)
            .feathered(radius: 6, context: doc.renderer.context)
        edit(doc) { editor.performMaskCommand(.fromSelection) }
        let root = editor.window!.contentView!
        editor.window!.orderFront(nil)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            app.appearance = NSAppearance(named: appearance)
            for size in [CGSize(width: 960, height: 640), CGSize(width: 1320, height: 860)] {
                editor.window!.setContentSize(size); root.layoutSubtreeIfNeeded(); editor.canvas.zoomToFit()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
                let table = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTableView }.first)
                let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
                let thumbnails = descendants(cell).compactMap { $0 as? LayerThumbnailButton }
                XCTAssertEqual(thumbnails.count, 2)
                for thumbnail in thumbnails {
                    let rect = thumbnail.convert(thumbnail.bounds, to: table)
                    XCTAssertGreaterThanOrEqual(rect.minX, 0)
                    XCTAssertLessThanOrEqual(rect.maxX, table.bounds.width)
                }
                let menu = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Layer Mask" })
                let name = try XCTUnwrap(descendants(cell).compactMap { $0 as? NSTextField }.first { $0.stringValue == "A long masked layer name" })
                XCTAssertLessThanOrEqual(name.convert(name.bounds, to: table).maxX, table.bounds.width)
                XCTAssertTrue(menu.itemArray.contains { $0.title == "Invert Mask" && $0.isEnabled })
                XCTAssertTrue(root.bounds.contains(menu.convert(menu.bounds, to: root)))
                if let folder = ProcessInfo.processInfo.environment["PAINTMAC_MASK_PREVIEW_DIR"], size.width == 1320 {
                    let bitmap = try XCTUnwrap(editor.canvas.snapshot(of: root))
                    let name = appearance == .aqua ? "mask-light.png" : "mask-dark.png"
                    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
                }
            }
        }
    }
}
