import XCTest
import AppKit
@testable import PaintMac

final class AppearanceTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        let result = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: result)
        return result
    }
    private func rgb(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var resolved: NSColor!
        appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
        return resolved
    }

    func testEditorInheritsLightAndDarkAppearanceAndUpdatesExistingPanels() throws {
        let app = NSApplication.shared, originalAppearance = NSApplication.shared.appearance
        defer { app.appearance = originalAppearance }
        app.appearance = NSAppearance(named: .aqua)
        let doc = PaintDocument(); doc.state = DocumentState(width: 400, height: 300)
        doc.makeWindowControllers()
        defer { doc.close() }
        let editor = doc.windowControllers[0] as! EditorWindowController
        let window = editor.window!, root = window.contentView!
        window.setContentSize(CGSize(width: 1320, height: 860))
        window.orderFront(nil)
        root.layoutSubtreeIfNeeded(); editor.canvas.setZoom(1)
        XCTAssertNil(window.appearance, "The editor must inherit the user's theme")
        let views = descendants(root), panels = views.compactMap { $0 as? EditorPanelView }
        XCTAssertEqual(panels.count, 4)
        let title = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Brush" })
        let originalState = doc.state
        var lightBackground: NSColor?
        for (index, name) in [NSAppearance.Name.aqua, .darkAqua, .aqua].enumerated() {
            app.appearance = NSAppearance(named: name)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
            XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), name)
            for panel in panels {
                XCTAssertNil(panel.appearance)
                XCTAssertEqual(panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), name)
                let image = try bitmap(panel)
                let actual = try XCTUnwrap(image.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
                let expected = rgb(panel.backgroundColor, in: panel.effectiveAppearance)
                // AppKit's display bitmap may use a different color profile.
                XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.05)
                XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.05)
                XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.05)
                if panel.accessibilityLabel() == "Colors & Layers inspector" {
                    let colorful = stride(from: 0, to: image.pixelsHigh, by: 8).reduce(0) { count, y in
                        count + stride(from: 0, to: image.pixelsWide, by: 8).filter { x in
                            guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                            let channels = [c.redComponent, c.greenComponent, c.blueComponent]
                            return channels.max()! - channels.min()! > 0.2
                        }.count
                    }
                    XCTAssertGreaterThan(colorful, 30, "Inspector controls and palette must render over the background")
                }
            }
            let text = rgb(title.textColor!, in: title.effectiveAppearance)
            let background = rgb(NSColor.controlBackgroundColor, in: title.effectiveAppearance)
            XCTAssertGreaterThan(abs(text.redComponent - background.redComponent), 0.6, "The options title must remain readable")
            if index == 0 { lightBackground = background }
            else if name == .darkAqua { XCTAssertGreaterThan(lightBackground!.redComponent - background.redComponent, 0.5) }
            XCTAssertEqual(doc.state, originalState, "Theme changes must not alter artwork")
            if let folder = ProcessInfo.processInfo.environment["PAINTMAC_APPEARANCE_PREVIEW_DIR"] {
                let filename = ["light", "dark", "light-again"][index]
                try bitmap(root).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(filename).png"))
            }
        }
    }
}
