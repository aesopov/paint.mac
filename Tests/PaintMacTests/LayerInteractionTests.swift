import XCTest
import AppKit
@testable import PaintMac

private final class LayerDragInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .move
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint = .zero
    var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSource: Any?
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight = .none
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    init(source: NSTableView, ids: [UUID]) {
        super.init(); draggingSource = source
        draggingPasteboard.writeObjects(ids.map { id in
            let item = NSPasteboardItem(); item.setString(id.uuidString, forType: LayerTableView.pasteboardType); return item
        })
    }
    deinit { draggingPasteboard.releaseGlobally() }
}

final class LayerInteractionTests: XCTestCase {
    private func layer(_ name: String, parent: UUID? = nil, group: Bool = false, clipped: Bool = false) -> PaintLayer {
        var value = PaintLayer(name: name, raster: Raster(width: 32, height: 24))
        value.parentID = parent; value.isGroup = group; value.isClipped = clipped; return value
    }
    private func doc(_ layers: [PaintLayer], active: UUID? = nil) -> PaintDocument {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 32, height: 24)
        doc.state.layers = layers; doc.state.activeID = active ?? layers.last!.id
        doc.undoManager!.groupsByEvent = false; return doc
    }
    private func transaction<T>(_ doc: PaintDocument, _ body: () throws -> T) rethrows -> T {
        doc.undoManager!.beginUndoGrouping(); defer { doc.undoManager!.endUndoGrouping() }; return try body()
    }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func mouse(_ type: NSEvent.EventType, canvas: CanvasView, x: CGFloat, y: CGFloat) -> NSEvent {
        let p = NSPoint(x: canvas.imageRect.minX + x * canvas.zoom, y: canvas.imageRect.minY + y * canvas.zoom)
        return NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                                 windowNumber: canvas.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    func testMoveMultipleLayersPreservesOrderAndSingleUndoAndNoOpHistory() throws {
        let a = layer("A"), b = layer("B"), c = layer("C"), d = layer("D")
        let doc = doc([a, b, c, d], active: b.id); defer { doc.close() }
        let original = doc.state
        try transaction(doc) { try doc.moveLayers([b.id, d.id], into: nil, before: a.id) }
        XCTAssertEqual(doc.state.layers.map(\.id), [b.id, d.id, a.id, c.id]); try doc.state.validateLayerTree()
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, original)
        XCTAssertFalse(doc.undoManager!.canUndo); XCTAssertTrue(doc.undoManager!.canRedo)
        try doc.moveLayers([c.id], into: nil, before: d.id)
        XCTAssertEqual(doc.state, original); XCTAssertTrue(doc.undoManager!.canRedo)
    }
    func testMoveClipStackAndNestedGroupAcrossParentsRejectsCyclesAndDepth() throws {
        let outer = layer("Outer", group: true), inner = layer("Inner", parent: outer.id, group: true)
        let child = layer("Child", parent: inner.id), clip = layer("Clip", parent: outer.id, clipped: true)
        let target = layer("Target", group: true), other = layer("Other")
        let doc = doc([child, inner, clip, outer, other, target], active: inner.id); defer { doc.close() }
        let original = doc.state
        try transaction(doc) { try doc.moveLayers([clip.id], into: target.id) }
        XCTAssertEqual(doc.state.layers.first { $0.id == inner.id }?.parentID, target.id)
        XCTAssertEqual(doc.state.layers.first { $0.id == clip.id }?.parentID, target.id)
        XCTAssertEqual(doc.state.layers.first { $0.id == child.id }?.parentID, inner.id)
        try doc.state.validateLayerTree()
        XCTAssertThrowsError(try doc.moveLayers([target.id], into: child.id))
        XCTAssertThrowsError(try doc.moveLayers([target.id], into: inner.id))
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, original)
        var chain: [PaintLayer] = []; var parent: UUID?
        for i in 0..<8 { let group = layer("Level \(i)", parent: parent, group: true); chain.insert(group, at: 0); parent = group.id }
        let extra = layer("Extra", group: true)
        let deep = self.doc(chain + [extra]); defer { deep.close() }
        XCTAssertThrowsError(try deep.moveLayers([extra.id], into: parent)); XCTAssertEqual(deep.state.layers, chain + [extra])
    }
    func testNativeDropCallbacksReorderIntoGroupAndTrashRejectsOtherDocuments() throws {
        let a = layer("A"), b = layer("B"), group = layer("Group", group: true)
        let doc = doc([a, b, group], active: b.id); doc.makeWindowControllers(); defer { doc.close() }
        let editor = doc.windowControllers[0] as! EditorWindowController
        let root = editor.window!.contentView!; root.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(views(root).compactMap { $0 as? LayerTableView }.first)
        let info = LayerDragInfo(source: table, ids: [a.id])
        XCTAssertEqual(editor.tableView(table, validateDrop: info, proposedRow: 1, proposedDropOperation: .on), [])
        XCTAssertEqual(editor.tableView(table, validateDrop: info, proposedRow: 0, proposedDropOperation: .on), .move)
        transaction(doc) { XCTAssertTrue(editor.tableView(table, acceptDrop: info, row: 0, dropOperation: .on)) }
        XCTAssertEqual(doc.state.layers.first { $0.id == a.id }?.parentID, group.id)
        let trash = try XCTUnwrap(views(root).compactMap { $0 as? LayerTrashButton }.first)
        let original = doc.state
        transaction(doc) { XCTAssertTrue(trash.performDragOperation(info)) }
        XCTAssertFalse(doc.state.layers.contains { $0.id == a.id }); doc.undoManager!.undo(); XCTAssertEqual(doc.state, original)
        let foreign = LayerDragInfo(source: LayerTableView(), ids: [a.id])
        XCTAssertFalse(trash.performDragOperation(foreign))
        XCTAssertEqual(editor.tableView(table, validateDrop: foreign, proposedRow: 0, proposedDropOperation: .on), [])
        doc.state.layers[doc.state.layers.firstIndex { $0.id == a.id }!].isLocked = true
        XCTAssertFalse(trash.performDragOperation(info))
    }
    func testLayerDeleteKeyDeletesSelectedRowsAndCanvasDeleteStillErasesPixels() throws {
        let a = layer("A"), b = layer("B"), c = layer("C")
        let doc = doc([a, b, c]); doc.makeWindowControllers(); defer { doc.close() }
        let editor = doc.windowControllers[0] as! EditorWindowController, root = editor.window!.contentView!
        root.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(views(root).compactMap { $0 as? LayerTableView }.first)
        table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: editor.window!.windowNumber,
                                  context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        transaction(doc) { table.keyDown(with: key) }
        XCTAssertEqual(doc.state.layers.map(\.id), [a.id])
        doc.undoManager!.undo(); XCTAssertEqual(doc.state.layers, [a, b, c])
        transaction(doc) { editor.canvas.keyDown(with: key) }
        XCTAssertEqual(doc.state.layers.count, 3)
    }
    func testLocksBlockPaintingMasksTextMoveAndDeletionButPermitSelectionAndPan() throws {
        var a = layer("Locked"); a.mask = .all(width: 32, height: 24); a.isLocked = true
        let doc = doc([layer("Other"), a]); doc.makeWindowControllers(); defer { doc.close() }
        let editor = doc.windowControllers[0] as! EditorWindowController, canvas = editor.canvas
        editor.window!.contentView!.layoutSubtreeIfNeeded(); canvas.setZoom(2)
        let original = doc.state
        for tool in [PaintTool.brush, .eraser, .fill, .line, .rectangle, .ellipse, .move, .text] {
            canvas.tool = tool
            canvas.mouseDown(with: mouse(.leftMouseDown, canvas: canvas, x: 5, y: 5))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas: canvas, x: 20, y: 15))
            canvas.mouseUp(with: mouse(.leftMouseUp, canvas: canvas, x: 20, y: 15))
            XCTAssertEqual(doc.state, original); XCTAssertNil(canvas.textEditor)
        }
        doc.invertLayerMask(); doc.deleteLayerMask(apply: true); doc.removeActiveNode(); canvas.deletePixels()
        XCTAssertEqual(doc.state, original); XCTAssertFalse(doc.undoManager!.canUndo)
        doc.state.editingMask = true
        transaction(doc) { doc.edit("Mask paint") { $0.editRaster { $0.fill(color: .maskBlack) } } }
        XCTAssertEqual(doc.state.activeLayer.mask, a.mask)
        canvas.beginText(in: CGRect(x: 2, y: 2, width: 20, height: 15), color: .white); XCTAssertNil(canvas.textEditor)
        canvas.tool = .selection
        transaction(doc) {
            canvas.mouseDown(with: mouse(.leftMouseDown, canvas: canvas, x: 5, y: 5))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas: canvas, x: 20, y: 15))
            canvas.mouseUp(with: mouse(.leftMouseUp, canvas: canvas, x: 20, y: 15))
        }
        XCTAssertNotNil(doc.state.selection); XCTAssertEqual(doc.state.layers, original.layers)
        let pan = canvas.imageRect.origin; canvas.tool = .hand
        canvas.mouseDown(with: mouse(.leftMouseDown, canvas: canvas, x: 5, y: 5))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas: canvas, x: 10, y: 10))
        canvas.mouseUp(with: mouse(.leftMouseUp, canvas: canvas, x: 10, y: 10))
        XCTAssertNotEqual(canvas.imageRect.origin, pan); XCTAssertEqual(doc.state.layers, original.layers)
    }
    func testGroupLockProtectsDescendantsStructuralChangesAndMergeInput() throws {
        var group = layer("Group", group: true); group.isLocked = true
        let child = layer("Child", parent: group.id), other = layer("Other")
        let doc = doc([child, group, other], active: child.id); defer { doc.close() }
        let original = doc.state
        XCTAssertTrue(doc.state.isEffectivelyLocked(child.id)); XCTAssertFalse(doc.state.canPaintTarget)
        XCTAssertThrowsError(try doc.moveLayers([child.id], into: nil))
        XCTAssertThrowsError(try doc.moveLayers([other.id], into: group.id))
        XCTAssertThrowsError(try doc.createGroup(wrapping: [child.id]))
        transaction(doc) {
            doc.toggleLayerLock(child.id); doc.removeActiveNode(); doc.reorderActiveNode(by: 1)
            doc.edit("Opacity") { $0.layers[$0.activeIndex].opacity = 0.5 }
        }
        XCTAssertEqual(doc.state, original)
        doc.state.activeID = group.id
        transaction(doc) { doc.mergeActiveGroup(); doc.ungroupActive() }
        XCTAssertTrue(doc.state.activeLayer.isGroup)
        doc.state.activeID = other.id
        XCTAssertFalse(doc.state.canMergeDown)
        transaction(doc) { doc.mergeActiveDown() }; XCTAssertEqual(doc.state.layers, original.layers)
        transaction(doc) { doc.edit("Visibility") { $0.layers[1].visible = false } }
        XCTAssertFalse(doc.state.layers[1].visible)
    }
    func testLockedTextAndEffectRemainEditableAfterUnlockAndSurviveSerialization() throws {
        var text = layer("Text")
        text.text = TextLayerContent(string: "Hello", style: TextStyle(), rect: CGRect(x: 0, y: 0, width: 30, height: 22), color: .white, opacity: 1, antialias: true)
        text.renderText(); text.isLocked = true
        var effect = layer("Invert"); effect.effect = EffectSettings(kind: .invert); effect.isLocked = true
        let doc = doc([text, effect], active: text.id); doc.makeWindowControllers(); defer { doc.close() }
        let editor = doc.windowControllers[0] as! EditorWindowController
        editor.canvas.editTextLayer(); XCTAssertNil(editor.canvas.textEditor)
        transaction(doc) { doc.rasterizeActiveText() }; XCTAssertNotNil(doc.state.activeLayer.text)
        try transaction(doc) { try doc.setEffect(EffectSettings(kind: .blur), on: effect.id) }
        XCTAssertEqual(doc.state.layers[1].effect?.kind, .invert)
        XCTAssertEqual(try ProjectCodec.decode(ProjectCodec.encode(doc.state)), doc.state)
        transaction(doc) { doc.toggleLayerLock(text.id) }
        editor.canvas.editTextLayer(); XCTAssertNotNil(editor.canvas.textEditor); editor.canvas.finishText(apply: false)
    }
    func testLockedDescendantCannotBeReparentedIndirectlyAndDeletionKeepsClipTreeValid() throws {
        let group = layer("Group", group: true)
        var child = layer("Locked child", parent: group.id); child.isLocked = true
        let other = layer("Other")
        let doc = doc([child, group, other], active: group.id); defer { doc.close() }
        XCTAssertThrowsError(try doc.createGroup(wrapping: [group.id]))
        XCTAssertThrowsError(try doc.moveLayers([group.id], into: nil))
        XCTAssertFalse(doc.state.canRemoveLayers([group.id])); XCTAssertFalse(doc.state.canRemoveLayers([child.id, other.id]))
        var base = layer("Base"); base.mask = .all(width: 32, height: 24)
        let clip = layer("Clip", clipped: true)
        doc.state.layers = [base, clip, other]; doc.state.activeID = clip.id
        let original = doc.state
        transaction(doc) { doc.removeLayers([base.id]) }
        XCTAssertEqual(doc.state.layers.map(\.id), [clip.id, other.id]); XCTAssertFalse(doc.state.layers[0].isClipped)
        try doc.state.validateLayerTree(); doc.undoManager!.undo(); XCTAssertEqual(doc.state, original)
        XCTAssertFalse(doc.state.canRemoveLayers(Set(doc.state.layers.map(\.id))))
    }
    func testLockUndoRoundTripDuplicationAndGlobalSizing() throws {
        let a = layer("A"), b = layer("B")
        let doc = doc([a, b]); defer { doc.close() }
        transaction(doc) { doc.toggleLayerLock(b.id) }
        XCTAssertTrue(doc.state.activeLayer.isLocked); doc.undoManager!.undo(); XCTAssertFalse(doc.state.activeLayer.isLocked)
        doc.undoManager!.redo(); let locked = doc.state
        let package = try ProjectCodec.encode(locked)
        let manifest = try JSONDecoder().decode(ProjectManifest.self, from: package.fileWrappers!["document.json"]!.regularFileContents!)
        XCTAssertEqual(manifest.version, 5); XCTAssertEqual(try ProjectCodec.decode(package), locked)
        var invalid = manifest; invalid.version = 4
        var files = package.fileWrappers!; files["document.json"] = FileWrapper(regularFileWithContents: try JSONEncoder().encode(invalid))
        XCTAssertThrowsError(try ProjectCodec.decode(FileWrapper(directoryWithFileWrappers: files)))
        try transaction(doc) { try doc.duplicateActiveNode() }; XCTAssertTrue(doc.state.activeLayer.isLocked)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, locked)
        try transaction(doc) { try doc.applySize(CanvasSizePlan(width: 48, height: 36, offsetX: 2, offsetY: 3), mode: .resize, smooth: false) }
        XCTAssertEqual(doc.state.width, 48); XCTAssertTrue(doc.state.activeLayer.isLocked)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, locked)
        transaction(doc) { doc.toggleLayerLock(b.id) }
        let unlocked = try ProjectCodec.encode(doc.state)
        XCTAssertEqual(try JSONDecoder().decode(ProjectManifest.self, from: unlocked.fileWrappers!["document.json"]!.regularFileContents!).version, 1)
    }
}
