import AppKit
import XCTest
@testable import PaintMac

final class MaskButtonTests: XCTestCase {
    private func editor() -> (PaintDocument, EditorWindowController) {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 64, height: 48)
        doc.undoManager!.groupsByEvent = false; doc.makeWindowControllers()
        let editor = doc.windowControllers[0] as! EditorWindowController
        editor.window!.contentView!.layoutSubtreeIfNeeded()
        return (doc, editor)
    }
    private func button(_ label: String, _ editor: EditorWindowController) throws -> NSButton {
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        return try XCTUnwrap(descendants(editor.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == label })
    }
    private func transaction(_ doc: PaintDocument, _ body: () -> Void) {
        doc.undoManager!.beginUndoGrouping(); body(); doc.undoManager!.endUndoGrouping()
    }
    private func coloredPixels(_ button: NSButton) throws -> Int {
        let rep = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: rep)
        var count = 0
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.1 else { continue }
            let channels = [color.redComponent, color.greenComponent, color.blueComponent]
            if channels.max()! - channels.min()! > 0.15 { count += 1 }
        } }
        return count
    }

    func testQuickMaskOffIsNeutralInBothAppearancesAndTracksToggleAndUndo() throws {
        let (doc, editor) = editor(); defer { doc.close() }
        let quick = try button("Quick Mask", editor)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            editor.window!.appearance = NSAppearance(named: appearance)
            editor.window!.contentView!.layoutSubtreeIfNeeded()
            XCTAssertEqual(try coloredPixels(quick), 0, "The inactive icon must have no accent-colored pixels")
            transaction(doc) { quick.performClick(nil) }
            XCTAssertTrue(doc.state.isQuickMask); XCTAssertEqual(quick.state, .on)
            let accent = try XCTUnwrap(NSColor.controlAccentColor.usingColorSpace(.sRGB))
            let channels = [accent.redComponent, accent.greenComponent, accent.blueComponent]
            if channels.max()! - channels.min()! > 0.15 { XCTAssertGreaterThan(try coloredPixels(quick), 100) }
            doc.undoManager!.undo()
            XCTAssertFalse(doc.state.isQuickMask); XCTAssertEqual(quick.state, .off)
            XCTAssertEqual(try coloredPixels(quick), 0)
            doc.undoManager!.redo(); XCTAssertTrue(doc.state.isQuickMask)
            doc.undoManager!.undo(); XCTAssertFalse(doc.state.isQuickMask)
        }
    }

    func testMaskIconClickRevealsAllPreservesPixelsAndSelectionAndUndoesOnce() throws {
        let (doc, editor) = editor(); defer { doc.close() }
        let maskButton = try button("Add Layer Mask", editor)
        doc.state.selection = .ellipse(CGRect(x: 10, y: 10, width: 25, height: 20), width: 64, height: 48)
        let original = doc.state
        transaction(doc) { maskButton.performClick(nil) }
        XCTAssertEqual(doc.state.activeLayer.mask, .all(width: 64, height: 48))
        XCTAssertEqual(doc.state.layers.map(\.raster), original.layers.map(\.raster))
        XCTAssertEqual(doc.state.selection, original.selection)
        XCTAssertTrue(doc.state.isEditingMask); XCTAssertFalse(maskButton.isEnabled)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, original); XCTAssertTrue(maskButton.isEnabled)
        XCTAssertFalse(doc.undoManager!.canUndo)
        doc.undoManager!.redo(); XCTAssertTrue(doc.state.isEditingMask); XCTAssertFalse(maskButton.isEnabled)
    }

    func testHideAllWorksOnGroupsWithoutChangingChildren() throws {
        let (doc, editor) = editor(); defer { doc.close() }
        doc.state.layers[1].raster.fill(color: PixelColor(r: 255, g: 0, b: 0))
        var group = PaintLayer(name: "Group", raster: Raster(width: 64, height: 48)); group.isGroup = true
        doc.state.layers[1].parentID = group.id; doc.state.layers.append(group); doc.state.activeID = group.id
        editor.refresh(); let original = doc.state
        transaction(doc) { editor.addLayerMaskFromPanel(hideAll: true) }
        XCTAssertEqual(doc.state.activeLayer.mask, .empty(width: 64, height: 48))
        XCTAssertEqual(doc.state.layers[1], original.layers[1]); XCTAssertTrue(doc.state.isEditingMask)
        XCTAssertEqual(try Raster(image: doc.composite).pixel(x: 20, y: 20), .white)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, original)
        XCTAssertEqual(try Raster(image: doc.composite).pixel(x: 20, y: 20), PixelColor(r: 255, g: 0, b: 0))
    }

    func testMaskButtonRespectsExistingMasksAndInheritedLocks() throws {
        let (doc, editor) = editor(); defer { doc.close() }
        let add = try button("Add Layer Mask", editor)
        doc.state.layers[1].isLocked = true; editor.refresh(); XCTAssertFalse(add.isEnabled)
        let locked = doc.state
        editor.addLayerMaskFromPanel(hideAll: true); XCTAssertEqual(doc.state, locked)
        doc.state.layers[1].isLocked = false; doc.state.layers[1].mask = .all(width: 64, height: 48)
        editor.refresh(); XCTAssertFalse(add.isEnabled); let masked = doc.state
        editor.addLayerMaskFromPanel(hideAll: true); XCTAssertEqual(doc.state, masked)
        doc.state.layers[1].mask = nil
        var group = PaintLayer(name: "Locked group", raster: Raster(width: 64, height: 48)); group.isGroup = true; group.isLocked = true
        doc.state.layers[1].parentID = group.id; doc.state.layers.append(group)
        editor.refresh(); XCTAssertFalse(add.isEnabled); let inherited = doc.state
        editor.addLayerMaskFromPanel(hideAll: false); XCTAssertEqual(doc.state, inherited)
        XCTAssertFalse(doc.undoManager!.canUndo)
    }

    func testAddingLayerMaskEndsQuickMaskInOneAtomicUndoStep() throws {
        let (doc, editor) = editor(); defer { doc.close() }
        let soft = SelectionMask.ellipse(CGRect(x: 10, y: 10, width: 25, height: 20), width: 64, height: 48).feathered(radius: 2, context: doc.renderer.context)
        doc.state.selection = soft
        transaction(doc) { editor.toggleQuickMask() }
        doc.undoManager!.removeAllActions(); let original = doc.state
        transaction(doc) { editor.addLayerMaskFromPanel(hideAll: true) }
        XCTAssertFalse(doc.state.isQuickMask); XCTAssertEqual(doc.state.selection, soft)
        XCTAssertTrue(doc.state.activeLayer.mask!.isEmpty); XCTAssertTrue(doc.state.isEditingMask)
        XCTAssertEqual(try button("Quick Mask", editor).state, .off)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, original)
        XCTAssertEqual(try button("Quick Mask", editor).state, .on)
        XCTAssertFalse(doc.undoManager!.canUndo)
        doc.undoManager!.redo(); XCTAssertFalse(doc.state.isQuickMask); XCTAssertTrue(doc.state.isEditingMask)
    }

    func testMaskActionFitsBesideOtherLayerButtonsAtMinimumInspectorWidth() throws {
        let (doc, editor) = editor(); defer { doc.close() }
        editor.window!.setContentSize(CGSize(width: 960, height: 580))
        let root = editor.window!.contentView!; root.layoutSubtreeIfNeeded()
        let add = try button("Add Layer Mask", editor)
        XCTAssertTrue(root.bounds.contains(add.convert(add.bounds, to: root)))
        let row = try XCTUnwrap(add.superview)
        XCTAssertEqual(row.subviews.compactMap { $0 as? NSButton }.count, 6)
        for control in row.subviews { XCTAssertTrue(root.bounds.contains(control.convert(control.bounds, to: root))) }
    }
}
