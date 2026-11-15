import AppKit

/// Sheet previews are rendered separately from document state. Cancel and
/// slider drags never touch artwork, edited state, or the undo stack.
final class EffectLayerDialog: NSObject {
    private let alert = NSAlert()
    private(set) var settings: EffectSettings
    private var sliders: [String: NSSlider] = [:]
    private var fields: [String: NSTextField] = [:]
    var onPreview: ((EffectSettings) -> Void)?
    var onApply: ((EffectSettings) -> Void)?
    var onClose: (() -> Void)?
    var formView: NSView { alert.accessoryView! }

    init(settings: EffectSettings) {
        self.settings = settings; super.init()
        alert.messageText = settings.kind.title
        alert.informativeText = "Preview an editable effect on the layers below. Its mask, opacity, and group control where it applies."
        alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
        let form = NSStackView(); form.orientation = .vertical; form.alignment = .leading; form.spacing = 14
        func row(_ key: String, title: String, value: Double, min: Double, max: Double) {
            let label = NSTextField(labelWithString: title); label.widthAnchor.constraint(equalToConstant: 90).isActive = true
            let slider = NSSlider(value: value, minValue: min, maxValue: max, target: self, action: #selector(sliderChanged(_:)))
            slider.identifier = .init(key); slider.isContinuous = true; slider.setAccessibilityLabel(title)
            slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
            let field = NSTextField(string: String(format: "%.2f", value)); field.identifier = .init(key)
            let formatter = NumberFormatter(); formatter.minimum = NSNumber(value: min); formatter.maximum = NSNumber(value: max)
            formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 2; field.formatter = formatter
            field.target = self; field.action = #selector(fieldChanged(_:)); field.setAccessibilityLabel(title + " value")
            field.widthAnchor.constraint(equalToConstant: 66).isActive = true
            let line = NSStackView(views: [label, slider, field]); line.spacing = 10; line.alignment = .centerY
            form.addArrangedSubview(line); sliders[key] = slider; fields[key] = field
        }
        switch settings.kind {
        case .blur: row("radius", title: "Radius (px)", value: settings.radius, min: 0, max: 200)
        case .brightnessContrast:
            row("brightness", title: "Brightness", value: settings.brightness, min: -1, max: 1)
            row("contrast", title: "Contrast", value: settings.contrast, min: 0, max: 4)
        case .hueSaturation:
            row("hue", title: "Hue (°)", value: settings.hue, min: -180, max: 180)
            row("saturation", title: "Saturation", value: settings.saturation, min: 0, max: 2)
        case .grayscale, .invert:
            form.addArrangedSubview(NSTextField(labelWithString: "Adjust strength with layer opacity after applying."))
        }
        form.frame = CGRect(x: 0, y: 0, width: 370, height: settings.kind == .hueSaturation || settings.kind == .brightnessContrast ? 70 : 34)
        alert.accessoryView = form
    }
    func show(for window: NSWindow) {
        onPreview?(settings)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn, self.readFields() { self.onApply?(self.settings) }
            self.onClose?()
        }
    }
    func cancel() { alert.window.sheetParent?.endSheet(alert.window, returnCode: .alertSecondButtonReturn) }
    private func set(_ key: String, _ value: Double) {
        switch key {
        case "radius": settings.radius = value
        case "brightness": settings.brightness = value
        case "contrast": settings.contrast = value
        case "hue": settings.hue = value
        case "saturation": settings.saturation = value
        default: break
        }
    }
    @objc private func sliderChanged(_ slider: NSSlider) {
        guard let key = slider.identifier?.rawValue else { return }
        fields[key]?.doubleValue = slider.doubleValue; set(key, slider.doubleValue); onPreview?(settings)
    }
    @objc private func fieldChanged(_ field: NSTextField) {
        guard readFields() else { NSSound.beep(); return }; onPreview?(settings)
    }
    @discardableResult private func readFields() -> Bool {
        var next = settings
        for (key, field) in fields {
            guard let slider = sliders[key], field.doubleValue.isFinite,
                  (slider.minValue...slider.maxValue).contains(field.doubleValue) else { settings = next; return false }
            set(key, field.doubleValue)
        }
        if (try? settings.validate()) == nil { swap(&next, &settings); return false }
        for (key, slider) in sliders { slider.doubleValue = fields[key]!.doubleValue }
        return true
    }
}
