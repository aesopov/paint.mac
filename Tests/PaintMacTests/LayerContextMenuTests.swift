import XCTest
import AppKit
@testable import PaintMac

final class LayerContextMenuTests: XCTestCase {
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func editor() throws -> (PaintDocument, EditorWindowController, LayerTableView) {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 40, height: 30)
        doc.undoManager!.groupsByEvent = false
        doc.makeWindowControllers()
        let editor = doc.windowControllers[0] as! EditorWindowController
        let root = editor.window!.contentView!; root.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(views(root).compactMap { $0 as? LayerTableView }.first)
        return (doc, editor, table)
    }
    private func item(_ title: String, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.title == title })
    }
    private func invoke(_ item: NSMenuItem) {
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(NSApp.sendAction(item.action!, to: item.target, from: item))
    }
    func testRightClickTargetsUnselectedRowWithoutPaintingHistoryAndBlankAreaHasNoMenu() throws {
        let (doc, editor, table) = try editor(); defer { doc.close() }
        let bottomID = doc.state.layers[0].id
        let before = doc.state.layers
        let rect = table.rect(ofRow: 1)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: table.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil), modifierFlags: [], timestamp: 0,
                                      windowNumber: editor.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let menu = try XCTUnwrap(table.menu(for: event))
        XCTAssertEqual(doc.state.activeID, bottomID)
        XCTAssertEqual(editor.selectedLayerIDs, [bottomID]); XCTAssertEqual(table.selectedRow, 1)
        XCTAssertEqual(doc.state.layers, before); XCTAssertFalse(doc.undoManager!.canUndo)
        XCTAssertFalse(try item("Merge Down", in: menu).isEnabled)
        XCTAssertNotNil(menu.item(withTitle: "Rename…"))
        XCTAssertNil(editor.layerContextMenu(forRow: -1)); XCTAssertNil(editor.layerContextMenu(forRow: 100))
    }
    func testMultiSelectionIsPreservedAndOffersBulkDeleteAndGroupingWithUndo() throws {
        let (doc, editor, table) = try editor(); defer { doc.close() }
        doc.undoManager!.beginUndoGrouping(); editor.addLayer(); doc.undoManager!.endUndoGrouping()
        doc.undoManager!.removeAllActions()
        table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        let selected = editor.selectedLayerIDs
        let menu = try XCTUnwrap(editor.layerContextMenu(forRow: 1))
        XCTAssertEqual(editor.selectedLayerIDs, selected); XCTAssertEqual(selected.count, 2)
        XCTAssertNil(menu.item(withTitle: "Rename…")); XCTAssertNil(menu.item(withTitle: "Merge Down"))
        XCTAssertTrue(try item("Group Selected Layers", in: menu).isEnabled)
        let before = doc.state
        doc.undoManager!.beginUndoGrouping(); invoke(try item("Delete Selected Layers", in: menu)); doc.undoManager!.endUndoGrouping()
        XCTAssertEqual(doc.state.layers.count, 1); XCTAssertFalse(doc.state.layers.contains { selected.contains($0.id) })
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, before)
        let only = try XCTUnwrap(editor.layerContextMenu(forRow: 2))
        XCTAssertEqual(editor.selectedLayerIDs.count, 1); XCTAssertNotNil(only.item(withTitle: "Rename…"))
    }
    func testVisibilityLockAndDuplicateActionsUseExistingUndoAndLimits() throws {
        let (doc, editor, _) = try editor(); defer { doc.close() }
        let id = doc.state.activeID
        var menu = try XCTUnwrap(editor.layerContextMenu(forRow: 0))
        let original = doc.state
        doc.undoManager!.beginUndoGrouping(); invoke(try item("Hide Layer", in: menu)); doc.undoManager!.endUndoGrouping()
        XCTAssertFalse(doc.state.activeLayer.visible)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, original)
        doc.undoManager!.beginUndoGrouping(); invoke(try item("Lock Layer", in: menu)); doc.undoManager!.endUndoGrouping()
        menu = try XCTUnwrap(editor.layerContextMenu(forRow: 0))
        XCTAssertNotNil(menu.item(withTitle: "Unlock Layer")); XCTAssertFalse(try item("Delete Layer", in: menu).isEnabled)
        XCTAssertFalse(try item("Merge Down", in: menu).isEnabled)
        XCTAssertTrue(try item("Rename…", in: menu).isEnabled); XCTAssertTrue(try item("Duplicate Layer", in: menu).isEnabled)
        doc.undoManager!.beginUndoGrouping(); invoke(try item("Duplicate Layer", in: menu)); doc.undoManager!.endUndoGrouping()
        XCTAssertEqual(doc.state.layers.count, 3); XCTAssertNotEqual(doc.state.activeID, id)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state.activeID, id)
    }
    func testTextEffectAndMaskMenusAreSpecificAndRespectInheritedLocks() throws {
        let (doc, editor, _) = try editor(); defer { doc.close() }
        var text = doc.state.activeLayer
        text.text = TextLayerContent(string: "Text", style: TextStyle(), rect: CGRect(x: 1, y: 1, width: 30, height: 20), color: .white, opacity: 1, antialias: true)
        text.mask = .all(width: 40, height: 30); doc.state.activeLayer = text; editor.refresh()
        let menu = try XCTUnwrap(editor.layerContextMenu(forRow: 0))
        XCTAssertTrue(try item("Edit Text…", in: menu).isEnabled)
        XCTAssertTrue(try item("Rasterize Text Layer", in: menu).isEnabled)
        let maskMenu = try XCTUnwrap(menu.item(withTitle: "Layer Mask")?.submenu)
        XCTAssertTrue(try item("Apply Mask & Rasterize Text", in: maskMenu).isEnabled)
        invoke(try item("Edit Layer Mask", in: menu)); XCTAssertTrue(doc.state.isEditingMask)
        XCTAssertNotNil(editor.layerContextMenu(forRow: 0)?.item(withTitle: "Edit Layer Image"))
        doc.state.editingMask = false
        doc.undoManager!.beginUndoGrouping(); try doc.createGroup(wrapping: [text.id]); doc.undoManager!.endUndoGrouping(); let parent = doc.state.activeID
        doc.state.layers[doc.state.activeIndex].isLocked = true; editor.refresh()
        let childRow = try XCTUnwrap(doc.state.visibleLayerIDs.firstIndex(of: text.id))
        let locked = try XCTUnwrap(editor.layerContextMenu(forRow: childRow))
        XCTAssertFalse(try item("Edit Text…", in: locked).isEnabled)
        XCTAssertFalse(try item("Lock Layer", in: locked).isEnabled)
        XCTAssertTrue(try item("Hide Layer", in: locked).isEnabled)
        doc.state.layers[doc.state.layers.firstIndex { $0.id == parent }!].isLocked = false
        doc.state.layers[doc.state.activeIndex].text = nil
        doc.state.layers[doc.state.activeIndex].effect = EffectSettings(kind: .blur); editor.refresh()
        let effect = try XCTUnwrap(editor.layerContextMenu(forRow: childRow))
        XCTAssertNotNil(effect.item(withTitle: "Edit Effect…")); XCTAssertNil(effect.item(withTitle: "Rasterize Text Layer"))
    }
    func testGroupAndMoveMenusShareStructuralValidation() throws {
        let (doc, editor, table) = try editor(); defer { doc.close() }
        doc.undoManager!.beginUndoGrouping(); try doc.createGroup(wrapping: [doc.state.activeID]); doc.undoManager!.endUndoGrouping(); let group = doc.state.activeID; editor.refresh()
        let menu = try XCTUnwrap(editor.layerContextMenu(forRow: 0))
        XCTAssertNotNil(menu.item(withTitle: "Collapse Group")); XCTAssertTrue(try item("Merge Group", in: menu).isEnabled)
        let move = try XCTUnwrap(menu.item(withTitle: "Move to Group")?.submenu)
        XCTAssertNil(move.item(withTitle: "Group")) // Can't move a group inside itself.
        doc.state.layers[doc.state.layers.firstIndex { $0.id == group }!].isLocked = true; editor.refresh()
        let locked = try XCTUnwrap(editor.layerContextMenu(forRow: 0))
        XCTAssertFalse(try item("Merge Group", in: locked).isEnabled)
        XCTAssertFalse(try item("Group Layer", in: locked).isEnabled)
        table.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
        let selected = try XCTUnwrap(editor.layerContextMenu(forRow: 0))
        XCTAssertFalse(try item("Group Selected Layers", in: selected).isEnabled)
    }
    func testOpeningMenuOnActiveTextDraftDoesNotCommitItOrChangeHistory() throws {
        let (doc, editor, _) = try editor(); defer { doc.close() }
        editor.canvas.beginText(in: CGRect(x: 1, y: 1, width: 30, height: 20), color: .white)
        let draft = try XCTUnwrap(editor.canvas.textEditor)
        draft.textView.insertText("Draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        let before = doc.state
        XCTAssertNotNil(editor.layerContextMenu(forRow: 0))
        XCTAssertTrue(editor.canvas.textEditor === draft)
        XCTAssertEqual(draft.textView.string, "Draft"); XCTAssertEqual(doc.state, before)
        XCTAssertFalse(doc.undoManager!.canUndo)
        editor.canvas.finishText(apply: false)
    }
    func testMenuActionKeepsClickedTargetWhenFinishingTextCreatesANewLayer() throws {
        let (doc, editor, _) = try editor(); defer { doc.close() }
        doc.state.layers[doc.state.activeIndex].raster.fill(color: .white)
        let clicked = doc.state.activeID
        editor.canvas.beginText(in: CGRect(x: 1, y: 1, width: 30, height: 20), color: .black)
        editor.canvas.textEditor!.textView.insertText("Draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        let menu = try XCTUnwrap(editor.layerContextMenu(forRow: 0))
        doc.undoManager!.beginUndoGrouping(); invoke(try item("Hide Layer", in: menu)); doc.undoManager!.endUndoGrouping()
        XCTAssertNil(editor.canvas.textEditor)
        XCTAssertEqual(doc.state.layers.count, 3)
        XCTAssertFalse(doc.state.layers.first { $0.id == clicked }!.visible)
        XCTAssertTrue(doc.state.layers.first { $0.text != nil }!.visible)
        XCTAssertEqual(doc.state.activeID, clicked)
    }
    func testOnlyLayerCannotBeDeletedFromMenu() throws {
        let (doc, editor, _) = try editor(); defer { doc.close() }
        doc.state.layers.removeFirst(); editor.refresh()
        let menu = try XCTUnwrap(editor.layerContextMenu(forRow: 0))
        XCTAssertFalse(try item("Delete Layer", in: menu).isEnabled)
        XCTAssertFalse(try item("Merge Down", in: menu).isEnabled)
    }
}
