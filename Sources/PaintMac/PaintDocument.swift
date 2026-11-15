import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

struct PaintLayer: Equatable {
    let id: UUID
    var name: String
    var raster: Raster
    var visible = true
    var opacity = 1.0
    var mask: SelectionMask?
    var maskEnabled = true
    var isGroup = false
    var parentID: UUID?
    var isClipped = false
    var expanded = true
    var isLocked = false
    var text: TextLayerContent?
    var textClip: SelectionMask?
    var effect: EffectSettings?

    var displayRaster: Raster {
        maskEnabled ? mask.map { raster.masked(using: $0) } ?? raster : raster
    }

    init(name: String, raster: Raster) {
        id = UUID(); self.name = name; self.raster = raster
    }

    init(id: UUID, name: String, raster: Raster, visible: Bool, opacity: Double) {
        self.id = id; self.name = name; self.raster = raster
        self.visible = visible; self.opacity = opacity
    }
}

struct DocumentState: Equatable {
    var width: Int
    var height: Int
    /// Bottom to top, matching the order used for compositing.
    var layers: [PaintLayer]
    var activeID: UUID { didSet { if activeID != oldValue { editingMask = false } } }
    var editingMask = false
    var selection: SelectionMask? = nil

    init(width: Int = 1200, height: Int = 800) {
        self.width = width; self.height = height
        let background = PaintLayer(name: "Background", raster: Raster(width: width, height: height, color: .white))
        let layer = PaintLayer(name: "Layer 1", raster: Raster(width: width, height: height))
        layers = [background, layer]; activeID = layer.id
    }

    var activeIndex: Int { layers.firstIndex(where: { $0.id == activeID }) ?? layers.count - 1 }
    var activeLayer: PaintLayer {
        get { layers[activeIndex] }
        set { layers[activeIndex] = newValue }
    }
    var isEditingMask: Bool { editingMask && activeLayer.mask != nil }
    var editingRaster: Raster {
        get { isEditingMask ? activeLayer.mask!.editingRaster : activeLayer.raster }
        set {
            if isEditingMask { layers[activeIndex].mask = SelectionMask(editingRaster: newValue) }
            else { layers[activeIndex].raster = newValue }
        }
    }
    mutating func editRaster(_ change: (inout Raster) -> Void) {
        guard canPaintTarget else { return }
        var raster = editingRaster
        change(&raster)
        editingRaster = raster
    }
}

struct ProjectManifest: Codable {
    struct Layer: Codable {
        var id: UUID
        var name: String
        var visible: Bool
        var opacity: Double
        var file: String
        var maskFile: String? = nil
        var maskEnabled: Bool? = nil
        var isGroup: Bool? = nil
        var parentID: UUID? = nil
        var isClipped: Bool? = nil
        var expanded: Bool? = nil
        var text: TextLayerContent? = nil
        var textClipFile: String? = nil
        var isLocked: Bool? = nil
        var effect: EffectSettings? = nil
    }
    var version: Int
    var width: Int
    var height: Int
    var activeID: UUID
    var layers: [Layer]
}

enum ProjectCodec {
    static func encode(_ state: DocumentState) throws -> FileWrapper {
        try state.validateLayerTree()
        var children: [String: FileWrapper] = [:]
        var layers: [ProjectManifest.Layer] = []
        for layer in state.layers {
            let filename = (layer.isGroup || layer.effect != nil) ? "" : "\(layer.id.uuidString).png"
            if !layer.isGroup && layer.effect == nil {
                let data = try imageData(layer.raster.cgImage, type: UTType.png.identifier)
                children[filename] = FileWrapper(regularFileWithContents: data)
            }
            var record = ProjectManifest.Layer(id: layer.id, name: layer.name, visible: layer.visible,
                                               opacity: layer.opacity, file: filename)
            record.isGroup = layer.isGroup ? true : nil; record.parentID = layer.parentID
            record.isClipped = layer.isClipped ? true : nil; record.expanded = layer.isGroup ? layer.expanded : nil
            if let mask = layer.mask {
                guard mask.width == state.width, mask.height == state.height else { throw PaintError.invalidProject }
                let maskFile = "\(layer.id.uuidString).mask"
                children[maskFile] = FileWrapper(regularFileWithContents: mask.coverage)
                record.maskFile = maskFile; record.maskEnabled = layer.maskEnabled
            }
            record.isLocked = layer.isLocked ? true : nil
            record.text = layer.text; record.effect = layer.effect
            if let clip = layer.textClip {
                let file = "\(layer.id.uuidString).text-mask"
                guard layer.text != nil, clip.width == state.width, clip.height == state.height else { throw PaintError.invalidProject }
                children[file] = FileWrapper(regularFileWithContents: clip.coverage); record.textClipFile = file
            }
            layers.append(record)
        }
        let version = state.layers.contains { $0.isLocked } ? 5 : state.layers.contains { $0.text != nil || $0.effect != nil } ? 4 : state.layers.contains { $0.isGroup || $0.parentID != nil || $0.isClipped } ? 3 : (state.layers.contains { $0.mask != nil } ? 2 : 1)
        let manifest = ProjectManifest(version: version, width: state.width, height: state.height,
                                       activeID: state.activeID, layers: layers)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        children["document.json"] = FileWrapper(regularFileWithContents: try encoder.encode(manifest))
        return FileWrapper(directoryWithFileWrappers: children)
    }

    static func decode(_ wrapper: FileWrapper) throws -> DocumentState {
        guard let children = wrapper.fileWrappers,
              let data = children["document.json"]?.regularFileContents else { throw PaintError.invalidProject }
        let manifest = try JSONDecoder().decode(ProjectManifest.self, from: data)
        guard (1...5).contains(manifest.version), manifest.width > 0, manifest.height > 0,
              manifest.width <= 8192, manifest.height <= 8192,
              manifest.width * manifest.height <= 32_000_000,
              !manifest.layers.isEmpty, manifest.layers.count <= 32,
              Set(manifest.layers.map(\.id)).count == manifest.layers.count,
              manifest.layers.contains(where: { $0.id == manifest.activeID }) else { throw PaintError.invalidProject }
        var layers: [PaintLayer] = []
        for layer in manifest.layers {
            guard layer.opacity.isFinite, (0...1).contains(layer.opacity) else { throw PaintError.invalidProject }
            if manifest.version < 3, layer.isGroup != nil || layer.parentID != nil || layer.isClipped != nil || layer.expanded != nil { throw PaintError.invalidProject }
            if manifest.version < 4, layer.text != nil || layer.textClipFile != nil || layer.effect != nil { throw PaintError.invalidProject }
            if manifest.version < 5, layer.isLocked != nil { throw PaintError.invalidProject }
            let kinds = (layer.isGroup == true ? 1 : 0) + (layer.text != nil ? 1 : 0) + (layer.effect != nil ? 1 : 0)
            guard kinds <= 1 else { throw PaintError.invalidProject }
            try layer.text?.validate(); try layer.effect?.validate()
            let raster: Raster
            if layer.isGroup == true || layer.effect != nil {
                guard layer.file.isEmpty else { throw PaintError.invalidProject }
                raster = Raster(width: manifest.width, height: manifest.height)
            } else {
                guard let png = children[layer.file]?.regularFileContents else { throw PaintError.invalidProject }
                raster = try decodeImage(png)
            }
            guard raster.width == manifest.width, raster.height == manifest.height else { throw PaintError.invalidProject }
            var decoded = PaintLayer(id: layer.id, name: layer.name, raster: raster,
                                     visible: layer.visible, opacity: layer.opacity)
            decoded.isLocked = layer.isLocked ?? false
            decoded.text = layer.text; decoded.effect = layer.effect
            if let file = layer.textClipFile {
                guard layer.text != nil, file == "\(layer.id.uuidString).text-mask", let payload = children[file]?.regularFileContents, payload.count == manifest.width * manifest.height else { throw PaintError.invalidProject }
                decoded.textClip = SelectionMask(width: manifest.width, height: manifest.height, coverage: payload)
            }
            decoded.isGroup = layer.isGroup ?? false; decoded.parentID = layer.parentID
            decoded.isClipped = layer.isClipped ?? false; decoded.expanded = layer.expanded ?? true
            if let maskFile = layer.maskFile {
                guard manifest.version >= 2, maskFile == "\(layer.id.uuidString).mask",
                      let data = children[maskFile]?.regularFileContents,
                      data.count == manifest.width * manifest.height else { throw PaintError.invalidProject }
                decoded.mask = SelectionMask(width: manifest.width, height: manifest.height, coverage: data)
                decoded.maskEnabled = layer.maskEnabled ?? true
            } else if layer.maskEnabled != nil { throw PaintError.invalidProject }
            layers.append(decoded)
        }
        var state = DocumentState(width: 1, height: 1)
        state.width = manifest.width; state.height = manifest.height
        state.layers = layers; state.activeID = manifest.activeID
        try state.validateLayerTree()
        return state
    }

    static func decodeImage(_ data: Data) throws -> Raster {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw PaintError.invalidImage }
        guard width <= 8192, height <= 8192, width * height <= 32_000_000 else { throw PaintError.imageTooLarge }
        // ImageIO applies EXIF orientation for photographs before they enter the document.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw PaintError.invalidImage }
        return try Raster(image: image)
    }

    static func imageData(_ image: CGImage, type: String) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { throw PaintError.invalidImage }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PaintError.invalidImage }
        return data as Data
    }
}

@objc(PaintDocument)
final class PaintDocument: NSDocument {
    static let typeName = "com.aesopov.paintmac.project"
    var state = DocumentState()
    let renderer = ImageRenderer()
    private(set) var imageCache: CGImage?
    private var compositionCache: CIImage?
    var onChange: (() -> Void)?
    var finishPendingEdits: (() -> Void)?
    var icnsSource: ICNSSource?
    var iconSource: IconSource? // import/export context; never part of compositing or project history

    override init() {
        super.init()
        fileType = Self.typeName
        hasUndoManager = true
        undoManager?.levelsOfUndo = 40
    }

    override class var autosavesInPlace: Bool { true }
    override var windowNibName: NSNib.Name? { nil }

    override func makeWindowControllers() {
        addWindowController(EditorWindowController(document: self))
    }

    var composite: CGImage {
        if let imageCache { return imageCache }
        let image = renderer.cgImage(compositeImage)
        imageCache = image
        return image
    }

    var compositeImage: CIImage {
        if let compositionCache { return compositionCache }
        let image = renderer.compositeImage(state.layers, width: state.width, height: state.height)
        compositionCache = image
        return image
    }

    func invalidate() { imageCache = nil; compositionCache = nil; onChange?() }

    /// Register once per user gesture; pixel Data is copied only on mutation.
    func commit(_ previous: DocumentState, name: String) {
        guard previous != state else { return }
        undoManager?.registerUndo(withTarget: self) { $0.restore(previous, name: name) }
        undoManager?.setActionName(name)
        invalidate()
    }

    private func restore(_ snapshot: DocumentState, name: String) {
        let current = state
        undoManager?.registerUndo(withTarget: self) { $0.restore(current, name: name) }
        undoManager?.setActionName(name)
        state = snapshot
        invalidate()
    }

    func edit(_ name: String, protectLockedLayers: Bool = true, _ change: (inout DocumentState) -> Void) {
        finishPendingEdits?()
        let previous = state
        change(&state)
        if protectLockedLayers && !previous.permitsLockedLayerChanges(to: state) { state = previous; return }
        commit(previous, name: name)
    }

    override func save(_ sender: Any?) { finishPendingEdits?(); super.save(sender) }
    override func saveAs(_ sender: Any?) { finishPendingEdits?(); super.saveAs(sender) }
    override func fileWrapper(ofType typeName: String) throws -> FileWrapper { try ProjectCodec.encode(state) }

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        state = try ProjectCodec.decode(fileWrapper)
        invalidate()
    }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] { [Self.typeName] }

    func export(to url: URL, jpeg: Bool) throws {
        try export(to: url, settings: ImageExportSettings(format: jpeg ? .jpeg : .png))
    }

    func export(to url: URL, settings: ImageExportSettings) throws {
        finishPendingEdits?()
        let raster = try Raster(image: composite)
        let data = try ImageFileIO.encode(raster, settings: settings, iconSource: iconSource, icnsSource: icnsSource)
        try data.write(to: url, options: .atomic)
    }
}
