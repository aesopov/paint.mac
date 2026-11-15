import XCTest
import AppKit
@testable import PaintMac

final class HistoryCacheTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("PaintMac-HistoryTests-" + UUID().uuidString) }
    private func transaction(_ doc: PaintDocument, _ body: () -> Void) {
        doc.undoManager!.beginUndoGrouping(); body(); doc.undoManager!.endUndoGrouping()
    }
    private func document(root: URL, memory: Int = 0, disk: Int = 20 * 1024 * 1024) -> PaintDocument {
        _ = NSApplication.shared
        let doc = PaintDocument(); doc.historyCache = HistoryTileCache(memoryBudget: memory, diskBudget: disk, root: root)
        doc.state = DocumentState(width: 600, height: 540); doc.undoManager!.groupsByEvent = false
        return doc
    }
    func testEvictedUndoRedoRestoresExactLayersMasksSelectionTextAndEffects() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let doc = document(root: root); defer { doc.close() }
        let original = doc.state
        var states = [original]
        for i in 0..<5 {
            transaction(doc) { doc.edit("Paint \(i)") { state in
                state.layers[state.activeIndex].raster.stroke(from: CGPoint(x: 240 + i * 10, y: 250), to: CGPoint(x: 300, y: 280 + i * 10), size: 30,
                                                            color: PixelColor(r: UInt8(30 + i * 20), g: 80, b: 210), opacity: 0.6, erase: false, clip: nil)
                state.layers[state.activeIndex].mask = .ellipse(CGRect(x: 230, y: 220, width: 100, height: 120), width: 600, height: 540)
                state.selection = .rectangle(CGRect(x: i * 10, y: 20, width: 320, height: 290), width: 600, height: 540)
            } }; states.append(doc.state)
        }
        transaction(doc) {
            try! doc.addEffect(EffectSettings(kind: .blur))
        }; states.append(doc.state)
        doc.historyCache.flush()
        XCTAssertEqual(doc.historyCache.statistics.residentBytes, 0)
        XCTAssertGreaterThan(doc.historyCache.statistics.diskBytes, 0)
        for expected in states.dropLast().reversed() { doc.undoManager!.undo(); XCTAssertEqual(doc.state, expected); doc.historyCache.flush() }
        XCTAssertFalse(doc.undoManager!.canUndo)
        for expected in states.dropFirst() { doc.undoManager!.redo(); XCTAssertEqual(doc.state, expected); doc.historyCache.flush() }
        XCTAssertFalse(doc.undoManager!.canRedo)
        let loaded = try ProjectCodec.decode(ProjectCodec.encode(doc.state))
        var expected = doc.state; expected.selection = nil; expected.editingMask = false
        XCTAssertEqual(loaded, expected)
    }
    func testSnapshotsDeduplicateTilesAndRAMBudgetEvictsOnlyPersistedData() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = HistoryTileCache(memoryBudget: 1, root: root); defer { cache.shutdown() }
        var raster = Raster(width: 600, height: 540)
        raster.fill(color: .white, rect: CGRect(x: 250, y: 250, width: 20, height: 20))
        var state = DocumentState(width: 600, height: 540); state.layers[state.activeIndex].raster = raster
        var first: HistorySnapshot? = HistorySnapshot(state, cache: cache)
        var second: HistorySnapshot? = HistorySnapshot(state, cache: cache)
        XCTAssertEqual(cache.statistics.tiles, 4)
        cache.flush(); XCTAssertEqual(cache.statistics.residentBytes, 0)
        XCTAssertEqual(try first!.restored(), state)
        first = nil; XCTAssertEqual(cache.statistics.tiles, 4)
        XCTAssertEqual(try second!.restored(), state)
        second = nil; cache.flush(); XCTAssertEqual(cache.statistics.tiles, 0); XCTAssertEqual(cache.statistics.diskBytes, 0)
    }
    func testColdSnapshotLoadsFromDiskAndRejectsCorruptPayload() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = HistoryTileCache(memoryBudget: 0, root: root); defer { cache.shutdown() }
        func snapshot() -> HistorySnapshot {
            var state = DocumentState(width: 600, height: 540)
            state.layers[state.activeIndex].raster.fill(color: .black, rect: CGRect(x: 5, y: 5, width: 10, height: 10))
            return HistorySnapshot(state, cache: cache)
        }
        let snap = snapshot(); cache.flush()
        XCTAssertEqual(cache.statistics.residentBytes, 0)
        XCTAssertEqual(try snap.restored().activeLayer.raster.pixel(x: 8, y: 8), .black)
        cache.flush()
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cache.directory!, includingPropertiesForKeys: nil).first { $0.lastPathComponent != "owner.lock" })
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try snap.restored())
    }
    func testDiskBudgetPrunesWholeGroupsAndKeepsCurrentPixels() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let doc = document(root: root, disk: 1); defer { doc.close() }
        transaction(doc) {
            for x in [10, 40] { doc.edit("Grouped edit") { $0.layers[$0.activeIndex].raster.fill(color: .black, rect: CGRect(x: x, y: 20, width: 10, height: 10)) } }
        }
        transaction(doc) { doc.edit("Next edit") { $0.layers[$0.activeIndex].raster.fill(color: .white, rect: CGRect(x: 10, y: 20, width: 10, height: 10)) } }
        let before = doc.state
        doc.historyCache.flush(); doc.trimHistory(); doc.historyCache.flush()
        XCTAssertEqual(doc.state, before); XCTAssertLessThanOrEqual(doc.historyCache.statistics.diskBytes, 1)
        XCTAssertFalse(doc.undoManager!.canUndo)
    }
    func testWriteFailureKeepsUndoInRAMAndRespectsFallbackBudget() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root) // Deliberately a file, not a directory.
        let doc = document(root: root, memory: 2 * 1024 * 1024); defer { doc.close() }
        let initial = doc.state
        transaction(doc) { doc.edit("Paint") { $0.layers[$0.activeIndex].raster.fill(color: .black, rect: CGRect(x: 250, y: 250, width: 20, height: 20)) } }
        transaction(doc) { doc.edit("Paint again") { $0.layers[$0.activeIndex].raster.fill(color: .white, rect: CGRect(x: 250, y: 250, width: 20, height: 20)) } }
        doc.trimHistory(); XCTAssertNotNil(doc.lastHistoryError)
        doc.undoManager!.undo(); doc.undoManager!.undo(); XCTAssertEqual(doc.state, initial)
    }
    func testCloseRemovesSessionAndAbandonedCleanupPreservesActiveSessions() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let doc = document(root: root)
        let active = try XCTUnwrap(doc.historyCache.directory)
        let abandoned = root.appendingPathComponent("session-abandoned", isDirectory: true)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data().write(to: abandoned.appendingPathComponent("owner.lock"))
        HistorySession.cleanAbandoned(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        doc.close(); XCTAssertFalse(FileManager.default.fileExists(atPath: active.path))
    }
    func testBranchingAfterDiskUndoDropsRedoAndKeepsSavedSnapshotsIndependent() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let doc = document(root: root); defer { doc.close() }
        for x in [10, 40, 70] {
            transaction(doc) { doc.edit("Paint") { $0.layers[$0.activeIndex].raster.fill(color: .black, rect: CGRect(x: x, y: 10, width: 8, height: 8)) } }
        }
        let saved = try ProjectCodec.encode(doc.state)
        doc.historyCache.flush(); doc.undoManager!.undo(); doc.undoManager!.undo()
        transaction(doc) { doc.edit("New branch") { $0.layers[$0.activeIndex].raster.fill(color: .white, rect: CGRect(x: 10, y: 10, width: 8, height: 8)) } }
        XCTAssertFalse(doc.undoManager!.canRedo)
        let old = try ProjectCodec.decode(saved)
        XCTAssertEqual(old.activeLayer.raster.pixel(x: 70, y: 10), .black)
        XCTAssertEqual(doc.state.activeLayer.raster.pixel(x: 70, y: 10), .clear)
        doc.historyCache.flush(); doc.undoManager!.undo()
        XCTAssertEqual(doc.state.activeLayer.raster.pixel(x: 10, y: 10), .black)
    }
}

extension HistoryCacheTests {
    func testHistoryRetainsMoreThanFortyOperationsWithPixelsOnDisk() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let doc = document(root: root); defer { doc.close() }
        for i in 0..<60 {
            transaction(doc) { doc.edit("Paint \(i)") {
                $0.layers[$0.activeIndex].raster.fill(color: .black, rect: CGRect(x: i + 1, y: 10, width: 1, height: 1))
            } }
        }
        doc.historyCache.flush(); doc.trimHistory()
        XCTAssertEqual(doc.historyCache.statistics.residentBytes, 0)
        for i in (0..<60).reversed() {
            doc.undoManager!.undo()
            XCTAssertEqual(doc.state.activeLayer.raster.pixel(x: i + 1, y: 10), .clear)
            if i > 0 { XCTAssertEqual(doc.state.activeLayer.raster.pixel(x: i, y: 10), .black) }
        }
        XCTAssertFalse(doc.undoManager!.canUndo)
        for _ in 0..<60 { doc.undoManager!.redo() }
        XCTAssertFalse(doc.undoManager!.canRedo)
        XCTAssertEqual(doc.state.activeLayer.raster.pixel(x: 60, y: 10), .black)
    }
    func testColdHistoryPreservesEditableTextGroupsClippingLocksAndMaskTargets() throws {
        _ = NSApplication.shared
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = HistoryTileCache(memoryBudget: 0, root: root); defer { cache.shutdown() }
        func make() -> HistorySnapshot {
            var state = DocumentState(width: 600, height: 540)
            var group = PaintLayer(name: "Folder", raster: Raster(width: 600, height: 540)); group.isGroup = true
            var text = PaintLayer(name: "Editable", raster: Raster(width: 600, height: 540))
            text.parentID = group.id
            var style = TextStyle(); style.size = 24
            text.text = TextLayerContent(string: "Tile boundary text", style: style, rect: CGRect(x: 240, y: 250, width: 220, height: 70), color: .black, opacity: 0.7, antialias: true)
            text.textClip = .rectangle(CGRect(x: 245, y: 250, width: 200, height: 65), width: 600, height: 540)
            text.renderText(); text.isLocked = true
            group.mask = .ellipse(CGRect(x: 200, y: 200, width: 300, height: 200), width: 600, height: 540)
            state.layers = [state.layers[0], text, group]; state.activeID = group.id; state.editingMask = true
            return HistorySnapshot(state, cache: cache)
        }
        let snapshot = make(); cache.flush()
        let loaded = try snapshot.restored()
        XCTAssertTrue(loaded.isEditingMask); XCTAssertTrue(loaded.activeLayer.isGroup)
        XCTAssertEqual(loaded.layers[1].text?.string, "Tile boundary text")
        XCTAssertTrue(loaded.layers[1].isLocked); XCTAssertNotNil(loaded.layers[1].textClip)
        XCTAssertFalse(loaded.layers[1].raster.isTransparent)
        try loaded.validateLayerTree()
        let reopened = try ProjectCodec.decode(ProjectCodec.encode(loaded))
        var expected = loaded; expected.editingMask = false
        XCTAssertEqual(reopened, expected)
    }
    func testCloseWithPendingWritesKeepsCurrentPixelsAndRemovesCache() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let doc = document(root: root)
        let directory = try XCTUnwrap(doc.historyCache.directory)
        for i in 0..<20 {
            transaction(doc) { doc.edit("Paint") { $0.layers[$0.activeIndex].raster.fill(color: .black, rect: CGRect(x: i * 20, y: 250, width: 20, height: 20)) } }
        }
        let current = doc.state
        doc.close()
        XCTAssertEqual(doc.state, current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(doc.historyCache.statistics.tiles, 0)
    }
}

extension HistoryCacheTests {
    func testUnreadableUndoLeavesCurrentDocumentUnchanged() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let doc = document(root: root); defer { doc.close() }
        for color in [PixelColor.black, .white] {
            transaction(doc) { doc.edit("Paint") { $0.layers[$0.activeIndex].raster.fill(color: color, rect: CGRect(x: 10, y: 10, width: 10, height: 10)) } }
        }
        doc.historyCache.flush()
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: doc.historyCache.directory!, includingPropertiesForKeys: nil).first { $0.lastPathComponent != "owner.lock" })
        var bytes = try Data(contentsOf: file); bytes[bytes.count - 1] ^= 0xff; try bytes.write(to: file)
        let current = doc.state
        doc.undoManager!.undo()
        XCTAssertEqual(doc.state, current); XCTAssertNotNil(doc.lastHistoryError)
    }
}
