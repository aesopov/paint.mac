import XCTest
import AppKit
import CoreImage
@testable import PaintMac

final class TiledStorageTests: XCTestCase {
    func testSparseLayersAndUniformMasksAllocateNoPixelTiles() {
        for color in [PixelColor.clear, .white, PixelColor(r: 30, g: 80, b: 200, a: 128)] {
            let raster = Raster(width: 4096, height: 4096, color: color)
            XCTAssertTrue(raster.storage.tiles.isEmpty)
            XCTAssertEqual(raster.pixel(x: 3000, y: 3000).a, color.a)
        }
        var icon = Raster(width: 16, height: 16)
        icon.fill(color: .white, rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(icon.storage.tiles.values.first?.data.count, 16 * 16 * 4)
        XCTAssertTrue(SelectionMask.all(width: 4096, height: 4096).storage.tiles.isEmpty)
        XCTAssertTrue(SelectionMask.empty(width: 4096, height: 4096).storage.tiles.isEmpty)
    }
    func testSmallEditCopiesOnlyIntersectingTilesAndPreservesOldVersions() {
        var raster = Raster(width: 4096, height: 4096)
        raster.stroke(from: CGPoint(x: 255.5, y: 255.5), to: CGPoint(x: 255.5, y: 255.5), size: 30,
                      color: .black, opacity: 1, erase: false, clip: nil)
        XCTAssertEqual(raster.storage.tiles.count, 4)
        XCTAssertEqual(raster.storage.tiles.values.reduce(0) { $0 + $1.data.count }, 1024 * 1024)
        let before = raster, ids = raster.storage.tiles.mapValues(\.id)
        raster.fill(color: .white, rect: CGRect(x: 4, y: 4, width: 2, height: 2))
        XCTAssertNotEqual(raster.storage.tiles[0]?.id, ids[0])
        for key in ids.keys where key != 0 { XCTAssertTrue(raster.storage.tiles[key] === before.storage.tiles[key]) }
        XCTAssertEqual(before.pixel(x: 4, y: 4), .clear)
        let unchanged = raster.storage.tiles.mapValues(\.id)
        raster.fill(color: .white, rect: CGRect(x: 4, y: 4, width: 2, height: 2))
        XCTAssertEqual(raster.storage.tiles.mapValues(\.id), unchanged)
        raster.fill(color: .clear); XCTAssertTrue(raster.storage.tiles.isEmpty)
    }
    func testOddEdgesReadWriteAndPixelsHaveNoPaddingLeak() {
        var erased = Raster(width: 17, height: 19, color: .white)
        erased.erase(selection: .all(width: 17, height: 19))
        XCTAssertTrue(erased.isTransparent, "Opaque defaults and padded pixels must not hide an empty image")
        var raster = Raster(width: 513, height: 519, color: .white)
        raster.fill(color: .clear, rect: CGRect(x: 255, y: 255, width: 258, height: 264))
        raster.fill(color: PixelColor(r: 230, g: 40, b: 80, a: 128), rect: CGRect(x: 510, y: 516, width: 3, height: 3))
        let contiguous = raster.bytes
        XCTAssertEqual(contiguous.count, 513 * 519 * 4)
        var decoded = Raster(width: 513, height: 519); decoded.bytes = contiguous
        XCTAssertEqual(decoded, raster)
        XCTAssertEqual(decoded.pixel(x: 512, y: 518).a, 128)
        XCTAssertEqual(decoded.pixel(x: 254, y: 255), .white)
        XCTAssertEqual(decoded.pixel(x: 255, y: 255), .clear)
    }
    func testMaskWorkingRasterReusesUntouchedTilesAndRoundTripsCoverage() {
        var grid = TileGrid(width: 800, height: 600, channels: 1, base: [255])
        grid.edit(in: CGRect(x: 255, y: 250, width: 4, height: 20)) { data, _ in data = Data(repeating: 90, count: data.count) }
        let mask = SelectionMask(storage: grid, bounds: grid.nonzeroBounds)
        var raster = mask.editingRaster
        let roundtrip = SelectionMask(editingRaster: raster)
        XCTAssertEqual(roundtrip, mask)
        for key in grid.tiles.keys { XCTAssertTrue(roundtrip.storage.tiles[key] === mask.storage.tiles[key]) }
        raster.stroke(from: CGPoint(x: 600, y: 400), to: CGPoint(x: 620, y: 400), size: 20, color: .maskBlack, opacity: 1, erase: false, clip: nil)
        let changed = SelectionMask(editingRaster: raster)
        for key in grid.tiles.keys { XCTAssertTrue(changed.storage.tiles[key] === mask.storage.tiles[key]) }
        XCTAssertEqual(changed.value(x: 610, y: 400), 0)
    }
    func testSoftStrokeAndShapeAreIdenticalAcrossTileBoundaries() {
        let offset = CGPoint(x: 240, y: 240)
        func image(shift: CGPoint, size: Int) -> Raster {
            let original = Raster(width: size, height: size)
            var result = original, brush = SoftBrushStroke(original: original)
            let path = [CGPoint(x: 20.5, y: 40.5), CGPoint(x: 120.5, y: 110.5), CGPoint(x: 30.5, y: 120.5), CGPoint(x: 90.5, y: 10.5)]
            for i in 1..<path.count {
                brush.paint(on: &result, from: CGPoint(x: path[i-1].x + shift.x, y: path[i-1].y + shift.y),
                            to: CGPoint(x: path[i].x + shift.x, y: path[i].y + shift.y), size: 40,
                            color: PixelColor(r: 40, g: 100, b: 240), opacity: 0.6, erase: false, selection: nil, antialias: true, hardness: 0)
            }
            result.strokeShape(in: CGRect(x: shift.x + 30, y: shift.y + 30, width: 90, height: 60), ellipse: true,
                               size: 18, color: .black, opacity: 0.5, clip: nil, fillColor: .white, hardness: 0.2)
            return result
        }
        let small = image(shift: .zero, size: 160), tiled = image(shift: offset, size: 600)
        XCTAssertEqual(tiled.cropped(to: CGRect(origin: offset, size: CGSize(width: 160, height: 160))), small)
    }
    func testTileRenderingAndBlurMatchContiguousImageAtEdgesAndFractionalZoom() throws {
        var raster = Raster(width: 513, height: 519, color: .white)
        raster.fill(color: .clear, rect: CGRect(x: 240, y: 240, width: 40, height: 60))
        raster.strokeShape(in: CGRect(x: 235, y: 235, width: 70, height: 80), ellipse: true, size: 15,
                           color: PixelColor(r: 210, g: 40, b: 70), opacity: 0.7, clip: nil, fillColor: .black)
        raster.fill(color: .black, rect: CGRect(x: 0, y: 0, width: 8, height: 15))
        raster.fill(color: .clear, rect: CGRect(x: 505, y: 510, width: 8, height: 9))
        let context = ImageRenderer().context
        func pixels(_ image: CIImage, size: CGSize) -> Data {
            var data = Data(count: Int(size.width * size.height) * 4)
            data.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(size.width) * 4,
                                                       bounds: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: Raster.colorSpace) }
            return data
        }
        for blur in [0.0, 8.0] { for zoom in [0.61, 1.0, 1.37, 2.0] {
            func transformed(_ input: CIImage) -> CIImage {
                let image = blur == 0 ? input : input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur]).cropped(to: raster.bounds)
                return CanvasViewport.image(image, imageRect: CGRect(x: -zoom * 220 + 0.3, y: -zoom * 220 + 0.7, width: 513 * zoom, height: 519 * zoom),
                                            viewSize: CGSize(width: 160, height: 160), drawableSize: CGSize(width: 320, height: 320), nearest: zoom >= 1)
            }
            let a = pixels(transformed(raster.ciImage), size: CGSize(width: 320, height: 320))
            let b = pixels(transformed(CIImage(cgImage: raster.cgImage)), size: CGSize(width: 320, height: 320))
            let worst = zip(a, b).map { abs(Int($0) - Int($1)) }.max()!
            XCTAssertLessThanOrEqual(worst, 2, "Tile seam at zoom \(zoom), blur \(blur)")
        } }
        let rendered = try Raster(image: ImageRenderer().cgImage(raster.ciImage))
        XCTAssertEqual(rendered, raster)
    }
    func testFillCrossesTilesButRespectsDisconnectedRegionsAndSelectionHoles() {
        var raster = Raster(width: 600, height: 540, color: .white)
        raster.fill(color: .black, rect: CGRect(x: 400, y: 0, width: 1, height: 540))
        let hole = SelectionMask.rectangle(CGRect(x: 250, y: 250, width: 20, height: 20), width: 600, height: 540)
        raster.floodFill(at: CGPoint(x: 100, y: 100), color: .black, tolerance: 0, clip: nil, selection: hole.inverted())
        XCTAssertEqual(raster.pixel(x: 300, y: 300), .black)
        XCTAssertEqual(raster.pixel(x: 260, y: 260), .white)
        XCTAssertEqual(raster.pixel(x: 450, y: 300), .white)
    }
}
