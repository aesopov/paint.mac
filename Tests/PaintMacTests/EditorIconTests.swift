import XCTest
import AppKit
@testable import PaintMac

final class EditorIconTests: XCTestCase {
    func testBundledIconsAreVectorTemplatesWithIndependentSizesAndLicenses() throws {
        _ = NSApplication.shared
        for icon in EditorIcon.allCases {
            let image = icon.image()
            XCTAssertTrue(image.isTemplate, icon.rawValue)
            XCTAssertTrue(image.representations.contains { $0 is NSPDFImageRep }, icon.rawValue)
            let menu = icon.image(size: 16)
            XCTAssertEqual(menu.size.width, 16); XCTAssertEqual(image.size.width, 18)
            XCTAssertFalse(menu === image)
        }
        let bundle = EditorIcon.resourceBundle
        for file in ["LICENSE", "COPYRIGHT", "NOTICES.txt", "UPSTREAM.json", "MergeLayers.svg"] {
            XCTAssertNotNil(bundle.url(forResource: file, withExtension: nil, subdirectory: "Spectrum"), file)
        }
        let license = try String(contentsOf: XCTUnwrap(bundle.url(forResource: "LICENSE", withExtension: nil, subdirectory: "Spectrum")))
        XCTAssertTrue(license.contains("Apache License")); XCTAssertTrue(license.contains("Version 2.0"))
    }
    func testCustomDrawnMergeIconRemainsVisibleAndChangesContrastWithAppearance() throws {
        _ = NSApplication.shared
        func rendered(_ name: NSAppearance.Name, background: NSColor) throws -> (Int, Double) {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                background.setFill(); CGRect(x: 0, y: 0, width: 36, height: 36).fill()
                EditorIcon.draw(EditorIcon.merge.image(), in: CGRect(x: 4, y: 4, width: 28, height: 28))
            }
            var ink = 0, sum = 0.0
            for y in 0..<36 { for x in 0..<36 {
                let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                let brightness = Double(c.redComponent + c.greenComponent + c.blueComponent) / 3
                if (name == .aqua && brightness < 0.7) || (name == .darkAqua && brightness > 0.3) { ink += 1; sum += brightness }
            } }
            return (ink, sum / Double(max(1, ink)))
        }
        let light = try rendered(.aqua, background: .white), dark = try rendered(.darkAqua, background: .black)
        XCTAssertGreaterThan(light.0, 80); XCTAssertGreaterThan(dark.0, 80)
        XCTAssertLessThan(light.1, 0.4); XCTAssertGreaterThan(dark.1, 0.6)
    }
    func testToolFlyoutAndLayerActionsUseConsistentVectorIconsWithoutChangingCommands() throws {
        _ = NSApplication.shared
        let group = ToolGroupButton(group: .shapes)
        for tool in [PaintTool.rectangle, .ellipse, .line] {
            group.setCurrentTool(tool)
            XCTAssertTrue(group.image!.isTemplate)
            XCTAssertTrue(group.image!.representations.contains { $0 is NSPDFImageRep })
        }
        let doc = PaintDocument(); defer { doc.close() }
        doc.makeWindowControllers()
        let editor = doc.windowControllers[0] as! EditorWindowController
        let menu = try XCTUnwrap(editor.layerContextMenu(forRow: 0))
        for title in ["Merge Down", "Duplicate Layer", "Rename…", "Group Layer", "Move Down"] {
            let item = try XCTUnwrap(menu.item(withTitle: title))
            XCTAssertTrue(try XCTUnwrap(item.image).isTemplate, title)
            XCTAssertEqual(item.image?.size.width, 16)
            XCTAssertNotNil(item.action)
        }
        let mask = try XCTUnwrap(menu.item(withTitle: "Layer Mask")?.submenu)
        XCTAssertTrue(try XCTUnwrap(mask.item(withTitle: "Add Mask — Reveal All")?.image).isTemplate)
    }
}
