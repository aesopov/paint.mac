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
    var format = RGBFormat.standard
    var resolution = ImageResolution.standard
    /// Bottom to top, matching the order used for compositing.
    var layers: [PaintLayer]
    var activeID: UUID { didSet { if activeID != oldValue { editingMask = false } } }
    var editingMask = false
    var selection: SelectionMask? = nil

    init(width: Int = 1200, height: Int = 800, format: RGBFormat = .standard, resolution: ImageResolution = .standard) {
        self.width = width; self.height = height; self.format = format; self.resolution = resolution
        let background = PaintLayer(name: "Background", raster: Raster(width: width, height: height, color: .white, format: format))
        let layer = PaintLayer(name: "Layer 1", raster: Raster(width: width, height: height, format: format))
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
    var format: RGBFormat? = nil
    var resolution: ImageResolution? = nil
}

enum ProjectCodec {
    static func encode(_ state: DocumentState) throws -> FileWrapper {
        try state.validateLayerTree()
        try state.format.validate(); try state.resolution.validate()
        let extended = state.format != .standard || state.resolution != .standard
        var children: [String: FileWrapper] = [:]
        var layers: [ProjectManifest.Layer] = []
        for layer in state.layers {
            let filename = (layer.isGroup || layer.effect != nil) ? "" : "\(layer.id.uuidString).\(extended ? "rgba" : "png")"
            if !layer.isGroup && layer.effect == nil {
                guard layer.raster.format == state.format else { throw PaintError.invalidProject }
                let data = try extended ? layer.raster.bytes : imageData(layer.raster.cgImage, type: UTType.png.identifier)
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
        let version = extended ? 6 : state.layers.contains { $0.isLocked } ? 5 : state.layers.contains { $0.text != nil || $0.effect != nil } ? 4 : state.layers.contains { $0.isGroup || $0.parentID != nil || $0.isClipped } ? 3 : (state.layers.contains { $0.mask != nil } ? 2 : 1)
        var manifest = ProjectManifest(version: version, width: state.width, height: state.height,
                                       activeID: state.activeID, layers: layers)
        manifest.format = extended ? state.format : nil; manifest.resolution = extended ? state.resolution : nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        children["document.json"] = FileWrapper(regularFileWithContents: try encoder.encode(manifest))
        return FileWrapper(directoryWithFileWrappers: children)
    }

    static func decode(_ wrapper: FileWrapper) throws -> DocumentState {
        guard let children = wrapper.fileWrappers,
              let data = children["document.json"]?.regularFileContents else { throw PaintError.invalidProject }
        let manifest = try JSONDecoder().decode(ProjectManifest.self, from: data)
        guard (1...6).contains(manifest.version), manifest.width > 0, manifest.height > 0,
              manifest.width <= 8192, manifest.height <= 8192,
              manifest.width * manifest.height <= 32_000_000,
              !manifest.layers.isEmpty, manifest.layers.count <= 32,
              Set(manifest.layers.map(\.id)).count == manifest.layers.count,
              manifest.layers.contains(where: { $0.id == manifest.activeID }) else { throw PaintError.invalidProject }
        guard manifest.version >= 6 || (manifest.format == nil && manifest.resolution == nil) else { throw PaintError.invalidProject }
        guard manifest.version < 6 || (manifest.format != nil && manifest.resolution != nil) else { throw PaintError.invalidProject }
        let format = manifest.format ?? .standard, resolution = manifest.resolution ?? .standard
        try format.validate(); try resolution.validate()
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
                raster = Raster(width: manifest.width, height: manifest.height, format: format)
            } else {
                guard let data = children[layer.file]?.regularFileContents else { throw PaintError.invalidProject }
                if manifest.version >= 6 {
                    guard layer.file == "\(layer.id.uuidString).rgba", data.count == manifest.width * manifest.height * format.depth.bytesPerPixel else { throw PaintError.invalidProject }
                    var pixels = Raster(width: manifest.width, height: manifest.height, format: format)
                    pixels.bytes = data; pixels.resolution = resolution; raster = pixels
                } else { raster = try decodeImage(data).converted(to: .standard) }
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
        state.format = format; state.resolution = resolution
        state.layers = layers; state.activeID = manifest.activeID
        try state.validateLayerTree()
        try state.format.validate(); try state.resolution.validate()
        return state
    }

    static func decodeImage(_ data: Data) throws -> Raster {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw PaintError.invalidImage }
        guard width <= 8192, height <= 8192, width * height <= 32_000_000 else { throw PaintError.imageTooLarge }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary) else { throw PaintError.invalidImage }
        let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
        let format = RGBFormat(profile: .imported(image.colorSpace), depth: image.bitsPerComponent > 8 ? .sixteen : .eight)
        let oriented: CGImage
        if (2...8).contains(orientation) {
            let graph = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation))
            oriented = ImageRenderer().cgImage(graph, format: format)
        } else { oriented = image }
        var raster = try Raster(image: oriented, format: format)
        let dx = (props[kCGImagePropertyDPIWidth] as? Double) ?? 72
        let dy = (props[kCGImagePropertyDPIHeight] as? Double) ?? dx
        let resolution = ImageResolution(x: dx, y: dy)
        if (try? resolution.validate()) != nil { raster.resolution = orientation >= 5 && orientation <= 8 ? ImageResolution(x: dy, y: dx) : resolution }
        return raster
    }

    static func imageData(_ image: CGImage, type: String, resolution: ImageResolution = .standard) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { throw PaintError.invalidImage }
        var properties = resolution.properties
        properties[kCGImageDestinationLossyCompressionQuality] = 0.92
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PaintError.invalidImage }
        return data as Data
    }
}

@objc(PaintDocument)
final class PaintDocument: NSDocument {
    static let typeName = "com.aesopov.paintmac.project"
    var historyCache = HistoryTileCache() {
        didSet { oldValue.shutdown(); configureHistoryCache() }
    }
    private var historyActions: [WeakHistoryAction] = []
    private var historyGroup: UInt64 = 0
    private var historyObserver: NSObjectProtocol?
    private(set) var lastHistoryError: Error?
    var onHistoryNotice: ((String) -> Void)?
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
        undoManager?.levelsOfUndo = 0
        configureHistoryCache()
        historyObserver = NotificationCenter.default.addObserver(forName: .NSUndoManagerDidCloseUndoGroup, object: undoManager, queue: .main) { [weak self] _ in
            guard let self, self.undoManager?.groupingLevel == 0 else { return }
            self.historyGroup &+= 1
            DispatchQueue.main.async { [weak self] in self?.trimHistory() }
        }
    }

    override class var autosavesInPlace: Bool { true }
    override var windowNibName: NSNib.Name? { nil }

    override func makeWindowControllers() {
        addWindowController(EditorWindowController(document: self))
    }

    var composite: CGImage {
        if let imageCache { return imageCache }
        let image = renderer.cgImage(compositeImage, format: state.format)
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

    private func configureHistoryCache() {
        historyCache.onBudgetChange = { [weak self] in self?.trimHistory() }
    }
    /// Register one metadata/tile-ID snapshot per user operation. Pixel versions
    /// are compressed on the cache queue, never in the input callback.
    func commit(_ previous: DocumentState, name: String) {
        guard previous != state else { return }
        registerHistory(previous, name: name)
        invalidate()
    }
    private func registerHistory(_ state: DocumentState, name: String) {
        guard let manager = undoManager, manager.isUndoRegistrationEnabled else { return }
        let action = TileHistoryAction(document: self, snapshot: HistorySnapshot(state, cache: historyCache), name: name, group: historyGroup)
        manager.registerUndo(withTarget: action) { [action] _ in action.perform() }
        manager.setActionName(name); historyActions.append(WeakHistoryAction(action))
    }
    func restoreHistory(_ snapshot: HistorySnapshot, name: String) {
        do {
            // Load and validate every needed tile before changing any state.
            let restored = try snapshot.restored()
            registerHistory(state, name: name)
            state = restored; invalidate()
        } catch {
            lastHistoryError = error
            // Native undo bookkeeping still advances after a failed handler.
            // Keep unsaved artwork marked dirty even when no inverse was made.
            updateChangeCount(.changeDone)
            onHistoryNotice?("This undo step could not be read from disk. The current canvas is unchanged.")
            if let window = windowControllers.first?.window { NSAlert(error: error).beginSheetModal(for: window) }
            else { NSLog("Paint.MAC undo cache: %@", error.localizedDescription) }
        }
    }
    /// Remove complete native undo groups, including any redo counterparts.
    /// Metadata has a separate cap, since tile budgets don't cover text strings.
    func trimHistory() {
        historyActions.removeAll { $0.action == nil }
        while true {
            let live = historyActions.compactMap(\.action).filter { $0.snapshot != nil }
            let stats = historyCache.statistics
            let metadataBytes = live.reduce(0) { $0 + ($1.snapshot?.metadataBytes ?? 0) }
            let failedDiskOverRAM = historyCache.lastError != nil && stats.residentBytes > historyCache.memoryBudget
            guard stats.diskBytes > historyCache.diskBudget || failedDiskOverRAM || metadataBytes > 16 * 1024 * 1024 || live.count > 500,
                  let oldest = live.first, oldest.group < historyGroup else { break }
            for action in live where action.group == oldest.group {
                undoManager?.removeAllActions(withTarget: action); action.snapshot = nil
            }
            historyActions.removeAll { $0.action?.snapshot == nil }
        }
        if let error = historyCache.lastError, lastHistoryError == nil {
            lastHistoryError = error
            onHistoryNotice?("Disk undo cache is unavailable. Undo history is limited to its RAM budget.")
        }
    }
    override func close() {
        undoManager?.removeAllActions(); historyActions.removeAll()
        historyCache.shutdown(); super.close()
    }
    deinit { if let historyObserver { NotificationCenter.default.removeObserver(historyObserver) } }

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
        let decoded = try ProjectCodec.decode(fileWrapper)
        undoManager?.removeAllActions(); historyActions.removeAll()
        state = decoded; invalidate()
    }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] { [Self.typeName] }

    func export(to url: URL, jpeg: Bool) throws {
        try export(to: url, settings: ImageExportSettings(format: jpeg ? .jpeg : .png))
    }

    func export(to url: URL, settings: ImageExportSettings) throws {
        finishPendingEdits?()
        var raster = try Raster(image: composite, format: state.format)
        raster.resolution = state.resolution
        let data = try ImageFileIO.encode(raster, settings: settings, iconSource: iconSource, icnsSource: icnsSource)
        try data.write(to: url, options: .atomic)
    }
}
