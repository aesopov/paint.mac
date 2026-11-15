import XCTest
import AppKit
import QuartzCore
@testable import PaintMac

final class EditableLayerTests: XCTestCase {
    private let red = PixelColor(r: 240, g: 30, b: 60)
    private func editor() -> (PaintDocument, EditorWindowController) {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 360, height: 240)
        doc.makeWindowControllers(); doc.undoManager!.groupsByEvent = false
        let editor = doc.windowControllers[0] as! EditorWindowController
        editor.window!.contentView!.layoutSubtreeIfNeeded(); editor.canvas.setZoom(1)
        return (doc, editor)
    }
    private func transaction<T>(_ doc: PaintDocument, _ work: () throws -> T) rethrows -> T {
        doc.undoManager!.beginUndoGrouping(); defer { doc.undoManager!.endUndoGrouping() }; return try work()
    }
    private func type(_ string: String, canvas: CanvasView) {
        canvas.textEditor!.textView.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    private func create(_ doc: PaintDocument, _ canvas: CanvasView, string: String = "Editable\nText") {
        canvas.textStyle.size = 36
        canvas.beginText(in: CGRect(x: 20, y: 30, width: 260, height: 120), color: red)
        type(string, canvas: canvas); transaction(doc) { canvas.finishText() }
    }
    private func views(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + views($0) } }

    func testTextRetainsSourceExactPreviewReeditsAndUndoRestoresBothPixelsAndSource() throws {
        let (doc, editor) = editor(); defer { doc.close() }
        let canvas = editor.canvas, original = doc.state
        canvas.beginText(in: CGRect(x: 20, y: 30, width: 180, height: 35), color: red)
        type("Huge letters\nOverflow", canvas: canvas)
        let preview = try XCTUnwrap(canvas.textPreviewRaster), visible = try Raster(image: canvas.displayedComposite)
        transaction(doc) { canvas.finishText() }
        XCTAssertEqual(doc.state.activeLayer.text?.string, "Huge letters\nOverflow")
        XCTAssertEqual(doc.state.activeLayer.raster, preview); XCTAssertEqual(try Raster(image: doc.composite), visible)
        let created = doc.state
        canvas.editTextLayer()
        XCTAssertEqual(canvas.textEditor!.textView.string, "Huge letters\nOverflow")
        XCTAssertEqual(canvas.textPreviewRaster, preview)
        canvas.textEditor!.textView.selectAll(nil); type("Changed", canvas: canvas)
        canvas.textStyle.bold = true; canvas.smooth = false
        canvas.textEditor!.setImageBounds(CGRect(x: 45, y: 55, width: 210, height: 70))
        let editedPreview = canvas.textPreviewRaster
        transaction(doc) { canvas.finishText() }
        XCTAssertEqual(doc.state.activeLayer.text?.string, "Changed"); XCTAssertEqual(doc.state.activeLayer.raster, editedPreview)
        XCTAssertTrue(doc.state.activeLayer.text!.style.bold)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, created)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, original)
        doc.undoManager!.redo(); XCTAssertEqual(doc.state, created)
    }

    func testDrawingTextOverPaintedPixelsCreatesSeparateLayerAndCancelDoesNothing() throws {
        let (doc, editor) = editor(); defer { doc.close() }
        doc.state.layers[1].raster.fill(color: red); doc.invalidate()
        let original = doc.state, canvas = editor.canvas
        canvas.beginText(in: CGRect(x: 20, y: 20, width: 200, height: 100), color: .white)
        type("Separate", canvas: canvas); XCTAssertEqual(doc.state, original)
        let preview = try Raster(image: canvas.displayedComposite)
        transaction(doc) { canvas.finishText() }
        XCTAssertEqual(doc.state.layers.count, 3); XCTAssertEqual(doc.state.layers[1], original.layers[1])
        XCTAssertEqual(doc.state.activeLayer.text!.string, "Separate"); XCTAssertEqual(try Raster(image: doc.composite), preview)
        let before = doc.state
        canvas.editTextLayer(); canvas.textEditor!.textView.selectAll(nil); type("Canceled", canvas: canvas)
        canvas.finishText(apply: false); XCTAssertEqual(doc.state, before)
        canvas.editTextLayer(); canvas.textEditor!.textView.selectAll(nil); type("", canvas: canvas)
        transaction(doc) { canvas.finishText() }
        XCTAssertEqual(doc.state.activeLayer.text!.string, "", "Empty text remains an editable layer")
    }

    func testPixelToolsRequireExplicitRasterizeWhileMaskEditingRemainsAvailable() throws {
        let (doc, editor) = editor(); defer { doc.close() }
        create(doc, editor.canvas)
        let before = doc.state
        XCTAssertFalse(doc.state.canPaintTarget)
        var state = doc.state; state.editRaster { $0.fill(color: .black) }; XCTAssertEqual(state, before)
        editor.applyAdjustment("CIColorInvert", name: "Invert"); XCTAssertEqual(doc.state, before)
        transaction(doc) { doc.addLayerMask(.revealAll) }; XCTAssertTrue(doc.state.canPaintTarget)
        transaction(doc) { editor.canvas.deletePixels() }; XCTAssertTrue(doc.state.activeLayer.mask!.isEmpty)
        XCTAssertEqual(doc.state.activeLayer.text, before.activeLayer.text)
        editor.selectLayerTarget(doc.state.activeID, mask: false)
        let masked = doc.state
        transaction(doc) { doc.rasterizeActiveText() }
        XCTAssertNil(doc.state.activeLayer.text); XCTAssertNil(doc.state.activeLayer.textClip)
        XCTAssertEqual(doc.state.activeLayer.raster, masked.activeLayer.raster); XCTAssertTrue(doc.state.canPaintTarget)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, masked)
    }

    func testCreationSelectionPersistsAcrossReeditingAndProjectRoundTrip() throws {
        let (doc, editor) = editor(); defer { doc.close() }
        let clip = SelectionMask.ellipse(CGRect(x: 30, y: 20, width: 180, height: 130), width: 360, height: 240)
            .feathered(radius: 3, context: doc.renderer.context)
        doc.state.selection = clip
        create(doc, editor.canvas)
        let pixels = doc.state.activeLayer.raster
        XCTAssertEqual(doc.state.activeLayer.textClip, clip)
        editor.canvas.selection = nil; editor.canvas.editTextLayer()
        XCTAssertEqual(editor.canvas.textPreviewRaster, pixels, "A later selection must not alter existing text")
        editor.canvas.finishText(apply: false)
        let wrapper = try ProjectCodec.encode(doc.state)
        let manifest = try JSONDecoder().decode(ProjectManifest.self, from: wrapper.fileWrappers!["document.json"]!.regularFileContents!)
        XCTAssertEqual(manifest.version, 4)
        XCTAssertEqual(try ProjectCodec.decode(wrapper), doc.state)
        var files = wrapper.fileWrappers!; files.removeValue(forKey: manifest.layers.last!.textClipFile!)
        XCTAssertThrowsError(try ProjectCodec.decode(FileWrapper(directoryWithFileWrappers: files)))
    }

    func testTextObjectMovesResizesAndCropsWithoutLosingEditableGeometry() throws {
        let (doc, editor) = editor(); defer { doc.close() }
        create(doc, editor.canvas)
        let original = doc.state, rect = original.activeLayer.text!.rect
        var moved = original; moved.moveActive(from: original, dx: 15, dy: -10, selection: nil)
        XCTAssertEqual(moved.activeLayer.text!.rect, rect.offsetBy(dx: 15, dy: -10))
        doc.state = moved; doc.invalidate()
        editor.canvas.editTextLayer(); XCTAssertEqual(editor.canvas.textPreviewRaster, moved.activeLayer.raster)
        editor.canvas.finishText(apply: false)
        try transaction(doc) { try doc.applySize(CanvasSizePlan(width: 720, height: 240, offsetX: 0, offsetY: 0), mode: .scale, smooth: false) }
        XCTAssertEqual(doc.state.activeLayer.text!.horizontalScale, 2)
        XCTAssertEqual(doc.state.activeLayer.text!.style.size, 36)
        editor.canvas.editTextLayer(); XCTAssertEqual(editor.canvas.textPreviewRaster, doc.state.activeLayer.raster)
        XCTAssertEqual(editor.canvas.textEditor!.textView.bounds.width, doc.state.activeLayer.text!.rect.width / 2)
        editor.canvas.finishText(apply: false)
        editor.canvas.selection = .rectangle(CGRect(x: 100, y: 50, width: 300, height: 140), width: 720, height: 240)
        transaction(doc) { editor.cropToSelection() }
        XCTAssertLessThan(doc.state.activeLayer.text!.rect.minX, 0)
        editor.canvas.editTextLayer()
        XCTAssertEqual(editor.canvas.textEditor!.imageBounds, doc.state.activeLayer.text!.rect)
        XCTAssertEqual(editor.canvas.textPreviewRaster, doc.state.activeLayer.raster)
        editor.canvas.finishText(apply: false)
        XCTAssertEqual(try ProjectCodec.decode(ProjectCodec.encode(doc.state)), doc.state)
    }

    func testFractionalScalingKeepsTextPreviewUnchangedWhenReopened() throws {
        let (doc, editor) = editor(); defer { doc.close() }
        create(doc, editor.canvas)
        try transaction(doc) { try doc.applySize(CanvasSizePlan(width: 151, height: 93, offsetX: 0, offsetY: 0), mode: .scale, smooth: true) }
        let before = doc.state
        editor.canvas.editTextLayer()
        XCTAssertEqual(editor.canvas.textEditor!.imageBounds, before.activeLayer.text!.rect)
        XCTAssertEqual(editor.canvas.textPreviewRaster, before.activeLayer.raster)
        transaction(doc) { editor.canvas.finishText() }; XCTAssertEqual(doc.state, before)
    }

    func testEditableLayersRemainReadableInBothAppearancesAndMinimumWindow() throws {
        let app = NSApplication.shared, appearance = app.appearance; defer { app.appearance = appearance }
        let (doc, editor) = editor(); defer { doc.close() }
        doc.state.layers[0].raster.fill(color: PixelColor(r: 242, g: 238, b: 228))
        doc.state.layers[1].raster.fill(color: PixelColor(r: 40, g: 90, b: 180), rect: CGRect(x: 16, y: 16, width: 328, height: 208))
        let imageID = doc.state.activeID
        editor.canvas.textStyle.size = 36
        editor.canvas.beginText(in: CGRect(x: 38, y: 50, width: 285, height: 130), color: .white)
        type("Text stays\neditable", canvas: editor.canvas); transaction(doc) { editor.canvas.finishText() }
        let textID = doc.state.activeID
        var effect = EffectSettings(kind: .hueSaturation); effect.hue = 25
        try transaction(doc) { try doc.addEffect(effect) }
        let effectID = doc.state.activeID
        try transaction(doc) { try doc.createGroup(wrapping: [imageID, textID, effectID]) }
        editor.selectLayerTarget(textID, mask: false); editor.canvas.editTextLayer()
        let original = doc.state, root = editor.window!.contentView!
        let originalImage = try Raster(image: editor.canvas.displayedComposite)
        editor.window!.orderFront(nil)
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            app.appearance = NSAppearance(named: theme)
            for size in [CGSize(width: 960, height: 640), CGSize(width: 1320, height: 860)] {
                editor.window!.setContentSize(size); root.layoutSubtreeIfNeeded()
                editor.canvas.setZoom(size.width == 1320 ? 2 : 1)
                root.displayIfNeeded(); editor.canvas.displayIfNeeded(); CATransaction.flush()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
                XCTAssertNotNil(editor.canvas.textEditor)
                XCTAssertEqual(try Raster(image: editor.canvas.displayedComposite), originalImage)
                let table = try XCTUnwrap(views(root).compactMap { $0 as? NSTableView }.first)
                XCTAssertEqual(table.numberOfRows, 5)
                for row in 0..<table.numberOfRows {
                    let cell = try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: true)); cell.layoutSubtreeIfNeeded()
                    for label in views(cell).compactMap({ $0 as? NSTextField }) {
                        XCTAssertLessThanOrEqual(label.convert(label.bounds, to: table).maxX, table.visibleRect.maxX)
                    }
                }
                XCTAssertEqual(doc.state, original)
                if size.width == 1320, let folder = ProcessInfo.processInfo.environment["PAINTMAC_EDITABLE_PREVIEW_DIR"] {
                    let bitmap = try XCTUnwrap(editor.canvas.snapshot(of: root))
                    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent(theme == .aqua ? "editable-light.png" : "editable-dark.png"))
                }
            }
        }
        editor.canvas.finishText(apply: false)
    }

    func testDuplicateGroupRemapsTextAndEffectsAndMergingBakesMetadata() throws {
        let (doc, editor) = editor(); defer { doc.close() }
        create(doc, editor.canvas)
        let textID = doc.state.activeID
        try transaction(doc) { try doc.addEffect(EffectSettings(kind: .invert)) }
        let effectID = doc.state.activeID
        try transaction(doc) { try doc.createGroup(wrapping: [textID, effectID]) }
        let original = doc.state, image = try Raster(image: doc.composite)
        XCTAssertFalse(doc.state.canUngroupActive, "Ungroup would change effect scope")
        try transaction(doc) { try doc.duplicateActiveNode() }
        let copies = doc.state.children(of: doc.state.activeID)
        XCTAssertEqual(copies[0].text, original.layers.first { $0.id == textID }!.text)
        XCTAssertEqual(copies[1].effect?.kind, .invert); try doc.state.validateLayerTree()
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, original)
        transaction(doc) { doc.mergeActiveGroup() }
        XCTAssertNil(doc.state.activeLayer.text); XCTAssertNil(doc.state.activeLayer.effect)
        XCTAssertEqual(try Raster(image: doc.composite), image)
    }

    func testDoubleClickOnTextLayerReopensNativeInputAndUpdatesControls() throws {
        let (doc, editor) = editor(); defer { doc.close() }
        create(doc, editor.canvas)
        let root = editor.window!.contentView!
        let table = try XCTUnwrap(views(root).compactMap { $0 as? NSTableView }.first)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(table.doubleAction), to: table.target, from: table))
        XCTAssertEqual(editor.canvas.textEditor?.textView.string, "Editable\nText")
        XCTAssertTrue(editor.window!.firstResponder === editor.canvas.textEditor!.textView)
        XCTAssertEqual(editor.canvas.tool, .text)
        editor.canvas.finishText(apply: false)
    }

    func testMalformedTextAndEffectMetadataAndOldVersionDowngradesAreRejected() throws {
        let (doc, editor) = editor(); defer { doc.close() }
        create(doc, editor.canvas)
        let wrapper = try ProjectCodec.encode(doc.state), files = wrapper.fileWrappers!
        let original = try JSONDecoder().decode(ProjectManifest.self, from: files["document.json"]!.regularFileContents!)
        let mutations: [(inout ProjectManifest) -> Void] = [
            { $0.version = 3 }, { $0.layers[1].text!.style.size = -1 },
            { $0.layers[1].text!.rect.size.width = 0 }, { $0.layers[1].text!.horizontalScale = 0 },
            { $0.layers[1].isGroup = true }, { $0.layers[1].effect = EffectSettings(kind: .blur) }
        ]
        for change in mutations {
            var manifest = original; change(&manifest)
            var copy = files; copy["document.json"] = FileWrapper(regularFileWithContents: try JSONEncoder().encode(manifest))
            XCTAssertThrowsError(try ProjectCodec.decode(FileWrapper(directoryWithFileWrappers: copy)))
        }
        var bad = EffectSettings(kind: .blur); bad.radius = -1
        XCTAssertThrowsError(try doc.addEffect(bad))
        var invalid = doc.state.activeLayer.text!; invalid.opacity = .nan
        XCTAssertThrowsError(try invalid.validate())
    }
}
