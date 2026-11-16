import AppKit

struct PrintSizePlan {
    let width: Int, height: Int
    let resolution: ImageResolution
    static func make(widthInches: Double, heightInches: Double, resolution: ImageResolution,
                     resample: Bool, originalWidth: Int, originalHeight: Int) throws -> Self {
        try resolution.validate()
        guard widthInches.isFinite, heightInches.isFinite, widthInches > 0, heightInches > 0 else { throw PaintError.invalidResolution }
        if !resample {
            let dpi = ImageResolution(x: Double(originalWidth) / widthInches, y: Double(originalHeight) / heightInches)
            try dpi.validate()
            return Self(width: originalWidth, height: originalHeight, resolution: dpi)
        }
        let w = widthInches * resolution.x, h = heightInches * resolution.y
        guard w.isFinite, h.isFinite, w >= 0.5, h >= 0.5, w <= 8192.49, h <= 8192.49 else { throw PaintError.imageTooLarge }
        let width = Int(w.rounded()), height = Int(h.rounded())
        try CanvasSizePlan.validate(width: width, height: height)
        return Self(width: width, height: height, resolution: resolution)
    }
}

final class ImagePropertiesDialog: NSObject, NSTextFieldDelegate {
    private let alert = NSAlert()
    private let profiles: [RGBProfile]
    private let profile = NSPopUpButton(), depth = NSPopUpButton(), units = NSPopUpButton()
    private let dpiX = NSTextField(), dpiY = NSTextField(), printWidth = NSTextField(), printHeight = NSTextField()
    private let resample = NSButton(checkboxWithTitle: "Resample pixels", target: nil, action: nil)
    private let smooth = NSPopUpButton()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let original: DocumentState
    private var plan: PrintSizePlan
    private var widthInches: Double, heightInches: Double
    var onApply: ((RGBFormat, ImageResolution, CGSize?, Bool) -> Void)?
    var formView: NSView { alert.accessoryView! }
    init(state: DocumentState) {
        original = state
        widthInches = Double(state.width) / state.resolution.x; heightInches = Double(state.height) / state.resolution.y
        plan = PrintSizePlan(width: state.width, height: state.height, resolution: state.resolution)
        profiles = RGBProfile.standard.contains(state.format.profile) ? RGBProfile.standard : RGBProfile.standard + [state.format.profile]
        super.init()
        alert.messageText = "Color & Resolution"
        alert.informativeText = "Convert colors to the selected RGB profile. Changing resolution without resampling changes print size only."
        alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
        profile.addItems(withTitles: profiles.map(\.name)); profile.selectItem(at: profiles.firstIndex(of: state.format.profile)!)
        depth.addItems(withTitles: RGBDepth.allCases.map(\.title)); depth.selectItem(at: state.format.depth == .eight ? 0 : 1)
        units.addItems(withTitles: ["Inches", "Centimeters"])
        smooth.addItems(withTitles: ["Smooth", "Sharp (nearest neighbor)"]); smooth.isEnabled = false
        dpiX.doubleValue = state.resolution.x; dpiY.doubleValue = state.resolution.y
        for (field, label) in zip([dpiX, dpiY, printWidth, printHeight], ["Horizontal resolution", "Vertical resolution", "Print width", "Print height"]) {
            field.delegate = self; field.setAccessibilityLabel(label)
            field.widthAnchor.constraint(equalToConstant: 100).isActive = true
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }
        for (control, label) in zip([profile, depth, units], ["RGB profile", "Color precision", "Print size units"]) {
            control.setAccessibilityLabel(label); control.target = self; control.action = #selector(optionsChanged(_:))
        }
        resample.target = self; resample.action = #selector(optionsChanged(_:))
        func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }
        let grid = NSGridView(views: [[label("RGB profile"), profile], [label("Precision"), depth],
                                     [label("Horizontal PPI"), dpiX], [label("Vertical PPI"), dpiY],
                                     [label("Print width"), printWidth], [label("Print height"), printHeight],
                                     [label("Print units"), units]])
        grid.rowSpacing = 12; grid.columnSpacing = 16
        let root = NSStackView(views: [grid, resample, smooth, summary]); root.orientation = .vertical
        root.alignment = .leading; root.spacing = 14
        summary.preferredMaxLayoutWidth = 430; summary.widthAnchor.constraint(equalToConstant: 430).isActive = true
        writePrintSize(); update()
        root.frame = CGRect(origin: .zero, size: root.fittingSize); alert.accessoryView = root
    }
    private var factor: Double { units.indexOfSelectedItem == 1 ? 2.54 : 1 }
    private func writePrintSize() {
        printWidth.stringValue = String(format: "%.6g", widthInches * factor)
        printHeight.stringValue = String(format: "%.6g", heightInches * factor)
    }
    @objc private func optionsChanged(_ sender: NSControl) {
        if sender === units { writePrintSize() }
        smooth.isEnabled = resample.state == .on
        update()
    }
    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field === printWidth || field === printHeight {
            widthInches = printWidth.doubleValue / factor; heightInches = printHeight.doubleValue / factor
            if resample.state == .off, widthInches > 0, heightInches > 0 {
                dpiX.doubleValue = Double(original.width) / widthInches; dpiY.doubleValue = Double(original.height) / heightInches
            }
        } else if resample.state == .off, dpiX.doubleValue > 0, dpiY.doubleValue > 0 {
            widthInches = Double(original.width) / dpiX.doubleValue; heightInches = Double(original.height) / dpiY.doubleValue
            writePrintSize()
        }
        update()
    }
    private func update() {
        do {
            let dpi = ImageResolution(x: dpiX.doubleValue, y: dpiY.doubleValue)
            plan = try PrintSizePlan.make(widthInches: widthInches, heightInches: heightInches, resolution: dpi,
                                          resample: resample.state == .on, originalWidth: original.width, originalHeight: original.height)
            let reduction = original.format.depth == .sixteen && depth.indexOfSelectedItem == 0
            summary.stringValue = "\(plan.width) × \(plan.height) px · \(profiles[profile.indexOfSelectedItem].name) · \(depth.titleOfSelectedItem ?? "")"
                + (reduction ? "\nReducing to 8 bits discards precision. Undo restores the original." : "")
            alert.buttons[0].isEnabled = true
        } catch { summary.stringValue = error.localizedDescription; alert.buttons[0].isEnabled = false }
    }
    func show(for window: NSWindow) {
        alert.beginSheetModal(for: window) { [self] response in
            guard response == .alertFirstButtonReturn, alert.buttons[0].isEnabled else { return }
            let format = RGBFormat(profile: profiles[profile.indexOfSelectedItem], depth: depth.indexOfSelectedItem == 0 ? .eight : .sixteen)
            onApply?(format, plan.resolution, resample.state == .on ? CGSize(width: plan.width, height: plan.height) : nil, smooth.indexOfSelectedItem == 0)
        }
    }
}
