import AppKit
import UniformTypeIdentifiers

/// Built-in format boundary, kept separate from tools and project serialization.
/// Future codecs can be added here without exposing document internals.
enum ImageExportFormat: Int, CaseIterable {
    case png, jpeg, ico, icns, tiff
    var title: String { ["PNG · transparency", "JPEG · white background", "Windows icon (.ico)", "macOS icon (.icns)", "TIFF · high precision"][rawValue] }
    var fileExtension: String { ["png", "jpg", "ico", "icns", "tiff"][rawValue] }
    var contentType: UTType { [.png, .jpeg, UTType(filenameExtension: "ico")!, .icns, .tiff][rawValue] }
}

enum IconExportMode: Int { case currentSize, windowsSizes, preserveOtherImages, macSizes }
struct ImageExportSettings {
    var format: ImageExportFormat = .png
    var iconMode: IconExportMode = .currentSize
    var smooth = true
    var icnsSlot: ICNSSlot? = nil
}

enum ImportedImageFile {
    case image(Raster)
    case icon(ICOFile)
    case macIcon(ICNSFile)
}

enum ImageFileIO {
    static var readableTypes: [UTType] { [.image, ImageExportFormat.ico.contentType, .icns] }
    static func read(_ data: Data, fileExtension: String) throws -> ImportedImageFile {
        if fileExtension.lowercased() == "icns" || ICNSCodec.isICNS(data) { return .macIcon(try ICNSCodec.read(data)) }
        if fileExtension.lowercased() == "ico" || ICOCodec.isICO(data) { return .icon(try ICOCodec.read(data)) }
        return .image(try ProjectCodec.decodeImage(data))
    }
    static func encode(_ raster: Raster, settings: ImageExportSettings, iconSource: IconSource?, icnsSource: ICNSSource? = nil) throws -> Data {
        switch settings.format {
        case .png, .tiff: return try ProjectCodec.imageData(raster.cgImage, type: settings.format.contentType.identifier, resolution: raster.resolution)
        case .jpeg:
            // JPEG has no alpha. Composite on white before passing it to ImageIO.
            let renderer = ImageRenderer()
            let image = renderer.composite([PaintLayer(name: "Export", raster: try raster.converted(to: .standard))], width: raster.width, height: raster.height, whiteBackground: true)
            return try ProjectCodec.imageData(image, type: UTType.jpeg.identifier, resolution: raster.resolution)
        case .ico:
            let raster = try raster.converted(to: .standard)
            switch settings.iconMode {
            case .currentSize: return try ICOCodec.encode([raster])
            case .windowsSizes: return try ICOCodec.sizeSet(from: raster, smooth: settings.smooth)
            case .macSizes: throw ICOError.invalidSize
            case .preserveOtherImages:
                guard let iconSource else { throw ICOError.invalidEntry }
                return try ICOCodec.replacing(iconSource, with: raster)
            }
        case .icns:
            let raster = try raster.converted(to: .standard)
            switch settings.iconMode {
            case .currentSize:
                guard let slot = settings.icnsSlot ?? ICNSSlot.choices(width: raster.width, height: raster.height).first(where: { $0.scale == 1 }) ?? ICNSSlot.choices(width: raster.width, height: raster.height).first else { throw ICNSError.invalidSlot }
                return try ICNSCodec.encode(raster, slot: slot)
            case .macSizes: return try ICNSCodec.sizeSet(from: raster, smooth: settings.smooth)
            case .preserveOtherImages:
                guard let icnsSource else { throw ICNSError.invalidSlot }
                return try ICNSCodec.replacing(icnsSource, with: raster)
            case .windowsSizes: throw ICNSError.invalidSlot
            }
        }
    }
}

/// Choose a representation before opening an icon; each size is an alternate
/// image, never a compositing layer. The document retains the original container.
final class IconImportDialog: NSObject {
    private let alert = NSAlert()
    private let popup = NSPopUpButton()
    private let preview = NSImageView()
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let decode: (Int) throws -> Raster
    var selectedIndex: Int { popup.indexOfSelectedItem }
    var formView: NSView { alert.accessoryView! }

    convenience init(file: ICOFile, name: String) {
        self.init(titles: file.entries.map(\.title), priorities: file.entries.map { $0.width * $0.height * 256 + $0.bitDepth },
                  kind: "ICO", name: name, decode: { try ICOCodec.decode(file, index: $0) })
    }
    convenience init(file: ICNSFile, name: String) {
        self.init(titles: file.representations.map(\.title), priorities: file.representations.map { $0.slot.pixels * $0.slot.pixels * 256 + ($0.slot.canReplace ? 128 : 0) + $0.slot.scale },
                  kind: "ICNS", name: name, decode: { try ICNSCodec.decode(file, index: $0) })
    }
    private init(titles: [String], priorities: [Int], kind: String, name: String, decode: @escaping (Int) throws -> Raster) {
        self.decode = decode
        super.init()
        alert.messageText = "Open \(name)"
        alert.informativeText = "This icon contains \(titles.count) images. Choose one to edit. \(kind) export can preserve the other images unchanged."
        alert.addButton(withTitle: "Open Image"); alert.addButton(withTitle: "Cancel")
        popup.addItems(withTitles: titles.enumerated().map { "\($0.offset + 1). \($0.element)" })
        let largest = priorities.indices.max { priorities[$0] < priorities[$1] } ?? 0
        popup.selectItem(at: largest); popup.target = self; popup.action = #selector(selectionChanged)
        popup.setAccessibilityLabel("Icon image to edit")
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true; preview.layer?.backgroundColor = NSColor(calibratedWhite: 0.8, alpha: 1).cgColor
        preview.widthAnchor.constraint(equalToConstant: 180).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 180).isActive = true
        detail.preferredMaxLayoutWidth = 360
        detail.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let form = NSStackView(views: [popup, preview, detail])
        form.orientation = .vertical; form.alignment = .leading; form.spacing = 12
        form.widthAnchor.constraint(equalToConstant: 380).isActive = true
        form.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        form.frame = CGRect(origin: .zero, size: form.fittingSize)
        alert.accessoryView = form
        selectionChanged()
    }
    @objc private func selectionChanged() {
        do {
            let raster = try decode(selectedIndex)
            preview.image = NSImage(cgImage: raster.cgImage, size: CGSize(width: raster.width, height: raster.height))
            detail.stringValue = "\(raster.width) × \(raster.height) pixels. Other icon images remain available when exporting this document."
            alert.buttons[0].isEnabled = true
        } catch {
            preview.image = nil; detail.stringValue = error.localizedDescription; alert.buttons[0].isEnabled = false
        }
    }
    func choose() -> Int? { alert.runModal() == .alertFirstButtonReturn ? selectedIndex : nil }
}

/// Native save-panel options. There is no dynamic code or plugin discovery.
final class ImageExportOptions: NSObject, NSOpenSavePanelDelegate {
    let view: NSStackView
    private let format = NSPopUpButton()
    private let mode = NSPopUpButton()
    private let scaling = NSPopUpButton()
    private let slotPopup = NSPopUpButton()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let iconRow: NSStackView
    private var modes: [IconExportMode] = [.currentSize, .windowsSizes]
    private var lastFormat: ImageExportFormat?
    private let slots: [ICNSSlot]
    private let width: Int, height: Int
    private let source: IconSource?
    private let icnsSource: ICNSSource?
    private weak var panel: NSSavePanel?

    var settings: ImageExportSettings {
        ImageExportSettings(format: ImageExportFormat(rawValue: format.indexOfSelectedItem) ?? .png,
                            iconMode: modes[max(0, mode.indexOfSelectedItem)], smooth: scaling.indexOfSelectedItem == 0,
                            icnsSlot: slots.indices.contains(slotPopup.indexOfSelectedItem) ? slots[slotPopup.indexOfSelectedItem] : nil)
    }
    init(width: Int, height: Int, source: IconSource?, smooth: Bool, icnsSource: ICNSSource? = nil) {
        self.width = width; self.height = height; self.source = source; self.icnsSource = icnsSource
        slots = ICNSSlot.choices(width: width, height: height)
        iconRow = NSStackView(views: [mode, scaling, slotPopup]); iconRow.orientation = .horizontal; iconRow.spacing = 10
        view = NSStackView(views: [format, iconRow, note])
        view.orientation = .vertical; view.alignment = .leading; view.spacing = 10
        view.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        super.init()
        view.widthAnchor.constraint(equalToConstant: 540).isActive = true
        format.addItems(withTitles: ImageExportFormat.allCases.map(\.title))
        format.selectItem(at: icnsSource != nil ? 3 : (source == nil ? 0 : 2))
        slotPopup.addItems(withTitles: slots.isEmpty ? ["No matching ICNS slot"] : slots.map { "\($0.points) pt @\($0.scale)x" })
        slotPopup.isEnabled = !slots.isEmpty
        let originalSlot = icnsSource.flatMap { $0.file.representations.indices.contains($0.index) ? $0.file.representations[$0.index].slot : nil }
        let selected = slots.firstIndex { $0.points == originalSlot?.points && $0.scale == originalSlot?.scale }
            ?? slots.firstIndex { $0.scale == 1 } ?? 0
        slotPopup.selectItem(at: selected)
        scaling.addItems(withTitles: ["Smooth scaling", "Sharp scaling"]); scaling.selectItem(at: smooth ? 0 : 1)
        format.setAccessibilityLabel("Export format"); mode.setAccessibilityLabel("Icon images to export")
        scaling.setAccessibilityLabel("Icon scaling quality"); slotPopup.setAccessibilityLabel("ICNS display size and scale")
        for control in [format, mode, scaling, slotPopup] { control.target = self; control.action = #selector(changed) }
        note.preferredMaxLayoutWidth = 510; note.widthAnchor.constraint(equalToConstant: 510).isActive = true
        changed()
    }
    func attach(to panel: NSSavePanel) {
        self.panel = panel; panel.accessoryView = view; panel.delegate = self; changed()
    }
    @objc private func changed() {
        let selectedFormat = ImageExportFormat(rawValue: format.indexOfSelectedItem) ?? .png
        if lastFormat != selectedFormat {
            let mac = selectedFormat == .icns
            modes = [.currentSize, mac ? .macSizes : .windowsSizes]
            if (mac && icnsSource != nil) || (!mac && source != nil) { modes.insert(.preserveOtherImages, at: 0) }
            mode.removeAllItems()
            mode.addItems(withTitles: modes.map {
                switch $0 {
                case .currentSize: return "Current size (\(width) × \(height))"
                case .windowsSizes: return "Windows size set (16–256 px)"
                case .macSizes: return "macOS set · standard + Retina"
                case .preserveOtherImages: return "Update opened icon · keep other images"
                }
            })
            if modes[0] == .currentSize && (mac ? slots.isEmpty : (width > 256 || height > 256)) { mode.selectItem(at: 1) }
            lastFormat = selectedFormat
        }
        let s = settings
        iconRow.isHidden = s.format != .ico && s.format != .icns
        scaling.isHidden = s.iconMode != .windowsSizes && s.iconMode != .macSizes
        slotPopup.isHidden = s.format != .icns || s.iconMode != .currentSize
        switch s.format {
        case .png, .tiff: note.stringValue = "Preserves the document RGB profile, 8/16-bit precision, resolution, and transparency."
        case .jpeg: note.stringValue = "Converts to 8-bit sRGB on a white background; preserves resolution."
        case .ico:
            switch s.iconMode {
            case .currentSize, .preserveOtherImages:
                if width > 256 || height > 256 { note.stringValue = "This canvas is too large for a single ICO image. Choose Windows size set or resize the canvas to 256 × 256 pixels or smaller." }
                else if s.iconMode == .preserveOtherImages { note.stringValue = "Replaces image \((source?.index ?? 0) + 1) in the original icon. Other images are copied unchanged." }
                else { note.stringValue = "One image at the current pixel dimensions, with transparency." }
            case .windowsSizes: note.stringValue = "Includes 16, 24, 32, 48, 64, 128 and 256 px images. Nonsquare artwork is fitted with transparent padding."
            case .macSizes: break
            }
        case .icns:
            switch s.iconMode {
            case .currentSize:
                note.stringValue = s.icnsSlot.map { "\($0.title). Display size and Retina scale identify the slot independently of pixel dimensions." }
                    ?? "This canvas has no matching ICNS slot. Choose the complete macOS set, or resize to a supported square size."
            case .macSizes: note.stringValue = "Includes 16, 32, 128, 256 and 512 pt slots, each at @1x and @2x (up to 1024 px). Nonsquare artwork gets transparent padding."
            case .preserveOtherImages:
                if let icnsSource {
                    do {
                        try ICNSCodec.validateReplacement(icnsSource, width: width, height: height)
                        let rep = icnsSource.file.representations[icnsSource.index]
                        note.stringValue = "Updates \(rep.slot.title). Other representations and metadata are preserved."
                    } catch { note.stringValue = error.localizedDescription }
                }
            case .windowsSizes: break
            }
        }
        view.frame = CGRect(origin: .zero, size: view.fittingSize)
        if let panel {
            panel.allowedContentTypes = [s.format.contentType]
            panel.nameFieldStringValue = (panel.nameFieldStringValue as NSString).deletingPathExtension + "." + s.format.fileExtension
        }
    }
    func panel(_ sender: Any, validate url: URL) throws {
        let s = settings
        if s.format == .ico && s.iconMode != .windowsSizes && (width > 256 || height > 256) { throw ICOError.invalidSize }
        if s.format == .icns {
            if s.iconMode == .currentSize && s.icnsSlot == nil { throw ICNSError.invalidSlot }
            if s.iconMode == .preserveOtherImages {
                guard let icnsSource else { throw ICNSError.invalidSlot }
                try ICNSCodec.validateReplacement(icnsSource, width: width, height: height)
            }
        }
    }
}
