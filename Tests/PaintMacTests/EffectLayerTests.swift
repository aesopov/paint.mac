import XCTest
import AppKit
@testable import PaintMac

final class EffectLayerTests: XCTestCase {
    private func layer(_ color: PixelColor = .clear, width: Int = 8, height: Int = 6) -> PaintLayer {
        PaintLayer(name: "Image", raster: Raster(width: width, height: height, color: color))
    }
    private func effect(_ kind: EffectKind, width: Int = 8, height: Int = 6) -> PaintLayer {
        var node = layer(width: width, height: height); node.effect = EffectSettings(kind: kind); return node
    }
    private func render(_ layers: [PaintLayer]) throws -> Raster {
        try Raster(image: ImageRenderer().composite(layers, width: layers[0].raster.width, height: layers[0].raster.height))
    }
    private func transaction<T>(_ doc: PaintDocument, _ body: () throws -> T) rethrows -> T {
        doc.undoManager!.beginUndoGrouping(); defer { doc.undoManager!.endUndoGrouping() }; return try body()
    }
    private func close(_ doc: PaintDocument) { doc.close() }
    private func document(_ nodes: [PaintLayer]) -> PaintDocument {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: nodes[0].raster.width, height: nodes[0].raster.height)
        doc.state.layers = nodes; doc.state.activeID = nodes.last!.id; doc.undoManager!.groupsByEvent = false
        return doc
    }
    private func near(_ lhs: Raster, _ rhs: Raster, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.width, rhs.width, file: file, line: line)
        for i in lhs.bytes.indices { XCTAssertLessThanOrEqual(abs(Int(lhs.bytes[i]) - Int(rhs.bytes[i])), 1, file: file, line: line) }
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    func testMaskedEffectInterpolatesOnceWithoutChangingSourceAlphaOrPixels() throws {
        let base = layer(PixelColor(r: 200, g: 40, b: 80, a: 128)), original = base.raster
        var adjustment = effect(.invert)
        adjustment.mask = SelectionMask(width: 8, height: 6, coverage: Data((0..<48).map { UInt8($0 % 3 == 0 ? 0 : ($0 % 3 == 1 ? 128 : 255)) }))
        adjustment.opacity = 0.5
        let output = try render([base, adjustment])
        near(output.cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)), original.cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)))
        XCTAssertEqual(Int(output.pixel(x: 2, y: 0).a), 128, accuracy: 1)
        XCTAssertEqual(Int(output.pixel(x: 2, y: 0).r), 127, accuracy: 3)
        XCTAssertEqual(Int(output.pixel(x: 1, y: 0).r), 163, accuracy: 3)
        XCTAssertEqual(base.raster, original)
        adjustment.maskEnabled = false; adjustment.opacity = 1
        let full = try render([base, adjustment]).pixel(x: 0, y: 0)
        XCTAssertEqual(Int(full.r), 55, accuracy: 3); XCTAssertEqual(Int(full.g), 215, accuracy: 3)
        adjustment.visible = false; near(try render([base, adjustment]), original)
        adjustment.visible = true; adjustment.opacity = 0; near(try render([base, adjustment]), original)
    }

    func testEffectsAreLiveAndRespectStackOrderAndGroupScope() throws {
        let bottom = layer(PixelColor(r: 255, g: 0, b: 0))
        var folder = layer(); folder.isGroup = true
        var child = layer(); child.parentID = folder.id
        child.raster.fill(color: PixelColor(r: 0, g: 0, b: 255), rect: CGRect(x: 2, y: 1, width: 3, height: 3))
        var invert = effect(.invert); invert.parentID = folder.id
        let nodes = [bottom, child, invert, folder]
        let output = try render(nodes)
        XCTAssertEqual(output.pixel(x: 0, y: 0), PixelColor(r: 255, g: 0, b: 0))
        XCTAssertEqual(output.pixel(x: 3, y: 2), PixelColor(r: 255, g: 255, b: 0))
        let doc = document(nodes); defer { close(doc) }
        doc.state.layers[1].raster.fill(color: PixelColor(r: 0, g: 255, b: 0)); doc.invalidate()
        XCTAssertEqual(try Raster(image: doc.composite).pixel(x: 3, y: 2), PixelColor(r: 255, g: 0, b: 255))
        XCTAssertEqual(doc.state.layers[2].effect, invert.effect)
    }

    func testClippedEffectsKeepBaseSilhouetteAndOpacityWithoutFadingTwice() throws {
        var base = layer(PixelColor(r: 255, g: 0, b: 0, a: 128)); base.opacity = 0.5
        var invert = effect(.invert); invert.isClipped = true
        let color = try render([base, invert]).pixel(x: 3, y: 2)
        XCTAssertEqual(Int(color.a), 64, accuracy: 1)
        XCTAssertEqual(Int(color.r), 0, accuracy: 1); XCTAssertEqual(Int(color.g), 255, accuracy: 1)
        var dot = layer(width: 20, height: 20)
        dot.raster.fill(color: .white, rect: CGRect(x: 10, y: 10, width: 1, height: 1))
        var blur = effect(.blur, width: 20, height: 20); blur.effect!.radius = 2
        XCTAssertGreaterThan(try render([dot, blur]).pixel(x: 8, y: 10).a, 0)
        blur.isClipped = true
        let clipped = try render([dot, blur])
        XCTAssertEqual(clipped.pixel(x: 8, y: 10).a, 0); XCTAssertEqual(clipped.pixel(x: 10, y: 10).a, 255)
    }

    func testMergeEffectBakesEntireInputPrefixAndUndoPreservesSettings() throws {
        let bottom = layer(PixelColor(r: 200, g: 40, b: 80))
        var middle = layer(); middle.raster.fill(color: .white, rect: CGRect(x: 2, y: 2, width: 3, height: 3)); middle.opacity = 0.5
        let fx = effect(.invert), above = layer()
        let doc = document([bottom, middle, fx, above]); defer { close(doc) }
        doc.state.activeID = fx.id
        let original = doc.state, image = try render(doc.state.layers)
        transaction(doc) { doc.mergeActiveDown() }
        XCTAssertEqual(doc.state.layers.count, 2); XCTAssertEqual(doc.state.layers.last, above)
        XCTAssertNil(doc.state.activeLayer.effect); near(try render(doc.state.layers), image)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, original)
        doc.state.activeID = above.id
        transaction(doc) { doc.mergeActiveDown() }
        XCTAssertEqual(doc.state.layers.count, 1); near(try render(doc.state.layers), image)
    }

    func testMaskApplyAndClippingReleaseKeepValidHierarchyAndUndo() throws {
        let base = layer(PixelColor(r: 255, g: 0, b: 0)), clip = layer(.white)
        var fx = effect(.invert); fx.isClipped = true; fx.mask = .all(width: 8, height: 6); fx.maskEnabled = false
        var clipped = clip; clipped.isClipped = true; clipped.opacity = 0.2
        let doc = document([base, fx, clipped]); defer { close(doc) }
        doc.state.activeID = fx.id; let original = doc.state
        transaction(doc) { doc.toggleClippingMask() }; try doc.state.validateLayerTree()
        XCTAssertFalse(doc.state.layers[1].isClipped); XCTAssertFalse(doc.state.layers[2].isClipped)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, original)
        var enabled = original.layers; enabled[1].maskEnabled = true
        transaction(doc) { doc.deleteLayerMask(apply: true) }
        near(try render(doc.state.layers), try render(enabled))
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, original)
    }

    func testEveryEffectKindPersistsWithMasksAndCanEditSettingsAndUndo() throws {
        for kind in EffectKind.allCases {
            let base = layer(PixelColor(r: 40, g: 140, b: 200)), doc = document([layer(PixelColor(r: 40, g: 140, b: 200))])
            defer { close(doc) }
            doc.state.selection = .rectangle(CGRect(x: 1, y: 1, width: 4, height: 3), width: 8, height: 6)
            let before = doc.state
            try transaction(doc) { try doc.addEffect(EffectSettings(kind: kind)) }
            XCTAssertNil(doc.state.selection); XCTAssertEqual(doc.state.activeLayer.mask, before.selection)
            XCTAssertFalse(doc.state.canPaintTarget)
            let created = doc.state
            var settings = doc.state.activeLayer.effect!; settings.radius = 23; settings.hue = 75
            try transaction(doc) { try doc.setEffect(settings, on: doc.state.activeID) }
            XCTAssertEqual(doc.state.activeLayer.effect, settings)
            XCTAssertEqual(try ProjectCodec.decode(ProjectCodec.encode(doc.state)), doc.state)
            doc.undoManager!.undo(); XCTAssertEqual(doc.state, created)
            doc.undoManager!.undo(); XCTAssertEqual(doc.state, before)
            XCTAssertEqual(doc.state.activeLayer.raster, base.raster)
        }
    }

    func testEffectDialogPreviewCancelAndApplyUseOneUndoAndLeaveDraftStateSeparate() throws {
        let doc = document([layer(PixelColor(r: 255, g: 0, b: 0), width: 120, height: 80)])
        doc.makeWindowControllers(); defer { close(doc) }
        let editor = doc.windowControllers[0] as! EditorWindowController
        let before = doc.state, image = try Raster(image: doc.composite)
        editor.showEffect(EffectSettings(kind: .invert))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(doc.state, before); XCTAssertFalse(doc.undoManager!.canUndo)
        XCTAssertNotEqual(try Raster(image: editor.canvas.displayedComposite), image)
        editor.window!.endSheet(try XCTUnwrap(editor.window!.attachedSheet), returnCode: .alertSecondButtonReturn)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertNil(editor.canvas.effectPreviewComposite); XCTAssertEqual(doc.state, before)
        editor.showEffect(EffectSettings(kind: .invert))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        doc.undoManager!.beginUndoGrouping()
        editor.window!.endSheet(try XCTUnwrap(editor.window!.attachedSheet), returnCode: .alertFirstButtonReturn)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        doc.undoManager!.endUndoGrouping()
        XCTAssertEqual(doc.state.activeLayer.effect?.kind, .invert)
        XCTAssertNil(editor.canvas.effectPreviewComposite)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, before)
    }

    func testEffectControlsFitBothThemesAndSliderUpdatesSettings() throws {
        let app = NSApplication.shared, appearance = app.appearance; defer { app.appearance = appearance }
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            app.appearance = NSAppearance(named: theme)
            for kind in EffectKind.allCases {
                let dialog = EffectLayerDialog(settings: EffectSettings(kind: kind))
                let form = dialog.formView; form.layoutSubtreeIfNeeded()
                var preview: EffectSettings?
                dialog.onPreview = { preview = $0 }
                for slider in descendants(form).compactMap({ $0 as? NSSlider }) {
                    slider.doubleValue = slider.maxValue
                    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(slider.action), to: slider.target, from: slider))
                    XCTAssertNotNil(preview); XCTAssertNoThrow(try preview!.validate())
                    XCTAssertTrue(form.bounds.contains(slider.convert(slider.bounds, to: form)))
                }
            }
        }
    }
}
