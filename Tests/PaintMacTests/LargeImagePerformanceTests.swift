import XCTest
import AppKit
import CoreImage
@testable import PaintMac

final class LargeImagePerformanceTests: XCTestCase {
    func testLargeImageBenchmarkWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["PAINTMAC_LARGE_IMAGE_BENCHMARK"] == "1" else { return }
        let raster: Raster
        if let path = ProcessInfo.processInfo.environment["PAINTMAC_BENCHMARK_IMAGE"] {
            raster = try Raster(image: XCTUnwrap(NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        } else {
            var data = Data(count: 3840 * 2160 * 4)
            data.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                for y in 0..<2160 { for x in 0..<3840 {
                    let i = (y * 3840 + x) * 4
                    p[i] = UInt8(x % 251); p[i+1] = UInt8(y % 251); p[i+2] = UInt8((x+y) % 251); p[i+3] = 255
                } }
            }
            var image = Raster(width: 3840, height: 2160); image.bytes = data; raster = image
        }
        let compositor = ImageRenderer()
        let renderer = try XCTUnwrap(MetalCanvasRenderer(renderer: compositor))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1600, height: 1000, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        var layer = PaintLayer(name: "Image", raster: raster)
        let image = compositor.compositeImage([layer], width: raster.width, height: raster.height)
        func frame(_ image: CIImage, zoom: Double) throws {
            let viewport = CanvasViewport.image(image, imageRect: CGRect(x: 20, y: 10, width: Double(raster.width) * zoom, height: Double(raster.height) * zoom), viewSize: CGSize(width: 800, height: 500), drawableSize: CGSize(width: 1600, height: 1000), nearest: zoom >= 1)
            let buffer = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
            let task = try renderer.encode(viewport, to: texture, commandBuffer: buffer)
            buffer.commit(); buffer.waitUntilCompleted(); _ = try task.waitUntilCompleted()
        }
        func timed(_ name: String, count: Int, _ operation: (Int) throws -> Void) rethrows {
            let start = ProcessInfo.processInfo.systemUptime
            for i in 0..<count { try autoreleasepool { try operation(i) } }
            print(String(format: "Large image %@: %.2f ms", name, (ProcessInfo.processInfo.systemUptime - start) * 1000 / Double(count)))
        }
        try timed("first frame", count: 1) { _ in try frame(image, zoom: 0.2) }
        try timed("zoom (GPU completion included)", count: 12) { i in try frame(image, zoom: [0.2, 0.5, 1.0, 1.5][i % 4]) }
        timed("thumbnail", count: 6) { _ in
            let scaled = layer.raster.ciImage.transformed(by: CGAffineTransform(scaleX: 80 / CGFloat(raster.width), y: 80 / CGFloat(raster.width)))
            _ = compositor.context.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: 80, height: ceil(80 * CGFloat(raster.height) / CGFloat(raster.width))))
        }
        try timed("edit + frame", count: 8) { i in
            layer.raster.stroke(from: CGPoint(x: 300 + i * 20, y: 300), to: CGPoint(x: 320 + i * 20, y: 300), size: 40, color: .black, opacity: 1, erase: false, clip: nil)
            try frame(compositor.compositeImage([layer], width: raster.width, height: raster.height), zoom: 0.5)
        }
    }
}
