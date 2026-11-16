import AppKit
import CoreImage
import MetalKit

/// The AppKit canvas uses top-left points; Core Image uses bottom-left pixels.
/// Transform before rendering so only the visible viewport needs an output texture,
/// even when the document is huge or zoomed far beyond the window.
enum CanvasViewport {
    static func image(_ image: CIImage, imageRect: CGRect, viewSize: CGSize,
                      drawableSize: CGSize, nearest: Bool) -> CIImage {
        let bounds = CGRect(origin: .zero, size: drawableSize)
        guard viewSize.width > 0, viewSize.height > 0, !image.extent.isEmpty else {
            return CIImage(color: .clear).cropped(to: bounds)
        }
        let sx = drawableSize.width / viewSize.width, sy = drawableSize.height / viewSize.height
        let transform = CGAffineTransform(a: imageRect.width / image.extent.width * sx, b: 0, c: 0,
                                          d: imageRect.height / image.extent.height * sy,
                                          tx: imageRect.minX * sx, ty: (viewSize.height - imageRect.maxY) * sy)
        // Resolve effects/compositing on the document pixel grid before nearest
        // sampling. Otherwise Core Image may fuse the viewport transform into
        // a filter and evaluate it between pixels at fractional zoom levels.
        let sampled = nearest ? image.insertingIntermediate().samplingNearest() : image.samplingLinear()
        let positioned = sampled.transformed(by: transform)
        // Write transparent pixels outside the image too: never leave old drawable
        // contents behind after a pan, resize, or transition to a smaller document.
        return positioned.composited(over: CIImage(color: .clear)).cropped(to: bounds)
    }
}

/// Shared by the onscreen drawable and GPU pixel regression tests. No CGImage
/// conversion or CPU readback occurs here.
final class MetalCanvasRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let context: CIContext

    init?(renderer: ImageRenderer) {
        guard let device = renderer.device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device; commandQueue = queue; context = renderer.context
        queue.label = "Paint.MAC canvas"
    }

    func encode(_ image: CIImage, to texture: MTLTexture, commandBuffer: MTLCommandBuffer, colorSpace: CGColorSpace = Raster.colorSpace) throws -> CIRenderTask {
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: commandBuffer)
        destination.colorSpace = colorSpace
        destination.alphaMode = .premultiplied
        // Metal row zero is the top of the presented texture.
        destination.isFlipped = true
        destination.isDithered = false
        return try context.startTask(toRender: image, from: CGRect(x: 0, y: 0, width: texture.width, height: texture.height),
                                     to: destination, at: .zero)
    }
}

/// Display on demand rather than running an idle animation loop. Input passes
/// through to CanvasView, and native selection/text controls sit above this view.
final class MetalCanvasView: MTKView, MTKViewDelegate {
    let canvasRenderer: MetalCanvasRenderer
    var imageProvider: ((CGSize) -> CIImage)?
    var onFailure: (() -> Void)?
    private let inFlight = DispatchSemaphore(value: 3)
    private var redrawPending = false
    private var redrawScheduled = false
    private(set) var submittedFrameCount = 0

    init(renderer: MetalCanvasRenderer) {
        canvasRenderer = renderer
        super.init(frame: .zero, device: renderer.device)
        colorPixelFormat = .rgba16Float
        colorspace = RGBProfile.displayP3.space
        framebufferOnly = false // Core Image writes to the drawable texture.
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        layer?.isOpaque = false
        // Use MTKView's explicit-draw mode. NSView.needsDisplay alone does not
        // reliably submit Metal frames in this layer-backed AppKit hierarchy.
        isPaused = true; enableSetNeedsDisplay = false; autoResizeDrawable = true
        delegate = self
        setAccessibilityElement(false)
    }
    required init(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); requestRedraw() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); requestRedraw() }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { requestRedraw() }

    /// Coalesce updates onto the next AppKit run-loop turn, including mouse
    /// tracking. Keeping the draw loop paused still avoids idle rendering.
    func requestRedraw() {
        guard !redrawScheduled else { return }
        redrawScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            guard let self else { return }
            self.redrawScheduled = false
            guard self.window != nil, !self.isHiddenOrHasHiddenAncestor else { return }
            self.draw()
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    func draw(in view: MTKView) {
        guard window != nil, bounds.width > 0, bounds.height > 0, let imageProvider else { return }
        guard inFlight.wait(timeout: .now()) == .success else { redrawPending = true; return }
        guard let drawable = currentDrawable, let buffer = canvasRenderer.commandQueue.makeCommandBuffer() else {
            inFlight.signal(); return
        }
        let image = imageProvider(CGSize(width: drawable.texture.width, height: drawable.texture.height))
        do {
            let task = try canvasRenderer.encode(image, to: drawable.texture, commandBuffer: buffer, colorSpace: RGBProfile.displayP3.space)
            let semaphore = inFlight
            buffer.addCompletedHandler { [weak self, image, task] completed in
                // Keep immutable pixels and the Core Image task alive until the GPU
                // finishes, even if a newer document snapshot replaces the cache.
                withExtendedLifetime((image, task)) {}
                semaphore.signal()
                let failed = completed.status == .error
                if failed { NSLog("Paint.MAC Metal canvas: %@", completed.error?.localizedDescription ?? "GPU rendering failed") }
                RunLoop.main.perform(inModes: [.common]) { [weak self] in
                    guard let self else { return }
                    if failed { self.onFailure?() }
                    else if self.redrawPending { self.redrawPending = false; self.requestRedraw() }
                }
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
            buffer.label = "Paint.MAC viewport"
            buffer.present(drawable); buffer.commit()
            submittedFrameCount += 1
        } catch {
            NSLog("Paint.MAC Metal canvas: %@", error.localizedDescription)
            inFlight.signal(); onFailure?()
        }
    }
}

/// An AppKit overlay keeps selection outlines, brush cursors, and text-box
/// previews independent of GPU presentation without intercepting mouse input.
final class CanvasOverlayView: NSView {
    weak var canvas: CanvasView?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { canvas?.drawOverlays() }
}
