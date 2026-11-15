import XCTest
import AppKit
@testable import PaintMac

final class LayerMergeTests: XCTestCase {
    private let red = PixelColor(r: 255, g: 0, b: 0)
    private let blue = PixelColor(r: 0, g: 0, b: 255)
    private let green = PixelColor(r: 0, g: 255, b: 0)
    private func views(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + views($0) } }

    func testMergeCurrentLayerDownPreservesAppearanceOtherLayersSelectionAndUndo() throws {
        _ = NSApplication.shared
        let document = PaintDocument()
        var bottom = PaintLayer(name: "Paper", raster: Raster(width: 10, height: 8, color: green))
        bottom.opacity = 0.5
        var lower = PaintLayer(name: "Lower", raster: Raster(width: 10, height: 8, color: red))
        lower.opacity = 0.4
        var current = PaintLayer(name: "Current", raster: Raster(width: 10, height: 8))
        current.raster.fill(color: blue, rect: CGRect(x: 2, y: 1, width: 5, height: 4)); current.opacity = 0.6
        var above = PaintLayer(name: "Above", raster: Raster(width: 10, height: 8))
        above.raster.fill(color: .white, rect: CGRect(x: 7, y: 5, width: 3, height: 3)); above.opacity = 0.25
        document.state = DocumentState(width: 10, height: 8)
        document.state.layers = [bottom, lower, current, above]; document.state.activeID = current.id
        document.state.selection = .rectangle(CGRect(x: 3, y: 2, width: 2, height: 2), width: 10, height: 8)
        let original = document.state
        let before = try Raster(image: document.composite)
        document.makeWindowControllers()
        defer { document.close() }
        let editor = document.windowControllers[0] as! EditorWindowController
        document.undoManager?.groupsByEvent = false
        document.undoManager?.beginUndoGrouping()
        editor.mergeDown()
        document.undoManager?.endUndoGrouping()
        XCTAssertEqual(document.state.layers.count, 3)
        XCTAssertEqual(document.state.layers.first, bottom); XCTAssertEqual(document.state.layers.last, above)
        XCTAssertEqual(document.state.activeID, lower.id); XCTAssertEqual(document.state.activeLayer.name, "Lower")
        XCTAssertEqual(document.state.activeLayer.opacity, 1)
        XCTAssertEqual(document.state.selection, original.selection)
        let merged = document.state.activeLayer.raster
        // Source-over: alpha = .6 + .4*(1-.6) = .76, including outside selection.
        let overlap = merged.pixel(x: 2, y: 1)
        XCTAssertEqual(Int(overlap.a), 194, accuracy: 1)
        XCTAssertEqual(Int(overlap.r), 54, accuracy: 1); XCTAssertEqual(Int(overlap.b), 201, accuracy: 1)
        XCTAssertEqual(Int(merged.pixel(x: 0, y: 0).a), 102, accuracy: 1)
        let after = try Raster(image: document.composite)
        for i in before.bytes.indices { XCTAssertLessThanOrEqual(abs(Int(before.bytes[i]) - Int(after.bytes[i])), 1) }
        let result = document.state
        document.undoManager?.undo(); XCTAssertEqual(document.state, original)
        document.undoManager?.redo(); XCTAssertEqual(document.state, result)
    }

    func testLayerPanelButtonTracksSelectionMergesAndDisablesOnBottomLayer() throws {
        _ = NSApplication.shared
        let document = PaintDocument(); document.state = DocumentState(width: 20, height: 20)
        document.makeWindowControllers()
        defer { document.close() }
        let editor = document.windowControllers[0] as! EditorWindowController
        editor.window!.setContentSize(CGSize(width: 960, height: 580))
        let root = editor.window!.contentView!; root.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(views(root).compactMap { $0 as? NSButton }.first { $0.title == "Merge Down" })
        let table = try XCTUnwrap(views(root).compactMap { $0 as? NSTableView }.first)
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(root.bounds.contains(button.convert(button.bounds, to: root)))
        let original = document.state
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(document.state.activeIndex, 0); XCTAssertFalse(button.isEnabled)
        editor.mergeDown(); XCTAssertEqual(document.state.layers, original.layers)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertEqual(document.state.activeIndex, 1); XCTAssertTrue(button.isEnabled)
        document.undoManager?.groupsByEvent = false
        document.undoManager?.beginUndoGrouping()
        button.performClick(nil)
        document.undoManager?.endUndoGrouping()
        XCTAssertEqual(document.state.layers.count, 1); XCTAssertFalse(button.isEnabled)
        document.undoManager?.undo()
        XCTAssertEqual(document.state, original); XCTAssertTrue(button.isEnabled)
    }

    func testMergeUsesCurrentVisibilityAndFinishesPendingText() throws {
        _ = NSApplication.shared
        let document = PaintDocument(); document.state = DocumentState(width: 240, height: 100)
        document.makeWindowControllers()
        defer { document.close() }
        let editor = document.windowControllers[0] as! EditorWindowController
        for lowerVisible in [false, true] {
            for upperVisible in [false, true] {
                document.state = DocumentState(width: 240, height: 100)
                document.state.layers[0].raster.fill(color: red); document.state.layers[0].visible = lowerVisible
                document.state.layers[1].raster.fill(color: blue); document.state.layers[1].visible = upperVisible
                document.invalidate()
                let before = try Raster(image: document.composite)
                editor.mergeDown()
                XCTAssertEqual(try Raster(image: document.composite), before)
            }
        }
        document.state = DocumentState(width: 240, height: 100); document.invalidate()
        editor.canvas.textStyle.size = 24
        editor.canvas.beginText(in: CGRect(x: 10, y: 10, width: 200, height: 70), color: red)
        editor.canvas.textEditor!.textView.insertText("Merge me", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.mergeDown()
        XCTAssertNil(editor.canvas.textEditor); XCTAssertEqual(document.state.layers.count, 1)
        XCTAssertTrue(stride(from: 0, to: document.state.activeLayer.raster.bytes.count, by: 4).contains {
            document.state.activeLayer.raster.bytes[$0] > document.state.activeLayer.raster.bytes[$0 + 1]
        })
    }
}
