import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import PaintMac

final class ColorResolutionTests: XCTestCase {
    let high = RGBFormat(profile: .displayP3, depth: .sixteen)
    private func gradient(width: Int = 19, height: Int = 13) -> Raster {
        var raster = Raster(width: width, height: height, format: high)
        var data = raster.bytes
        data.withUnsafeMutableBytes { raw in
            let p = RGBSamples(raw: raw, depth: .sixteen)
            for i in 0..<width * height {
                p[i * 4] = Double((i * 173 + 101) % 65536)
                p[i * 4 + 1] = Double((i * 223 + 131) % 65536)
                p[i * 4 + 2] = Double((i * 97 + 23) % 65536)
                p[i * 4 + 3] = 65535
            }
        }
        raster.bytes = data; raster.resolution = ImageResolution(x: 300, y: 240)
        return raster
    }
    private func state(_ raster: Raster) -> DocumentState {
        var state = DocumentState(width: raster.width, height: raster.height, format: raster.format, resolution: raster.resolution)
        state.layers = [PaintLayer(name: "Precise", raster: raster)]; state.activeID = state.layers[0].id
        return state
    }
    func testSixteenBitTilesKeepLowBitsAcrossBoundariesAndGeometry() throws {
        let raster = gradient(width: 263, height: 259)
        XCTAssertEqual(raster.stride, 8); XCTAssertEqual(raster.cgImage.bitsPerComponent, 16)
        XCTAssertEqual(raster.storage.tiles.count, 4)
        let copy = try Raster(image: raster.cgImage)
        XCTAssertEqual(copy.format, high)
        XCTAssertEqual(copy.bytes, raster.bytes)
        let crop = raster.cropped(to: CGRect(x: 251, y: 249, width: 12, height: 10))
        XCTAssertEqual(crop.bytes, raster.storage.read(CGRect(x: 251, y: 249, width: 12, height: 10)))
        let pad = crop.resizedCanvas(width: 20, height: 18, offsetX: 4, offsetY: 3)
        XCTAssertEqual(pad.storage.read(CGRect(x: 4, y: 3, width: 12, height: 10)), crop.bytes)
        XCTAssertEqual(try crop.scaled(width: 24, height: 20, smooth: false).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)).bytes, crop.storage.read(CGRect(x: 0, y: 0, width: 1, height: 1)))
        XCTAssertEqual(crop.format, high); XCTAssertEqual(pad.format, high)
    }
    func testHighPrecisionBrushEraserFillShapesTextAndSelections() throws {
        _ = NSApplication.shared
        let red = PixelColor(r: 255, g: 0, b: 0)
        var raster = Raster(width: 90, height: 70, format: high)
        raster.stroke(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 65, y: 10), size: 8, color: red, opacity: 0.001, erase: false, clip: nil)
        let before = raster.bytes
        XCTAssertTrue(before.contains { $0 != 0 })
        // An opacity below one 8-bit step still paints visible low bits in RGBA16.
        XCTAssertGreaterThan(UInt16(before[(10 * 90 + 15) * 8 + 6]), 0)
        raster.stroke(from: CGPoint(x: 20, y: 10), to: CGPoint(x: 30, y: 10), size: 8, color: red, opacity: 0.5, erase: true, clip: nil)
        XCTAssertNotEqual(raster.bytes, before)
        raster.strokeShape(in: CGRect(x: 15, y: 20, width: 40, height: 25), ellipse: true, size: 5, color: red, opacity: 0.31, clip: nil, fillColor: .white)
        raster.strokeShape(in: CGRect(x: 20, y: 25, width: 40, height: 25), ellipse: false, size: 7, color: red, opacity: 0.31, clip: nil, fillColor: .white, hardness: 0)
        raster.drawText("P3", at: CGPoint(x: 5, y: 35), font: .systemFont(ofSize: 20), color: red, opacity: 0.37, antialias: true, selection: nil)
        let mask = SelectionMask(width: 90, height: 70, coverage: Data(repeating: 128, count: 90 * 70))
        let masked = raster.masked(using: mask)
        XCTAssertEqual(masked.format, high); XCTAssertNotEqual(masked.bytes, raster.bytes)
        XCTAssertEqual(raster.blending(raster, selection: mask).bytes, raster.bytes)
        XCTAssertEqual(raster.moved(dx: 3, dy: 4, selection: mask).format, high)
        var fill = Raster(width: 9, height: 7, color: .white, format: high)
        fill.floodFill(at: .zero, color: red, tolerance: 0, clip: nil)
        XCTAssertEqual(fill.bytes, Raster(width: 9, height: 7, color: red, format: high).bytes)
        raster.erase(selection: nil); XCTAssertTrue(raster.isTransparent)
    }
    func testSoftStrokeRetainsPrecisionAndTileSeams() {
        let original = Raster(width: 520, height: 520, format: high)
        var raster = original, stroke = SoftBrushStroke(original: original)
        stroke.paint(on: &raster, from: CGPoint(x: 240, y: 250), to: CGPoint(x: 280, y: 270), size: 40,
                     color: .white, opacity: 0.001, erase: false, selection: nil, antialias: true, hardness: 0)
        XCTAssertFalse(raster.isTransparent); XCTAssertEqual(raster.storage.tiles.count, 4)
        let cropped = raster.cropped(to: CGRect(x: 230, y: 230, width: 70, height: 70))
        XCTAssertTrue(cropped.bytes.contains { $0 > 0 })
        XCTAssertEqual(raster.format, high)
    }
    func testRendererKeepsLowOrderSamplesAndFillMatchesUnquantizedSeed() throws {
        let raster = gradient()
        let renderer = ImageRenderer()
        let composite = renderer.composite([PaintLayer(name: "Gradient", raster: raster)], width: raster.width, height: raster.height)
        let output = try Raster(image: composite, format: high)
        func samples(_ data: Data) -> [Double] {
            data.withUnsafeBytes { raw in
                let p = RGBSamples(raw: UnsafeMutableRawBufferPointer(mutating: raw), depth: .sixteen)
                return (0..<data.count / 2).map { p[$0] }
            }
        }
        let difference = zip(samples(raster.bytes), samples(output.bytes)).map { abs($0 - $1) }.max()!
        XCTAssertLessThanOrEqual(difference, 3)
        var filled = raster
        filled.floodFill(at: CGPoint(x: 4, y: 3), color: .white, tolerance: 0, clip: nil)
        XCTAssertEqual(filled.pixel(x: 4, y: 3), .white)
        XCTAssertEqual(filled.storage.read(CGRect(x: 5, y: 3, width: 1, height: 1)), raster.storage.read(CGRect(x: 5, y: 3, width: 1, height: 1)))
        let blurred = renderer.cgImage(raster.ciImage.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 1]).cropped(to: raster.bounds), format: high)
        XCTAssertEqual(blurred.bitsPerComponent, 16)
    }
    func testResolutionResamplingTransformsMasksSelectionTextAndRetainsPrecision() throws {
        _ = NSApplication.shared
        let doc = PaintDocument(); defer { doc.close() }
        doc.state = state(gradient(width: 20, height: 10))
        doc.state.selection = .rectangle(CGRect(x: 0, y: 0, width: 10, height: 10), width: 20, height: 10)
        doc.state.layers[0].mask = doc.state.selection
        doc.state.layers[0].text = TextLayerContent(string: "Text", style: TextStyle(), rect: CGRect(x: 1, y: 2, width: 10, height: 6), color: .white, opacity: 1, antialias: true)
        try doc.applyColorSettings(high, resolution: ImageResolution(x: 600, y: 600), pixelSize: CGSize(width: 40, height: 20), smooth: false)
        XCTAssertEqual(doc.state.width, 40); XCTAssertEqual(doc.state.height, 20)
        XCTAssertEqual(doc.state.layers[0].mask?.width, 40); XCTAssertEqual(doc.state.selection?.height, 20)
        XCTAssertEqual(doc.state.layers[0].text?.rect.origin, CGPoint(x: 2, y: 4))
        XCTAssertEqual(doc.state.layers[0].raster.format, high)
        let before = doc.state
        XCTAssertThrowsError(try doc.applyColorSettings(high, resolution: .standard, pixelSize: CGSize(width: CGFloat.nan, height: 1)))
        XCTAssertEqual(doc.state, before)
    }
    func testProjectV6PreservesExactPixelsProfilesResolutionAndEditableText() throws {
        _ = NSApplication.shared
        var s = state(gradient())
        s.layers[0].mask = .all(width: s.width, height: s.height)
        s.layers[0].text = TextLayerContent(string: "Color", style: TextStyle(), rect: CGRect(x: 0, y: 0, width: 19, height: 13), color: .white, opacity: 1, antialias: true)
        let wrapper = try ProjectCodec.encode(s)
        let manifest = try JSONDecoder().decode(ProjectManifest.self, from: wrapper.fileWrappers!["document.json"]!.regularFileContents!)
        XCTAssertEqual(manifest.version, 6)
        let restored = try ProjectCodec.decode(wrapper)
        XCTAssertEqual(restored, s); XCTAssertEqual(restored.layers[0].raster.bytes, s.layers[0].raster.bytes)
        XCTAssertEqual(restored.resolution, ImageResolution(x: 300, y: 240))
        var legacy = DocumentState(width: 5, height: 5)
        let old = try ProjectCodec.encode(legacy)
        XCTAssertEqual(try JSONDecoder().decode(ProjectManifest.self, from: old.fileWrappers!["document.json"]!.regularFileContents!).version, 1)
        XCTAssertEqual(try ProjectCodec.decode(old), legacy)
        legacy.resolution = ImageResolution(x: 300, y: 300)
        XCTAssertEqual(try ProjectCodec.decode(ProjectCodec.encode(legacy)).resolution, legacy.resolution)
    }
    func testProjectRejectsInvalidProfileDepthResolutionAndRawPayload() throws {
        let s = state(gradient())
        func damaged(_ change: (inout ProjectManifest, inout [String: FileWrapper]) -> Void) throws -> FileWrapper {
            var files = try ProjectCodec.encode(s).fileWrappers!
            var manifest = try JSONDecoder().decode(ProjectManifest.self, from: files["document.json"]!.regularFileContents!)
            change(&manifest, &files)
            files["document.json"] = FileWrapper(regularFileWithContents: try JSONEncoder().encode(manifest))
            return FileWrapper(directoryWithFileWrappers: files)
        }
        XCTAssertThrowsError(try ProjectCodec.decode(damaged { m, _ in m.format?.profile.icc = Data([1, 2, 3]) }))
        XCTAssertThrowsError(try ProjectCodec.decode(damaged { m, _ in m.resolution?.x = 0 }))
        XCTAssertThrowsError(try ProjectCodec.decode(damaged { m, _ in m.version = 5 }))
        XCTAssertThrowsError(try ProjectCodec.decode(damaged { m, files in files[m.layers[0].file] = FileWrapper(regularFileWithContents: Data([0])) }))
    }
    func testPNGAndTIFFKeepSixteenBitRGBAndDPI() throws {
        let raster = gradient()
        for format in [ImageExportFormat.png, .tiff] {
            let data = try ImageFileIO.encode(raster, settings: ImageExportSettings(format: format), iconSource: nil)
            let source = CGImageSourceCreateWithData(data as CFData, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            XCTAssertEqual(image.bitsPerComponent, 16)
            let decoded = try ProjectCodec.decodeImage(data)
            XCTAssertEqual(decoded.format, high)
            XCTAssertEqual(decoded.bytes, raster.bytes)
            XCTAssertEqual(decoded.resolution.x, 300, accuracy: 0.02)
            XCTAssertEqual(decoded.resolution.y, 240, accuracy: 0.02)
        }
    }
    func testProfileConversionPreservesAppearanceAndWideGamut() throws {
        var p3 = Raster(width: 2, height: 2, format: high)
        // Saturated P3 red has negative green/blue coordinates in extended sRGB.
        p3.bytes.withUnsafeMutableBytes { raw in
            let p = RGBSamples(raw: raw, depth: .sixteen)
            for i in 0..<4 { p[i * 4] = 65535; p[i * 4 + 3] = 65535 }
        }
        let picked = p3.pixel(x: 0, y: 0)
        XCTAssertNotNil(picked.extendedRGB)
        let repaint = Raster(width: 2, height: 2, color: picked, format: high)
        let maxDelta = zip(repaint.bytes, p3.bytes).map { abs(Int($0) - Int($1)) }.max()!
        XCTAssertLessThanOrEqual(maxDelta, 2)
        let rendered = ImageRenderer().cgImage(p3.ciImage, format: high)
        let output = try Raster(image: rendered, format: high)
        XCTAssertEqual(output.format, high)
        XCTAssertGreaterThan(output.bytes[1], 250)
        let converted = try p3.converted(to: RGBFormat(profile: .adobeRGB, depth: .sixteen))
        XCTAssertEqual(converted.format.profile, .adobeRGB)
        XCTAssertNotEqual(converted.bytes, p3.bytes)
        XCTAssertEqual(try converted.converted(to: .standard).depth, .eight)
    }
    func testResolutionOnlyIsUndoableAndNeverChangesPixelsEvenOnLockedLayers() throws {
        _ = NSApplication.shared
        let doc = PaintDocument(); defer { doc.close() }
        doc.state = state(gradient()); doc.state.layers[0].isLocked = true
        doc.undoManager!.groupsByEvent = false
        let before = doc.state
        doc.undoManager!.beginUndoGrouping()
        try doc.applyColorSettings(high, resolution: ImageResolution(x: 600, y: 600))
        doc.undoManager!.endUndoGrouping()
        XCTAssertEqual(doc.state.layers[0].raster.bytes, before.layers[0].raster.bytes)
        XCTAssertEqual(doc.state.width, before.width)
        XCTAssertEqual(doc.state.resolution.x, 600)
        doc.undoManager!.undo(); XCTAssertEqual(doc.state, before)
        doc.undoManager!.redo(); XCTAssertEqual(doc.state.resolution.x, 600)
    }
    func testColdDiskHistoryRetainsFormatAndLowBits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = HistoryTileCache(memoryBudget: 0, root: root)
        defer { cache.shutdown(); try? FileManager.default.removeItem(at: root) }
        var expected: Data!
        func snapshot() -> HistorySnapshot {
            let s = state(gradient(width: 263, height: 259)); expected = s.layers[0].raster.bytes
            return HistorySnapshot(s, cache: cache)
        }
        let snap = snapshot(); cache.flush()
        XCTAssertEqual(cache.statistics.residentBytes, 0)
        let restored = try snap.restored()
        XCTAssertEqual(restored.format, high); XCTAssertEqual(restored.layers[0].raster.format, high)
        XCTAssertEqual(restored.layers[0].raster.bytes, expected)
        XCTAssertEqual(restored.resolution.x, 300)
    }
    func testPrintSizePlanChangesPPIWithoutResamplingOrResamplesToPrintSize() throws {
        let dpi = ImageResolution(x: 300, y: 300)
        let metadata = try PrintSizePlan.make(widthInches: 4, heightInches: 2, resolution: dpi, resample: false, originalWidth: 1200, originalHeight: 800)
        XCTAssertEqual(metadata.width, 1200); XCTAssertEqual(metadata.height, 800)
        XCTAssertEqual(metadata.resolution, ImageResolution(x: 300, y: 400))
        let resampled = try PrintSizePlan.make(widthInches: 4, heightInches: 2, resolution: dpi, resample: true, originalWidth: 1200, originalHeight: 800)
        XCTAssertEqual(resampled.width, 1200); XCTAssertEqual(resampled.height, 600)
        XCTAssertThrowsError(try PrintSizePlan.make(widthInches: .infinity, heightInches: 2, resolution: dpi, resample: true, originalWidth: 10, originalHeight: 10))
        XCTAssertThrowsError(try PrintSizePlan.make(widthInches: 1000, heightInches: 2, resolution: dpi, resample: true, originalWidth: 10, originalHeight: 10))
    }
    func testHighPrecisionTextLayersMergeAndImportedLayersUseDocumentFormat() throws {
        _ = NSApplication.shared
        let doc = PaintDocument(); defer { doc.close() }
        doc.state = DocumentState(width: 90, height: 70, format: high)
        doc.makeWindowControllers()
        let editor = doc.windowControllers[0] as! EditorWindowController
        try editor.importLayer(Raster(width: 10, height: 10, color: .white), name: "Import")
        XCTAssertEqual(doc.state.activeLayer.raster.format, high)
        var text = doc.state.activeLayer
        text.text = TextLayerContent(string: "P3", style: TextStyle(), rect: CGRect(x: 5, y: 5, width: 70, height: 40), color: .white, opacity: 0.35, antialias: true)
        text.renderText(); XCTAssertEqual(text.raster.depth, .sixteen)
        doc.state.activeLayer = text
        doc.mergeActiveDown()
        XCTAssertEqual(doc.state.activeLayer.raster.format, high)
        XCTAssertEqual(doc.composite.bitsPerComponent, 16)
        XCTAssertNoThrow(ImagePropertiesDialog(state: doc.state))
    }
}
