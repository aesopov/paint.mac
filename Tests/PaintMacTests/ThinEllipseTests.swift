import AppKit
import XCTest
@testable import PaintMac

final class ThinEllipseTests: XCTestCase {
    private let blue = PixelColor(r: 64, g: 117, b: 245)
    private func draw(_ rect: CGRect, alignment: ShapeOutlineAlignment, smooth: Bool = false,
                      fill: PixelColor? = nil, format: RGBFormat = .standard, selection: SelectionMask? = nil,
                      opacity: Double = 1) -> Raster {
        var raster = Raster(width: 80, height: 70, format: format)
        raster.strokeShape(in: rect, ellipse: true, size: 1, color: blue, opacity: opacity, clip: nil,
                           selection: selection, antialias: smooth, fillColor: fill, alignment: alignment)
        return raster
    }
    func testOnePixelSharpEllipsesHaveOnePixelCardinalEdgesForAllAlignments() throws {
        for alignment in ShapeOutlineAlignment.allCases { for dimensions in [(12.0,12.0), (13,13), (32,20), (21,33)] {
            let phase: CGFloat = alignment == .center ? 0.5 : 0
            let rect = CGRect(x: 20 + phase, y: 16 + phase, width: dimensions.0, height: dimensions.1)
            let raster = draw(rect, alignment: alignment)
            let vertical = (0..<raster.height).filter { raster.pixel(x: Int(rect.midX), y: $0).a > 0 }
            let horizontal = (0..<raster.width).filter { raster.pixel(x: $0, y: Int(rect.midY)).a > 0 }
            XCTAssertEqual(vertical.count, 2, "Top and bottom must each be one pixel: \(alignment), \(dimensions), \(vertical)")
            XCTAssertEqual(horizontal.count, 2, "Left and right must each be one pixel: \(alignment), \(dimensions), \(horizontal)")
            let bytes = raster.bytes
            XCTAssertTrue(stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 0 || bytes[$0] == 255 })
        } }
        try writePreviewIfRequested()
    }
    private func writePreviewIfRequested() throws {
        guard let destination = ProcessInfo.processInfo.environment["PAINTMAC_THIN_ELLIPSE_PREVIEW"] else { return }
        var preview = Raster(width: 40, height: 16, color: .white)
        preview.strokeLine(from: CGPoint(x: 3.5, y: 2.5), to: CGPoint(x: 3.5, y: 13.5), size: 1,
                           color: blue, opacity: 1, selection: nil, antialias: false, hardness: 1, border: .solid)
        for (x, ellipse) in [(9.0, false), (25, true)] {
            preview.strokeShape(in: CGRect(x: x, y: 2, width: 12, height: 12), ellipse: ellipse, size: 1,
                                color: blue, opacity: 1, clip: nil, antialias: false, alignment: .inside)
        }
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 320, bitsPerComponent: 8, bytesPerRow: 800 * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.draw(preview.cgImage, in: CGRect(x: 0, y: 0, width: 800, height: 320))
        let image = try XCTUnwrap(context.makeImage()), rep = NSBitmapImageRep(cgImage: image)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: destination))
    }
    func testThinEllipseStillHonorsOpacitySelectionFillAndSixteenBitProfile() {
        let format = RGBFormat(profile: .displayP3, depth: .sixteen)
        let selection = SelectionMask(width: 80, height: 70, coverage: Data(repeating: 128, count: 80 * 70))
        for alignment in ShapeOutlineAlignment.allCases {
            let rect = CGRect(x: 20, y: 16, width: 24, height: 24)
            let raster = draw(rect, alignment: alignment, fill: .white, format: format, selection: selection, opacity: 0.5)
            XCTAssertEqual(raster.format, format)
            XCTAssertEqual(raster.pixel(x: 32, y: 28).a, 64)
            for y in 0..<70 { for x in 0..<80 { XCTAssertLessThanOrEqual(raster.pixel(x: x, y: y).a, 64) } }
            let smooth = draw(rect, alignment: alignment, smooth: true)
            let bytes = smooth.bytes
            XCTAssertTrue(stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 && bytes[$0] < 255 })
        }
    }
}
