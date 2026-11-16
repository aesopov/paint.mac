import XCTest
import AppKit
import CoreImage
@testable import PaintMac

final class DisplayPerformanceRegressionTests: XCTestCase {
    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date(timeIntervalSinceNow: 5)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testProviderCopiesUnalignedTileRegionsWithPaddingAndKeepsSnapshot() {
        for channels in [1, 4, 8] {
            var grid = TileGrid(width: 513, height: 519, channels: channels, base: Array(repeating: 23, count: channels))
            let region = CGRect(x: 250, y: 250, width: 263, height: 269)
            var data = Data(count: Int(region.width * region.height) * channels)
            for i in data.indices { data[i] = UInt8(i % 251) }
            grid.write(data, in: region)
            let provider = TileImageProvider(grid), original = grid
            grid.write(Data(repeating: 255, count: data.count), in: region)
            let width = 270, height = 272, stride = channels == 1 ? 4 : channels, rowBytes = width * stride + 16
            var output = Data(repeating: 99, count: rowBytes * height)
            output.withUnsafeMutableBytes {
                provider.provideImageData($0.baseAddress!, bytesPerRow: rowBytes, origin: 247, 247, size: width, height, userInfo: nil)
            }
            for y in 0..<height { for x in 0..<width { for c in 0..<stride {
                XCTAssertEqual(output[y * rowBytes + x * stride + c], original.value(x: 247 + x, y: 247 + y, channel: channels == 1 ? 0 : c))
            } }
                XCTAssertEqual(output[y * rowBytes + width * stride], 99, "Row padding is not pixel data")
            }
        }
    }

    func testThumbnailsCoalesceVersionsCacheAndRejectObsoleteWorkAfterUndo() throws {
        _ = NSApplication.shared
        let renderer = LayerThumbnailRenderer(), key = LayerThumbnailRenderer.Key(layer: UUID(), mask: false)
        var original = Raster(width: 1024, height: 768, color: .white)
        original.fill(color: .black, rect: CGRect(x: 0, y: 0, width: 200, height: 200))
        var changed = original; changed.fill(color: PixelColor(r: 255, g: 0, b: 0))
        var delivered: CGImage?
        renderer.request(original.storage, key: key) { _ in XCTFail("Obsolete preview published") }
        for _ in 0..<30 { renderer.request(changed.storage, key: key) { delivered = $0 } }
        XCTAssertEqual(renderer.renderedCount, 0, "Input must not synchronously render")
        wait { delivered != nil }
        XCTAssertEqual(renderer.renderedCount, 1)
        let color = try Raster(image: XCTUnwrap(delivered)).pixel(x: 20, y: 20)
        XCTAssertEqual(color.r, 255); XCTAssertLessThanOrEqual(color.g, 1); XCTAssertLessThanOrEqual(color.b, 1)
        let count = renderer.renderedCount
        var immediate = false
        renderer.request(changed.storage, key: key) { _ in immediate = true }
        XCTAssertTrue(immediate); XCTAssertEqual(renderer.renderedCount, count)
        // Undo back to a cached version before a queued replacement starts.
        renderer.request(original.storage, key: key) { _ in XCTFail("Cancelled replacement published") }
        renderer.request(changed.storage, key: key) { _ in }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        XCTAssertEqual(renderer.renderedCount, count)
    }

    func testLivePixelUpdatesReuseLayerControlsAndEventuallyPublishLatestThumbnail() throws {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 3840, height: 2160)
        doc.makeWindowControllers(); defer { doc.close() }
        let editor = doc.windowControllers[0] as! EditorWindowController
        let window = editor.window!
        window.orderFront(nil); window.contentView!.layoutSubtreeIfNeeded()
        func thumbnail(_ view: NSView) -> LayerThumbnailButton? {
            if let button = view as? LayerThumbnailButton, button.layerID == doc.state.activeID { return button }
            return view.subviews.lazy.compactMap { thumbnail($0) }.first
        }
        let button = try XCTUnwrap(thumbnail(window.contentView!))
        let before = editor.thumbnailRenderer.renderedCount
        for i in 0..<30 {
            doc.state.layers[doc.state.activeIndex].raster.fill(color: .black, rect: CGRect(x: i * 10, y: 100, width: 10, height: 10))
            doc.invalidate()
            XCTAssertTrue(try XCTUnwrap(thumbnail(window.contentView!)) === button)
        }
        XCTAssertEqual(editor.thumbnailRenderer.renderedCount, before)
        wait { button.hasPixelPreview }
        XCTAssertNil(doc.imageCache)
        let metal = try XCTUnwrap(editor.canvas.metalView)
        editor.canvas.setZoom(0.5)
        wait { metal.completedFrameCount > 0 }
        let frames = metal.completedFrameCount
        for zoom: CGFloat in [1, 1.5, 0.25, 2, 0.75] { editor.canvas.setZoom(zoom) }
        wait { metal.completedFrameCount > frames }
        XCTAssertEqual(editor.canvas.zoom, 0.75)
        XCTAssertNil(doc.imageCache)
    }

    func testCheckerboardAndArtworkShareViewportTransform() throws {
        let renderer = try XCTUnwrap(MetalCanvasRenderer(renderer: ImageRenderer()))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 80, height: 60, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        var source = Raster(width: 40, height: 30)
        source.fill(color: PixelColor(r: 255, g: 0, b: 0), rect: CGRect(x: 0, y: 0, width: 20, height: 30))
        for rect in [CGRect(x: 10, y: 10, width: 40, height: 30), CGRect(x: 25, y: 5, width: 20, height: 15)] {
            let image = CanvasViewport.image(source.ciImage, imageRect: rect, viewSize: CGSize(width: 80, height: 60), drawableSize: CGSize(width: 80, height: 60), nearest: true, checkerboard: true)
            let buffer = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
            let task = try renderer.encode(image, to: target, commandBuffer: buffer)
            buffer.commit(); buffer.waitUntilCompleted(); _ = try task.waitUntilCompleted()
            var bytes = Data(count: 80 * 60 * 4)
            bytes.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 80 * 4, from: MTLRegionMake2D(0, 0, 80, 60), mipmapLevel: 0) }
            var pixels = Raster(width: 80, height: 60); pixels.bytes = bytes
            XCTAssertEqual(pixels.pixel(x: Int(rect.minX + 2), y: Int(rect.minY + 2)), PixelColor(r: 255, g: 0, b: 0))
            let check = pixels.pixel(x: Int(rect.maxX - 2), y: Int(rect.midY))
            XCTAssertEqual(check.a, 255); XCTAssertEqual(check.r, check.g); XCTAssertEqual(check.g, check.b)
            XCTAssertEqual(pixels.pixel(x: Int(rect.maxX + 2), y: Int(rect.midY)), .clear)
        }
    }
}
