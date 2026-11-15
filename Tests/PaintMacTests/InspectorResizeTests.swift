import XCTest
import AppKit
import QuartzCore
@testable import PaintMac

final class InspectorResizeTests: XCTestCase {
    private func preferences() -> (UserDefaults, String) {
        let name = "PaintMacInspectorTests." + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }
    private func views(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + views($0) } }
    private func setWidth(_ width: CGFloat, split: InspectorSplitView) {
        // NSSplitView applies the same delegate constraints as a divider drag.
        split.setPosition(split.bounds.width - split.dividerThickness - width, ofDividerAt: 0)
        split.superview?.layoutSubtreeIfNeeded()
    }
    private func editor(preferences: UserDefaults) -> (PaintDocument, EditorWindowController, InspectorSplitView) {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 320, height: 240)
        let editor = EditorWindowController(document: doc, layoutPreferences: preferences)
        doc.addWindowController(editor)
        editor.window!.setContentSize(CGSize(width: 1320, height: 860))
        editor.window!.contentView!.layoutSubtreeIfNeeded()
        return (doc, editor, views(editor.window!.contentView!).compactMap { $0 as? InspectorSplitView }.first!)
    }

    func testNativeDividerConstraintsPersistWidthAndTemporarilyClampOnWindowResize() throws {
        _ = NSApplication.shared
        let (prefs, domain) = preferences(); defer { prefs.removePersistentDomain(forName: domain) }
        let split = InspectorSplitView(canvas: NSView(), inspector: NSView(), preferences: prefs)
        split.setFrameSize(CGSize(width: 1000, height: 600))
        XCTAssertEqual(split.arrangedSubviews[1].frame.width, 252)
        setWidth(420, split: split)
        XCTAssertEqual(split.arrangedSubviews[1].frame.width, 420, accuracy: 0.5)
        XCTAssertEqual(prefs.double(forKey: InspectorSplitView.widthPreferenceKey), 420, accuracy: 0.5)
        split.setFrameSize(CGSize(width: 700, height: 600))
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, 320, accuracy: 0.5)
        XCTAssertEqual(split.preferredInspectorWidth, 420, accuracy: 0.5)
        split.setFrameSize(CGSize(width: 1000, height: 600))
        XCTAssertEqual(split.arrangedSubviews[1].frame.width, 420, accuracy: 0.5)
        let restored = InspectorSplitView(canvas: NSView(), inspector: NSView(), preferences: prefs)
        restored.setFrameSize(CGSize(width: 1000, height: 600))
        XCTAssertEqual(restored.arrangedSubviews[1].frame.width, 420, accuracy: 0.5)
        setWidth(10, split: split)
        XCTAssertEqual(split.arrangedSubviews[1].frame.width, 252, accuracy: 0.5)
        setWidth(2000, split: split)
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, 320, accuracy: 0.5)
        XCTAssertFalse(split.isSubviewCollapsed(split.arrangedSubviews[1]))
    }

    func testResizeAndDoubleClickResetPreserveTextDraftArtworkSelectionZoomAndHistory() throws {
        let (prefs, domain) = preferences(); defer { prefs.removePersistentDomain(forName: domain) }
        let (doc, editor, split) = editor(preferences: prefs); defer { doc.close() }
        doc.undoManager!.groupsByEvent = false
        editor.canvas.selection = .ellipse(CGRect(x: 10, y: 10, width: 240, height: 180), width: 320, height: 240)
        editor.canvas.beginText(in: CGRect(x: 24, y: 40, width: 230, height: 120), color: .black)
        let draft = try XCTUnwrap(editor.canvas.textEditor)
        draft.textView.insertText("Keep editing", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.canvas.setZoom(1.5)
        let original = doc.state, preview = editor.canvas.textPreviewRaster
        let composite = try Raster(image: editor.canvas.displayedComposite), zoom = editor.canvas.zoom
        let oldWidth = editor.canvas.bounds.width
        for width: CGFloat in [480, 300, 560] {
            setWidth(width, split: split)
            editor.canvas.layoutSubtreeIfNeeded()
            XCTAssertTrue(editor.canvas.textEditor === draft)
            XCTAssertTrue(editor.window!.firstResponder === draft.textView)
            XCTAssertEqual(draft.textView.string, "Keep editing")
            XCTAssertEqual(editor.canvas.textPreviewRaster, preview)
            XCTAssertEqual(try Raster(image: editor.canvas.displayedComposite), composite)
            XCTAssertEqual(editor.canvas.zoom, zoom); XCTAssertEqual(doc.state, original)
            XCTAssertFalse(doc.undoManager!.canUndo)
            XCTAssertLessThan(editor.canvas.bounds.width, oldWidth)
            let expected = CGPoint(x: editor.canvas.imageRect.minX + draft.imageBounds.minX * zoom,
                                   y: editor.canvas.imageRect.minY + draft.imageBounds.minY * zoom)
            let actual = draft.convert(draft.textView.frame.origin, to: editor.canvas)
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.5); XCTAssertEqual(actual.y, expected.y, accuracy: 0.5)
        }
        let point = split.convert(CGPoint(x: split.arrangedSubviews[0].frame.maxX, y: split.bounds.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                   windowNumber: editor.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1))
        split.mouseDown(with: event)
        XCTAssertEqual(split.arrangedSubviews[1].frame.width, 252, accuracy: 0.5)
        XCTAssertEqual(doc.state, original); XCTAssertTrue(editor.canvas.textEditor === draft)
        editor.canvas.finishText(apply: false)
    }

    func testExpandedControlsAndLayerNamesFitBothThemesAtMinimumWindowSize() throws {
        let app = NSApplication.shared, appearance = app.appearance; defer { app.appearance = appearance }
        let (prefs, domain) = preferences(); defer { prefs.removePersistentDomain(forName: domain) }
        let (doc, editor, split) = editor(preferences: prefs); defer { doc.close() }
        doc.state.layers[1].name = "A longer layer name with an editable mask"
        doc.state.layers[1].raster.fill(color: PixelColor(r: 50, g: 110, b: 220))
        doc.state.layers[1].raster.drawText("Paint.MAC", in: CGRect(x: 25, y: 80, width: 290, height: 100), font: .boldSystemFont(ofSize: 48),
                                          color: .white, opacity: 1, antialias: true, selection: nil)
        doc.state.layers[1].mask = .ellipse(CGRect(x: 15, y: 15, width: 290, height: 210), width: 320, height: 240)
        doc.invalidate()
        let root = editor.window!.contentView!, inspector = split.arrangedSubviews[1]
        let controls = views(inspector)
        let field = try XCTUnwrap(controls.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Main hex color" })
        let opacity = try XCTUnwrap(controls.compactMap { $0 as? NSSlider }.first { $0.accessibilityLabel() == "Layer opacity" })
        let mask = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Layer Mask" })
        let table = try XCTUnwrap(controls.compactMap { $0 as? NSTableView }.first)
        let original = doc.state
        editor.window!.orderFront(nil)
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            app.appearance = NSAppearance(named: theme)
            for size in [CGSize(width: 960, height: 640), CGSize(width: 1320, height: 860)] {
                editor.window!.setContentSize(size); root.layoutSubtreeIfNeeded()
                setWidth(252, split: split); root.layoutSubtreeIfNeeded()
                let narrow = (field.frame.width, opacity.frame.width, mask.frame.width)
                setWidth(480, split: split); root.layoutSubtreeIfNeeded()
                root.displayIfNeeded(); editor.canvas.displayIfNeeded(); CATransaction.flush()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
                XCTAssertGreaterThan(field.frame.width, narrow.0 + 100)
                XCTAssertGreaterThan(opacity.frame.width, narrow.1 + 100)
                XCTAssertGreaterThan(mask.frame.width, narrow.2 + 100)
                for control in [field as NSView, opacity, mask] {
                    XCTAssertTrue(inspector.bounds.contains(control.convert(control.bounds, to: inspector)))
                }
                let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true)); cell.layoutSubtreeIfNeeded()
                for label in views(cell).compactMap({ $0 as? NSTextField }) {
                    XCTAssertLessThanOrEqual(label.convert(label.bounds, to: table).maxX, table.visibleRect.maxX)
                }
                XCTAssertEqual(doc.state, original); XCTAssertGreaterThanOrEqual(editor.canvas.bounds.width, 320)
                if size.width == 1320, let folder = ProcessInfo.processInfo.environment["PAINTMAC_INSPECTOR_PREVIEW_DIR"] {
                    editor.canvas.zoomToFit(); root.displayIfNeeded(); CATransaction.flush()
                    let bitmap = try XCTUnwrap(editor.canvas.snapshot(of: root))
                    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent(theme == .aqua ? "inspector-light.png" : "inspector-dark.png"))
                }
            }
        }
    }
}
