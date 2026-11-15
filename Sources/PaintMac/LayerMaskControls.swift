import AppKit

enum LayerMaskCommand: String, CaseIterable {
    case revealAll, hideAll, fromSelection, invert, feather, toggle, apply, delete
    func title(in state: DocumentState?) -> String {
        switch self {
        case .revealAll: return "Add Mask — Reveal All"
        case .hideAll: return "Add Mask — Hide All"
        case .fromSelection: return "Mask from Selection"
        case .invert: return "Invert Mask"
        case .feather: return "Feather Mask…"
        case .toggle: return state?.activeLayer.maskEnabled == false ? "Enable Mask" : "Disable Mask"
        case .apply:
            if state?.activeLayer.isGroup == true { return "Apply Mask & Merge Group" }
            if state?.activeLayer.effect != nil { return "Apply Mask & Merge Below" }
            return state?.activeLayer.text != nil ? "Apply Mask & Rasterize Text" : "Apply Mask"
        case .delete: return "Delete Mask"
        }
    }
    func isEnabled(in state: DocumentState) -> Bool {
        switch self {
        case .revealAll, .hideAll: return state.activeLayer.mask == nil
        case .fromSelection: return state.activeLayer.mask == nil && state.selection != nil
        case .apply: return state.activeLayer.mask != nil && (state.activeLayer.effect == nil || state.canMergeDown)
        default: return state.activeLayer.mask != nil
        }
    }
    static func menu(target: AnyObject, action: Selector, state: DocumentState? = nil) -> NSMenu {
        let menu = NSMenu(title: "Layer Mask")
        for command in allCases {
            if command == .invert || command == .apply { menu.addItem(.separator()) }
            let item = NSMenuItem(title: command.title(in: state), action: action, keyEquivalent: "")
            item.target = target; item.representedObject = command.rawValue
            if let state { item.isEnabled = command.isEnabled(in: state) }
            menu.addItem(item)
        }
        return menu
    }
}

final class LayerThumbnailButton: NSButton {
    let layerID: UUID
    let editsMask: Bool
    private let preview: NSImage
    private let selected: Bool
    private let disabledMask: Bool

    init(layer: PaintLayer, mask: Bool, selected: Bool, target: AnyObject, action: Selector) {
        layerID = layer.id; editsMask = mask; self.selected = selected
        disabledMask = mask && !layer.maskEnabled
        if (layer.isGroup || layer.effect != nil) && !mask {
            preview = NSImage(systemSymbolName: layer.isGroup ? "folder.fill" : "camera.filters", accessibilityDescription: layer.isGroup ? "Layer group" : "Effect layer")!
        } else {
            let image = mask ? layer.mask!.editingRaster.cgImage : layer.raster.cgImage
            preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        super.init(frame: .zero)
        self.target = target; self.action = action; isBordered = false
        let kind = layer.isGroup ? "group" : (layer.effect != nil ? "effect layer" : (layer.text != nil ? "text layer" : "image layer"))
        setAccessibilityLabel(mask ? "Edit mask for \(layer.name)" : "Select \(kind) \(layer.name)")
        toolTip = mask ? "Edit layer mask: black hides, white reveals.\(disabledMask ? " Mask is disabled." : "")"
            : (layer.isGroup ? "Select group. Move moves its contents and masks together. Add a layer inside the group to paint."
               : (layer.text != nil ? "Double-click to edit text. Rasterize Text Layer enables pixel painting."
                  : (layer.effect != nil ? "Double-click to edit effect settings. Its mask controls where the effect applies."
                     : "Edit image pixels. Move moves the image and its mask together.")))
        widthAnchor.constraint(equalToConstant: mask ? 32 : 44).isActive = true
        heightAnchor.constraint(equalToConstant: 36).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor(calibratedWhite: 0.9, alpha: 1).setFill(); rect.fill()
        let scale = min(rect.width / preview.size.width, rect.height / preview.size.height)
        let size = NSSize(width: preview.size.width * scale, height: preview.size.height * scale)
        preview.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        (selected ? NSColor.controlAccentColor : .separatorColor).setStroke()
        path.lineWidth = selected ? 2 : 1; path.stroke()
        if disabledMask {
            NSColor.systemRed.setStroke()
            let slash = NSBezierPath(); slash.move(to: CGPoint(x: rect.minX, y: rect.minY))
            slash.line(to: CGPoint(x: rect.maxX, y: rect.maxY)); slash.lineWidth = 2; slash.stroke()
        }
    }
}
