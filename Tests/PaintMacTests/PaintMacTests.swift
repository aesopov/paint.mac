import XCTest
import AppKit
@testable import PaintMac

final class PaintMacTests: XCTestCase {
    let red = PixelColor(r: 255, g: 0, b: 0)
    let blue = PixelColor(r: 0, g: 0, b: 255)

    func testBrushCoverageClippingAndErase() {
        var raster = Raster(width: 20, height: 20)
        raster.stroke(from: CGPoint(x: 2, y: 3), to: CGPoint(x: 15, y: 3), size: 4,
                      color: red, opacity: 1, erase: false, clip: CGRect(x: 0, y: 0, width: 10, height: 20))
        XCTAssertEqual(raster.pixel(x: 4, y: 3), red)
        XCTAssertEqual(raster.pixel(x: 12, y: 3), .clear)
        XCTAssertEqual(raster.pixel(x: 4, y: 17), .clear)
        raster.stroke(from: CGPoint(x: 4, y: 3), to: CGPoint(x: 4, y: 3), size: 4,
                      color: .black, opacity: 0.5, erase: true, clip: nil)
        XCTAssertEqual(raster.pixel(x: 4, y: 3).a, 128)
        XCTAssertEqual(raster.pixel(x: 4, y: 3).r, 255)
    }

    func testFloodFillRespectsBoundaryAndSelection() {
        var raster = Raster(width: 8, height: 8, color: .white)
        raster.fill(color: .black, rect: CGRect(x: 4, y: 0, width: 1, height: 8))
        raster.floodFill(at: CGPoint(x: 0, y: 0), color: red, tolerance: 0, clip: CGRect(x: 0, y: 0, width: 8, height: 4))
        XCTAssertEqual(raster.pixel(x: 3, y: 3), red)
        XCTAssertEqual(raster.pixel(x: 3, y: 4), .white)
        XCTAssertEqual(raster.pixel(x: 4, y: 3), .black)
        XCTAssertEqual(raster.pixel(x: 5, y: 3), .white)
    }

    func testMoveSelectionClearsSourceAndPreservesOtherPixels() {
        var raster = Raster(width: 8, height: 8)
        raster.fill(color: red, rect: CGRect(x: 1, y: 1, width: 2, height: 2))
        raster.fill(color: blue, rect: CGRect(x: 7, y: 7, width: 1, height: 1))
        let moved = raster.translated(dx: 2, dy: 3, selection: CGRect(x: 1, y: 1, width: 2, height: 2))
        XCTAssertEqual(moved.pixel(x: 1, y: 1), .clear)
        XCTAssertEqual(moved.pixel(x: 3, y: 4), red)
        XCTAssertEqual(moved.pixel(x: 7, y: 7), blue)
        let cropped = moved.cropped(to: CGRect(x: 3, y: 4, width: 2, height: 2))
        XCTAssertEqual(cropped.width, 2); XCTAssertEqual(cropped.height, 2)
        XCTAssertEqual(cropped.pixel(x: 0, y: 0), red)
    }

    func testPNGPreservesTopLeftCoordinatesAndTransparency() throws {
        var raster = Raster(width: 7, height: 9)
        raster.fill(color: red, rect: CGRect(x: 0, y: 0, width: 2, height: 1))
        raster.fill(color: blue, rect: CGRect(x: 4, y: 8, width: 3, height: 1))
        let data = try ProjectCodec.imageData(raster.cgImage, type: "public.png")
        let restored = try ProjectCodec.decodeImage(data)
        XCTAssertEqual(restored, raster)
        XCTAssertEqual(restored.pixel(x: 0, y: 0), red)
        XCTAssertEqual(restored.pixel(x: 6, y: 8), blue)
        XCTAssertEqual(restored.pixel(x: 3, y: 4), .clear)
    }

    func testLayerOrderOpacityAndVisibility() throws {
        let bottom = PaintLayer(name: "bottom", raster: Raster(width: 4, height: 4, color: red))
        var top = PaintLayer(name: "top", raster: Raster(width: 4, height: 4, color: blue))
        let renderer = ImageRenderer()
        var result = try Raster(image: renderer.composite([bottom, top], width: 4, height: 4))
        XCTAssertEqual(result.pixel(x: 0, y: 0), blue)
        top.opacity = 0.5
        result = try Raster(image: renderer.composite([bottom, top], width: 4, height: 4))
        let pixel = result.pixel(x: 0, y: 0)
        XCTAssertGreaterThan(pixel.r, 0); XCTAssertGreaterThan(pixel.b, 0)
        XCTAssertEqual(pixel.a, 255)
        top.visible = false
        result = try Raster(image: renderer.composite([bottom, top], width: 4, height: 4))
        XCTAssertEqual(result.pixel(x: 0, y: 0), red)
    }

    func testProjectRoundTripPreservesEveryLayerProperty() throws {
        var state = DocumentState(width: 12, height: 9)
        state.layers[0].name = "Paper"
        state.layers[0].visible = false
        state.layers[1].opacity = 0.37
        state.layers[1].raster.fill(color: red, rect: CGRect(x: 1, y: 2, width: 4, height: 3))
        let wrapper = try ProjectCodec.encode(state)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".paintmac")
        defer { try? FileManager.default.removeItem(at: url) }
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        let fromDisk = try FileWrapper(url: url)
        XCTAssertEqual(try ProjectCodec.decode(fromDisk), state)
    }

    func testRejectsDamagedAndUnsupportedProjects() throws {
        let state = DocumentState(width: 2, height: 2)
        let wrapper = try ProjectCodec.encode(state)
        var manifest = try JSONDecoder().decode(ProjectManifest.self, from: wrapper.fileWrappers!["document.json"]!.regularFileContents!)
        manifest.version = 99
        var children = wrapper.fileWrappers!
        children["document.json"] = FileWrapper(regularFileWithContents: try JSONEncoder().encode(manifest))
        XCTAssertThrowsError(try ProjectCodec.decode(FileWrapper(directoryWithFileWrappers: children)))
        manifest.version = 1; manifest.layers[0].opacity = 2
        children["document.json"] = FileWrapper(regularFileWithContents: try JSONEncoder().encode(manifest))
        XCTAssertThrowsError(try ProjectCodec.decode(FileWrapper(directoryWithFileWrappers: children)))
    }

    func testUndoRedoRestoresPixelsAndDocumentSize() {
        _ = NSApplication.shared
        let document = PaintDocument()
        document.state = DocumentState(width: 8, height: 8)
        NSDocumentController.shared.addDocument(document)
        defer { document.close() }
        let initial = document.state
        document.undoManager?.groupsByEvent = false
        document.undoManager?.beginUndoGrouping()
        document.edit("Paint") { $0.layers[$0.activeIndex].raster.fill(color: red) }
        document.undoManager?.endUndoGrouping()
        let edited = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in document.isDocumentEdited }, object: document)
        wait(for: [edited], timeout: 2)
        let painted = document.state
        XCTAssertNotEqual(initial, painted)
        document.undoManager?.undo()
        XCTAssertEqual(document.state, initial)
        XCTAssertFalse(document.isDocumentEdited)
        document.undoManager?.redo()
        XCTAssertEqual(document.state, painted)
        document.undoManager?.beginUndoGrouping()
        document.edit("Crop") { state in
            for i in state.layers.indices { state.layers[i].raster = state.layers[i].raster.cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4)) }
            state.width = 4; state.height = 4
        }
        document.undoManager?.endUndoGrouping()
        document.undoManager?.undo()
        XCTAssertEqual(document.state, painted)
    }

    func testDocumentOwnsItsEditorWindow() {
        _ = NSApplication.shared
        let document = PaintDocument()
        document.state = DocumentState(width: 20, height: 20)
        document.makeWindowControllers()
        XCTAssertEqual(document.windowControllers.count, 1)
        XCTAssertTrue(document.windowControllers.first?.document === document)
        XCTAssertNotNil(document.windowControllers.first?.window?.contentView)
        document.close()
    }

    func testDocumentSaveReopenAndImageExport() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = PaintDocument()
        document.state = DocumentState(width: 12, height: 10)
        document.state.layers[0].visible = false
        document.state.layers[1].raster.fill(color: red, rect: CGRect(x: 0, y: 0, width: 3, height: 2))
        let projectURL = folder.appendingPathComponent("example.paintmac")
        try document.write(to: projectURL, ofType: PaintDocument.typeName)
        let reopened = try PaintDocument(contentsOf: projectURL, ofType: PaintDocument.typeName)
        XCTAssertEqual(reopened.state, document.state)
        let pngURL = folder.appendingPathComponent("example.png")
        let jpgURL = folder.appendingPathComponent("example.jpg")
        try document.export(to: pngURL, jpeg: false)
        try document.export(to: jpgURL, jpeg: true)
        let png = try ProjectCodec.decodeImage(Data(contentsOf: pngURL))
        let jpg = try ProjectCodec.decodeImage(Data(contentsOf: jpgURL))
        XCTAssertEqual(png.pixel(x: 0, y: 0), red)
        XCTAssertEqual(png.pixel(x: 11, y: 9), .clear)
        let white = jpg.pixel(x: 11, y: 9)
        XCTAssertEqual(white.a, 255)
        XCTAssertGreaterThan(white.r, 245); XCTAssertGreaterThan(white.g, 245); XCTAssertGreaterThan(white.b, 245)
    }
}
