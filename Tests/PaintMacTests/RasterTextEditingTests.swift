import XCTest
import AppKit
@testable import PaintMac

final class RasterTextEditingTests: XCTestCase {
    private let blue = PixelColor(r: 20, g: 80, b: 230)
    private func makeEditor() -> (PaintDocument, EditorWindowController) {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 360, height: 240)
        doc.makeWindowControllers()
        let editor = doc.windowControllers[0] as! EditorWindowController
        editor.window!.contentView!.layoutSubtreeIfNeeded(); editor.canvas.setZoom(1)
        return (doc, editor)
    }
    private func hasInk(_ image: Raster) -> Bool { stride(from: 3, to: image.bytes.count, by: 4).contains { image.bytes[$0] != 0 } }

    func testTallGlyphsAndPartialLinesAreClippedInsteadOfOmitted() {
        _ = NSApplication.shared
        let font = NSFont.systemFont(ofSize: 72)
        for smooth in [false, true] {
            var complete = Raster(width: 240, height: 300)
            complete.drawText("Hgj\nSecond\nThird", in: CGRect(x: 20, y: 10, width: 200, height: 280), font: font,
                              color: blue, opacity: 1, antialias: smooth, selection: nil)
            // Include visible ink, but stay well below a complete 72px line.
            for height in [30, 70, 110] {
                let box = CGRect(x: 20, y: 10, width: 200, height: height)
                var cropped = Raster(width: 240, height: 300)
                cropped.drawText("Hgj\nSecond\nThird", in: box, font: font, color: blue, opacity: 1, antialias: smooth, selection: nil)
                let expected = complete.masked(using: .rectangle(box, width: 240, height: 300))
                XCTAssertTrue(hasInk(cropped), "A short box must retain visible parts of tall glyphs")
                XCTAssertEqual(cropped, expected, "Height \(height), smooth \(smooth)")
            }
            var completeLetter = Raster(width: 240, height: 150), narrow = completeLetter
            completeLetter.drawText("H", in: CGRect(x: 20, y: 10, width: 200, height: 130), font: font, color: blue, opacity: 1, antialias: smooth, selection: nil)
            let box = CGRect(x: 20, y: 10, width: 16, height: 130)
            narrow.drawText("H", in: box, font: font, color: blue, opacity: 1, antialias: smooth, selection: nil)
            XCTAssertTrue(hasInk(narrow), "An oversized single glyph must be clipped horizontally")
            XCTAssertEqual(narrow, completeLetter.masked(using: .rectangle(box, width: 240, height: 150)))
        }
    }

    func testLiveRasterPreviewMatchesCommittedPixelsWithLayerOpacityMaskAndOverflow() throws {
        let (doc, editor) = makeEditor()
        defer { doc.close() }
        doc.state.layers[0].raster.fill(color: PixelColor(r: 255, g: 200, b: 100))
        doc.state.layers[1].opacity = 0.6
        var above = PaintLayer(name: "Foreground", raster: Raster(width: 360, height: 240))
        above.raster.fill(color: .black, rect: CGRect(x: 40, y: 30, width: 20, height: 20)); above.opacity = 0.3
        doc.state.layers.append(above)
        doc.state.selection = SelectionMask.rectangle(CGRect(x: 20, y: 10, width: 140, height: 110), width: 360, height: 240)
            .feathered(radius: 3, context: doc.renderer.context)
        doc.invalidate()
        let original = doc.state, baseline = try Raster(image: doc.composite)
        let canvas = editor.canvas
        editor.selectTool(.text); canvas.textStyle.size = 48
        canvas.beginText(in: CGRect(x: 20, y: 20, width: 140, height: 16), color: blue)
        let draft = try XCTUnwrap(canvas.textEditor)
        draft.textView.insertText("Huge text\nMore text\nПривет", replacementRange: NSRange(location: NSNotFound, length: 0))
        let partialPreview = try XCTUnwrap(canvas.textPreviewRaster)
        XCTAssertTrue(hasInk(partialPreview)); XCTAssertEqual(doc.state, original)
        XCTAssertNotEqual(try Raster(image: canvas.displayedComposite), baseline)
        // Moving/resizing, font and quality changes refresh the image; zoom only scales it.
        draft.setImageBounds(CGRect(x: 25, y: 15, width: 150, height: 65))
        canvas.textStyle.size = 40; canvas.brushOpacity = 0.75; canvas.smooth = false
        editor.setColor(PixelColor(r: 200, g: 30, b: 90))
        let preview = try XCTUnwrap(canvas.textPreviewRaster)
        let visible = try Raster(image: canvas.displayedComposite)
        canvas.setZoom(2.5)
        XCTAssertEqual(canvas.textPreviewRaster, preview)
        XCTAssertEqual(draft.textView.font!.pointSize, 40)
        XCTAssertEqual(draft.textView.bounds.size, draft.imageBounds.size)
        XCTAssertEqual(doc.state, original)
        doc.undoManager?.groupsByEvent = false; doc.undoManager?.beginUndoGrouping()
        canvas.finishText()
        doc.undoManager?.endUndoGrouping()
        XCTAssertEqual(doc.state.layers[1].raster, preview)
        XCTAssertEqual(try Raster(image: canvas.displayedComposite), visible, "Finishing must not change visible text pixels")
        XCTAssertNil(canvas.textPreviewRaster)
        doc.undoManager?.undo(); XCTAssertEqual(doc.state, original)
    }

    func testNoButtonsNoScrollbarsNoVectorGlyphsAndOverflowNeverScrolls() throws {
        let (doc, editor) = makeEditor()
        defer { doc.close() }
        let canvas = editor.canvas
        canvas.textStyle.size = 32
        canvas.beginText(in: CGRect(x: 20, y: 20, width: 100, height: 20), color: blue)
        let draft = try XCTUnwrap(canvas.textEditor)
        draft.textView.insertText(String(repeating: "Overflow text\n", count: 15), replacementRange: NSRange(location: NSNotFound, length: 0))
        func views(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + views($0) } }
        XCTAssertFalse(views(draft).contains { $0 is NSButton || $0 is NSScrollView || $0 is NSScroller })
        draft.textView.scrollRangeToVisible(NSRange(location: (draft.textView.string as NSString).length, length: 0))
        XCTAssertEqual(draft.textView.bounds.origin, .zero)
        XCTAssertEqual(draft.textView.bounds.size, CGSize(width: 100, height: 20))
        XCTAssertTrue(hasInk(try XCTUnwrap(canvas.textPreviewRaster)))
        // Render the input view alone with no caret/selection: only the canvas
        // underneath it should supply glyph pixels.
        editor.window?.makeFirstResponder(canvas)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 20, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current!.cgContext.clear(CGRect(x: 0, y: 0, width: 100, height: 20))
        draft.textView.draw(draft.textView.bounds)
        NSGraphicsContext.restoreGraphicsState()
        XCTAssertFalse(hasInk(try Raster(image: XCTUnwrap(bitmap.cgImage))))
        canvas.finishText(apply: false)
        XCTAssertEqual(doc.state.activeLayer.raster, Raster(width: 360, height: 240))
        XCTAssertNil(canvas.textPreviewRaster)
    }

    func testNativeTextUndoAlsoUpdatesRasterPreview() throws {
        let (doc, editor) = makeEditor()
        defer { doc.close() }
        let canvas = editor.canvas
        canvas.beginText(in: CGRect(x: 20, y: 20, width: 200, height: 120), color: blue)
        let draft = try XCTUnwrap(canvas.textEditor)
        draft.textView.insertText("Undo text", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(hasInk(try XCTUnwrap(canvas.textPreviewRaster)))
        draft.textView.undoManager?.undo()
        XCTAssertTrue(draft.textView.string.isEmpty)
        XCTAssertFalse(hasInk(try XCTUnwrap(canvas.textPreviewRaster)))
        draft.textView.undoManager?.redo()
        XCTAssertEqual(draft.textView.string, "Undo text")
        XCTAssertTrue(hasInk(try XCTUnwrap(canvas.textPreviewRaster)))
    }

    func testSelectingAnotherLayerFinishesDraftAndKeepsChosenLayerSelected() throws {
        let (doc, editor) = makeEditor()
        defer { doc.close() }
        let originalID = doc.state.activeID, targetID = doc.state.layers[0].id
        editor.canvas.beginText(in: CGRect(x: 20, y: 20, width: 200, height: 120), color: blue)
        editor.canvas.textEditor!.textView.insertText("Finish on layer change", replacementRange: NSRange(location: NSNotFound, length: 0))
        func tables(_ view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
        }
        let table = try XCTUnwrap(tables(editor.window!.contentView!).first)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertNil(editor.canvas.textEditor)
        XCTAssertEqual(doc.state.activeID, targetID)
        XCTAssertEqual(table.selectedRow, 1)
        XCTAssertTrue(hasInk(doc.state.layers.first { $0.id == originalID }!.raster))
    }
}
