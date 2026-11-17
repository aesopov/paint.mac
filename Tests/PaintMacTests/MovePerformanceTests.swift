import AppKit
import CoreImage
import XCTest
@testable import PaintMac

final class MovePerformanceTests: XCTestCase {
    func testMoveBenchmarkWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["PAINTMAC_MOVE_BENCHMARK"] == "1" else { return }
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 3840, height: 2160)
        var raster = Raster(width: 3840, height: 2160, color: .white)
        if let path = ProcessInfo.processInfo.environment["PAINTMAC_BENCHMARK_IMAGE"] {
            raster = try Raster(image: XCTUnwrap(NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        }
        doc.state.layers[1].raster = raster
        let canvas = CanvasView(document: doc, useMetal: false)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas; defer { window.close(); doc.close() }
        canvas.setZoom(0.25); canvas.tool = .move
        canvas.selection = .rectangle(CGRect(x: 400, y: 300, width: 1600, height: 1000), width: 3840, height: 2160)
        func mouse(_ type: NSEvent.EventType, _ offset: Int) -> NSEvent {
            let p = CGPoint(x: canvas.imageRect.minX + CGFloat(600 + offset) * canvas.zoom, y: canvas.imageRect.minY + 500 * canvas.zoom)
            return NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        doc.undoManager!.groupsByEvent = false; doc.undoManager!.beginUndoGrouping()
        var start = ProcessInfo.processInfo.systemUptime
        canvas.mouseDown(with: mouse(.leftMouseDown, 0))
        print(String(format: "Move prepare: %.2f ms", (ProcessInfo.processInfo.systemUptime - start) * 1000))
        start = ProcessInfo.processInfo.systemUptime
        for i in 1...8 { autoreleasepool { canvas.mouseDragged(with: mouse(.leftMouseDragged, i * 10)) } }
        print(String(format: "Move drag input: %.2f ms/event (4K, 1600×1000 selection)", (ProcessInfo.processInfo.systemUptime - start) * 1000 / 8))
        let renderer = try XCTUnwrap(MetalCanvasRenderer(renderer: doc.renderer))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1600, height: 1000, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        func frame(_ offset: Int) throws {
            canvas.mouseDragged(with: mouse(.leftMouseDragged, offset))
            let image = CanvasViewport.image(canvas.displayedImage, imageRect: canvas.imageRect, viewSize: canvas.bounds.size, drawableSize: CGSize(width: 1600, height: 1000), nearest: false, checkerboard: true)
            let buffer = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
            let task = try renderer.encode(image, to: target, commandBuffer: buffer)
            buffer.commit(); buffer.waitUntilCompleted(); _ = try task.waitUntilCompleted()
        }
        try frame(80)
        start = ProcessInfo.processInfo.systemUptime
        for i in 1...12 { try autoreleasepool { try frame(80 + i * 4) } }
        print(String(format: "Move preview render: %.2f ms/frame (GPU completion included)", (ProcessInfo.processInfo.systemUptime - start) * 1000 / 12))
        start = ProcessInfo.processInfo.systemUptime
        canvas.mouseUp(with: mouse(.leftMouseUp, 80)); doc.undoManager!.endUndoGrouping()
        print(String(format: "Move commit: %.2f ms", (ProcessInfo.processInfo.systemUptime - start) * 1000))
    }
}
