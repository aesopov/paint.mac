import AppKit
import XCTest
@testable import PaintMac

final class SelectionAnimationTests: XCTestCase {
    private func run(for interval: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: interval)
        repeat {
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        } while Date() < deadline
    }
    private func fixture(useMetal: Bool = false) throws -> (PaintDocument, CanvasView, CanvasOverlayView, NSWindow) {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 100, height: 80)
        let canvas = CanvasView(document: doc, useMetal: useMetal)
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 300, height: 240),
                              styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        // A background XCTest process cannot reliably put a normal window
        // above the active desktop app. Keep this visibility-dependent fixture
        // above normal editor windows; production occlusion behavior is unchanged.
        window.level = .floating
        window.isReleasedWhenClosed = false; window.contentView = canvas
        window.orderFrontRegardless(); canvas.layoutSubtreeIfNeeded(); canvas.setZoom(1)
        run(for: 0.2)
        // Earlier editor tests can still have queued window/Metal callbacks.
        // Reassert ordering while AppKit drains them instead of assuming the
        // first asynchronous WindowServer occlusion update has arrived.
        let visibleDeadline = Date(timeIntervalSinceNow: 1.5)
        while !window.occlusionState.contains(.visible) && Date() < visibleDeadline {
            window.orderFrontRegardless()
            run(for: 0.05)
        }
        XCTAssertTrue(window.occlusionState.contains(.visible), "The test window must be onscreen")
        return (doc, canvas, try XCTUnwrap(canvas.subviews.compactMap { $0 as? CanvasOverlayView }.first), window)
    }
    private func waitForTick(_ overlay: CanvasOverlayView) {
        let phase = overlay.selectionDashPhase, deadline = Date(timeIntervalSinceNow: 1)
        while overlay.selectionDashPhase == phase && Date() < deadline {
            run(for: 0.02)
        }
        XCTAssertNotEqual(overlay.selectionDashPhase, phase, "A visible selection must animate")
    }
    private func pixels(_ canvas: CanvasView) throws -> Raster {
        let width = Int(canvas.bounds.width), height = Int(canvas.bounds.height)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4, space: Raster.colorSpace,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        canvas.drawOverlays()
        NSGraphicsContext.restoreGraphicsState()
        return try Raster(image: XCTUnwrap(context.makeImage()))
    }

    func testAnimationChangesOnlyOverlayWithoutGPUFramesCPUCompositeOrHistory() throws {
        let (doc, canvas, overlay, window) = try fixture(useMetal: true)
        defer { window.close(); doc.close() }
        let metal = try XCTUnwrap(canvas.metalView)
        XCTAssertGreaterThan(metal.submittedFrameCount, 0)
        canvas.selection = .ellipse(CGRect(x: 10, y: 10, width: 60, height: 50), width: 100, height: 80)
        let before = doc.state, frames = metal.submittedFrameCount
        XCTAssertTrue(overlay.isAnimatingSelection)
        waitForTick(overlay)
        let phase = overlay.selectionDashPhase, deadline = Date(timeIntervalSinceNow: 0.2)
        while Date() < deadline {
            RunLoop.current.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.02))
        }
        XCTAssertNotEqual(overlay.selectionDashPhase, phase, "Ants must continue during mouse tracking")
        run(for: 0.25)
        XCTAssertEqual(metal.submittedFrameCount, frames)
        XCTAssertNil(doc.imageCache)
        XCTAssertEqual(doc.state, before)
        XCTAssertFalse(doc.undoManager!.canUndo)
    }

    func testAnimatedPixelsFollowOuterContourAndHoleAtEveryZoom() throws {
        let (doc, canvas, overlay, window) = try fixture()
        defer { window.close(); doc.close() }
        let outer = SelectionMask.rectangle(CGRect(x: 10, y: 10, width: 80, height: 60), width: 100, height: 80)
        let hole = SelectionMask.rectangle(CGRect(x: 35, y: 25, width: 30, height: 30), width: 100, height: 80)
        canvas.selection = outer.combined(with: hole, mode: .subtract)
        for zoom: CGFloat in [0.5, 1, 2] {
            canvas.setZoom(zoom)
            let first = try pixels(canvas)
            waitForTick(overlay)
            let second = try pixels(canvas)
            let a = first.bytes, b = second.bytes
            var outerChanges = 0, holeChanges = 0
            for y in 0..<first.height { for x in 0..<first.width {
                let i = (y * first.width + x) * 4
                guard a[i..<i+4] != b[i..<i+4] else { continue }
                let point = canvas.toImage(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
                if point.x > 33 && point.x < 67 && point.y > 23 && point.y < 57 { holeChanges += 1 }
                else { outerChanges += 1 }
            } }
            XCTAssertGreaterThan(outerChanges, 0, "Outer contour at zoom \(zoom)")
            XCTAssertGreaterThan(holeChanges, 0, "Hole contour at zoom \(zoom)")
            XCTAssertEqual(first.pixel(x: 150, y: 120), second.pixel(x: 150, y: 120), "Interior shading must stay still")
        }
    }

    func testAnimationStopsWhenDeselectedEmptyHiddenOrderedOutOrDetached() throws {
        let (doc, canvas, overlay, window) = try fixture()
        defer { window.close(); doc.close() }
        let selection = SelectionMask.all(width: 100, height: 80)
        canvas.selection = selection; XCTAssertTrue(overlay.isAnimatingSelection)
        canvas.selection = nil; XCTAssertFalse(overlay.isAnimatingSelection)
        canvas.selection = .empty(width: 100, height: 80); XCTAssertFalse(overlay.isAnimatingSelection)
        // Quick Mask itself is a painted overlay; only its local marquee has ants.
        doc.state.quickMask = selection; canvas.selection = nil
        XCTAssertFalse(overlay.isAnimatingSelection)
        canvas.selection = selection; XCTAssertTrue(overlay.isAnimatingSelection)
        canvas.isHidden = true; XCTAssertFalse(overlay.isAnimatingSelection)
        canvas.isHidden = false; XCTAssertTrue(overlay.isAnimatingSelection)
        window.orderOut(nil)
        run(for: 0.15)
        XCTAssertFalse(overlay.isAnimatingSelection)
        let phase = overlay.selectionDashPhase
        run(for: 0.15)
        XCTAssertEqual(overlay.selectionDashPhase, phase)
        window.orderFrontRegardless()
        run(for: 0.15)
        XCTAssertTrue(overlay.isAnimatingSelection)
        window.contentView = nil; XCTAssertFalse(overlay.isAnimatingSelection)
    }

    func testAnimationDoesNotRetainClosedCanvas() throws {
        weak var releasedCanvas: CanvasView?
        weak var releasedOverlay: CanvasOverlayView?
        try autoreleasepool {
            let (doc, canvas, overlay, window) = try fixture()
            canvas.selection = .all(width: 100, height: 80)
            XCTAssertTrue(overlay.isAnimatingSelection)
            releasedCanvas = canvas; releasedOverlay = overlay
            window.contentView = nil; window.close(); doc.close()
        }
        XCTAssertNil(releasedCanvas); XCTAssertNil(releasedOverlay)
    }
}
