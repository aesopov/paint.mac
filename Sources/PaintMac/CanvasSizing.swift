import AppKit

enum CanvasSizeMode: Int { case scale, resize }
enum SizeUnit: Int { case pixels, percent }
enum CanvasAnchor: Int, CaseIterable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    var column: Int { rawValue % 3 }
    var row: Int { rawValue / 3 }
    var title: String { ["↖", "↑", "↗", "←", "•", "→", "↙", "↓", "↘"][rawValue] }
    var name: String { ["Top left", "Top", "Top right", "Left", "Center", "Right", "Bottom left", "Bottom", "Bottom right"][rawValue] }
}

struct CanvasSizePlan: Equatable {
    let width: Int
    let height: Int
    let offsetX: Int
    let offsetY: Int

    static func validate(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 32_000_000 else { throw PaintError.imageTooLarge }
    }
    private static func pixels(_ value: Double, unit: SizeUnit, original: Int) throws -> Int {
        let pixels = unit == .pixels ? value : Double(original) * value / 100
        guard pixels.isFinite, abs(pixels) <= 16384 else { throw PaintError.imageTooLarge }
        return Int(pixels.rounded())
    }
    static func dimensions(width: Double, height: Double, unit: SizeUnit,
                           originalWidth: Int, originalHeight: Int, anchor: CanvasAnchor) throws -> Self {
        let w = try pixels(width, unit: unit, original: originalWidth)
        let h = try pixels(height, unit: unit, original: originalHeight)
        try validate(width: w, height: h)
        return Self(width: w, height: h, offsetX: Int(floor(Double(w - originalWidth) * Double(anchor.column) / 2)),
                    offsetY: Int(floor(Double(h - originalHeight) * Double(anchor.row) / 2)))
    }
    static func edges(left: Double, top: Double, right: Double, bottom: Double, unit: SizeUnit,
                      originalWidth: Int, originalHeight: Int) throws -> Self {
        let l = try pixels(left, unit: unit, original: originalWidth), r = try pixels(right, unit: unit, original: originalWidth)
        let t = try pixels(top, unit: unit, original: originalHeight), b = try pixels(bottom, unit: unit, original: originalHeight)
        let w = originalWidth + l + r, h = originalHeight + t + b
        try validate(width: w, height: h)
        return Self(width: w, height: h, offsetX: l, offsetY: t)
    }
}

extension PaintDocument {
    func applySize(_ plan: CanvasSizePlan, mode: CanvasSizeMode, smooth: Bool) throws {
        try CanvasSizePlan.validate(width: plan.width, height: plan.height)
        guard (-16384...16384).contains(plan.offsetX), (-16384...16384).contains(plan.offsetY) else { throw PaintError.imageTooLarge }
        finishPendingEdits?()
        // Prepare all new layers before changing the document, so a failure cannot leave mixed dimensions.
        var next = state
        for i in next.layers.indices {
            let raster = state.layers[i].raster
            next.layers[i].raster = try mode == .scale
                ? raster.scaled(width: plan.width, height: plan.height, smooth: smooth)
                : raster.resizedCanvas(width: plan.width, height: plan.height, offsetX: plan.offsetX, offsetY: plan.offsetY)
            if var text = state.layers[i].text {
                if mode == .scale { text.transform(sx: Double(plan.width) / Double(state.width), sy: Double(plan.height) / Double(state.height)) }
                else { text.transform(dx: Double(plan.offsetX), dy: Double(plan.offsetY)) }
                try text.validate(); next.layers[i].text = text
                if let clip = state.layers[i].textClip {
                    next.layers[i].textClip = mode == .scale ? clip.scaled(width: plan.width, height: plan.height, smooth: smooth)
                        : clip.translated(dx: plan.offsetX, dy: plan.offsetY, width: plan.width, height: plan.height)
                }
                next.layers[i].renderText()
            }
            if let mask = state.layers[i].mask {
                next.layers[i].mask = mode == .scale
                    ? mask.scaled(width: plan.width, height: plan.height, smooth: smooth)
                    : mask.resizedLayerMask(width: plan.width, height: plan.height, offsetX: plan.offsetX, offsetY: plan.offsetY)
            }
        }
        if let mask = state.selection {
            next.selection = mode == .scale
                ? mask.scaled(width: plan.width, height: plan.height, smooth: smooth)
                : mask.translated(dx: plan.offsetX, dy: plan.offsetY, width: plan.width, height: plan.height)
        }
        if let mask = state.quickMask {
            next.quickMask = mode == .scale
                ? mask.scaled(width: plan.width, height: plan.height, smooth: smooth)
                : mask.translated(dx: plan.offsetX, dy: plan.offsetY, width: plan.width, height: plan.height)
        }
        next.width = plan.width; next.height = plan.height
        let previous = state; state = next
        commit(previous, name: mode == .scale ? "Scale Image" : "Resize Canvas")
    }
}

final class CanvasSizeDialog: NSObject, NSTextFieldDelegate {
    private let originalWidth: Int, originalHeight: Int
    private let alert = NSAlert()
    private let modeControl = NSSegmentedControl(labels: ["Scale Image", "Resize Canvas"], trackingMode: .selectOne, target: nil, action: nil)
    private let unitControl = NSPopUpButton()
    private let smoothControl = NSPopUpButton()
    private let keepAspect = NSButton(checkboxWithTitle: "Keep proportions", target: nil, action: nil)
    private let widthField = NSTextField(), heightField = NSTextField()
    private let leftField = NSTextField(), topField = NSTextField(), rightField = NSTextField(), bottomField = NSTextField()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private var anchorButtons: [NSButton] = []
    private var anchor: CanvasAnchor = .center
    private var customEdges = false
    private var unit: SizeUnit = .pixels
    private var plan: CanvasSizePlan
    private var updating = false
    var onApply: ((CanvasSizePlan, CanvasSizeMode, Bool) -> Void)?
    var formView: NSView { alert.accessoryView! }

    init(width: Int, height: Int, mode: CanvasSizeMode, smooth: Bool) {
        originalWidth = width; originalHeight = height
        plan = CanvasSizePlan(width: width, height: height, offsetX: 0, offsetY: 0)
        super.init()
        alert.messageText = "Image & Canvas Size"
        alert.informativeText = "Scale changes pixel size. Resize Canvas adds or removes space; use an anchor or adjust individual edges. Positive edge values add space; negative values crop."
        alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
        modeControl.selectedSegment = mode.rawValue; modeControl.target = self; modeControl.action = #selector(modeChanged)
        modeControl.setAccessibilityLabel("Size mode")
        unitControl.addItems(withTitles: ["Pixels", "Percent"]); unitControl.target = self; unitControl.action = #selector(unitChanged)
        unitControl.setAccessibilityLabel("Size units")
        smoothControl.addItems(withTitles: ["Smooth", "Sharp (nearest neighbor)"])
        smoothControl.selectItem(at: smooth ? 0 : 1)
        keepAspect.state = .on
        let fields = [widthField, heightField, leftField, topField, rightField, bottomField]
        for (index, field) in fields.enumerated() {
            field.tag = index; field.delegate = self
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.widthAnchor.constraint(equalToConstant: 90).isActive = true
            field.setAccessibilityLabel(["Width", "Height", "Left edge", "Top edge", "Right edge", "Bottom edge"][index])
        }
        func text(_ string: String) -> NSTextField { NSTextField(labelWithString: string) }
        func row(_ views: [NSView], vertical: Bool = false) -> NSStackView {
            let stack = NSStackView(views: views); stack.orientation = vertical ? .vertical : .horizontal
            stack.alignment = vertical ? .leading : .centerY; stack.spacing = 10; return stack
        }
        let dimensions = NSGridView(views: [[text("Width"), widthField, text("Height"), heightField]])
        dimensions.columnSpacing = 12
        var anchorRows: [NSView] = []
        for r in 0..<3 {
            var buttons: [NSView] = []
            for c in 0..<3 {
                let a = CanvasAnchor(rawValue: r * 3 + c)!
                let button = NSButton(title: a.title, target: self, action: #selector(anchorChanged(_:)))
                button.tag = a.rawValue; button.setButtonType(.pushOnPushOff); button.bezelStyle = .regularSquare
                button.widthAnchor.constraint(equalToConstant: 30).isActive = true
                button.heightAnchor.constraint(equalToConstant: 26).isActive = true
                button.setAccessibilityLabel("Anchor \(a.name)")
                button.toolTip = "Keep \(a.name.lowercased()) fixed"
                anchorButtons.append(button); buttons.append(button)
            }
            let line = row(buttons); line.spacing = 3; anchorRows.append(line)
        }
        let anchorGrid = row(anchorRows, vertical: true); anchorGrid.spacing = 3
        let edges = NSGridView(views: [[text("Left"), leftField, text("Right"), rightField],
                                     [text("Top"), topField, text("Bottom"), bottomField]])
        edges.columnSpacing = 10; edges.rowSpacing = 10
        let root = row([modeControl, row([text("Units"), unitControl]), dimensions,
                        row([keepAspect, smoothControl]), text("Canvas anchor & edge changes"),
                        row([anchorGrid, edges]), summary], vertical: true)
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        summary.preferredMaxLayoutWidth = 440
        root.frame = NSRect(origin: .zero, size: root.fittingSize)
        alert.accessoryView = root
        writeFields(); modeChanged()
    }

    func show(for window: NSWindow) {
        alert.window.initialFirstResponder = widthField
        alert.beginSheetModal(for: window) { [self] response in
            if response == .alertFirstButtonReturn, alert.buttons[0].isEnabled {
                onApply?(plan, CanvasSizeMode(rawValue: modeControl.selectedSegment)!, smoothControl.indexOfSelectedItem == 0)
            }
        }
    }
    private func display(_ pixels: Int, original: Int) -> String {
        if unit == .pixels { return String(pixels) }
        return String(format: "%.3f", Double(pixels) * 100 / Double(original))
    }
    private func writeFields() {
        updating = true; defer { updating = false }
        widthField.stringValue = display(plan.width, original: originalWidth)
        heightField.stringValue = display(plan.height, original: originalHeight)
        leftField.stringValue = display(plan.offsetX, original: originalWidth)
        topField.stringValue = display(plan.offsetY, original: originalHeight)
        rightField.stringValue = display(plan.width - originalWidth - plan.offsetX, original: originalWidth)
        bottomField.stringValue = display(plan.height - originalHeight - plan.offsetY, original: originalHeight)
        for button in anchorButtons { button.state = !customEdges && button.tag == anchor.rawValue ? .on : .off }
        summary.stringValue = "\(originalWidth) × \(originalHeight) → \(plan.width) × \(plan.height) px"
        alert.buttons[0].isEnabled = true
    }
    @objc private func unitChanged() { unit = SizeUnit(rawValue: unitControl.indexOfSelectedItem)!; writeFields() }
    @objc private func modeChanged() {
        let resize = modeControl.selectedSegment == CanvasSizeMode.resize.rawValue
        for field in [leftField, topField, rightField, bottomField] { field.isEnabled = resize }
        for button in anchorButtons { button.isEnabled = resize }
        keepAspect.isEnabled = !resize; smoothControl.isEnabled = !resize
    }
    @objc private func anchorChanged(_ sender: NSButton) {
        anchor = CanvasAnchor(rawValue: sender.tag)!
        customEdges = false
        do {
            plan = try .dimensions(width: widthField.doubleValue, height: heightField.doubleValue, unit: unit,
                                   originalWidth: originalWidth, originalHeight: originalHeight, anchor: anchor)
            writeFields()
        } catch { invalid(error) }
    }
    private func invalid(_ error: Error) { summary.stringValue = error.localizedDescription; alert.buttons[0].isEnabled = false }
    func controlTextDidChange(_ notification: Notification) {
        guard !updating, let field = notification.object as? NSTextField else { return }
        do {
            if field.tag < 2 {
                customEdges = false
                var w = widthField.doubleValue, h = heightField.doubleValue
                if modeControl.selectedSegment == CanvasSizeMode.scale.rawValue && keepAspect.state == .on {
                    if field === widthField { h = unit == .percent ? w : w * Double(originalHeight) / Double(originalWidth) }
                    else { w = unit == .percent ? h : h * Double(originalWidth) / Double(originalHeight) }
                }
                plan = try .dimensions(width: w, height: h, unit: unit, originalWidth: originalWidth, originalHeight: originalHeight, anchor: anchor)
                // Preserve the active field while typing (e.g. a trailing decimal point).
                let input = field.stringValue; writeFields(); field.stringValue = input
            } else {
                customEdges = true
                plan = try .edges(left: leftField.doubleValue, top: topField.doubleValue, right: rightField.doubleValue, bottom: bottomField.doubleValue,
                                  unit: unit, originalWidth: originalWidth, originalHeight: originalHeight)
                let input = field.stringValue; writeFields(); field.stringValue = input
            }
        } catch { invalid(error) }
    }
}
