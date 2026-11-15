import XCTest
import AppKit
import ImageIO
@testable import PaintMac

final class ICOTests: XCTestCase {
    private let red = PixelColor(r: 255, g: 0, b: 0)
    private let blue = PixelColor(r: 0, g: 0, b: 255)
    private let green = PixelColor(r: 0, g: 255, b: 0)

    private func word(_ value: Int) -> [UInt8] { [UInt8(value & 255), UInt8((value >> 8) & 255)] }
    private func dword(_ value: Int) -> [UInt8] { word(value) + word(value >> 16) }
    // Independent 2×2 ICO fixtures with padded bottom-up rows and an AND mask.
    // Top: red, transparent green. Bottom: blue, white. 1-bit uses white/black.
    private func fixture(bits: Int, bitfields: Bool = false, legacyAlpha: Bool = false) -> Data {
        var dib: [UInt8] = dword(40) + dword(2) + dword(4) + word(1) + word(bits)
        dib += dword(bitfields ? 3 : 0) + dword(0) + dword(0) + dword(0)
        dib += dword(bits == 1 ? 2 : (bits <= 8 ? 5 : 0)) + dword(0)
        if bitfields { dib += dword(0xf800) + dword(0x07e0) + dword(0x001f) }
        if bits <= 8 {
            let colors: [[UInt8]] = bits == 1 ? [[0,0,0,0], [255,255,255,0]] : [[0,0,0,0], [0,0,255,0], [0,255,0,0], [255,0,0,0], [255,255,255,0]]
            dib += colors.flatMap { $0 }
        }
        switch bits {
        case 1: dib += [0x40,0,0,0, 0x80,0,0,0]
        case 4: dib += [0x34,0,0,0, 0x12,0,0,0]
        case 8: dib += [3,4,0,0, 1,2,0,0]
        case 16: dib += word(0x001f) + word(bitfields ? 0xffff : 0x7fff) + word(bitfields ? 0xf800 : 0x7c00) + word(bitfields ? 0x07e0 : 0x03e0)
        case 24: dib += [255,0,0, 255,255,255, 0,0, 0,0,255, 0,255,0, 0,0]
        case 32:
            dib += [255,0,0,legacyAlpha ? 0 : 255, 255,255,255,legacyAlpha ? 0 : 255,
                    0,0,255,legacyAlpha ? 0 : 128, 0,255,0,0]
        default: fatalError("Unsupported fixture")
        }
        dib += [0,0,0,0, 0x40,0,0,0]
        return Data(word(0) + word(1) + word(1) + [2,2,0,0] + word(1) + word(bits) + dword(dib.count) + dword(22) + dib)
    }

    func testLegacyBitmapDepthsMasksPaddingAndTopLeftOrientation() throws {
        for bits in [1, 4, 8, 16, 24, 32] {
            let image = try ICOCodec.decode(ICOCodec.read(fixture(bits: bits)), index: 0)
            XCTAssertEqual(image.width, 2); XCTAssertEqual(image.height, 2)
            XCTAssertEqual(image.pixel(x: 1, y: 0), .clear, "\(bits)-bit AND/alpha")
            XCTAssertEqual(image.pixel(x: 1, y: 1), .white)
            if bits == 1 {
                XCTAssertEqual(image.pixel(x: 0, y: 0), .white)
                XCTAssertEqual(image.pixel(x: 0, y: 1), PixelColor(r: 0, g: 0, b: 0))
            } else {
                XCTAssertEqual(image.pixel(x: 0, y: 0), PixelColor(r: 255, g: 0, b: 0, a: bits == 32 ? 128 : 255))
                XCTAssertEqual(image.pixel(x: 0, y: 1), blue)
            }
        }
        let fields = try ICOCodec.decode(ICOCodec.read(fixture(bits: 16, bitfields: true)), index: 0)
        XCTAssertEqual(fields.pixel(x: 0, y: 0), red); XCTAssertEqual(fields.pixel(x: 0, y: 1), blue)
        let legacy = try ICOCodec.decode(ICOCodec.read(fixture(bits: 32, legacyAlpha: true)), index: 0)
        XCTAssertEqual(legacy.pixel(x: 0, y: 0), red); XCTAssertEqual(legacy.pixel(x: 1, y: 0), .clear)
        // Negative DIB height means top-down rows for both image and mask.
        var topDown = fixture(bits: 24)
        topDown.replaceSubrange(30..<34, with: dword(-4))
        let bottomPixels = topDown.subdata(in: 62..<70), topPixels = topDown.subdata(in: 70..<78)
        topDown.replaceSubrange(62..<70, with: topPixels); topDown.replaceSubrange(70..<78, with: bottomPixels)
        topDown.replaceSubrange(78..<86, with: [0x40,0,0,0, 0,0,0,0])
        XCTAssertEqual(try ICOCodec.decode(ICOCodec.read(topDown), index: 0), try ICOCodec.decode(ICOCodec.read(fixture(bits: 24)), index: 0))
        // A 32-bit frame with meaningful alpha can omit the legacy AND mask.
        var noMask = fixture(bits: 32); noMask.removeLast(8)
        noMask.replaceSubrange(14..<18, with: dword(noMask.count - 22))
        let noMaskImage = try ICOCodec.decode(ICOCodec.read(noMask), index: 0)
        XCTAssertEqual(noMaskImage.pixel(x: 0, y: 0).a, 128); XCTAssertEqual(noMaskImage.pixel(x: 1, y: 0), .clear)
    }

    func testMixedBitmapAndPNGExportRoundTripsAndImageIOCanReadEveryFrame() throws {
        var small = Raster(width: 17, height: 13)
        small.fill(color: red, rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        small.fill(color: blue, rect: CGRect(x: 16, y: 12, width: 1, height: 1))
        small.fill(color: PixelColor(r: 0, g: 255, b: 0, a: 128), rect: CGRect(x: 5, y: 3, width: 1, height: 1))
        var large = Raster(width: 256, height: 256)
        large.fill(color: blue, rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        large.fill(color: red, rect: CGRect(x: 255, y: 255, width: 1, height: 1))
        let data = try ICOCodec.encode([small, large])
        let file = try ICOCodec.read(data)
        XCTAssertFalse(file.entries[0].isPNG); XCTAssertTrue(file.entries[1].isPNG)
        XCTAssertEqual(try ICOCodec.decode(file, index: 0), small)
        XCTAssertEqual(try ICOCodec.decode(file, index: 1), large)
        // Verify encoded files with a separate system decoder, not only our reader.
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        // ImageIO orders ICO representations by size rather than directory order.
        let nativeImages = try (0..<CGImageSourceGetCount(source)).map { try Raster(image: XCTUnwrap(CGImageSourceCreateImageAtIndex(source, $0, nil))) }
        for expected in [small, large] {
            let image = try XCTUnwrap(nativeImages.first { $0.width == expected.width && $0.height == expected.height })
            XCTAssertEqual(image.width, expected.width); XCTAssertEqual(image.height, expected.height)
            XCTAssertEqual(image.pixel(x: 0, y: 0), expected.pixel(x: 0, y: 0))
            XCTAssertEqual(image.pixel(x: image.width - 1, y: image.height - 1), expected.pixel(x: expected.width - 1, y: expected.height - 1))
            XCTAssertEqual(image.pixel(x: 1, y: 1), .clear)
        }
    }

    func testReplacingChosenImagePreservesOtherRepresentationsByteForByte() throws {
        let first = Raster(width: 16, height: 16, color: red)
        let second = Raster(width: 32, height: 32, color: blue)
        let third = Raster(width: 256, height: 256, color: green)
        let original = try ICOCodec.read(ICOCodec.encode([first, second, third]))
        let replacement = Raster(width: 48, height: 48, color: .white)
        let source = IconSource(file: original, index: 1, name: "test")
        let result = try ICOCodec.read(ICOCodec.replacing(source, with: replacement))
        XCTAssertEqual(result.entries.count, 3)
        for index in [0, 2] {
            XCTAssertEqual(result.entries[index].payload, original.entries[index].payload)
            XCTAssertEqual(result.entries[index].directory, original.entries[index].directory)
        }
        XCTAssertEqual(try ICOCodec.decode(result, index: 1), replacement)
    }

    func testWindowsSizeSetFitsWithoutDistortingAndSupportsSharpScaling() throws {
        let source = Raster(width: 4, height: 2, color: red)
        for smooth in [false, true] {
            let data = try ICOCodec.sizeSet(from: source, smooth: smooth)
            let file = try ICOCodec.read(data)
            XCTAssertEqual(file.entries.map(\.width), ICOCodec.standardSizes)
            let native = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetCount(native), 7)
            for index in file.entries.indices {
                let image = try ICOCodec.decode(file, index: index), size = ICOCodec.standardSizes[index]
                XCTAssertEqual(image.width, size); XCTAssertEqual(image.height, size)
                XCTAssertEqual(image.pixel(x: size / 2, y: 0), .clear)
                XCTAssertEqual(image.pixel(x: size / 2, y: size / 2), red)
                XCTAssertEqual(image.pixel(x: 0, y: size / 4), red)
                XCTAssertNotNil(CGImageSourceCreateImageAtIndex(native, index, nil))
            }
        }
    }

    func testMalformedContainersAndBitmapsAreRejectedBeforeDecoding() throws {
        let valid = fixture(bits: 24)
        for length in [0, 1, 5, 6, 21, valid.count - 1] { XCTAssertThrowsError(try ICOCodec.read(Data(valid.prefix(length)))) }
        var corrupt = valid; corrupt[2] = 2 // CUR is not ICO
        XCTAssertThrowsError(try ICOCodec.read(corrupt))
        corrupt = valid; corrupt[4] = 0
        XCTAssertThrowsError(try ICOCodec.read(corrupt))
        corrupt = valid; corrupt.replaceSubrange(18..<22, with: dword(0xfffffff0))
        XCTAssertThrowsError(try ICOCodec.read(corrupt))
        corrupt = valid; corrupt.replaceSubrange(14..<18, with: dword(0xffffffff))
        XCTAssertThrowsError(try ICOCodec.read(corrupt))
        corrupt = valid; corrupt[6] = 3 // directory and bitmap dimensions disagree
        XCTAssertThrowsError(try ICOCodec.read(corrupt))
        corrupt = valid; corrupt.replaceSubrange(38..<42, with: dword(1)) // RLE
        XCTAssertThrowsError(try ICOCodec.read(corrupt))
        corrupt = fixture(bits: 4); corrupt[22 + 40 + 20] = 0xf4 // palette index past its table
        let file = try ICOCodec.read(corrupt)
        XCTAssertThrowsError(try ICOCodec.decode(file, index: 0))
        XCTAssertThrowsError(try ICOCodec.decode(file, index: -1))
        XCTAssertThrowsError(try ICOCodec.decode(file, index: 100))
        XCTAssertThrowsError(try ICOCodec.encode([]))
        XCTAssertThrowsError(try ICOCodec.encode([Raster(width: 257, height: 16)]))
        XCTAssertThrowsError(try ICOCodec.encode([Raster(width: 16, height: 257)]))
    }

    func testDocumentExportUsesVisibleCompositeFinishesTextAndKeepsExistingIconFrames() throws {
        _ = NSApplication.shared
        let original = try ICOCodec.read(ICOCodec.encode([Raster(width: 16, height: 16, color: blue), Raster(width: 32, height: 32, color: green)]))
        let document = PaintDocument()
        document.state = DocumentState(width: 16, height: 16)
        document.state.layers[0].visible = false
        document.state.layers[1].raster.fill(color: red, rect: CGRect(x: 0, y: 0, width: 3, height: 3))
        document.iconSource = IconSource(file: original, index: 0, name: "original")
        var finished = false
        document.finishPendingEdits = { finished = true }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ico")
        defer { try? FileManager.default.removeItem(at: url) }
        try document.export(to: url, settings: ImageExportSettings(format: .ico, iconMode: .preserveOtherImages))
        XCTAssertTrue(finished)
        let written = try ICOCodec.read(Data(contentsOf: url))
        let image = try ICOCodec.decode(written, index: 0)
        XCTAssertEqual(image.pixel(x: 0, y: 0), red); XCTAssertEqual(image.pixel(x: 15, y: 15), .clear)
        XCTAssertEqual(written.entries[1].payload, original.entries[1].payload)
        // Export context does not alter the existing native project format.
        let reopened = try ProjectCodec.decode(ProjectCodec.encode(document.state))
        XCTAssertEqual(reopened, document.state)
        document.state = DocumentState(width: 400, height: 400)
        document.invalidate()
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try document.export(to: url, settings: ImageExportSettings(format: .ico)))
        XCTAssertEqual(try Data(contentsOf: url), before, "A failed export must not replace an existing file")
    }

    func testIconDialogLayouts() throws {
        _ = NSApplication.shared
        let file = try ICOCodec.read(ICOCodec.encode([Raster(width: 16, height: 16, color: red), Raster(width: 256, height: 256, color: blue)]))
        let source = IconSource(file: file, index: 0, name: "example")
        let chooser = IconImportDialog(file: file, name: "example.ico")
        let options = ImageExportOptions(width: 16, height: 16, source: source, smooth: false)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        for (name, form) in [("ico-import", chooser.formView), ("ico-export", options.view)] {
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: form.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = form; form.layoutSubtreeIfNeeded()
            defer { window.close() }
            XCTAssertGreaterThan(form.bounds.width, 300)
            for control in descendants(form).compactMap({ $0 as? NSControl }) where !control.isHiddenOrHasHiddenAncestor {
                XCTAssertTrue(form.bounds.insetBy(dx: -1, dy: -1).contains(control.convert(control.bounds, to: form)), "\(name): \(type(of: control)) \(control.convert(control.bounds, to: form)) outside \(form.bounds)")
            }
            if let folder = ProcessInfo.processInfo.environment["PAINTMAC_ICO_PREVIEW_DIR"], let bitmap = form.bitmapImageRepForCachingDisplay(in: form.bounds) {
                form.cacheDisplay(in: form.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
            }
        }
    }

    func testImportAndExportOptionsExposeICOAndValidateSingleImageSizes() throws {
        _ = NSApplication.shared
        guard case .icon(let icon) = try ImageFileIO.read(fixture(bits: 24), fileExtension: "ICO") else { return XCTFail("ICO import") }
        XCTAssertEqual(icon.entries.count, 1)
        let options = ImageExportOptions(width: 400, height: 200, source: nil, smooth: false)
        let panel = NSSavePanel(); panel.nameFieldStringValue = "test.png"; options.attach(to: panel)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let popups = descendants(options.view).compactMap { $0 as? NSPopUpButton }
        let format = try XCTUnwrap(popups.first { $0.itemTitles.contains("Windows icon (.ico)") })
        format.selectItem(at: 2); _ = format.sendAction(format.action, to: format.target)
        XCTAssertEqual(panel.allowedContentTypes, [ImageExportFormat.ico.contentType]); XCTAssertEqual(panel.nameFieldStringValue, "test.ico")
        XCTAssertEqual(options.settings.iconMode, .windowsSizes); XCTAssertFalse(options.settings.smooth)
        let mode = try XCTUnwrap(popups.first { $0.itemTitles.contains("Windows size set (16–256 px)") })
        mode.selectItem(at: 0); _ = mode.sendAction(mode.action, to: mode.target)
        XCTAssertThrowsError(try options.panel(panel, validate: URL(fileURLWithPath: "/tmp/test.ico")))
        mode.selectItem(at: 1); _ = mode.sendAction(mode.action, to: mode.target)
        XCTAssertNoThrow(try options.panel(panel, validate: URL(fileURLWithPath: "/tmp/test.ico")))
        let source = IconSource(file: icon, index: 0, name: "test")
        let preserve = ImageExportOptions(width: 2, height: 2, source: source, smooth: true)
        XCTAssertEqual(preserve.settings.format, .ico); XCTAssertEqual(preserve.settings.iconMode, .preserveOtherImages)
        let chooser = IconImportDialog(file: try ICOCodec.read(ICOCodec.encode([Raster(width: 16, height: 16), Raster(width: 32, height: 32)])), name: "test.ico")
        XCTAssertEqual(chooser.selectedIndex, 1)
        let newSize = descendants(chooser.formView).compactMap { $0 as? NSPopUpButton }.first!
        newSize.selectItem(at: 0); _ = newSize.sendAction(newSize.action, to: newSize.target)
        XCTAssertEqual(chooser.selectedIndex, 0)
    }
}
