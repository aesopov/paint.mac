import XCTest
import AppKit
@testable import PaintMac

final class LayerGroupTests: XCTestCase {
    private let red = PixelColor(r: 255, g: 0, b: 0)
    private let blue = PixelColor(r: 0, g: 0, b: 255)
    private let green = PixelColor(r: 0, g: 255, b: 0)
    private func layer(_ name: String, _ color: PixelColor? = nil, parent: UUID? = nil, clipped: Bool = false) -> PaintLayer {
        var node = PaintLayer(name: name, raster: Raster(width: 3, height: 2, color: color ?? .clear))
        node.parentID = parent; node.isClipped = clipped
        return node
    }
    private func group(_ name: String, parent: UUID? = nil) -> PaintLayer {
        var node = layer(name, parent: parent); node.isGroup = true; return node
    }
    private func state(_ layers: [PaintLayer], active: UUID? = nil) -> DocumentState {
        var result = DocumentState(width: 3, height: 2)
        result.layers = layers; result.activeID = active ?? layers.last!.id; return result
    }
    private func document(_ layers: [PaintLayer], active: UUID? = nil) -> PaintDocument {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = state(layers, active: active)
        doc.undoManager!.groupsByEvent = false; return doc
    }
    private func transaction<T>(_ doc: PaintDocument, _ body: () throws -> T) rethrows -> T {
        doc.undoManager!.beginUndoGrouping(); defer { doc.undoManager!.endUndoGrouping() }; return try body()
    }
    private func rendered(_ state: DocumentState) throws -> Raster {
        try Raster(image: ImageRenderer().composite(state.layers, width: state.width, height: state.height))
    }
    private func approximatelyEqual(_ lhs: Raster, _ rhs: Raster, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.width, rhs.width, file: file, line: line); XCTAssertEqual(lhs.height, rhs.height, file: file, line: line)
        for index in lhs.bytes.indices {
            XCTAssertLessThanOrEqual(abs(Int(lhs.bytes[index]) - Int(rhs.bytes[index])), 1, file: file, line: line)
        }
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    func testNestedGroupOpacityAndMaskApplyOnceAfterChildrenWithCorrectOrientation() throws {
        var outer = group("Outer"), inner = group("Inner")
        inner.parentID = outer.id; inner.opacity = 0.5; outer.opacity = 0.5
        let lower = layer("Lower", red, parent: inner.id), upper = layer("Upper", blue, parent: inner.id)
        outer.mask = SelectionMask(width: 3, height: 2, coverage: Data([0, 128, 255, 255, 64, 0]))
        var original = state([lower, upper, inner, outer])
        try original.validateLayerTree()
        let result = try rendered(original)
        XCTAssertEqual(result.pixel(x: 0, y: 0).a, 0); XCTAssertEqual(result.pixel(x: 2, y: 1).a, 0)
        XCTAssertEqual(Int(result.pixel(x: 1, y: 0).a), 32, accuracy: 1)
        XCTAssertEqual(Int(result.pixel(x: 2, y: 0).a), 64, accuracy: 1)
        XCTAssertEqual(Int(result.pixel(x: 1, y: 1).a), 16, accuracy: 1)
        XCTAssertEqual(result.pixel(x: 2, y: 0).b, 255)
        original.layers[3].maskEnabled = false
        XCTAssertEqual(Int(try rendered(original).pixel(x: 0, y: 0).a), 64, accuracy: 1)
        original.layers[2].visible = false
        XCTAssertEqual(try rendered(original), Raster(width: 3, height: 2))
    }

    func testClippingStackPreservesBaseAlphaAndInheritsItsOpacityOnce() throws {
        var base = layer("Base", red)
        base.mask = SelectionMask(width: 3, height: 2, coverage: Data([0, 128, 255, 255, 64, 0])); base.opacity = 0.5
        var upper = layer("Blue", blue, clipped: true); upper.opacity = 0.5
        var top = layer("Green", green, clipped: true); top.opacity = 0.5
        var original = state([base, upper, top])
        try original.validateLayerTree()
        let result = try rendered(original)
        for y in 0..<2 { for x in 0..<3 {
            XCTAssertEqual(Int(result.pixel(x: x, y: y).a), Int(base.mask!.value(x: x, y: y)) / 2, accuracy: 1)
        } }
        let color = result.pixel(x: 2, y: 0)
        XCTAssertEqual(Int(color.r), 64, accuracy: 2); XCTAssertEqual(Int(color.g), 128, accuracy: 2)
        XCTAssertEqual(Int(color.b), 64, accuracy: 2)
        original.layers[0].visible = false
        XCTAssertEqual(try rendered(original), Raster(width: 3, height: 2), "Hidden base hides its whole clipping stack")
    }

    func testClippingSupportsGroupsAsBasesAndUpperLayersWithoutCrossingParentBoundaries() throws {
        var folder = group("Base Group"); folder.opacity = 0.5
        folder.mask = SelectionMask(width: 3, height: 2, coverage: Data([0, 128, 255, 255, 128, 0]))
        let child = layer("Child", red, parent: folder.id), clip = layer("Clipped", blue, clipped: true)
        let result = try rendered(state([child, folder, clip]))
        XCTAssertEqual(result.pixel(x: 0, y: 0).a, 0)
        XCTAssertEqual(Int(result.pixel(x: 1, y: 0).a), 64, accuracy: 1)
        XCTAssertEqual(result.pixel(x: 2, y: 0).b, 255)
        var upperGroup = group("Clipped Group"); upperGroup.isClipped = true
        let upperChild = layer("Paint", green, parent: upperGroup.id)
        let nested = state([child, folder, upperChild, upperGroup])
        try nested.validateLayerTree()
        XCTAssertEqual(try rendered(nested).pixel(x: 2, y: 0).g, 255)
        var invalidChild = child; invalidChild.isClipped = true
        XCTAssertThrowsError(try state([layer("Outside", blue), invalidChild, folder]).validateLayerTree())
    }

    func testGroupingCarriesClippingStackAndUndoRestoresOriginalTree() throws {
        let base = layer("Base", red), clip = layer("Clip", blue, clipped: true), above = layer("Above")
        let doc = document([base, clip, above], active: clip.id); defer { doc.close() }
        let before = doc.state, pixels = try rendered(before)
        try transaction(doc) { try doc.createGroup(wrapping: [clip.id]) }
        let grouped = doc.state, folder = grouped.activeLayer
        doc.deleteLayerMask(apply: true); XCTAssertEqual(doc.state, grouped)
        XCTAssertTrue(folder.isGroup); XCTAssertEqual(grouped.children(of: folder.id).map(\.id), [base.id, clip.id])
        XCTAssertEqual(grouped.children(of: nil).map(\.id), [folder.id, above.id])
        try grouped.validateLayerTree(); approximatelyEqual(try rendered(grouped), pixels)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, before)
        doc.undoManager!.redo(); XCTAssertEqual(doc.state, grouped)
        transaction(doc) { doc.ungroupActive() }
        XCTAssertEqual(doc.state.layers, before.layers); approximatelyEqual(try rendered(doc.state), pixels)
    }

    func testNewGroupsAndDuplicateBaseDoNotStealExistingClippedLayers() throws {
        let base = layer("Base", red), clip = layer("Clip", blue, clipped: true)
        let doc = document([base, clip], active: base.id); defer { doc.close() }
        let before = doc.state
        try transaction(doc) { try doc.createGroup() }
        XCTAssertEqual(doc.state.children(of: nil).map(\.id).prefix(2), [base.id, clip.id])
        XCTAssertTrue(doc.state.activeLayer.isGroup); try doc.state.validateLayerTree()
        approximatelyEqual(try rendered(doc.state), try rendered(before))
        doc.undoManager!.undo()
        try transaction(doc) { try doc.duplicateActiveNode() }
        XCTAssertEqual(doc.state.children(of: nil).map(\.id).prefix(2), [base.id, clip.id])
        XCTAssertEqual(doc.state.clippingUnits(parent: nil).first, [base.id, clip.id])
        try doc.state.validateLayerTree()
    }

    func testNestedDuplicationRemapsParentIDsAndDeletingAGroupRemovesItsSubtree() throws {
        var folder = group("Folder"), inner = group("Nested")
        inner.parentID = folder.id; folder.mask = .all(width: 3, height: 2)
        var child = layer("Image", red, parent: inner.id); child.mask = .all(width: 3, height: 2); child.maskEnabled = false
        let other = layer("Outside", blue)
        let doc = document([other, child, inner, folder]); defer { doc.close() }
        let before = doc.state
        try transaction(doc) { try doc.duplicateActiveNode() }
        let copy = doc.state.activeLayer, copied = doc.state.children(of: copy.id).first!
        XCTAssertEqual(doc.state.layers.count, 7); XCTAssertNotEqual(copy.id, folder.id)
        XCTAssertEqual(copy.mask, folder.mask); XCTAssertNotEqual(copied.id, inner.id)
        let copiedChild = doc.state.children(of: copied.id).first!
        XCTAssertEqual(copiedChild.mask, child.mask); XCTAssertFalse(copiedChild.maskEnabled)
        try doc.state.validateLayerTree()
        transaction(doc) { doc.removeActiveNode() }
        XCTAssertEqual(doc.state.layers, before.layers)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state.activeID, copy.id)
        doc.state.activeID = folder.id
        transaction(doc) { doc.removeActiveNode() }; try doc.state.validateLayerTree()
        XCTAssertFalse(doc.state.layers.contains { [folder.id, inner.id, child.id].contains($0.id) })
    }

    func testMoveToGroupCarriesClipStacksAndRejectsCyclesNonAdjacentGroupingAndExcessDepth() throws {
        let base = layer("Base", red), clip = layer("Clip", blue, clipped: true), target = group("Target")
        let doc = document([base, clip, target], active: clip.id); defer { doc.close() }
        let before = doc.state
        try transaction(doc) { try doc.moveLayers([clip.id], into: target.id) }
        XCTAssertEqual(doc.state.children(of: target.id).map(\.id), [base.id, clip.id]); try doc.state.validateLayerTree()
        approximatelyEqual(try rendered(doc.state), try rendered(before))
        let moved = doc.state
        XCTAssertThrowsError(try doc.moveLayers([target.id], into: target.id)); XCTAssertEqual(doc.state, moved)
        try transaction(doc) { try doc.moveLayers([base.id], into: nil) }; try doc.state.validateLayerTree()
        XCTAssertEqual(doc.state.children(of: nil).map(\.id), [target.id, base.id, clip.id])
        let a = layer("a"), b = layer("b"), c = layer("c")
        doc.state = state([a, b, c])
        XCTAssertThrowsError(try doc.createGroup(wrapping: [a.id, c.id])); XCTAssertEqual(doc.state.layers, [a, b, c])
        doc.state = state([group("Root")])
        for _ in 1..<DocumentState.maximumGroupDepth { try transaction(doc) { try doc.createGroup() } }
        let deepest = doc.state
        XCTAssertThrowsError(try doc.createGroup()); XCTAssertEqual(doc.state, deepest)
        var image = layer("At deepest level"); image.parentID = doc.state.activeID
        doc.state.insertLayer(image); try doc.state.validateLayerTree()
    }

    func testReorderingMovesWholeSiblingClipUnitsAndDeletingBaseReleasesClips() throws {
        let folder = group("Folder"), a = layer("a", red, parent: folder.id)
        let clip = layer("clip", blue, parent: folder.id, clipped: true), b = layer("b", green, parent: folder.id)
        let outside = layer("outside")
        let doc = document([a, clip, b, folder, outside], active: clip.id); defer { doc.close() }
        XCTAssertFalse(doc.state.canReorderActive(by: -1)); XCTAssertTrue(doc.state.canReorderActive(by: 1))
        transaction(doc) { doc.reorderActiveNode(by: 1) }
        XCTAssertEqual(doc.state.children(of: folder.id).map(\.id), [b.id, a.id, clip.id]); try doc.state.validateLayerTree()
        doc.undoManager!.undo(); XCTAssertEqual(doc.state.children(of: folder.id).map(\.id), [a.id, clip.id, b.id])
        doc.state.activeID = a.id
        transaction(doc) { doc.removeActiveNode() }
        XCTAssertFalse(doc.state.children(of: folder.id).first!.isClipped); try doc.state.validateLayerTree()
        doc.state.activeID = clip.id; XCTAssertFalse(doc.state.canClipActive)
        doc.state.activeID = b.id
        transaction(doc) { doc.toggleClippingMask() }; XCTAssertTrue(doc.state.activeLayer.isClipped)
        transaction(doc) { doc.toggleClippingMask() }; XCTAssertFalse(doc.state.activeLayer.isClipped)
    }

    func testMergeGroupAndApplyDisabledGroupMaskPreserveExternalOpacityAndClipping() throws {
        let background = layer("Background", green)
        var folder = group("Folder"); folder.opacity = 0.6; folder.isClipped = true
        folder.mask = SelectionMask(width: 3, height: 2, coverage: Data([0, 128, 255, 255, 128, 0]))
        let lower = layer("red", red, parent: folder.id), upper = layer("blue", blue, parent: folder.id)
        let doc = document([background, lower, upper, folder]); defer { doc.close() }
        let before = doc.state, image = try rendered(before)
        XCTAssertFalse(doc.state.canUngroupActive)
        transaction(doc) { doc.mergeActiveGroup() }
        XCTAssertEqual(doc.state.layers.count, 2); XCTAssertFalse(doc.state.activeLayer.isGroup)
        XCTAssertEqual(doc.state.activeLayer.opacity, 0.6); XCTAssertTrue(doc.state.activeLayer.isClipped)
        XCTAssertNil(doc.state.activeLayer.mask); try doc.state.validateLayerTree()
        approximatelyEqual(try rendered(doc.state), image)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, before)
        doc.state.layers[doc.state.activeIndex].maskEnabled = false
        transaction(doc) { doc.deleteLayerMask(apply: true) }
        approximatelyEqual(try rendered(doc.state), image)
    }

    func testMergeDownInsideGroupBakesClippingStackOnceAndPreservesOtherNodes() throws {
        var folder = group("Folder"); folder.opacity = 0.5
        folder.mask = SelectionMask(width: 3, height: 2, coverage: Data([0, 128, 255, 255, 128, 0]))
        var base = layer("Base", red, parent: folder.id); base.opacity = 0.7
        var clip = layer("Clip", blue, parent: folder.id, clipped: true); clip.opacity = 0.4
        let bottom = layer("Bottom", green, parent: folder.id), outside = layer("Outside")
        let doc = document([bottom, base, clip, folder, outside], active: clip.id); defer { doc.close() }
        let before = doc.state, image = try rendered(before)
        transaction(doc) { doc.mergeActiveDown() }
        XCTAssertEqual(doc.state.layers.count, 4); XCTAssertEqual(doc.state.activeID, base.id)
        XCTAssertEqual(doc.state.activeLayer.parentID, folder.id); XCTAssertEqual(doc.state.layers[2], folder)
        approximatelyEqual(try rendered(doc.state), image); try doc.state.validateLayerTree()
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, before)
        doc.state.activeID = base.id
        transaction(doc) { doc.mergeActiveDown() }
        XCTAssertEqual(doc.state.layers.count, 3); XCTAssertEqual(doc.state.activeID, bottom.id)
        approximatelyEqual(try rendered(doc.state), image); try doc.state.validateLayerTree()
    }

    func testMoveGroupMovesAllPixelsAndMasksButMaskTargetMovesOnlyGroupMask() throws {
        var folder = group("Folder")
        folder.mask = .rectangle(CGRect(x: 0, y: 0, width: 1, height: 1), width: 3, height: 2)
        var child = layer("Child", parent: folder.id); child.raster.fill(color: red, rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        child.mask = folder.mask
        let before = state([child, folder]), beforePixels = child.raster
        var next = before; next.moveActive(from: before, dx: 1, dy: 1, selection: nil)
        XCTAssertEqual(next.layers[0].raster.pixel(x: 1, y: 1), red)
        XCTAssertEqual(next.layers[0].mask!.value(x: 1, y: 1), 255)
        XCTAssertEqual(next.activeLayer.mask!.value(x: 1, y: 1), 255)
        var maskState = before; maskState.editingMask = true
        next = maskState; next.moveActive(from: maskState, dx: 1, dy: 1, selection: nil)
        XCTAssertEqual(next.layers[0].raster, beforePixels); XCTAssertEqual(next.layers[0].mask, child.mask)
        XCTAssertEqual(next.activeLayer.mask!.value(x: 1, y: 1), 255)
        next = before; XCTAssertFalse(next.canPaintTarget)
        next.editRaster { $0.fill(color: blue) }; XCTAssertEqual(next, before)
        next.editingMask = true; XCTAssertTrue(next.canPaintTarget)
        next.editRaster { $0.fill(color: .maskBlack) }; XCTAssertTrue(next.activeLayer.mask!.isEmpty)
        next.activeID = child.id; next.layers[1].visible = false; XCTAssertFalse(next.activeEffectivelyVisible)
    }

    func testProjectV3RoundTripAndMalformedTreeRejection() throws {
        var folder = group("Folder"); folder.expanded = false; folder.opacity = 0.4
        folder.mask = SelectionMask(width: 3, height: 2, coverage: Data([0, 1, 128, 254, 255, 42])); folder.maskEnabled = false
        let base = layer("Base", red, parent: folder.id), clip = layer("Clip", blue, parent: folder.id, clipped: true)
        let original = state([base, clip, folder])
        let wrapper = try ProjectCodec.encode(original), children = wrapper.fileWrappers!
        let manifest = try JSONDecoder().decode(ProjectManifest.self, from: children["document.json"]!.regularFileContents!)
        XCTAssertEqual(manifest.version, 3); XCTAssertEqual(manifest.layers.last!.file, "")
        XCTAssertEqual(try ProjectCodec.decode(wrapper), original)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".paintmac")
        defer { try? FileManager.default.removeItem(at: url) }
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        XCTAssertEqual(try ProjectCodec.decode(FileWrapper(url: url)), original)
        let mutations: [(inout ProjectManifest) -> Void] = [
            { $0.version = 2 }, { $0.version = 99 },
            { $0.layers[0].parentID = UUID() }, { $0.layers[0].parentID = $0.layers[1].id },
            { $0.layers[2].parentID = $0.layers[2].id },
            { $0.layers[0].isClipped = true }, { $0.layers.swapAt(0, 2) },
            { $0.layers[2].file = $0.layers[0].file }
        ]
        for mutation in mutations {
            var corrupt = manifest; mutation(&corrupt)
            var files = children; files["document.json"] = FileWrapper(regularFileWithContents: try JSONEncoder().encode(corrupt))
            XCTAssertThrowsError(try ProjectCodec.decode(FileWrapper(directoryWithFileWrappers: files)))
        }
        var a = group("a"), b = group("b"); a.parentID = b.id; b.parentID = a.id
        XCTAssertThrowsError(try state([a, b]).validateLayerTree())
    }

    func testMovingOverlappingSelectionsRetainsDescendantsInsideCarriedClipGroup() throws {
        let base = layer("Base", red), destination = group("Destination")
        var clippedGroup = group("Clipped Group"); clippedGroup.isClipped = true
        let child = layer("Child", blue, parent: clippedGroup.id)
        let doc = document([base, child, clippedGroup, destination]); defer { doc.close() }
        try transaction(doc) { try doc.moveLayers([base.id, child.id], into: destination.id) }
        XCTAssertEqual(doc.state.children(of: destination.id).map(\.id), [base.id, clippedGroup.id])
        XCTAssertEqual(doc.state.children(of: clippedGroup.id).map(\.id), [child.id]); try doc.state.validateLayerTree()
    }

    func testGroupResizeCropAndExportKeepMasksAndHierarchyAligned() throws {
        var folder = group("Folder")
        folder.mask = SelectionMask(width: 3, height: 2, coverage: Data([0, 128, 255, 255, 128, 0]))
        let child = layer("Child", red, parent: folder.id), clip = layer("Clip", blue, parent: folder.id, clipped: true)
        let doc = document([child, clip, folder]); doc.makeWindowControllers(); defer { doc.close() }
        let editor = doc.windowControllers[0] as! EditorWindowController, before = doc.state
        let image = try rendered(before)
        try transaction(doc) { try doc.applySize(CanvasSizePlan(width: 6, height: 4, offsetX: 0, offsetY: 0), mode: .scale, smooth: false) }
        XCTAssertEqual(doc.state.activeLayer.mask!.value(x: 2, y: 0), 128)
        XCTAssertEqual(doc.state.children(of: folder.id).map(\.id), [child.id, clip.id]); try doc.state.validateLayerTree()
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, before)
        try transaction(doc) { try doc.applySize(CanvasSizePlan(width: 5, height: 4, offsetX: 1, offsetY: 1), mode: .resize, smooth: false) }
        XCTAssertEqual(doc.state.activeLayer.mask!.value(x: 2, y: 1), 128)
        editor.canvas.selection = .rectangle(CGRect(x: 1, y: 1, width: 3, height: 2), width: 5, height: 4)
        transaction(doc) { editor.cropToSelection() }
        approximatelyEqual(try rendered(doc.state), image); try doc.state.validateLayerTree()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try doc.export(to: url, jpeg: false)
        approximatelyEqual(try ProjectCodec.decodeImage(Data(contentsOf: url)), image)
    }

    func testStructuralCommandsFinishInlineTextAndGroupMaskPaintingRemainsUndoable() throws {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.state = DocumentState(width: 120, height: 80); doc.makeWindowControllers()
        defer { doc.close() }
        doc.undoManager!.groupsByEvent = false
        let editor = doc.windowControllers[0] as! EditorWindowController, canvas = editor.canvas
        canvas.beginText(in: CGRect(x: 5, y: 5, width: 110, height: 60), color: red)
        canvas.textEditor!.textView.insertText("Grouped text", replacementRange: NSRange(location: NSNotFound, length: 0))
        let imageID = doc.state.activeID
        try transaction(doc) { try doc.createGroup(wrapping: [imageID]) }
        XCTAssertNil(canvas.textEditor); XCTAssertTrue(doc.state.activeLayer.isGroup)
        let child = try XCTUnwrap(doc.state.layers.first { $0.id == imageID })
        XCTAssertTrue(stride(from: 3, to: child.raster.bytes.count, by: 4).contains { child.raster.bytes[$0] != 0 })
        transaction(doc) { doc.addLayerMask(.revealAll) }
        let before = doc.state
        transaction(doc) { canvas.deletePixels() }
        XCTAssertTrue(doc.state.activeLayer.mask!.isEmpty)
        XCTAssertEqual(doc.state.layers.first { $0.id == imageID }!.raster, child.raster)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, before)
        editor.selectLayerTarget(doc.state.activeID, mask: false)
        canvas.beginText(in: CGRect(x: 0, y: 0, width: 60, height: 40), color: blue)
        XCTAssertNotNil(canvas.textEditor, "A new text layer can be created inside a group")
        canvas.finishText(apply: false)
        editor.applyAdjustment("CIColorInvert", name: "Invert")
        XCTAssertEqual(doc.state.layers.first { $0.id == imageID }!.raster, child.raster)
    }

    func testPanelMultipleSelectionGroupingDisclosureAndMovingIntoGroup() throws {
        let a = layer("a", red), b = layer("b", blue), c = layer("c", green)
        let doc = document([a, b, c]); doc.makeWindowControllers(); defer { doc.close() }
        let editor = doc.windowControllers[0] as! EditorWindowController, root = editor.window!.contentView!
        let table = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTableView }.first)
        XCTAssertTrue(table.allowsMultipleSelection)
        table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        transaction(doc) { editor.groupSelected() }
        XCTAssertTrue(doc.state.activeLayer.isGroup)
        let folder = doc.state.activeID
        XCTAssertEqual(doc.state.children(of: folder).map(\.id), [b.id, c.id])
        XCTAssertEqual(table.numberOfRows, 4)
        let row = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let collapse = try XCTUnwrap(descendants(row).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Collapse Group" })
        collapse.performClick(nil); XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(doc.state.visibleLayerIDs, [folder, a.id])
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(doc.state.activeID, a.id)
        let popup = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Layer groups and clipping masks" })
        let destination = try XCTUnwrap(popup.menu?.items.first { $0.title == "Move to Group" }?.submenu?.items.first { $0.representedObject as? String == folder.uuidString })
        try transaction(doc) { XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(destination.action), to: destination.target, from: destination)) }
        XCTAssertEqual(doc.state.activeLayer.parentID, folder); XCTAssertTrue(doc.state.layers.last!.expanded)
        XCTAssertEqual(table.numberOfRows, 4); try doc.state.validateLayerTree()
    }

    func testGroupControlsAndNestedThumbnailsFitMinimumWindowInBothThemes() throws {
        let app = NSApplication.shared, old = app.appearance; defer { app.appearance = old }
        var folder = group("A long group name"), nested = group("Nested group")
        folder.mask = .all(width: 3, height: 2); nested.parentID = folder.id
        var child = layer("A long child layer name", red, parent: nested.id); child.mask = .all(width: 3, height: 2)
        let clip = layer("Clipped color", blue, parent: nested.id, clipped: true)
        let doc = document([child, clip, nested, folder]); doc.makeWindowControllers(); defer { doc.close() }
        let editor = doc.windowControllers[0] as! EditorWindowController, root = editor.window!.contentView!
        editor.window!.orderFront(nil)
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            app.appearance = NSAppearance(named: theme)
            for size in [CGSize(width: 960, height: 640), CGSize(width: 1320, height: 860)] {
                editor.window!.setContentSize(size); root.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
                let table = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTableView }.first)
                XCTAssertEqual(table.numberOfRows, 4)
                for row in 0..<table.numberOfRows {
                    let cell = try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: true))
                    cell.layoutSubtreeIfNeeded()
                    for thumbnail in descendants(cell).compactMap({ $0 as? LayerThumbnailButton }) {
                        let frame = thumbnail.convert(thumbnail.bounds, to: table)
                        XCTAssertGreaterThanOrEqual(frame.minX, 0); XCTAssertLessThanOrEqual(frame.maxX, table.bounds.width)
                    }
                    for label in descendants(cell).compactMap({ $0 as? NSTextField }) {
                        XCTAssertEqual(label.maximumNumberOfLines, 1)
                        XCTAssertEqual(label.lineBreakMode, .byTruncatingTail)
                        XCTAssertLessThanOrEqual(label.convert(label.bounds, to: table).maxX, table.visibleRect.maxX)
                    }
                }
                let popup = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Layer groups and clipping masks" })
                XCTAssertTrue(root.bounds.contains(popup.convert(popup.bounds, to: root)))
                XCTAssertTrue(popup.itemArray.contains { $0.title == "Merge Group" && $0.isEnabled })
                if let folder = ProcessInfo.processInfo.environment["PAINTMAC_GROUP_PREVIEW_DIR"], size.width == 1320 {
                    let bitmap = try XCTUnwrap(editor.canvas.snapshot(of: root))
                    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent(theme == .aqua ? "groups-light.png" : "groups-dark.png"))
                }
            }
        }
    }
}
