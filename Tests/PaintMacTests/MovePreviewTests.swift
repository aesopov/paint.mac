import AppKit
import CoreImage
import XCTest
@testable import PaintMac

final class MovePreviewTests: XCTestCase {
    func testLiveMetalMovePresentsPreviewWithoutMutatingPixelsOrSelection() throws {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 800, height: 600)
        doc.state.layers[1].raster.fill(color: .white, rect: CGRect(x: 100, y: 100, width: 250, height: 250))
        let canvas = CanvasView(document: doc)
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.level = .floating; window.contentView = canvas
        defer { window.close(); doc.close() }
        window.orderFrontRegardless(); canvas.layoutSubtreeIfNeeded(); canvas.setZoom(1)
        let metal = try XCTUnwrap(canvas.metalView)
        func wait(_ condition: () -> Bool) {
            let deadline = Date(timeIntervalSinceNow: 3)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
            XCTAssertTrue(condition())
        }
        wait { metal.completedFrameCount > 0 }
        canvas.selection = .ellipse(CGRect(x: 100, y: 100, width: 250, height: 250), width: 800, height: 600)
        canvas.tool = .move
        let original = doc.state, frames = metal.completedFrameCount
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(CGPoint(x: canvas.imageRect.minX + x, y: canvas.imageRect.minY + 200), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: mouse(.leftMouseDown, 200)); canvas.mouseDragged(with: mouse(.leftMouseDragged, 300))
        wait { metal.completedFrameCount > frames }
        XCTAssertEqual(doc.state, original); XCTAssertNil(doc.imageCache)
        doc.undoManager!.groupsByEvent = false; doc.undoManager!.beginUndoGrouping()
        canvas.mouseUp(with: mouse(.leftMouseUp, 300)); doc.undoManager!.endUndoGrouping()
        XCTAssertEqual(doc.state.activeLayer.raster, original.activeLayer.raster.moved(dx: 100, dy: 0, selection: original.selection))
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, original)
    }

    /// Contiguous reference for the original cut, mask-round, source-over rules.
    /// Deliberately independent of the new tile-region implementation.
    private func reference(_ raster: Raster, dx: Int, dy: Int, selection: SelectionMask?) -> Data {
        let source = raster.bytes, mask = selection?.coverage
        var output = source
        if dx == 0 && dy == 0 { return output }
        output.withUnsafeMutableBytes { raw in
            source.withUnsafeBytes { old in
                let dst = RGBSamples(raw: raw, depth: raster.depth)
                let src = RGBSamples(raw: UnsafeMutableRawBufferPointer(mutating: old), depth: raster.depth)
                for i in 0..<raster.width * raster.height {
                    let a = Double(mask?[i] ?? 255)
                    for c in 0..<4 { dst[i * 4 + c] = src[i * 4 + c] * (255 - a) / 255 }
                }
                for y in 0..<raster.height { for x in 0..<raster.width {
                    let tx = x + dx, ty = y + dy
                    guard tx >= 0, tx < raster.width, ty >= 0, ty < raster.height else { continue }
                    let i = y * raster.width + x, j = (ty * raster.width + tx) * 4
                    let amount = Double(mask?[i] ?? 255)
                    let alpha = (src[i * 4 + 3] * amount / 255).rounded() / src.maximum
                    for c in 0..<4 { dst[j + c] = (src[i * 4 + c] * amount / 255).rounded() + dst[j + c] * (1 - alpha) }
                } }
            }
        }
        return output
    }

    func testBoundedMovesExactlyMatchReferenceAndShareUnaffectedTilesInBothDepths() throws {
        for depth in [RGBDepth.eight, .sixteen] {
            let format = RGBFormat(profile: .displayP3, depth: depth)
            var source = Raster(width: 530, height: 300, format: format)
            source.resolution = ImageResolution(x: 144, y: 96)
            var data = Data(count: source.width * source.height * depth.bytesPerPixel)
            data.withUnsafeMutableBytes { raw in
                let p = RGBSamples(raw: raw, depth: depth)
                for i in 0..<source.width * source.height {
                    let alpha = Double((i * 31) % 200 + 50) / 255 * p.maximum
                    p[i * 4] = alpha * 0.7; p[i * 4 + 1] = alpha * 0.2; p[i * 4 + 2] = alpha * 0.4; p[i * 4 + 3] = alpha
                }
            }
            source.bytes = data
            var grid = TileGrid(width: 530, height: 300, channels: 1)
            let area = CGRect(x: 245, y: 245, width: 35, height: 35)
            var coverage = Data(count: 35 * 35)
            for i in coverage.indices { coverage[i] = [0, 64, 128, 255][i % 4] }
            grid.write(coverage, in: area)
            let partial = SelectionMask(storage: grid, bounds: grid.nonzeroBounds)
            for mask in [partial, SelectionMask.empty(width: 530, height: 300), nil] {
                for offset in [(0, 0), (4, -7), (-250, -250), (700, 600)] {
                    let moved = source.moved(dx: offset.0, dy: offset.1, selection: mask)
                    XCTAssertEqual(moved.bytes, reference(source, dx: offset.0, dy: offset.1, selection: mask))
                    XCTAssertEqual(moved.format, source.format); XCTAssertEqual(moved.resolution, source.resolution)
                    if mask == partial, offset == (4, -7) { XCTAssertTrue(moved.storage.tiles[2] === source.storage.tiles[2]) }
                }
            }
        }
    }

    func testPreviewMatchesCommitForGroupsClippingEffectsMasksAndQuickMask() throws {
        _ = NSApplication.shared
        let renderer = ImageRenderer()
        for mode in 0..<9 {
            var state = DocumentState(width: 80, height: 60)
            var group = PaintLayer(name: "Group", raster: Raster(width: 80, height: 60))
            group.isGroup = true; group.opacity = 0.7
            group.mask = .ellipse(CGRect(x: 3, y: 4, width: 70, height: 50), width: 80, height: 60)
            var image = PaintLayer(name: "Pixels", raster: Raster(width: 80, height: 60, color: PixelColor(r: 100, g: 20, b: 180, a: 170)))
            image.parentID = group.id
            image.raster.fill(color: PixelColor(r: 30, g: 180, b: 90), rect: CGRect(x: 10, y: 20, width: 30, height: 20))
            image.mask = .rectangle(CGRect(x: 8, y: 6, width: 60, height: 47), width: 80, height: 60).feathered(radius: 2, context: renderer.context)
            var clip = PaintLayer(name: "Clip", raster: Raster(width: 80, height: 60, color: PixelColor(r: 220, g: 30, b: 50, a: 100)))
            clip.parentID = group.id; clip.isClipped = true
            var effect = PaintLayer(name: "Blur", raster: Raster(width: 80, height: 60))
            effect.parentID = group.id; effect.effect = EffectSettings(kind: .blur, radius: 1)
            effect.mask = image.mask
            state.layers = [state.layers[0], image, clip, effect, group]
            if mode == 6 || mode == 8 {
                state.layers[1].text = TextLayerContent(string: "Move", style: TextStyle(size: 20), rect: CGRect(x: mode == 8 ? -20 : 12, y: 15, width: 55, height: 30), color: .white, opacity: 0.8, antialias: true)
                state.layers[1].renderText()
            }
            if mode == 7 {
                for i in state.layers.indices {
                    state.layers[i].raster = try state.layers[i].raster.converted(to: RGBFormat(profile: .displayP3, depth: .sixteen))
                }
            }
            state.activeID = mode == 0 ? group.id : mode == 4 ? effect.id : image.id
            state.editingMask = mode == 2 || mode == 4
            if mode == 3 { state.quickMask = image.mask }
            if mode == 5 { state.layers[1].maskEnabled = false }
            let selection = SelectionMask.ellipse(CGRect(x: 15, y: 12, width: 35, height: 30), width: 80, height: 60).feathered(radius: 1, context: renderer.context)
            let preview = MovePreview(state: state, selection: selection)
            for offset in [(0, 0), (7, -4), (-30, 10)] {
                let actual = try Raster(image: renderer.cgImage(preview.image(dx: offset.0, dy: offset.1, renderer: renderer)))
                var expected = state
                expected.moveActive(from: state, dx: offset.0, dy: offset.1, selection: selection)
                var expectedImage = renderer.compositeImage(expected.layers, width: 80, height: 60)
                if let mask = expected.quickMask { expectedImage = QuickMaskOverlay.image(mask, over: expectedImage) }
                let committed = try Raster(image: renderer.cgImage(expectedImage))
                let difference = zip(actual.bytes, committed.bytes).map { abs(Int($0) - Int($1)) }.max()!
                XCTAssertLessThanOrEqual(difference, 2, "Mode \(mode), offset \(offset)")
            }
        }
    }

    func testMoveGestureDefersPixelsAndSelectionUntilCommitAndCancelsWithoutHistory() throws {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 3840, height: 2160)
        doc.state.layers[1].raster.fill(color: .white)
        let canvas = CanvasView(document: doc, useMetal: false)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas; defer { window.close(); doc.close() }
        canvas.setZoom(0.25); canvas.tool = .move
        canvas.selection = .rectangle(CGRect(x: 400, y: 300, width: 1600, height: 1000), width: 3840, height: 2160)
        let before = doc.state
        func mouse(_ type: NSEvent.EventType, _ offset: Int) -> NSEvent {
            let p = CGPoint(x: canvas.imageRect.minX + CGFloat(600 + offset) * canvas.zoom, y: canvas.imageRect.minY + 500 * canvas.zoom)
            return NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        doc.undoManager!.groupsByEvent = false; doc.undoManager!.beginUndoGrouping()
        canvas.mouseDown(with: mouse(.leftMouseDown, 0))
        let start = ProcessInfo.processInfo.systemUptime
        for i in 1...40 { canvas.mouseDragged(with: mouse(.leftMouseDragged, i * 4)) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.4, "Drag events must not copy 4K pixels or rebuild the selection")
        XCTAssertEqual(doc.state, before); XCTAssertEqual(doc.state.selection?.id, before.selection?.id)
        XCTAssertNil(doc.imageCache)
        canvas.mouseUp(with: mouse(.leftMouseUp, 160)); doc.undoManager!.endUndoGrouping()
        XCTAssertEqual(doc.state.activeLayer.raster.pixel(x: 405, y: 305), .clear)
        XCTAssertEqual(doc.state.activeLayer.raster.pixel(x: 1800, y: 305), .white)
        XCTAssertEqual(canvas.selection, before.selection!.translated(dx: 160, dy: 0))
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, before)
        XCTAssertTrue(doc.undoManager!.canRedo)
        canvas.mouseDown(with: mouse(.leftMouseDown, 0)); canvas.mouseDragged(with: mouse(.leftMouseDragged, 100))
        canvas.rightMouseDown(with: mouse(.rightMouseDown, 100))
        canvas.rightMouseUp(with: mouse(.rightMouseUp, 100)); canvas.mouseUp(with: mouse(.leftMouseUp, 100))
        XCTAssertEqual(doc.state, before); XCTAssertTrue(doc.undoManager!.canRedo)
        doc.undoManager!.redo(); XCTAssertNotEqual(doc.state, before)
    }

    func testPendingMoveFinishesForSaveAndEscapeRestoresOriginal() throws {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 80, height: 60)
        doc.state.layers[1].raster.fill(color: .white)
        let canvas = CanvasView(document: doc, useMetal: false)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 80, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas; defer { window.close(); doc.close() }
        canvas.setZoom(1); canvas.tool = .move
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(CGPoint(x: canvas.imageRect.minX + x, y: canvas.imageRect.minY + 20), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let before = doc.state
        canvas.mouseDown(with: mouse(.leftMouseDown, 20)); canvas.mouseDragged(with: mouse(.leftMouseDragged, 25))
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        canvas.keyDown(with: escape); XCTAssertEqual(doc.state, before)
        canvas.mouseUp(with: mouse(.leftMouseUp, 25))
        doc.undoManager!.groupsByEvent = false; doc.undoManager!.beginUndoGrouping()
        canvas.mouseDown(with: mouse(.leftMouseDown, 20)); canvas.mouseDragged(with: mouse(.leftMouseDragged, 25))
        XCTAssertThrowsError(try canvas.commitEditingWithoutPresentingError(), "Autosave must defer a pending move")
        XCTAssertTrue(canvas.commitEditing()); doc.undoManager!.endUndoGrouping()
        XCTAssertEqual(doc.state.activeLayer.raster.pixel(x: 0, y: 20), .clear)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, before)
    }
}
