import AppKit

/// An explicitly licensed subset of Adobe Spectrum 1.7.0. Templates remain
/// vector PDFs, with native AppKit tinting for light/dark and disabled states.
enum EditorIcon: String, CaseIterable {
    case brush = "Brush", erase = "Erase", rectangleSelect = "RectSelect", ellipseSelect = "SelectCircular"
    case move = "SelectionMove", fill = "ColorFill", sampler = "Sampler", line = "Line"
    case rectangle = "Rectangle", ellipse = "Ellipse", text = "Text", crop = "Crop"
    case merge = "MergeLayers", group = "Group", ungroup = "Ungroup", duplicate = "Duplicate"
    case rename = "Rename", effects = "Effects", forward = "LayersForward", backward = "LayersBackward"
    case layers = "Layers", mask = "InvertAdj"

    static var resourceBundle: Bundle {
        // App bundles contain their own resource bundle; never rely on the
        // developer's build directory when running a packaged application.
        if let url = Bundle.main.resourceURL?.appendingPathComponent("PaintMac_PaintMac.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return .module // SwiftPM executable and test runs.
    }
    private static var images: [EditorIcon: NSImage] = [:]
    func image(size: CGFloat = 18, description: String? = nil) -> NSImage {
        let original: NSImage
        if let cached = Self.images[self] { original = cached }
        else {
            guard let url = Self.resourceBundle.url(forResource: rawValue, withExtension: "pdf", subdirectory: "Spectrum"),
                  let image = NSImage(contentsOf: url) else { preconditionFailure("Missing Spectrum icon: \(rawValue)") }
            image.isTemplate = true; Self.images[self] = image; original = image
        }
        let result = original.copy() as! NSImage
        result.size = NSSize(width: size, height: size); result.accessibilityDescription = description
        return result
    }
    static func forAction(_ action: Selector, size: CGFloat = 16) -> NSImage? {
        let icon: EditorIcon?
        switch NSStringFromSelector(action) {
        case "mergeDown", "mergeGroup", "mergeSelected": icon = .merge
        case "groupSelected", "newGroup": icon = .group
        case "ungroup": icon = .ungroup
        case "duplicateLayer": icon = .duplicate
        case "renameLayer": icon = .rename
        case "layerUp": icon = .forward
        case "layerDown": icon = .backward
        case "addEffectLayer:": icon = .effects
        case "rasterizeTextLayer": icon = .text
        default: icon = nil
        }
        return icon?.image(size: size)
    }
    /// NSImage.draw doesn't automatically tint template PDFs like NSButton does.
    /// Apply the semantic color at draw time so flyouts follow their appearance.
    static func draw(_ image: NSImage, in rect: CGRect, color: NSColor = .labelColor) {
        let tinted = NSImage(size: image.size, flipped: false) { bounds in
            image.draw(in: bounds)
            color.setFill(); bounds.fill(using: .sourceIn)
            return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

extension PaintTool {
    var editorIcon: EditorIcon? {
        switch self {
        case .brush: return .brush
        case .eraser: return .erase
        case .selection: return .rectangleSelect
        case .ellipseSelect: return .ellipseSelect
        case .move: return .move
        case .fill: return .fill
        case .eyedropper: return .sampler
        case .line: return .line
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .text: return .text
        case .crop: return .crop
        case .lasso, .hand, .blur, .sharpen, .smudge: return nil
        }
    }
    var icon: NSImage {
        editorIcon?.image(description: title) ?? NSImage(systemSymbolName: symbol, accessibilityDescription: title)!
    }
}
