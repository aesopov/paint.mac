import AppKit
import ImageIO
import XCTest
@testable import PaintMac

final class SmudgeTests: XCTestCase {
    private func bands() -> Raster {
        var raster = Raster(width: 112, height: 48, color: PixelColor(r: 0, g: 0, b: 255))
        raster.fill(color: PixelColor(r: 255, g: 0, b: 0), rect: CGRect(x: 32, y: 0, width: 80, height: 48))
        return raster
    }
    private func stroke(_ source: Raster, length: Double, strength: Double = 1, preserveAlpha: Bool = false) -> Raster {
        var result = source
        var brush = RetouchStroke(kind: .smudge, size: 20, hardness: 1, strength: strength, antialias: true,
                                  smudgeLength: length, preserveAlpha: preserveAlpha)
        brush.paint(on: &result, to: CGPoint(x: 20.5, y: 24.5), selection: nil)
        brush.paint(on: &result, to: CGPoint(x: 80.5, y: 24.5), selection: nil)
        return result
    }
    func testFullStrengthPicksUpNewColorInsteadOfRepeatingTheOriginalStamp() {
        let original = bands(), result = stroke(original, length: 0.5)
        let color = result.pixel(x: 76, y: 24)
        XCTAssertGreaterThan(color.r, 120, "Newly encountered red must enter the reservoir even at full strength")
        XCTAssertGreaterThan(result.pixel(x: 34, y: 24).b, 0, "The brush must transport some initial blue onto the red area")
        XCTAssertEqual(color.a, 255)
        XCTAssertEqual(result.pixel(x: 76, y: 2), original.pixel(x: 76, y: 2))
    }
    func testLengthControlsTravelIndependentlyOfStrengthAndLimitsAreIntentional() {
        let original = bands()
        XCTAssertEqual(stroke(original, length: 0), original)
        XCTAssertEqual(stroke(original, length: 0.7, strength: 0), original)
        let short = stroke(original, length: 0.15), long = stroke(original, length: 0.85)
        XCTAssertGreaterThan(long.pixel(x: 76, y: 24).b, short.pixel(x: 76, y: 24).b)
        XCTAssertGreaterThan(short.pixel(x: 76, y: 24).r, long.pixel(x: 76, y: 24).r)
        let retained = stroke(original, length: 1).pixel(x: 76, y: 24)
        XCTAssertGreaterThan(retained.b, 245); XCTAssertLessThan(retained.r, 10)
        XCTAssertNotEqual(stroke(original, length: 0.5, strength: 0.25), stroke(original, length: 0.5))
    }
    func testSelectionCoverageAppliedExactlyOncePerDabAndHolesStayUntouched() {
        let original = bands()
        var full = original, partial = original
        let selection = SelectionMask(width: original.width, height: original.height,
                                      coverage: Data(repeating: 128, count: original.width * original.height))
        var a = RetouchStroke(kind: .smudge, size: 20, hardness: 1, strength: 0.7, antialias: true, smudgeLength: 0.6), b = a
        for p in [CGPoint(x: 31.5, y: 24.5), CGPoint(x: 32.5, y: 24.5)] {
            a.paint(on: &full, to: p, selection: nil); b.paint(on: &partial, to: p, selection: selection)
        }
        XCTAssertNotEqual(full, original)
        let before = original.bytes, after = full.bytes, selected = partial.bytes
        for i in 0..<before.count {
            let expected = (Double(after[i]) * 128 + Double(before[i]) * 127) / 255
            XCTAssertEqual(Double(selected[i]), expected, accuracy: 1)
        }
        var holes = Data(repeating: 255, count: original.width * original.height)
        for y in 0..<original.height { for x in 45..<52 { holes[y * original.width + x] = 0 } }
        var result = original, brush = RetouchStroke(kind: .smudge, size: 20, hardness: 0, strength: 1, antialias: false)
        let mask = SelectionMask(width: original.width, height: original.height, coverage: holes)
        for p in [CGPoint(x: 20.5, y: 24.5), CGPoint(x: 80.5, y: 24.5)] { brush.paint(on: &result, to: p, selection: mask) }
        for y in 0..<original.height { for x in 45..<52 { XCTAssertEqual(result.pixel(x: x, y: y), original.pixel(x: x, y: y)) } }
    }
    func testPreserveAlphaLocksEverySampleIncludingTransparentPixelsAndSixteenBitLowBits() {
        for depth in [RGBDepth.eight, .sixteen] { for smooth in [false, true] {
            let format = RGBFormat(profile: .displayP3, depth: depth)
            var original = Raster(width: 520, height: 64, format: format)
            original.editPixels(in: original.bounds) { raw, _ in
                let p = RGBSamples(raw: raw, depth: depth)
                for y in 0..<64 { for x in 0..<520 {
                    let i = (y * 520 + x) * 4
                    let alpha = (x + y) % 7 == 0 ? 0 : Double((x * 139 + y * 97) % Int(p.maximum))
                    p[i + 3] = alpha; p[i] = x < 256 ? alpha : 0; p[i + 1] = 0; p[i + 2] = x < 256 ? 0 : alpha
                } }
            }
            var result = original
            var brush = RetouchStroke(kind: .smudge, size: 32, hardness: 0.3, strength: 1, antialias: smooth,
                                      smudgeLength: 0.7, preserveAlpha: true)
            for p in [CGPoint(x: 245.5, y: 32.5), CGPoint(x: 280.5, y: 32.5)] { brush.paint(on: &result, to: p, selection: nil) }
            XCTAssertNotEqual(result, original); XCTAssertEqual(result.format, format)
            XCTAssertTrue(result.storage.tiles[2] === original.storage.tiles[2])
            let before = original.bytes, after = result.bytes
            before.withUnsafeBytes { old in after.withUnsafeBytes { new in
                let a = RGBSamples(raw: UnsafeMutableRawBufferPointer(mutating: old), depth: depth)
                let b = RGBSamples(raw: UnsafeMutableRawBufferPointer(mutating: new), depth: depth)
                for i in 0..<(520 * 64) {
                    XCTAssertEqual(b[i * 4 + 3], a[i * 4 + 3])
                    for c in 0..<3 { XCTAssertLessThanOrEqual(b[i * 4 + c], b[i * 4 + 3]) }
                }
            } }
        } }
    }
    func testFractionalDiagonalStrokeIsIndependentOfEventFrequencyWithPreservedAlpha() {
        for preserve in [false, true] {
            var a = bands(), b = a
            var coarse = RetouchStroke(kind: .smudge, size: 23, hardness: 0, strength: 0.7, antialias: true,
                                       smudgeLength: 0.7, preserveAlpha: preserve), fine = coarse
            let start = CGPoint(x: 20.25, y: 8.25)
            coarse.paint(on: &a, to: start, selection: nil); fine.paint(on: &b, to: start, selection: nil)
            coarse.paint(on: &a, to: CGPoint(x: 70.25, y: 33.25), selection: nil)
            for i in 1...100 { fine.paint(on: &b, to: CGPoint(x: 20.25 + Double(i) / 2, y: 8.25 + Double(i) / 4), selection: nil) }
            XCTAssertEqual(a, b)
        }
    }
    func testSoftStrokeDoesNotLeaveStrongerColorRailsAlongItsEdges() throws {
        for depth in [RGBDepth.eight, .sixteen] { for smooth in [false, true] {
            var result = Raster(width: 660, height: 96, color: .white,
                                format: RGBFormat(profile: .sRGB, depth: depth))
            result.fill(color: PixelColor(r: 0, g: 100, b: 255), rect: CGRect(x: 0, y: 0, width: 72, height: 96))
            let original = result
            var brush = RetouchStroke(kind: .smudge, size: 48, hardness: 0, strength: 0.7, antialias: smooth,
                                      smudgeLength: 0.5)
            for point in [CGPoint(x: 35.25, y: 48.25), CGPoint(x: 620.25, y: 48.25)] {
                brush.paint(on: &result, to: point, selection: nil)
            }
            let data = result.bytes
            var excess: Double = 0
            data.withUnsafeBytes { raw in
                let p = RGBSamples(raw: UnsafeMutableRawBufferPointer(mutating: raw), depth: depth)
                func blue(_ x: Int, _ y: Int) -> Double {
                    let i = (y * 660 + x) * 4
                    return (p[i + 2] - p[i]) / p.maximum
                }
                for x in 100..<600 {
                    let center = blue(x, 48)
                    for y in 25..<72 { excess = max(excess, blue(x, y) - center) }
                }
                XCTAssertLessThanOrEqual(blue(500, 30), 2 / 255.0, "Picked-up blue must fade away at the soft fringe")
            }
            XCTAssertLessThanOrEqual(excess, 2 / 255.0, "A soft brush must not leave stronger blue rails than its center (\(depth), smooth \(smooth))")
            if let directory = ProcessInfo.processInfo.environment["PAINTMAC_SMUDGE_SAMPLES"], depth == .eight, smooth {
                for (raster, name) in [(original, "glow-source"), (result, "glow-result")] {
                    let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
                    let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                    CGImageDestinationAddImage(dest, raster.cgImage, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
                }
            }
        } }
    }
    func testVisualSamplesWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["PAINTMAC_SMUDGE_SAMPLES"] else { return }
        var original = Raster(width: 600, height: 220, color: .white)
        original.fill(color: PixelColor(r: 0, g: 90, b: 255), rect: CGRect(x: 40, y: 30, width: 180, height: 160))
        original.fill(color: PixelColor(r: 240, g: 40, b: 30), rect: CGRect(x: 220, y: 30, width: 340, height: 160))
        // Thin lines expose excessive texture loss and repeated stamping.
        for y in stride(from: 40, to: 190, by: 12) {
            original.fill(color: PixelColor(r: 255, g: 220, b: 60), rect: CGRect(x: 40, y: y, width: 180, height: 3))
        }
        func save(_ raster: Raster, _ name: String) throws {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
            let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(dest, raster.cgImage, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
        }
        try save(original, "source")
        for length in [0.2, 0.5, 0.85, 1] {
            var result = original
            var brush = RetouchStroke(kind: .smudge, size: 90, hardness: 0.3, strength: 1, antialias: true, smudgeLength: length)
            for p in [CGPoint(x: 140.5, y: 90.5), CGPoint(x: 350.5, y: 90.5), CGPoint(x: 420.5, y: 150.5)] {
                brush.paint(on: &result, to: p, selection: nil)
            }
            try save(result, "length-\(Int(length * 100))")
        }
    }
}
