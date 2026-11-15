import XCTest
import AppKit
import CoreImage
import MetalKit
@testable import PaintMac

final class MetalCanvasTests: XCTestCase {
    private let red = PixelColor(r: 255, g: 0, b: 0)
    private let blue = PixelColor(r: 0, g: 0, b: 255)

    private func renderer() throws -> MetalCanvasRenderer {
        guard let renderer = MetalCanvasRenderer(renderer: ImageRenderer()) else { throw XCTSkip("Metal is unavailable") }
        return renderer
    }
    private func texture(_ renderer: MetalCanvasRenderer, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        return try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
    }
    private func draw(_ image: CIImage, renderer: MetalCanvasRenderer, into texture: MTLTexture) throws {
        let buffer = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        let task = try renderer.encode(image, to: texture, commandBuffer: buffer)
        buffer.commit(); buffer.waitUntilCompleted()
        XCTAssertEqual(buffer.status, .completed, "\(String(describing: buffer.error))")
        _ = try task.waitUntilCompleted()
    }
    private func pixels(_ texture: MTLTexture) -> Raster {
        var result = Raster(width: texture.width, height: texture.height)
        result.bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: bytes.count, by: 4) { let b = bytes[i]; bytes[i] = bytes[i + 2]; bytes[i + 2] = b }
        }
        return result
    }
    private func viewport(_ image: CIImage, rect: CGRect? = nil, size: CGSize? = nil, scale: CGFloat = 1, nearest: Bool = true) -> CIImage {
        let viewSize = size ?? image.extent.size
        return CanvasViewport.image(image, imageRect: rect ?? CGRect(origin: .zero, size: image.extent.size),
                                    viewSize: viewSize, drawableSize: CGSize(width: viewSize.width * scale, height: viewSize.height * scale), nearest: nearest)
    }
    private func near(_ actual: Raster, _ expected: Raster, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.width, expected.width, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, file: file, line: line)
        let difference = zip(actual.bytes, expected.bytes).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(difference, 2, "Maximum channel difference", file: file, line: line)
    }

    func testGPUColorsAlphaAndTopLeftOrientationMatchExport() throws {
        let renderer = try renderer(), target = try texture(renderer, width: 16, height: 12)
        var source = Raster(width: 16, height: 12)
        source.fill(color: red, rect: CGRect(x: 0, y: 0, width: 5, height: 4))
        source.fill(color: blue, rect: CGRect(x: 11, y: 8, width: 5, height: 4))
        source.fill(color: PixelColor(r: 40, g: 180, b: 95, a: 128), rect: CGRect(x: 6, y: 4, width: 4, height: 3))
        try draw(viewport(CIImage(cgImage: source.cgImage)), renderer: renderer, into: target)
        near(pixels(target), source)
        XCTAssertEqual(pixels(target).pixel(x: 0, y: 0), red)
        XCTAssertEqual(pixels(target).pixel(x: 15, y: 11), blue)
    }

    func testRetinaZoomPanAndDrawableReuseNeverLeaveStalePixels() throws {
        let renderer = try renderer()
        var source = Raster(width: 2, height: 2)
        source.fill(color: red, rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        source.fill(color: blue, rect: CGRect(x: 1, y: 1, width: 1, height: 1))
        let image = CIImage(cgImage: source.cgImage)
        for scale: CGFloat in [1, 2] {
            let size = CGSize(width: 12, height: 10)
            let target = try texture(renderer, width: Int(size.width * scale), height: Int(size.height * scale))
            try draw(viewport(image, rect: CGRect(x: 2, y: 1, width: 8, height: 8), size: size, scale: scale), renderer: renderer, into: target)
            let first = pixels(target)
            XCTAssertEqual(first.pixel(x: Int(3 * scale), y: Int(2 * scale)), red)
            XCTAssertEqual(first.pixel(x: Int(8 * scale), y: Int(7 * scale)), blue)
            XCTAssertEqual(first.pixel(x: 0, y: 0), .clear)
            XCTAssertTrue(stride(from: 3, to: first.bytes.count, by: 4).allSatisfy { first.bytes[$0] == 0 || first.bytes[$0] == 255 })
            // The image now extends far beyond the viewport, as during a zoomed pan.
            try draw(viewport(image, rect: CGRect(x: -8, y: -8, width: 20, height: 20), size: size, scale: scale), renderer: renderer, into: target)
            XCTAssertEqual(pixels(target).pixel(x: Int(9 * scale), y: Int(8 * scale)), blue)
            try draw(viewport(image, rect: CGRect(x: 30, y: 30, width: 8, height: 8), size: size, scale: scale), renderer: renderer, into: target)
            XCTAssertEqual(pixels(target), Raster(width: target.width, height: target.height))
        }
    }

    func testSmoothSamplingInterpolatesWhileHighZoomKeepsPixelEdges() throws {
        let renderer = try renderer(), target = try texture(renderer, width: 24, height: 16)
        var source = Raster(width: 2, height: 2, color: red)
        source.fill(color: blue, rect: CGRect(x: 1, y: 0, width: 1, height: 2))
        let image = CIImage(cgImage: source.cgImage)
        for nearest in [false, true] {
            try draw(viewport(image, rect: CGRect(x: 0, y: 0, width: 24, height: 16), size: CGSize(width: 24, height: 16), nearest: nearest), renderer: renderer, into: target)
            let middle = pixels(target).pixel(x: 11, y: 8)
            if nearest { XCTAssertEqual(middle, red) }
            else { XCTAssertGreaterThan(middle.r, 30); XCTAssertGreaterThan(middle.b, 30) }
        }
    }

    func testCanvasKeepsPixelsCrispAtAndAboveActualSizeOnStandardAndRetinaDisplays() throws {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 2, height: 2)
        doc.state.layers[1].raster.fill(color: red)
        doc.state.layers[1].raster.fill(color: blue, rect: CGRect(x: 1, y: 0, width: 1, height: 2))
        let canvas = CanvasView(document: doc); canvas.frame = CGRect(x: 0, y: 0, width: 16, height: 12)
        let provider = try XCTUnwrap(canvas.metalView?.imageProvider), renderer = try renderer()
        for scale in [1, 2] {
            let target = try texture(renderer, width: 16 * scale, height: 12 * scale)
            for zoom: CGFloat in [0.75, 0.99, 1, 1.25, 1.5, 2, 2.99, 3, 4] {
                // Offset the seam from the output pixel grid so interpolation
                // below 100% is observable rather than coincidentally aligned.
                canvas.setZoom(zoom, anchor: CGPoint(x: 10, y: 6))
                try draw(provider(CGSize(width: target.width, height: target.height)), renderer: renderer, into: target)
                let raster = pixels(target)
                let mixed = stride(from: 0, to: raster.bytes.count, by: 4).contains {
                    raster.bytes[$0] > 1 && raster.bytes[$0 + 2] > 1
                }
                XCTAssertEqual(mixed, zoom < 1, "Zoom \(zoom), backing scale \(scale)")
            }
        }
    }

    func testCoreGraphicsFallbackKeepsMagnifiedPixelsCrisp() throws {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 8, height: 8)
        doc.state.layers[1].raster.fill(color: red)
        doc.state.layers[1].raster.fill(color: blue, rect: CGRect(x: 4, y: 0, width: 4, height: 8))
        let canvas = CanvasView(document: doc, useMetal: false)
        canvas.frame = CGRect(x: 0, y: 0, width: 64, height: 64); canvas.setZoom(1.5)
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                            bytesPerRow: 64 * 4, space: Raster.colorSpace,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let raster = try Raster(image: XCTUnwrap(context.makeImage()))
        XCTAssertEqual(raster.pixel(x: 31, y: 32), red)
        XCTAssertEqual(raster.pixel(x: 32, y: 32), blue)
    }

    func testGroupsClippingMasksEffectsAndTextMatchCPUComposite() throws {
        _ = NSApplication.shared
        let renderer = try renderer(), compositor = ImageRenderer()
        var group = PaintLayer(name: "Group", raster: Raster(width: 100, height: 70))
        group.isGroup = true; group.opacity = 0.7
        group.mask = .ellipse(CGRect(x: 3, y: 2, width: 94, height: 66), width: 100, height: 70).feathered(radius: 2, context: compositor.context)
        var base = PaintLayer(name: "Base", raster: Raster(width: 100, height: 70, color: PixelColor(r: 170, g: 40, b: 100, a: 180)))
        base.parentID = group.id; base.opacity = 0.8
        var text = PaintLayer(name: "Text", raster: Raster(width: 100, height: 70))
        text.parentID = group.id; text.isClipped = true
        text.text = TextLayerContent(string: "Ab", style: TextStyle(size: 40), rect: CGRect(x: 8, y: 4, width: 80, height: 60), color: .white, opacity: 1, antialias: true)
        text.raster = text.text!.rendered(width: 100, height: 70, clip: nil)
        var effect = PaintLayer(name: "Effect", raster: Raster(width: 100, height: 70))
        effect.parentID = group.id; effect.effect = EffectSettings(kind: .hueSaturation, hue: 35, saturation: 0.7)
        effect.opacity = 0.4
        let nodes = [base, text, effect, group]
        let target = try texture(renderer, width: 100, height: 70)
        let image = compositor.compositeImage(nodes, width: 100, height: 70)
        try draw(viewport(image), renderer: renderer, into: target)
        near(pixels(target), try Raster(image: compositor.composite(nodes, width: 100, height: 70)))
    }

    func testDocumentInvalidationKeepsSubmittedPixelsImmutableAndRefreshesExport() throws {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 16, height: 12)
        doc.state.layers[0].visible = false
        doc.state.layers[1].raster.fill(color: red)
        let renderer = try renderer(), target = try texture(renderer, width: 16, height: 12)
        let old = doc.compositeImage
        XCTAssertNil(doc.imageCache)
        doc.state.layers[1].raster.fill(color: blue); doc.invalidate()
        try draw(viewport(old), renderer: renderer, into: target)
        XCTAssertEqual(pixels(target).pixel(x: 3, y: 3), red)
        try draw(viewport(doc.compositeImage), renderer: renderer, into: target)
        XCTAssertEqual(pixels(target).pixel(x: 3, y: 3), blue)
        XCTAssertNil(doc.imageCache)
        near(pixels(target), try Raster(image: doc.composite))
        XCTAssertNotNil(doc.imageCache)
    }

    func testZoomedEffectsKeepTheSameResultAsScalingExportedPixels() throws {
        let compositor = ImageRenderer(), renderer = try renderer()
        var base = PaintLayer(name: "Image", raster: Raster(width: 100, height: 70))
        base.raster.strokeShape(in: CGRect(x: 8, y: 5, width: 75, height: 50), ellipse: true,
                               size: 5, color: red, opacity: 0.8, clip: nil, fillColor: blue)
        var blur = PaintLayer(name: "Blur", raster: Raster(width: 100, height: 70))
        blur.effect = EffectSettings(kind: .blur, radius: 2)
        let nodes = [base, blur]
        let direct = compositor.compositeImage(nodes, width: 100, height: 70)
        let exported = CIImage(cgImage: compositor.composite(nodes, width: 100, height: 70))
        let size = CGSize(width: 120, height: 90)
        for scale: CGFloat in [1, 2] {
            let target = try texture(renderer, width: Int(size.width * scale), height: Int(size.height * scale))
            for zoom: CGFloat in [0.5, 1, 1.25, 2, 4] {
                let rect = CGRect(x: -3, y: 7, width: 100 * zoom, height: 70 * zoom)
                try draw(viewport(direct, rect: rect, size: size, scale: scale, nearest: zoom >= 1), renderer: renderer, into: target)
                let actual = pixels(target)
                try draw(viewport(exported, rect: rect, size: size, scale: scale, nearest: zoom >= 1), renderer: renderer, into: target)
                near(actual, pixels(target))
            }
        }
    }

    func testOnscreenCanvasDrawsOnDemandWithoutCPUCompositeAndKeepsInput() throws {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 180, height: 120)
        let canvas = CanvasView(document: doc)
        let view = try XCTUnwrap(canvas.metalView)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas; defer { window.close() }
        window.orderFront(nil); canvas.layoutSubtreeIfNeeded(); canvas.setZoom(1)
        canvas.displayIfNeeded(); view.draw()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        XCTAssertGreaterThan(view.submittedFrameCount, 0)
        XCTAssertNil(doc.imageCache, "Onscreen rendering must not request an intermediate CGImage")
        XCTAssertTrue(view.isPaused); XCTAssertFalse(view.enableSetNeedsDisplay)
        let idle = view.submittedFrameCount
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertEqual(view.submittedFrameCount, idle, "An idle editor must not keep drawing")
        XCTAssertTrue(canvas.hitTest(CGPoint(x: 200, y: 150)) === canvas)
        let move = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: canvas.convert(CGPoint(x: 200, y: 150), to: nil),
                                                  modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        canvas.mouseMoved(with: move)
        canvas.selection = .ellipse(CGRect(x: 20, y: 20, width: 60, height: 50), width: 180, height: 120)
        canvas.displayIfNeeded(); RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(view.submittedFrameCount, idle, "Cursor and selection overlays must not recomposite artwork")
        canvas.beginText(in: CGRect(x: 30, y: 30, width: 100, height: 60), color: blue)
        let draft = try XCTUnwrap(canvas.textEditor)
        draft.textView.insertText("Metal", replacementRange: NSRange(location: NSNotFound, length: 0))
        let before = doc.state
        canvas.setZoom(2); canvas.layoutSubtreeIfNeeded(); view.draw()
        window.setContentSize(CGSize(width: 520, height: 340)); canvas.layoutSubtreeIfNeeded(); view.draw()
        XCTAssertTrue(window.firstResponder === draft.textView)
        XCTAssertEqual(doc.state, before); XCTAssertNil(doc.imageCache)
        XCTAssertEqual(canvas.subviews.last, draft)
        view.onFailure?()
        XCTAssertNil(canvas.metalView); XCTAssertTrue(window.firstResponder === draft.textView)
        XCTAssertEqual(doc.state, before, "Switching to fallback must preserve the inline draft and artwork")
        canvas.finishText(apply: false)
    }

    func testCoreGraphicsFallbackAndSelectionOverlayRemainAvailable() throws {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 100, height: 80)
        let canvas = CanvasView(document: doc, useMetal: false)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas; defer { window.close() }
        canvas.layoutSubtreeIfNeeded(); canvas.setZoom(1)
        canvas.selection = .rectangle(CGRect(x: 10, y: 10, width: 40, height: 40), width: 100, height: 80)
        let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        XCTAssertNil(canvas.metalView)
        // Selected white pixels stay white; excluded white pixels are dimmed.
        let scale = CGFloat(bitmap.pixelsWide) / canvas.bounds.width
        func color(_ x: CGFloat, _ y: CGFloat) -> NSColor {
            bitmap.colorAt(x: Int((canvas.imageRect.minX + x) * scale), y: Int((canvas.imageRect.minY + y) * scale))!.usingColorSpace(.sRGB)!
        }
        XCTAssertGreaterThan(color(25, 25).redComponent, 0.97)
        XCTAssertLessThan(color(70, 60).redComponent, 0.9)
    }

    func testLiveEditorRepaintsAfterDrawingZoomPanAndResizeWithoutManualDrawCalls() throws {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 300, height: 200)
        doc.makeWindowControllers(); defer { doc.close() }
        let editor = doc.windowControllers[0] as! EditorWindowController
        let canvas = editor.canvas, window = editor.window!
        let metal = try XCTUnwrap(canvas.metalView)
        window.orderFront(nil); window.contentView!.layoutSubtreeIfNeeded(); canvas.setZoom(1)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        var frames = metal.submittedFrameCount
        XCTAssertGreaterThan(frames, 0)
        doc.undoManager!.groupsByEvent = false
        doc.undoManager!.beginUndoGrouping()
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
            let point = CGPoint(x: canvas.imageRect.minX + x * canvas.zoom, y: canvas.imageRect.minY + y * canvas.zoom)
            return NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                                     timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: mouse(.leftMouseDown, 30, 30))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, 180, 120))
        canvas.mouseUp(with: mouse(.leftMouseUp, 180, 120))
        doc.undoManager!.endUndoGrouping()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertGreaterThan(metal.submittedFrameCount, frames, "A real painting gesture must present a new frame")
        frames = metal.submittedFrameCount
        canvas.setZoom(2)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertGreaterThan(metal.submittedFrameCount, frames, "Zoom must present a new frame")
        frames = metal.submittedFrameCount
        editor.selectTool(.hand)
        canvas.mouseDown(with: mouse(.leftMouseDown, 70, 70))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, 120, 90))
        canvas.mouseUp(with: mouse(.leftMouseUp, 120, 90))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertGreaterThan(metal.submittedFrameCount, frames, "Pan must present a new frame")
        frames = metal.submittedFrameCount
        let oldSize = window.contentView!.bounds.size
        window.setContentSize(CGSize(width: oldSize.width + 120, height: oldSize.height + 60))
        window.contentView!.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertGreaterThan(metal.submittedFrameCount, frames, "Resize must present a new frame")
        XCTAssertNil(doc.imageCache, "Live updates must use the Metal path")
    }

    func testInitialFitWaitsForBothViewportDimensions() {
        _ = NSApplication.shared
        let doc = PaintDocument()
        let canvas = CanvasView(document: doc)
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 0); canvas.layout()
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600); canvas.layout()
        XCTAssertEqual(canvas.zoom, 704.0 / 1200, accuracy: 0.001)
    }

    func testExplicitSnapshotIncludesMetalArtworkAndSelectionWithoutChangingDocument() throws {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 100, height: 80)
        doc.state.layers[1].raster.fill(color: red, rect: CGRect(x: 0, y: 0, width: 50, height: 40))
        doc.state.layers[1].raster.fill(color: blue, rect: CGRect(x: 50, y: 40, width: 50, height: 40))
        let canvas = CanvasView(document: doc)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas; defer { window.close() }
        window.orderFront(nil); canvas.layoutSubtreeIfNeeded(); canvas.setZoom(1)
        canvas.selection = .rectangle(CGRect(x: 0, y: 0, width: 50, height: 40), width: 100, height: 80)
        let before = doc.state
        let bitmap = try XCTUnwrap(canvas.snapshot())
        let scale = CGFloat(bitmap.pixelsWide) / canvas.bounds.width
        func color(_ x: CGFloat, _ y: CGFloat) -> NSColor {
            bitmap.colorAt(x: Int((canvas.imageRect.minX + x) * scale), y: Int((canvas.imageRect.minY + y) * scale))!.usingColorSpace(.sRGB)!
        }
        // AppKit's display-cache profile can differ from sRGB; the raw Metal
        // texture tests above check exact channel values independently of it.
        XCTAssertGreaterThan(color(25, 20).redComponent, 0.9)
        XCTAssertLessThan(color(25, 20).blueComponent, 0.25)
        XCTAssertGreaterThan(color(75, 60).blueComponent, 0.7)
        XCTAssertLessThan(color(75, 60).blueComponent, 0.9)
        XCTAssertNotNil(canvas.metalView); XCTAssertEqual(doc.state, before)
        XCTAssertFalse(doc.undoManager!.canUndo)
    }

    func testRenderingBenchmarkWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["PAINTMAC_METAL_BENCHMARK"] == "1" else { return }
        let compositor = ImageRenderer(), renderer = try renderer()
        let size = CGSize(width: 1200, height: 800), documentSize = CGSize(width: 2400, height: 1600)
        var layers: [PaintLayer] = []
        for i in 0..<6 {
            var raster = Raster(width: 2400, height: 1600)
            raster.strokeShape(in: CGRect(x: 100 + i * 120, y: 100 + i * 80, width: 1400, height: 900),
                               ellipse: true, size: 40, color: red, opacity: 0.7, clip: nil, fillColor: blue)
            layers.append(PaintLayer(name: "Layer \(i)", raster: raster))
        }
        var blur = PaintLayer(name: "Blur", raster: Raster(width: 2400, height: 1600))
        blur.effect = EffectSettings(kind: .blur, radius: 4); layers.append(blur)
        let target = try texture(renderer, width: 1200, height: 800)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8,
                                            bytesPerRow: 1200 * 4, space: Raster.colorSpace,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .high
        let rect = CGRect(origin: .zero, size: size)
        func legacy() {
            let image = compositor.composite(layers, width: Int(documentSize.width), height: Int(documentSize.height))
            context.clear(rect); context.draw(image, in: rect); context.flush()
        }
        func direct() throws {
            let image = compositor.compositeImage(layers, width: Int(documentSize.width), height: Int(documentSize.height))
            try draw(viewport(image, rect: rect, size: size, nearest: false), renderer: renderer, into: target)
        }
        legacy(); try direct() // Warm both pipelines before timing.
        let iterations = 12
        var start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<iterations { autoreleasepool { legacy() } }
        let old = (ProcessInfo.processInfo.systemUptime - start) / Double(iterations)
        start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<iterations { try autoreleasepool { try direct() } }
        let new = (ProcessInfo.processInfo.systemUptime - start) / Double(iterations)
        print(String(format: "Canvas benchmark: 2400×1600, 6 image layers + blur, 1200×800 viewport. Legacy %.2f ms; direct Metal %.2f ms (GPU completion included), %.2f×.", old * 1000, new * 1000, old / new))
    }
}
