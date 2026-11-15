import XCTest
import AppKit
import ImageIO
@testable import PaintMac

final class ICNSTests: XCTestCase {
    private let red = PixelColor(r: 255, g: 0, b: 0)
    private let blue = PixelColor(r: 0, g: 0, b: 255)
    private let green = PixelColor(r: 0, g: 255, b: 0)

    func testEveryStandardSlotRoundTripsAndNativeImageIODecodesItsPixels() throws {
        for slot in ICNSSlot.standard {
            var image = Raster(width: slot.pixels, height: slot.pixels)
            image.fill(color: red, rect: CGRect(x: 0, y: 0, width: 1, height: 1))
            image.fill(color: blue, rect: CGRect(x: slot.pixels - 1, y: slot.pixels - 1, width: 1, height: 1))
            image.fill(color: PixelColor(r: 0, g: 255, b: 0, a: 128), rect: CGRect(x: 5, y: 3, width: 1, height: 1))
            let data = try ICNSCodec.encode(image, slot: slot), file = try ICNSCodec.read(data)
            XCTAssertEqual(file.representations.count, 1); XCTAssertEqual(file.representations[0].slot, slot)
            XCTAssertEqual(try ICNSCodec.decode(file, index: 0), image, slot.type)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let native = try Raster(image: XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
            XCTAssertEqual(native.width, image.width); XCTAssertEqual(native.height, image.height)
            XCTAssertEqual(native.pixel(x: 0, y: 0), red)
            XCTAssertEqual(native.pixel(x: native.width - 1, y: native.height - 1), blue)
            XCTAssertEqual(native.pixel(x: 5, y: 3), PixelColor(r: 0, g: 255, b: 0, a: 128))
            XCTAssertEqual(native.pixel(x: 1, y: 1), .clear)
        }
    }

    func testSamePixelDimensionsRetainIndependentStandardAndRetinaArtwork() throws {
        let retina = ICNSSlot.standard.first { $0.points == 16 && $0.scale == 2 }!
        let standard = ICNSSlot.standard.first { $0.points == 32 && $0.scale == 1 }!
        let a = try ICNSCodec.read(ICNSCodec.encode(Raster(width: 32, height: 32, color: blue), slot: retina))
        let b = try ICNSCodec.read(ICNSCodec.encode(Raster(width: 32, height: 32, color: red), slot: standard))
        let file = try ICNSCodec.read(ICNSCodec.pack(a.elements + b.elements))
        XCTAssertEqual(try ICNSCodec.decode(file, index: 0).pixel(x: 0, y: 0), blue)
        XCTAssertEqual(try ICNSCodec.decode(file, index: 1).pixel(x: 0, y: 0), red)
        XCTAssertEqual(file.representations.map { $0.slot.scale }, [2, 1])
        let result = try ICNSCodec.read(ICNSCodec.replacing(ICNSSource(file: file, index: 0, name: "test"), with: Raster(width: 32, height: 32, color: green)))
        XCTAssertEqual(result.elements[1], file.elements[1])
        XCTAssertEqual(result.representations[0].slot, retina)
        XCTAssertEqual(try ICNSCodec.decode(result, index: 0).pixel(x: 0, y: 0), green)
    }

    func testCompleteSetFitsArtworkAndKeepsTenLogicalSlots() throws {
        let raster = Raster(width: 4, height: 2, color: red)
        for smooth in [false, true] {
            let data = try ICNSCodec.sizeSet(from: raster, smooth: smooth)
            let file = try ICNSCodec.read(data)
            XCTAssertEqual(file.representations.map(\.slot), ICNSSlot.standard)
            for index in file.representations.indices {
                let image = try ICNSCodec.decode(file, index: index), size = file.representations[index].slot.pixels
                XCTAssertEqual(image.width, size); XCTAssertEqual(image.height, size)
                XCTAssertEqual(image.pixel(x: size / 2, y: 0), .clear)
                XCTAssertEqual(image.pixel(x: size / 2, y: size / 2), red)
                XCTAssertEqual(image.pixel(x: 0, y: size / 4), red)
            }
        }
    }

    func testAppleIconutilGeneratedFilesImportReplaceAndExportWithoutLosingMetadata() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let iconset = folder.appendingPathComponent("test.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for slot in ICNSSlot.standard {
            let color = slot.scale == 2 ? blue : red
            let raster = Raster(width: slot.pixels, height: slot.pixels, color: color)
            let name = "icon_\(slot.points)x\(slot.points)" + (slot.scale == 2 ? "@2x" : "") + ".png"
            try ProjectCodec.imageData(raster.cgImage, type: "public.png").write(to: iconset.appendingPathComponent(name))
        }
        let original = folder.appendingPathComponent("original.icns")
        try iconutil(["-c", "icns", "-o", original.path, iconset.path])
        let file = try ICNSCodec.read(Data(contentsOf: original))
        XCTAssertEqual(file.representations.count, 10)
        for (index, rep) in file.representations.enumerated() {
            let image = try ICNSCodec.decode(file, index: index)
            XCTAssertEqual(image.width, rep.slot.pixels)
            XCTAssertEqual(image.pixel(x: 0, y: 0), rep.slot.scale == 2 ? blue : red, rep.slot.type)
        }
        let index = try XCTUnwrap(file.representations.firstIndex { $0.slot.points == 16 && $0.slot.scale == 2 })
        let edited = try ICNSCodec.replacing(ICNSSource(file: file, index: index, name: "test"), with: Raster(width: 32, height: 32, color: green))
        let parsed = try ICNSCodec.read(edited), selectedElement = file.representations[index].elementIndex
        for i in file.elements.indices where i != selectedElement && file.elements[i].type != "TOC " { XCTAssertEqual(parsed.elements[i], file.elements[i]) }
        let updated = folder.appendingPathComponent("updated.icns")
        try edited.write(to: updated)
        let extracted = folder.appendingPathComponent("updated.iconset")
        try iconutil(["-c", "iconset", "-o", extracted.path, updated.path])
        let greenImage = try ProjectCodec.decodeImage(Data(contentsOf: extracted.appendingPathComponent("icon_16x16@2x.png")))
        let redImage = try ProjectCodec.decodeImage(Data(contentsOf: extracted.appendingPathComponent("icon_32x32.png")))
        XCTAssertEqual(greenImage.pixel(x: 0, y: 0), green)
        XCTAssertEqual(redImage.pixel(x: 0, y: 0), red)
        // Our complete-set encoder must also be accepted by Apple's pack/unpack tool.
        let generated = folder.appendingPathComponent("generated.icns")
        try ICNSCodec.sizeSet(from: Raster(width: 48, height: 48, color: blue), smooth: false).write(to: generated)
        let generatedSet = folder.appendingPathComponent("generated.iconset")
        try iconutil(["-c", "iconset", "-o", generatedSet.path, generated.path])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: generatedSet.path).filter { $0.hasSuffix(".png") }.count, 10)
    }
    private func iconutil(_ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil"); process.arguments = arguments
        let pipe = Pipe(); process.standardError = pipe; process.standardOutput = pipe
        try process.run(); process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, output)
        if process.terminationStatus != 0 { throw ICNSError.invalidFile }
    }

    func testLegacyRGBCompanionMaskRoundTripsAndMetadataAndTOCArePreserved() throws {
        let slot = ICNSSlot.readable.first { $0.type == "is32" }!
        var raster = Raster(width: 16, height: 16)
        raster.fill(color: red, rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        raster.fill(color: PixelColor(r: 0, g: 0, b: 255, a: 128), rect: CGRect(x: 10, y: 15, width: 1, height: 1))
        let encoded = try ICNSCodec.read(ICNSCodec.encode(raster, slot: slot))
        XCTAssertEqual(encoded.elements.map(\.type), ["is32", "s8mk"])
        XCTAssertEqual(try ICNSCodec.decode(encoded, index: 0), raster)
        let elements = encoded.elements + [ICNSFile.Element(type: "TOC ", payload: Data()),
                                          .init(type: "info", payload: Data("metadata".utf8)), .init(type: "zzzz", payload: Data([1, 2, 3]))]
        let original = try ICNSCodec.read(ICNSCodec.pack(elements))
        let updated = try ICNSCodec.read(ICNSCodec.replacing(ICNSSource(file: original, index: 0, name: "test"), with: Raster(width: 16, height: 16, color: green)))
        XCTAssertEqual(try ICNSCodec.decode(updated, index: 0).pixel(x: 0, y: 0), green)
        for type in ["info", "zzzz"] { XCTAssertEqual(updated.elements.first { $0.type == type }, original.elements.first { $0.type == type }) }
        let toc = try XCTUnwrap(updated.elements.first { $0.type == "TOC " }?.payload)
        XCTAssertEqual(toc.count, (updated.elements.count - 1) * 8)
        XCTAssertEqual(toc.prefix(4), Data("is32".utf8))
    }

    func testLegacyIndexedAndMonochromeSlotsUseTheCorrectImageAndMask() throws {
        var mono = Data(repeating: 0xaa, count: 32)
        var mask = Data(repeating: 0xff, count: 32); mask[0] = 0x7f
        mono.append(mask)
        let data = try ICNSCodec.pack([.init(type: "ics8", payload: Data(repeating: 255, count: 256)), .init(type: "ics#", payload: mono)])
        let file = try ICNSCodec.read(data)
        let indexed = try ICNSCodec.decode(file, index: 0), monochrome = try ICNSCodec.decode(file, index: 1)
        XCTAssertEqual(indexed.pixel(x: 0, y: 0).a, 0)
        XCTAssertEqual(indexed.pixel(x: 3, y: 3).a, 255)
        XCTAssertEqual(indexed.pixel(x: 3, y: 3), indexed.pixel(x: 4, y: 3), "The indexed image must not be replaced by its monochrome companion")
        XCTAssertNotEqual(monochrome.pixel(x: 3, y: 3), monochrome.pixel(x: 4, y: 3))
        XCTAssertThrowsError(try ICNSCodec.validateReplacement(ICNSSource(file: file, index: 0, name: "legacy"), width: 16, height: 16))
        XCTAssertThrowsError(try ICNSCodec.read(ICNSCodec.pack([.init(type: "ics8", payload: Data(count: 255))])))
    }

    func testJPEG2000ResourceUsesItsOwnPixels() throws {
        let slot = ICNSSlot.standard.first { $0.type == "ic08" }!
        let raster = Raster(width: 256, height: 256, color: red)
        let jp2 = try ProjectCodec.imageData(raster.cgImage, type: "public.jpeg-2000")
        let data = try ICNSCodec.pack([.init(type: slot.type, payload: jp2)])
        let file = try ICNSCodec.read(data)
        let expected = try ProjectCodec.decodeImage(jp2)
        XCTAssertEqual(try ICNSCodec.decode(file, index: 0), expected)
        XCTAssertEqual(file.representations[0].slot, slot)
    }

    func testICNSDialogLayouts() throws {
        _ = NSApplication.shared
        let bytes = try ICNSCodec.sizeSet(from: Raster(width: 64, height: 64, color: blue), smooth: true)
        let file = try ICNSCodec.read(bytes), source = ICNSSource(file: file, index: 1, name: "example")
        let chooser = IconImportDialog(file: file, name: "example.icns")
        let options = ImageExportOptions(width: 32, height: 32, source: nil, smooth: true, icnsSource: source)
        func views(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + views($0) } }
        // Include the single-slot controls where both a mode and a Retina choice are visible.
        let modes = views(options.view).compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("macOS set · standard + Retina") }!
        modes.selectItem(at: 1); _ = modes.sendAction(modes.action, to: modes.target)
        for (name, form) in [("icns-import", chooser.formView), ("icns-export", options.view)] {
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: form.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = form; form.layoutSubtreeIfNeeded()
            defer { window.close() }
            for control in views(form).compactMap({ $0 as? NSControl }) where !control.isHiddenOrHasHiddenAncestor {
                XCTAssertTrue(form.bounds.insetBy(dx: -1, dy: -1).contains(control.convert(control.bounds, to: form)), "\(name): control outside form")
            }
            if let folder = ProcessInfo.processInfo.environment["PAINTMAC_ICNS_PREVIEW_DIR"], let bitmap = form.bitmapImageRepForCachingDisplay(in: form.bounds) {
                form.cacheDisplay(in: form.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
            }
        }
    }

    func testMalformedICNSAndMismatchedSlotsFailBeforeWriting() throws {
        let slot = ICNSSlot.standard[0]
        let valid = try ICNSCodec.encode(Raster(width: 16, height: 16, color: red), slot: slot)
        for length in [0, 4, 7, 8, valid.count - 1] { XCTAssertThrowsError(try ICNSCodec.read(Data(valid.prefix(length)))) }
        var bad = valid; bad[0] = 0
        XCTAssertThrowsError(try ICNSCodec.read(bad))
        bad = valid; bad.replaceSubrange(12..<16, with: [0, 0, 0, 7])
        XCTAssertThrowsError(try ICNSCodec.read(bad))
        bad = valid; bad.replaceSubrange(12..<16, with: [255, 255, 255, 255])
        XCTAssertThrowsError(try ICNSCodec.read(bad))
        XCTAssertThrowsError(try ICNSCodec.read(ICNSCodec.pack([.init(type: "info", payload: Data())])))
        let png = try ProjectCodec.imageData(Raster(width: 64, height: 64).cgImage, type: "public.png")
        XCTAssertThrowsError(try ICNSCodec.read(ICNSCodec.pack([.init(type: "ic11", payload: png)])))
        XCTAssertThrowsError(try ICNSCodec.encode(Raster(width: 32, height: 32), slot: slot))
        let file = try ICNSCodec.read(valid)
        XCTAssertThrowsError(try ICNSCodec.replacing(ICNSSource(file: file, index: 0, name: "test"), with: Raster(width: 32, height: 32)))
        XCTAssertThrowsError(try ICNSCodec.decode(file, index: -1))
        XCTAssertThrowsError(try ICNSCodec.decode(file, index: 100))
        XCTAssertTrue(ICNSSlot.choices(width: 32, height: 16).isEmpty)
    }

    func testFormatBoundaryDocumentExportAndRetinaUIOptions() throws {
        _ = NSApplication.shared
        let slot = ICNSSlot.standard.first { $0.points == 16 && $0.scale == 2 }!
        let bytes = try ICNSCodec.encode(Raster(width: 32, height: 32, color: blue), slot: slot)
        guard case .macIcon(let file) = try ImageFileIO.read(bytes, fileExtension: "ICNS") else { return XCTFail("ICNS import") }
        let source = ICNSSource(file: file, index: 0, name: "test")
        let document = PaintDocument(); document.state = DocumentState(width: 32, height: 32)
        document.state.layers[0].visible = false; document.state.layers[1].raster.fill(color: red)
        document.icnsSource = source
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".icns")
        defer { try? FileManager.default.removeItem(at: url) }
        try document.export(to: url, settings: ImageExportSettings(format: .icns, iconMode: .preserveOtherImages))
        let reopened = try ICNSCodec.read(Data(contentsOf: url))
        XCTAssertEqual(reopened.representations[0].slot, slot)
        XCTAssertEqual(try ICNSCodec.decode(reopened, index: 0).pixel(x: 0, y: 0), red)
        let options = ImageExportOptions(width: 32, height: 32, source: nil, smooth: true, icnsSource: source)
        let panel = NSSavePanel(); panel.nameFieldStringValue = "test.png"; options.attach(to: panel)
        XCTAssertEqual(options.settings.format, .icns); XCTAssertEqual(options.settings.iconMode, .preserveOtherImages)
        XCTAssertEqual(panel.nameFieldStringValue, "test.icns")
        func views(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + views($0) } }
        let popups = views(options.view).compactMap { $0 as? NSPopUpButton }
        let mode = try XCTUnwrap(popups.first { $0.itemTitles.contains("macOS set · standard + Retina") })
        mode.selectItem(at: 1); _ = mode.sendAction(mode.action, to: mode.target)
        let display = try XCTUnwrap(popups.first { $0.itemTitles.contains("16 pt @2x") })
        XCTAssertFalse(display.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(options.settings.icnsSlot, slot)
        display.selectItem(withTitle: "32 pt @1x"); _ = display.sendAction(display.action, to: display.target)
        XCTAssertEqual(options.settings.icnsSlot?.scale, 1)
        XCTAssertNoThrow(try options.panel(panel, validate: url))
        let chooser = IconImportDialog(file: file, name: "test.icns")
        XCTAssertEqual(chooser.selectedIndex, 0)
        let invalid = ImageExportOptions(width: 64, height: 64, source: nil, smooth: true, icnsSource: source)
        XCTAssertThrowsError(try invalid.panel(panel, validate: url))
    }
}
