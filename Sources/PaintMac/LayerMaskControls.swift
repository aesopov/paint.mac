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
        guard !state.isEffectivelyLocked(state.activeID) else { return false }
        switch self {
        case .revealAll, .hideAll: return state.activeLayer.mask == nil
        case .fromSelection: return state.activeLayer.mask == nil && state.selection != nil
        case .apply: return state.activeLayer.mask != nil && (!state.activeLayer.isGroup || state.canModifySubtree(state.activeID)) && (state.activeLayer.effect == nil || state.canMergeDown)
        default: return state.activeLayer.mask != nil
        }
    }
    static func menu(target: AnyObject, action: Selector, state: DocumentState? = nil) -> NSMenu {
        let menu = NSMenu(title: "Layer Mask")
        for command in allCases {
            if command == .invert || command == .apply { menu.addItem(.separator()) }
            let item = NSMenuItem(title: command.title(in: state), action: action, keyEquivalent: "")
            switch command {
            case .revealAll, .hideAll, .fromSelection: item.image = EditorIcon.mask.image(size: 16)
            case .apply: item.image = EditorIcon.merge.image(size: 16)
            default: break
            }
            item.target = target; item.representedObject = command.rawValue
            if let state { item.isEnabled = command.isEnabled(in: state) }
            menu.addItem(item)
        }
        return menu
    }
}

/// Keep Option's meaning from the beginning of the native click, including
/// when the user releases the modifier before releasing the mouse button.
final class LayerMaskAddButton: NSButton {
    private var initialModifiers: NSEvent.ModifierFlags?
    var optionClick: Bool {
        (initialModifiers ?? NSApp.currentEvent?.modifierFlags ?? []).contains(.option)
    }
    override func mouseDown(with event: NSEvent) {
        initialModifiers = event.modifierFlags
        defer { initialModifiers = nil }
        super.mouseDown(with: event)
    }
}

final class LayerThumbnailButton: NSButton {
    private static let previewContext = ImageRenderer().context
    let layerID: UUID
    let editsMask: Bool
    private let preview: NSImage
    private let selected: Bool
    private let disabledMask: Bool
    private let showsTransparency: Bool

    init(layer: PaintLayer, mask: Bool, selected: Bool, target: AnyObject, action: Selector) {
        layerID = layer.id; editsMask = mask; self.selected = selected
        disabledMask = mask && !layer.maskEnabled
        showsTransparency = !mask && !layer.isGroup && layer.effect == nil
        if (layer.isGroup || layer.effect != nil) && !mask {
            preview = layer.isGroup ? NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Layer group")! : EditorIcon.effects.image(description: "Effect layer")
        } else {
            let raster = mask ? layer.mask!.editingRaster : layer.raster
            let scale = min(1, min(80 / CGFloat(raster.width), 64 / CGFloat(raster.height)))
            let size = CGSize(width: max(1, ceil(CGFloat(raster.width) * scale)), height: max(1, ceil(CGFloat(raster.height) * scale)))
            let pixels = raster.ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let image = Self.previewContext.createCGImage(pixels, from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: RGBProfile.displayP3.space)!
            preview = NSImage(cgImage: image, size: size)
        }
        super.init(frame: .zero)
        self.target = target; self.action = action; isBordered = false
        let kind = layer.isGroup ? "group" : (layer.effect != nil ? "effect layer" : (layer.text != nil ? "text layer" : "image layer"))
        setAccessibilityLabel(mask ? "Edit mask for \(layer.name)" : "Select \(kind) \(layer.name)")
        toolTip = mask ? "Edit layer mask: black hides, white reveals.\(disabledMask ? " Mask is disabled." : "")"
            : (layer.isGroup ? "Select group. Move moves its contents and masks together. Drawing creates a paint layer inside the group."
               : (layer.text != nil ? "Double-click to edit text. Rasterize Text Layer enables pixel painting."
                  : (layer.effect != nil ? "Double-click to edit effect settings. Its mask controls where the effect applies."
                     : "Edit image pixels. Move moves the image and its mask together.")))
        widthAnchor.constraint(equalToConstant: 44).isActive = true
        heightAnchor.constraint(equalToConstant: 36).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    // The table handles pointer clicks and drags; keep native button actions
    // available for accessibility and keyboard activation.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor(calibratedWhite: showsTransparency ? 0.94 : 0.9, alpha: 1).setFill(); rect.fill()
        if showsTransparency {
            NSColor(calibratedWhite: 0.76, alpha: 1).setFill()
            let tile: CGFloat = 4
            for y in 0..<Int(ceil(rect.height / tile)) {
                for x in 0..<Int(ceil(rect.width / tile)) where (x + y) % 2 == 0 {
                    NSRect(x: rect.minX + CGFloat(x) * tile, y: rect.minY + CGFloat(y) * tile, width: tile, height: tile).fill()
                }
            }
        }
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
