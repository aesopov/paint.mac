import AppKit
import UniformTypeIdentifiers

private func label(_ title: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: title)
    field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
    return field
}

private func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 12) -> NSStackView {
    let view = NSStackView(views: views)
    view.orientation = vertical ? .vertical : .horizontal
    view.alignment = vertical ? .leading : .centerY
    view.spacing = spacing
    return view
}

private func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }

private final class ToolRailView: NSView { override var isFlipped: Bool { true } }

/// Keep the one layer column inside the clip view, including when macOS
/// changes between overlay and space-consuming vertical scrollbars.
private final class LayerScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let table = documentView as? NSTableView, let column = table.tableColumns.first else { return }
        let width = contentView.bounds.width
        guard width > 0 else { return }
        if abs(table.frame.width - width) > 0.5 { table.setFrameSize(NSSize(width: width, height: table.frame.height)) }
        if abs(column.width - width) > 0.5 { column.width = width }
    }
}

private final class SwatchButton: NSButton {
    private let normalColor: PixelColor
    private let maskShade: UInt8
    var color: PixelColor { maskMode ? PixelColor(r: maskShade, g: maskShade, b: maskShade) : normalColor }
    var maskMode = false {
        didSet {
            toolTip = "\(color.hex) · Left: main / Right: alternate"
            setAccessibilityLabel("Color \(color.hex)"); needsDisplay = true
        }
    }
    var onAlternateClick: ((PixelColor) -> Void)?
    init(color: PixelColor, maskShade: UInt8, target: AnyObject?, action: Selector) {
        normalColor = color; self.maskShade = maskShade
        super.init(frame: .zero)
        self.target = target; self.action = action
        isBordered = false; title = ""; toolTip = color.hex
        setAccessibilityLabel("Color \(color.hex)")
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5)
        color.nsColor.setFill(); path.fill()
        NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
    }
    override func rightMouseDown(with event: NSEvent) { onAlternateClick?(color) }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

private final class LayerMenuInvocation {
    let action: Selector
    let value: Any?
    let activeID: UUID
    let selectedIDs: Set<UUID>
    let editingMask: Bool
    init(action: Selector, value: Any?, state: DocumentState, selectedIDs: Set<UUID>) {
        self.action = action; self.value = value; activeID = state.activeID
        self.selectedIDs = selectedIDs; editingMask = state.isEditingMask
    }
}

final class EditorWindowController: NSWindowController, NSToolbarDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let paintDocument: PaintDocument
    let canvas: CanvasView
    private let layoutPreferences: UserDefaults
    private var toolButtons: [PaintTool: ToolButton] = [:]
    private var toolGroupButtons: [ToolGroup: ToolGroupButton] = [:]
    private let toolTitle = label("Brush", size: 13, weight: .semibold)
    private let hardnessSlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let hardnessValue = label("100%", size: 11, color: .secondaryLabelColor)
    private var hardnessOptions: NSStackView!
    private let sizeValue = label("18 px", size: 11, color: .secondaryLabelColor)
    private let sizeSlider = NSSlider(value: 18, minValue: 1, maxValue: 300, target: nil, action: nil)
    private let opacitySlider = NSSlider(value: 100, minValue: 1, maxValue: 100, target: nil, action: nil)
    private let opacityValue = label("100%", size: 11, color: .secondaryLabelColor)
    private let toleranceSlider = NSSlider(value: 32, minValue: 0, maxValue: 255, target: nil, action: nil)
    private let colorWell = NSColorWell()
    private let alternateColorWell = NSColorWell()
    private let hexField = NSTextField(string: "#4075F5")
    private let alternateHexField = NSTextField(string: "#FFFFFF")
    private let layerTable = LayerTableView()
    private let layerTrash = LayerTrashButton(frame: .zero)
    private var displayedLayerIDs: [UUID] = []
    private let structureButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let layerOpacity = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let layerOpacityLabel = label("100%", size: 11, color: .secondaryLabelColor)
    private let mergeDownButton = NSButton(title: "Merge Down", target: nil, action: nil)
    private let maskButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var editingMaskColors = false
    private var pixelColors: (PixelColor, PixelColor)?
    private var paletteButtons: [SwatchButton] = []
    private let layerCount = label("2", size: 11, color: .tertiaryLabelColor)
    private let status = label("", size: 11, color: .secondaryLabelColor)
    private let dimensions = label("1200 × 800 px", size: 11, color: .secondaryLabelColor)
    private let zoomButton = NSButton(title: "100%", target: nil, action: nil)
    private var lastLayers: [String] = []
    private var refreshing = false
    private var effectDialog: EffectLayerDialog?
    private var brushOptions: NSStackView!
    private var selectionOptions: NSStackView!
    private let selectionModePopup = NSPopUpButton()
    private let featherButton = NSButton(title: "Feather…", target: nil, action: nil)
    private let edgeMode = NSSegmentedControl(labels: ["Smooth", "Sharp"], trackingMode: .selectOne, target: nil, action: nil)
    private let shapeFill = NSButton(checkboxWithTitle: "Filled", target: nil, action: nil)
    private var textOptions: NSStackView!
    private var opacityOptions: NSStackView!
    private let fontFamily = NSPopUpButton()
    private let fontSize = NSTextField(string: "48")
    private let fontBold = NSButton(checkboxWithTitle: "B", target: nil, action: nil)
    private let fontItalic = NSButton(checkboxWithTitle: "I", target: nil, action: nil)

    init(document: PaintDocument, layoutPreferences: UserDefaults = .standard) {
        self.layoutPreferences = layoutPreferences
        paintDocument = document
        canvas = CanvasView(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 960, height: 640)
        window.title = "Untitled"
        window.subtitle = "Paint.MAC"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "PaintMacDocuments"
        super.init(window: window)
        buildInterface()
        buildToolbar()
        window.center()
        window.setFrameAutosaveName("PaintMacEditor")
        document.onChange = { [weak self] in self?.refresh() }
        document.onHistoryNotice = { [weak self] in self?.status.stringValue = $0 }
        canvas.onToolChange = { [weak self] in self?.selectTool($0) }
        canvas.onColorPick = { [weak self] color, alternate in self?.setColor(color, alternate: alternate) }
        canvas.onSwapColors = { [weak self] in self?.swapColors() }
        document.finishPendingEdits = { [weak canvas] in canvas?.finishText() }
        canvas.onStatus = { [weak self] in self?.status.stringValue = $0 }
        canvas.onSizeChange = { [weak self] size in self?.sizeSlider.doubleValue = size; self?.updateBrushControls() }
        canvas.onZoomChange = { [weak self] in self?.refreshZoom() }
        canvas.onSelectionChange = { [weak self] in
            self?.refreshDimensions()
            self?.featherButton.isEnabled = self?.canvas.selection?.isEmpty == false
            self?.toolButtons[.crop]?.isEnabled = self?.canvas.selection?.isEmpty == false
        }
        canvas.onTextSettingsChange = { [weak self] in self?.synchronizeTextControls() }
        selectTool(.brush)
        refresh()
        window.makeFirstResponder(canvas)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildInterface() {
        guard let root = window?.contentView else { return }
        let rail = EditorPanelView(backgroundColor: .windowBackgroundColor)
        let inspector = EditorPanelView(backgroundColor: .windowBackgroundColor)
        let options = EditorPanelView(backgroundColor: .controlBackgroundColor)
        let footer = EditorPanelView(backgroundColor: .windowBackgroundColor)
        let split = InspectorSplitView(canvas: canvas, inspector: inspector, preferences: layoutPreferences)
        let views: [NSView] = [rail, options, split, footer]
        for view in views { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            options.topAnchor.constraint(equalTo: root.topAnchor), options.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            options.trailingAnchor.constraint(equalTo: root.trailingAnchor), options.heightAnchor.constraint(equalToConstant: 48),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor), footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor), footer.heightAnchor.constraint(equalToConstant: 30),
            rail.leadingAnchor.constraint(equalTo: root.leadingAnchor), rail.topAnchor.constraint(equalTo: options.bottomAnchor),
            rail.bottomAnchor.constraint(equalTo: footer.topAnchor), rail.widthAnchor.constraint(equalToConstant: 60),
            split.leadingAnchor.constraint(equalTo: rail.trailingAnchor), split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: options.bottomAnchor), split.bottomAnchor.constraint(equalTo: footer.topAnchor)
        ])

        var tools: [NSView] = []
        let railTools: [PaintTool] = [.brush, .eraser, .selection, .move, .fill, .eyedropper, .rectangle, .text, .crop, .hand]
        for tool in railTools {
            let button: ToolButton
            if let group = ToolGroup.allCases.first(where: { $0.tools[0] == tool }) {
                let grouped = ToolGroupButton(group: group)
                grouped.onChoose = { [weak self] in self?.selectTool($0) }
                toolGroupButtons[group] = grouped; button = grouped
            } else {
                button = ToolButton(image: NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title)!, target: self, action: #selector(toolClicked(_:)))
                button.tag = PaintTool.allCases.firstIndex(of: tool)!; button.isBordered = false; button.imagePosition = .imageOnly
                button.imageScaling = .scaleProportionallyDown
                button.toolTip = "\(tool.title) (\(tool.key.uppercased()))"; button.setAccessibilityLabel(tool.title)
                toolButtons[tool] = button
            }
            button.widthAnchor.constraint(equalToConstant: 38).isActive = true
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            tools.append(button)
        }
        let toolStack = stack(tools, spacing: 4)
        let toolScroll = NSScrollView()
        toolScroll.drawsBackground = false; toolScroll.hasVerticalScroller = true
        toolScroll.autohidesScrollers = true; toolScroll.scrollerStyle = .overlay
        toolScroll.clipsToBounds = true; toolScroll.contentView.clipsToBounds = true
        let toolDocument = ToolRailView(frame: CGRect(x: 0, y: 0, width: 60, height: tools.count * 38 + 24))
        toolStack.translatesAutoresizingMaskIntoConstraints = false; toolDocument.addSubview(toolStack)
        toolScroll.documentView = toolDocument
        toolScroll.translatesAutoresizingMaskIntoConstraints = false; rail.addSubview(toolScroll)
        NSLayoutConstraint.activate([toolScroll.topAnchor.constraint(equalTo: rail.topAnchor), toolScroll.bottomAnchor.constraint(equalTo: rail.bottomAnchor),
                                     toolScroll.leadingAnchor.constraint(equalTo: rail.leadingAnchor), toolScroll.trailingAnchor.constraint(equalTo: rail.trailingAnchor),
                                     toolStack.topAnchor.constraint(equalTo: toolDocument.topAnchor, constant: 14),
                                     toolStack.centerXAnchor.constraint(equalTo: toolDocument.centerXAnchor)])

        brushOptions = stack([label("Size", size: 11, color: .secondaryLabelColor), sizeSlider, sizeValue], vertical: false, spacing: 8)
        opacityOptions = stack([label("Opacity", size: 11, color: .secondaryLabelColor), opacitySlider, opacityValue], vertical: false, spacing: 8)
        hardnessOptions = stack([label("Hardness", size: 11, color: .secondaryLabelColor), hardnessSlider, hardnessValue], vertical: false, spacing: 6)
        hardnessSlider.widthAnchor.constraint(equalToConstant: 70).isActive = true
        hardnessValue.widthAnchor.constraint(equalToConstant: 34).isActive = true
        hardnessSlider.target = self; hardnessSlider.action = #selector(hardnessChanged); hardnessSlider.isContinuous = true
        hardnessSlider.setAccessibilityLabel("Brush hardness")
        hardnessSlider.toolTip = "100%: hard edge. 0%: gradual fade. Applies to brush, eraser, lines, and shape outlines. Independent of antialiasing."
        selectionModePopup.addItems(withTitles: SelectionMode.allCases.map(\.rawValue))
        selectionModePopup.target = self; selectionModePopup.action = #selector(selectionModeChanged)
        selectionModePopup.setAccessibilityLabel("Selection combine mode")
        featherButton.target = self; featherButton.action = #selector(featherSelection)
        featherButton.bezelStyle = .rounded
        selectionOptions = stack([label("Mode", size: 11, color: .secondaryLabelColor), selectionModePopup,
                                  featherButton, label("⇧ Add   ⌥ Subtract   ⇧⌥ Intersect", size: 11, color: .secondaryLabelColor)], vertical: false, spacing: 12)
        fontFamily.addItems(withTitles: NSFontManager.shared.availableFontFamilies.sorted())
        fontFamily.selectItem(withTitle: canvas.textStyle.family)
        fontFamily.widthAnchor.constraint(equalToConstant: 140).isActive = true
        fontFamily.target = self; fontFamily.action = #selector(textStyleChanged)
        fontFamily.setAccessibilityLabel("Text font family")
        fontSize.widthAnchor.constraint(equalToConstant: 48).isActive = true
        fontSize.setAccessibilityLabel("Text font size in image pixels"); fontSize.delegate = self
        fontSize.target = self; fontSize.action = #selector(textStyleChanged)
        for button in [fontBold, fontItalic] { button.target = self; button.action = #selector(textStyleChanged) }
        textOptions = stack([fontFamily, fontSize, label("px", size: 11), fontBold, fontItalic], vertical: false, spacing: 6)
        edgeMode.selectedSegment = 0; edgeMode.target = self; edgeMode.action = #selector(edgeModeChanged)
        edgeMode.setAccessibilityLabel("Painting edge mode")
        edgeMode.toolTip = "Smooth enables antialiasing. Sharp disables antialiasing."
        shapeFill.target = self; shapeFill.action = #selector(shapeFillChanged)
        shapeFill.setAccessibilityLabel("Fill shapes")
        shapeFill.toolTip = "Left mouse: main outline, alternate fill. Right mouse: alternate outline, main fill."
        let optionStack = stack([toolTitle, separator(), brushOptions, selectionOptions, textOptions, opacityOptions, hardnessOptions, edgeMode, shapeFill], vertical: false, spacing: 10)
        optionStack.translatesAutoresizingMaskIntoConstraints = false; options.addSubview(optionStack)
        toolTitle.widthAnchor.constraint(equalToConstant: 96).isActive = true
        sizeSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        sizeValue.widthAnchor.constraint(equalToConstant: 44).isActive = true
        opacitySlider.widthAnchor.constraint(equalToConstant: 72).isActive = true
        sizeSlider.target = self; sizeSlider.action = #selector(brushChanged); sizeSlider.isContinuous = true
        opacitySlider.target = self; opacitySlider.action = #selector(brushChanged); opacitySlider.isContinuous = true
        sizeSlider.setAccessibilityLabel("Brush size")
        opacitySlider.setAccessibilityLabel("Brush opacity")
        NSLayoutConstraint.activate([optionStack.leadingAnchor.constraint(equalTo: options.leadingAnchor, constant: 20),
                                     optionStack.centerYAnchor.constraint(equalTo: options.centerYAnchor)])

        for (well, field, alternate) in [(colorWell, hexField, false), (alternateColorWell, alternateHexField, true)] {
            well.color = (alternate ? canvas.alternateColor : canvas.color).nsColor
            well.colorWellStyle = .minimal
            well.target = self; well.action = #selector(colorChanged(_:))
            well.widthAnchor.constraint(equalToConstant: 38).isActive = true
            well.heightAnchor.constraint(equalToConstant: 30).isActive = true
            well.setAccessibilityLabel(alternate ? "Alternate color (right mouse)" : "Main color (left mouse)")
            field.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            field.target = self; field.action = #selector(hexChanged(_:))
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
            field.setAccessibilityLabel(alternate ? "Alternate hex color" : "Main hex color")
        }
        let swap = iconButton("arrow.triangle.2.circlepath", help: "Swap Main and Alternate Colors (X)", action: #selector(swapColors))
        let mainColorRow = stack([colorWell, hexField, swap], vertical: false, spacing: 10)
        let alternateColorRow = stack([alternateColorWell, alternateHexField], vertical: false, spacing: 10)
        for row in [mainColorRow, alternateColorRow] { row.distribution = .fill }
        let colorRows = stack([
            label("Main · left mouse", size: 10, color: .secondaryLabelColor), mainColorRow,
            label("Alternate · right mouse", size: 10, color: .secondaryLabelColor), alternateColorRow
        ], spacing: 6)
        let palette: [PixelColor] = [
            .init(r: 29, g: 32, b: 39), .init(r: 105, g: 112, b: 125), .init(r: 197, g: 202, b: 211), .white,
            .init(r: 255, g: 91, b: 107), .init(r: 255, g: 158, b: 79), .init(r: 250, g: 211, b: 92), .init(r: 177, g: 220, b: 98),
            .init(r: 73, g: 194, b: 151), .init(r: 68, g: 196, b: 212), .init(r: 64, g: 117, b: 245), .init(r: 137, g: 109, b: 238),
            .init(r: 203, g: 116, b: 218), .init(r: 242, g: 151, b: 187), .init(r: 148, g: 106, b: 84), .init(r: 232, g: 209, b: 180)
        ]
        let paletteRows = (0..<2).map { row in
            stack((0..<8).map {
                let button = SwatchButton(color: palette[row * 8 + $0], maskShade: UInt8((row * 8 + $0) * 17), target: self, action: #selector(swatchClicked(_:)))
                paletteButtons.append(button)
                button.onAlternateClick = { [weak self] in self?.setColor($0, alternate: true) }
                button.toolTip = "\(button.color.hex) · Left: main / Right: alternate"
                return button
            }, vertical: false, spacing: 2)
        }
        let toleranceRow = stack([label("Fill tolerance", size: 11, color: .secondaryLabelColor), toleranceSlider], vertical: false, spacing: 10)
        toleranceSlider.target = self; toleranceSlider.action = #selector(toleranceChanged)
        toleranceRow.distribution = .fill
        toleranceSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 108).isActive = true
        toleranceSlider.setAccessibilityLabel("Fill tolerance")
        let colorSection = stack([sectionTitle("COLORS"), colorRows, stack(paletteRows, spacing: 2), toleranceRow], spacing: 14)
        colorSection.translatesAutoresizingMaskIntoConstraints = false; inspector.addSubview(colorSection)
        for row in [colorRows, mainColorRow, alternateColorRow, toleranceRow] {
            row.widthAnchor.constraint(equalTo: colorSection.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([colorSection.topAnchor.constraint(equalTo: inspector.topAnchor, constant: 20),
                                     colorSection.leadingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: 20),
                                     colorSection.trailingAnchor.constraint(equalTo: inspector.trailingAnchor, constant: -20)])

        let line = separator(); line.translatesAutoresizingMaskIntoConstraints = false; inspector.addSubview(line)
        NSLayoutConstraint.activate([line.topAnchor.constraint(equalTo: colorSection.bottomAnchor, constant: 22),
                                     line.leadingAnchor.constraint(equalTo: inspector.leadingAnchor), line.trailingAnchor.constraint(equalTo: inspector.trailingAnchor)])
        let layerHeading = stack([sectionTitle("LAYERS"), layerCount], vertical: false, spacing: 10)
        layerHeading.translatesAutoresizingMaskIntoConstraints = false; inspector.addSubview(layerHeading)
        NSLayoutConstraint.activate([layerHeading.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 20),
                                     layerHeading.leadingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: 20)])
        let opacityRow = stack([label("Opacity", size: 11, color: .secondaryLabelColor), layerOpacity, layerOpacityLabel], vertical: false, spacing: 8)
        layerOpacity.target = self; layerOpacity.action = #selector(layerOpacityChanged); layerOpacity.isContinuous = false
        opacityRow.distribution = .fill
        layerOpacityLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        layerOpacity.widthAnchor.constraint(greaterThanOrEqualToConstant: 108).isActive = true
        layerOpacity.setAccessibilityLabel("Layer opacity")
        opacityRow.translatesAutoresizingMaskIntoConstraints = false; inspector.addSubview(opacityRow)
        NSLayoutConstraint.activate([opacityRow.leadingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: 20),
                                     opacityRow.trailingAnchor.constraint(equalTo: inspector.trailingAnchor, constant: -20),
                                     opacityRow.topAnchor.constraint(equalTo: layerHeading.bottomAnchor, constant: 14)])

        let column = NSTableColumn(identifier: .init("layer")); column.width = 250
        layerTable.addTableColumn(column); layerTable.headerView = nil
        layerTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        layerTable.autoresizingMask = [.width]
        layerTable.rowHeight = 58; layerTable.intercellSpacing = NSSize(width: 0, height: 4)
        layerTable.backgroundColor = .clear; layerTable.style = .plain
        layerTable.selectionHighlightStyle = .regular
        layerTable.allowsMultipleSelection = true
        layerTable.delegate = self; layerTable.dataSource = self
        layerTable.target = self; layerTable.action = #selector(layerRowClicked)
        layerTable.doubleAction = #selector(layerRowDoubleClicked)
        layerTable.setAccessibilityLabel("Layers")
        layerTable.registerForDraggedTypes([LayerTableView.pasteboardType])
        layerTable.setDraggingSourceOperationMask(.move, forLocal: true)
        layerTable.onDelete = { [weak self] in self?.removeLayer() }
        layerTable.contextMenuProvider = { [weak self] row in self?.layerContextMenu(forRow: row) }
        layerTrash.sourceTable = layerTable
        layerTrash.canDelete = { [weak self] ids in self?.paintDocument.state.canRemoveLayers(ids) == true }
        layerTrash.deleteLayers = { [weak self] ids in self?.paintDocument.removeLayers(ids) }
        layerTrash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        layerTrash.target = self; layerTrash.action = #selector(removeLayer)
        layerTrash.isBordered = false; layerTrash.contentTintColor = .secondaryLabelColor
        layerTrash.toolTip = "Delete selected layers (Delete), or drop layers here"
        layerTrash.setAccessibilityLabel("Delete Layer")
        layerTrash.widthAnchor.constraint(equalToConstant: 28).isActive = true
        layerTrash.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let scroll = LayerScrollView(); scroll.documentView = layerTable; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false; scroll.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(scroll)
        let buttons = [
            iconButton("plus", help: "Add Layer ⇧⌘N", action: #selector(addLayer)),
            iconButton("square.on.square", help: "Duplicate Layer", action: #selector(duplicateLayer)),
            iconButton("arrow.up", help: "Move Layer Up", action: #selector(layerUp)),
            iconButton("arrow.down", help: "Move Layer Down", action: #selector(layerDown)),
            layerTrash
        ]
        let layerActions = stack(buttons, vertical: false, spacing: 9)
        mergeDownButton.target = self; mergeDownButton.action = #selector(mergeSelected)
        mergeDownButton.bezelStyle = .rounded
        mergeDownButton.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil)
        mergeDownButton.imagePosition = .imageLeading
        mergeDownButton.setAccessibilityLabel("Merge Down")
        mergeDownButton.widthAnchor.constraint(equalToConstant: 116).isActive = true
        maskButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 216).isActive = true
        maskButton.setAccessibilityLabel("Layer Mask")
        structureButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true
        structureButton.setAccessibilityLabel("Layer groups and clipping masks")
        let mergeAndStructure = stack([mergeDownButton, structureButton], vertical: false, spacing: 8)
        mergeAndStructure.distribution = .fill
        let layerControls = stack([layerActions, mergeAndStructure, maskButton], spacing: 8)
        mergeAndStructure.widthAnchor.constraint(equalTo: layerControls.widthAnchor).isActive = true
        maskButton.widthAnchor.constraint(equalTo: layerControls.widthAnchor).isActive = true
        layerControls.translatesAutoresizingMaskIntoConstraints = false; inspector.addSubview(layerControls)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: opacityRow.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: 5),
            scroll.trailingAnchor.constraint(equalTo: inspector.trailingAnchor, constant: -5),
            scroll.bottomAnchor.constraint(equalTo: layerControls.topAnchor, constant: -10),
            layerControls.leadingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: 18),
            layerControls.trailingAnchor.constraint(equalTo: inspector.trailingAnchor, constant: -18),
            layerControls.bottomAnchor.constraint(equalTo: inspector.bottomAnchor, constant: -16)
        ])

        status.lineBreakMode = .byTruncatingTail
        let footerStack = stack([status, NSView(), dimensions, separator(), zoomButton], vertical: false, spacing: 16)
        footerStack.translatesAutoresizingMaskIntoConstraints = false; footer.addSubview(footerStack)
        zoomButton.bezelStyle = .inline; zoomButton.target = self; zoomButton.action = #selector(showZoomMenu(_:))
        zoomButton.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomButton.widthAnchor.constraint(equalToConstant: 68).isActive = true
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dimensions.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([footerStack.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14),
                                     footerStack.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -12),
                                     footerStack.centerYAnchor.constraint(equalTo: footer.centerYAnchor)])
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let field = label(text, size: 10, weight: .semibold, color: .secondaryLabelColor)
        field.attributedStringValue = NSAttributedString(string: text, attributes: [.kern: 1.5, .font: field.font!, .foregroundColor: NSColor.secondaryLabelColor])
        return field
    }
    private func iconButton(_ symbol: String, help: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help)!, target: self, action: action)
        button.isBordered = false; button.contentTintColor = .secondaryLabelColor; button.toolTip = help
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "PaintMacToolbar")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [NSToolbarItem.Identifier("new"), .init("open"), .init("save"), .flexibleSpace,
         .init("undo"), .init("redo"), .space, .init("fit"), .init("actual"), .flexibleSpace, .init("export")]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let items: [String: (String, String, Selector)] = [
            "new": ("New Image", "doc.badge.plus", #selector(AppDelegate.newImage)),
            "open": ("Open…", "folder", #selector(AppDelegate.openImage)),
            "save": ("Save Project", "square.and.arrow.down", #selector(AppDelegate.saveProject)),
            "undo": ("Undo", "arrow.uturn.backward", #selector(AppDelegate.undoEdit)),
            "redo": ("Redo", "arrow.uturn.forward", #selector(AppDelegate.redoEdit)),
            "fit": ("Fit to Window", "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left", #selector(AppDelegate.zoomFit)),
            "actual": ("Actual Size", "1.magnifyingglass", #selector(AppDelegate.zoomActual)),
            "export": ("Export Image…", "square.and.arrow.up", #selector(AppDelegate.exportImage))
        ]
        guard let (title, symbol, action) = items[id.rawValue] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = title; item.toolTip = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.target = NSApp.delegate; item.action = action
        return item
    }

    var selectedLayerIDs: Set<UUID> {
        let ids = Set(layerTable.selectedRowIndexes.compactMap { displayedLayerIDs.indices.contains($0) ? displayedLayerIDs[$0] : nil })
        return ids.isEmpty ? [paintDocument.state.activeID] : ids
    }
    func refresh(selectedIDs requested: Set<UUID>? = nil, updateRows: Bool = true) {
        let previousSelection = requested ?? selectedLayerIDs
        refreshing = true
        defer { refreshing = false }
        canvas.needsDisplay = true
        synchronizeMaskColors()
        canvas.refreshTextPreview()
        for id in paintDocument.state.ancestors(of: paintDocument.state.activeID) {
            if let index = paintDocument.state.layers.firstIndex(where: { $0.id == id }) { paintDocument.state.layers[index].expanded = true }
        }
        let state = paintDocument.state
        displayedLayerIDs = state.visibleLayerIDs
        if let selection = canvas.selection, selection.width != state.width || selection.height != state.height {
            canvas.selection = selection.translated(dx: 0, dy: 0, width: state.width, height: state.height)
        }
        canvas.synchronizeSelection()
        featherButton.isEnabled = canvas.selection?.isEmpty == false
        toolButtons[.crop]?.isEnabled = canvas.selection?.isEmpty == false
        let signature = ["\(state.width)x\(state.height)-\(state.activeID)-\(state.isEditingMask)"] + state.layers.map { "\($0.id)-\($0.name)-\($0.visible)-\($0.opacity)-\($0.mask != nil)-\($0.maskEnabled)-\($0.parentID?.uuidString ?? "root")-\($0.isGroup)-\($0.expanded)-\($0.isClipped)-\($0.isLocked)-\($0.text != nil)-\($0.effect?.kind.rawValue ?? "")" }
        if updateRows {
            if signature != lastLayers {
                lastLayers = signature
                layerTable.reloadData()
            } else {
                // Update only the active thumbnail during a brush gesture.
                if let row = displayedLayerIDs.firstIndex(of: state.activeID) {
                    layerTable.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
                }
            }
        }
        let selection = previousSelection.contains(state.activeID) ? previousSelection : [state.activeID]
        let selectedRows = IndexSet(displayedLayerIDs.indices.filter { selection.contains(displayedLayerIDs[$0]) })
        if layerTable.selectedRowIndexes != selectedRows { layerTable.selectRowIndexes(selectedRows, byExtendingSelection: false) }
        layerOpacity.isEnabled = !state.isEffectivelyLocked(state.activeID)
        layerTrash.isEnabled = state.canRemoveLayers(selectedLayerIDs)
        layerOpacity.doubleValue = state.activeLayer.opacity * 100
        layerOpacityLabel.stringValue = "\(Int(layerOpacity.doubleValue.rounded()))%"
        layerCount.stringValue = "\(state.layers.count)"
        updateMergeDownButton()
        let maskMenu = LayerMaskCommand.menu(target: self, action: #selector(maskCommand(_:)), state: state)
        maskMenu.autoenablesItems = false
        maskMenu.insertItem(withTitle: state.isEditingMask ? "Editing Layer Mask" : "Layer Mask", action: nil, keyEquivalent: "", at: 0)
        maskButton.menu = maskMenu
        maskButton.toolTip = state.isEditingMask ? "Black hides · white reveals · X swaps colors. Click the image thumbnail to edit pixels." : "Add or manage the current layer's mask."
        updateStructureMenu()
        refreshDimensions()
    }
    private func updateMergeDownButton() {
        let state = paintDocument.state
        mergeDownButton.title = state.activeLayer.isGroup ? "Merge Group" : (state.activeLayer.effect != nil ? "Merge Below" : "Merge Down")
        mergeDownButton.setAccessibilityLabel(mergeDownButton.title)
        mergeDownButton.isEnabled = state.activeLayer.isGroup ? state.canModifySubtree(state.activeID) : state.canMergeDown
        mergeDownButton.toolTip = state.activeLayer.isGroup ? "Merge this group's visible contents into one layer" : "Merge with the lower sibling, including clipping stacks and any input layers needed by an effect (⇧⌘M)"
    }

    private func refreshDimensions() {
        let state = paintDocument.state
        if let selection = canvas.selection {
            let size = selection.isEmpty ? "empty" : "\(Int(selection.bounds.width)) × \(Int(selection.bounds.height))"
            dimensions.stringValue = "Selection \(size) · \(state.width) × \(state.height) px"
        }
        else { dimensions.stringValue = "\(state.width) × \(state.height) px · \(state.format.profile.name) · \(state.format.depth.rawValue)-bit" }
        dimensions.toolTip = String(format: "%.6g × %.6g PPI · %.3f × %.3f inches", state.resolution.x, state.resolution.y, Double(state.width) / state.resolution.x, Double(state.height) / state.resolution.y)
    }
    private func refreshZoom() { zoomButton.title = "\(Int((canvas.zoom * 100).rounded()))% ▾" }

    func selectTool(_ tool: PaintTool) {
        if tool == .crop {
            if canvas.selection?.isEmpty == false { cropToSelection() }
            else { status.stringValue = "Make a selection before cropping."; NSSound.beep() }
            return
        }
        canvas.tool = tool; toolTitle.stringValue = tool.title
        brushOptions.isHidden = ![.brush, .eraser, .line, .rectangle, .ellipse].contains(tool)
        selectionOptions.isHidden = !tool.isSelection
        textOptions.isHidden = tool != .text
        opacityOptions.isHidden = !tool.isPainting
        hardnessOptions.isHidden = ![.brush, .eraser, .line, .rectangle, .ellipse].contains(tool)
        edgeMode.isHidden = !(tool.isPainting || tool.isSelection)
        shapeFill.isHidden = tool != .rectangle && tool != .ellipse
        for (key, button) in toolButtons { button.selected = key == tool }
        for (group, button) in toolGroupButtons {
            button.dismissFlyout()
            if group.tools.contains(tool) { button.setCurrentTool(tool) }
            button.selected = group.tools.contains(tool)
        }
        status.stringValue = tool.help
        window?.makeFirstResponder(canvas)
    }
    @objc private func toolClicked(_ sender: NSButton) { selectTool(PaintTool.allCases[sender.tag]) }
    @objc private func edgeModeChanged() {
        canvas.smooth = edgeMode.selectedSegment == 0
        canvas.focusText()
    }
    @objc private func shapeFillChanged() {
        canvas.fillShapes = shapeFill.state == .on
        window?.makeFirstResponder(canvas)
    }
    @objc private func textStyleChanged() {
        guard fontSize.doubleValue.isFinite, (1...1024).contains(fontSize.doubleValue) else {
            fontSize.doubleValue = canvas.textStyle.size; NSSound.beep(); return
        }
        canvas.textStyle = TextStyle(family: fontFamily.titleOfSelectedItem ?? "Helvetica Neue", size: fontSize.doubleValue,
                                     bold: fontBold.state == .on, italic: fontItalic.state == .on)
        canvas.focusText()
    }
    func controlTextDidChange(_ notification: Notification) {
        if fontSize.doubleValue.isFinite, (1...1024).contains(fontSize.doubleValue) {
            var style = canvas.textStyle; style.size = fontSize.doubleValue; canvas.textStyle = style
        }
    }
    func paintText(_ text: String, at point: CGPoint, font: NSFont, color: PixelColor, opacity: Double, antialias: Bool) {
        guard paintDocument.state.activeEffectivelyVisible, paintDocument.state.canPaintTarget else { NSSound.beep(); return }
        paintDocument.edit("Text") { state in
            let selection = state.selection, color = state.isEditingMask ? color.maskColor : color
            state.editRaster { $0.drawText(text, at: point, font: font, color: color,
                                          opacity: opacity, antialias: antialias, selection: selection) }
        }
    }
    private func synchronizeTextControls() {
        selectTool(.text)
        fontFamily.selectItem(withTitle: canvas.textStyle.family); fontSize.doubleValue = canvas.textStyle.size
        fontBold.state = canvas.textStyle.bold ? .on : .off; fontItalic.state = canvas.textStyle.italic ? .on : .off
        edgeMode.selectedSegment = canvas.smooth ? 0 : 1
        opacitySlider.doubleValue = canvas.brushOpacity * 100; opacityValue.stringValue = "\(Int(opacitySlider.doubleValue.rounded()))%"
        colorWell.color = canvas.color.nsColor; hexField.stringValue = canvas.color.hex
    }
    @objc func editLayerContent() {
        let state = paintDocument.state
        guard !state.isEffectivelyLocked(state.activeID) || (state.activeLayer.text == nil && state.activeLayer.effect == nil) else { return }
        if paintDocument.state.activeLayer.text != nil { canvas.editTextLayer() }
        else if let settings = paintDocument.state.activeLayer.effect { showEffect(settings, editing: paintDocument.state.activeID) }
        else { renameLayer() }
    }
    @objc func rasterizeTextLayer() { paintDocument.rasterizeActiveText() }
    @objc func addEffectLayer(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = EffectKind(rawValue: raw) else { return }
        showEffect(EffectSettings(kind: kind))
    }
    func showEffect(_ settings: EffectSettings, editing id: UUID? = nil) {
        canvas.finishText()
        guard id.map({ !paintDocument.state.isEffectivelyLocked($0) }) ?? true, effectDialog == nil, id != nil || paintDocument.state.layers.count < 32 else { return }
        let baseline = paintDocument.state
        let dialog = EffectLayerDialog(settings: settings); effectDialog = dialog
        dialog.onPreview = { [weak self] settings in
            guard let self else { return }
            var preview = baseline
            if let id, let index = preview.layers.firstIndex(where: { $0.id == id }) { preview.layers[index].effect = settings }
            else {
                var layer = PaintLayer(name: settings.kind.title, raster: Raster(width: preview.width, height: preview.height, format: preview.format))
                layer.effect = settings; layer.mask = preview.selection; preview.insertLayer(layer)
            }
            self.canvas.effectPreviewImage = self.paintDocument.renderer.compositeImage(preview.layers, width: preview.width, height: preview.height)
        }
        dialog.onApply = { [weak self] settings in
            guard let self else { return }
            self.canvas.effectPreviewImage = nil
            do {
                if let id { try self.paintDocument.setEffect(settings, on: id) }
                else { try self.paintDocument.addEffect(settings) }
            } catch { self.showError(error) }
        }
        dialog.onClose = { [weak self] in self?.canvas.effectPreviewImage = nil; self?.effectDialog = nil }
        dialog.show(for: window!)
    }
    private func effectMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for kind in EffectKind.allCases {
            let item = NSMenuItem(title: kind.title + "…", action: #selector(addEffectLayer(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = kind.rawValue; item.isEnabled = paintDocument.state.layers.count < 32
            menu.addItem(item)
        }
        return menu
    }
    @objc private func selectionModeChanged() {
        canvas.selectionMode = SelectionMode.allCases[selectionModePopup.indexOfSelectedItem]
        window?.makeFirstResponder(canvas)
    }

    @objc func featherSelection() {
        guard canvas.selection?.isEmpty == false else { return }
        let alert = NSAlert()
        alert.messageText = "Feather Selection"
        alert.informativeText = "Soften the selection edge with a Gaussian radius in pixels. Image pixels stay unchanged until you paint or apply an edit."
        alert.addButton(withTitle: "Feather"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "8")
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal
        formatter.minimum = 0; formatter.maximum = 200
        field.formatter = formatter
        field.setAccessibilityLabel("Feather radius in pixels")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let radius = field.doubleValue
            guard radius.isFinite, (0...200).contains(radius) else { NSSound.beep(); return }
            self.applyFeather(radius: radius)
        }
    }

    func applyFeather(radius: Double) {
        guard let mask = canvas.selection, !mask.isEmpty, radius.isFinite, (0...200).contains(radius) else { return }
        canvas.changeSelection(mask.feathered(radius: radius, context: paintDocument.renderer.context), name: "Feather Selection")
    }
    @objc private func maskCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = LayerMaskCommand(rawValue: raw) else { return }
        performMaskCommand(command)
    }
    func performMaskCommand(_ command: LayerMaskCommand) {
        canvas.finishText()
        guard command.isEnabled(in: paintDocument.state) else { return }
        switch command {
        case .revealAll: paintDocument.addLayerMask(.revealAll)
        case .hideAll: paintDocument.addLayerMask(.hideAll)
        case .fromSelection: paintDocument.addLayerMask(.selection)
        case .invert: paintDocument.invertLayerMask()
        case .feather: featherMask(); return
        case .toggle: paintDocument.toggleLayerMask()
        case .apply: paintDocument.deleteLayerMask(apply: true)
        case .delete: paintDocument.deleteLayerMask(apply: false)
        }
        status.stringValue = paintDocument.state.isEditingMask ? "Editing layer mask · black hides · white reveals · X swaps colors." : canvas.tool.help
        window?.makeFirstResponder(canvas)
    }
    private func featherMask() {
        let layerID = paintDocument.state.activeID
        let alert = NSAlert(); alert.messageText = "Feather Layer Mask"
        alert.informativeText = "Soften mask edges with a Gaussian radius in image pixels. Original image pixels remain intact."
        alert.addButton(withTitle: "Feather"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "8")
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal; formatter.minimum = 0; formatter.maximum = 200
        field.formatter = formatter; field.setAccessibilityLabel("Mask feather radius in pixels")
        field.frame = CGRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, self.paintDocument.state.activeID == layerID,
                  field.doubleValue.isFinite, (0...200).contains(field.doubleValue) else { return }
            self.paintDocument.featherLayerMask(radius: field.doubleValue)
        }
    }
    private var clickedThumbnail: LayerThumbnailButton? {
        guard let event = NSApp.currentEvent, event.type == .leftMouseUp || event.type == .leftMouseDown,
              displayedLayerIDs.indices.contains(layerTable.clickedRow),
              let cell = layerTable.view(atColumn: 0, row: layerTable.clickedRow, makeIfNecessary: false) else { return nil }
        func thumbnail(in view: NSView) -> LayerThumbnailButton? {
            if let button = view as? LayerThumbnailButton, button.bounds.contains(button.convert(event.locationInWindow, from: nil)) { return button }
            return view.subviews.lazy.compactMap { thumbnail(in: $0) }.first
        }
        return thumbnail(in: cell)
    }
    @objc private func layerRowClicked() {
        guard NSApp.currentEvent?.modifierFlags.intersection([.command, .shift]).isEmpty == true,
              let button = clickedThumbnail else { return }
        selectLayerTarget(button.layerID, mask: button.editsMask)
        window?.makeFirstResponder(layerTable)
    }
    @objc private func layerRowDoubleClicked() {
        if let button = clickedThumbnail { selectLayerTarget(button.layerID, mask: button.editsMask); if button.editsMask { return } }
        editLayerContent()
    }
    @objc private func thumbnailClicked(_ sender: LayerThumbnailButton) {
        selectLayerTarget(sender.layerID, mask: sender.editsMask)
        window?.makeFirstResponder(layerTable)
        if !sender.editsMask, NSApp.currentEvent?.clickCount == 2 { editLayerContent() }
    }
    func selectLayerTarget(_ id: UUID, mask: Bool) {
        canvas.finishText()
        guard let layer = paintDocument.state.layers.first(where: { $0.id == id }), !mask || layer.mask != nil else { return }
        paintDocument.state.activeID = id; paintDocument.state.editingMask = mask
        refresh()
        status.stringValue = mask ? "Editing layer mask · black hides · white reveals · X swaps colors." : canvas.tool.help
        window?.makeFirstResponder(canvas)
    }
    private func synchronizeMaskColors() {
        let editingMask = paintDocument.state.isEditingMask
        guard editingMask != editingMaskColors else { return }
        if editingMask {
            pixelColors = (canvas.color, canvas.alternateColor)
            canvas.color = .maskBlack; canvas.alternateColor = .white
        } else if let saved = pixelColors {
            canvas.color = saved.0; canvas.alternateColor = saved.1; pixelColors = nil
        }
        editingMaskColors = editingMask
        for button in paletteButtons { button.maskMode = editingMask }
        colorWell.color = canvas.color.nsColor; hexField.stringValue = canvas.color.hex
        alternateColorWell.color = canvas.alternateColor.nsColor; alternateHexField.stringValue = canvas.alternateColor.hex
    }
    func invertSelection() {
        guard let mask = canvas.selection else { return }
        canvas.changeSelection(mask.inverted(), name: "Invert Selection")
    }
    @objc private func hardnessChanged() {
        canvas.brushHardness = hardnessSlider.doubleValue / 100
        hardnessValue.stringValue = "\(Int(hardnessSlider.doubleValue.rounded()))%"
        canvas.needsDisplay = true
    }
    @objc private func brushChanged() { updateBrushControls(); if canvas.textEditor != nil { canvas.focusText() } }
    private func updateBrushControls() {
        canvas.brushSize = sizeSlider.doubleValue.rounded()
        canvas.brushOpacity = opacitySlider.doubleValue / 100
        sizeValue.stringValue = "\(Int(canvas.brushSize)) px"
        opacityValue.stringValue = "\(Int(opacitySlider.doubleValue))%"
        canvas.needsDisplay = true
    }
    @objc private func toleranceChanged() { canvas.tolerance = toleranceSlider.integerValue }
    @objc private func colorChanged(_ sender: NSColorWell) { setColor(PixelColor(sender.color), alternate: sender === alternateColorWell) }
    @objc private func swatchClicked(_ sender: SwatchButton) { setColor(sender.color) }
    func setColor(_ color: PixelColor, alternate: Bool = false) {
        let color = paintDocument.state.isEditingMask ? color.maskColor : color
        if alternate {
            canvas.alternateColor = color; alternateColorWell.color = color.nsColor; alternateHexField.stringValue = color.hex
        } else {
            canvas.color = color; colorWell.color = color.nsColor; hexField.stringValue = color.hex
        }
        canvas.updateTextColor(color, alternate: alternate)
        canvas.focusText()
    }
    @objc private func swapColors() {
        let main = canvas.color
        setColor(canvas.alternateColor)
        setColor(main, alternate: true)
    }
    @objc private func hexChanged(_ sender: NSTextField) {
        let alternate = sender === alternateHexField
        let hex = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        if hex.count == 6, let value = UInt32(hex, radix: 16) {
            setColor(PixelColor(r: UInt8((value >> 16) & 255), g: UInt8((value >> 8) & 255), b: UInt8(value & 255)), alternate: alternate)
        } else { sender.stringValue = (alternate ? canvas.alternateColor : canvas.color).hex; NSSound.beep() }
    }
    @objc private func layerOpacityChanged() {
        paintDocument.edit("Layer Opacity") { $0.layers[$0.activeIndex].opacity = layerOpacity.doubleValue / 100 }
        window?.makeFirstResponder(canvas)
    }

    /// Right-click selects an unselected row, preserving a multi-selection
    /// when the clicked row is already included. Menu inspection never edits.
    func layerContextMenu(forRow row: Int) -> NSMenu? {
        guard displayedLayerIDs.indices.contains(row) else { return nil }
        let id = displayedLayerIDs[row]
        var selected = selectedLayerIDs
        if !selected.contains(id) { selected = [id] }
        if paintDocument.state.activeID != id {
            canvas.finishText()
            paintDocument.state.activeID = id
        }
        refresh(selectedIDs: selected)
        window?.makeFirstResponder(layerTable)
        return makeLayerContextMenu()
    }
    private func makeLayerContextMenu() -> NSMenu {
        let state = paintDocument.state, selected = selectedLayerIDs, layer = state.activeLayer
        let single = selected.count == 1
        let menu = NSMenu(title: single ? layer.name : "Selected Layers"); menu.autoenablesItems = false
        func bind(_ item: NSMenuItem) {
            guard let action = item.action else { return }
            item.representedObject = LayerMenuInvocation(action: action, value: item.representedObject, state: state, selectedIDs: selected)
            item.target = self; item.action = #selector(performLayerMenuAction(_:))
        }
        func command(_ title: String, _ action: Selector, enabled: Bool = true, value: String? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.isEnabled = enabled; item.representedObject = value; bind(item); menu.addItem(item)
        }
        if single {
            command("Rename…", #selector(renameLayer))
            command(layer.isGroup ? "Duplicate Group" : "Duplicate Layer", #selector(duplicateLayer), enabled: state.layers.count + state.subtreeIDs(layer.id).count <= 32)
            command(layer.visible ? "Hide Layer" : "Show Layer", #selector(contextVisibility))
            command(layer.isLocked ? "Unlock Layer" : "Lock Layer", #selector(toggleLayerLock), enabled: !state.ancestors(of: layer.id).contains(where: state.isEffectivelyLocked))
            if layer.text != nil || layer.effect != nil {
                menu.addItem(.separator())
                command(layer.text != nil ? "Edit Text…" : "Edit Effect…", #selector(editLayerContent), enabled: !state.isEffectivelyLocked(layer.id))
                if layer.text != nil { command("Rasterize Text Layer", #selector(rasterizeTextLayer), enabled: !state.isEffectivelyLocked(layer.id)) }
            }
            menu.addItem(.separator())
            if layer.isGroup {
                command(layer.expanded ? "Collapse Group" : "Expand Group", #selector(contextDisclosure))
                command("Ungroup", #selector(ungroup), enabled: state.canUngroupActive)
                command("Merge Group", #selector(mergeGroup), enabled: state.canModifySubtree(layer.id))
            } else {
                command(layer.effect != nil ? "Merge Below" : "Merge Down", #selector(mergeDown), enabled: state.canMergeDown)
            }
        }
        command(single ? "Group Layer" : "Group Selected Layers", #selector(groupSelected), enabled: (try? state.groupingLayers(selected)) != nil)
        let move = NSMenuItem(title: "Move to Group", action: nil, keyEquivalent: "")
        let destinations = NSMenu(); destinations.autoenablesItems = false
        func destination(_ title: String, parent: UUID?) {
            let item = NSMenuItem(title: title, action: #selector(contextMoveToGroup(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = parent?.uuidString
            let candidate = try? state.relocatingLayers(selected, into: parent, before: nil)
            item.isEnabled = candidate != nil && candidate != state && state.layers.contains { selected.contains($0.id) && $0.parentID != parent }
            bind(item); destinations.addItem(item)
        }
        destination("Top Level", parent: nil)
        let excluded = state.expandedMovingIDs(selected)
        for group in state.layers.reversed() where group.isGroup && !excluded.contains(group.id) {
            let path = (state.ancestors(of: group.id).reversed().compactMap { id in state.layers.first { $0.id == id }?.name } + [group.name]).joined(separator: " / ")
            destination(path, parent: group.id)
        }
        move.submenu = destinations; move.isEnabled = destinations.items.contains { $0.isEnabled }; menu.addItem(move)
        if single {
            command("Move Up", #selector(layerUp), enabled: state.canReorderActive(by: 1))
            command("Move Down", #selector(layerDown), enabled: state.canReorderActive(by: -1))
            menu.addItem(.separator())
            command(layer.isClipped ? "Release Clipping Mask" : "Create Clipping Mask", #selector(toggleClipping), enabled: state.canClipActive)
            let mask = NSMenuItem(title: "Layer Mask", action: nil, keyEquivalent: "")
            mask.submenu = LayerMaskCommand.menu(target: self, action: #selector(maskCommand(_:)), state: state)
            mask.submenu?.autoenablesItems = false
            mask.submenu?.items.forEach(bind)
            menu.addItem(mask)
            if layer.mask != nil {
                command(state.isEditingMask ? "Edit Layer Image" : "Edit Layer Mask", #selector(contextEditingTarget))
            }
        }
        menu.addItem(.separator())
        command(single ? (layer.isGroup ? "Delete Group" : "Delete Layer") : "Delete Selected Layers", #selector(removeLayer), enabled: state.canRemoveLayers(selected))
        return menu
    }
    @objc private func performLayerMenuAction(_ sender: NSMenuItem) {
        guard let invocation = sender.representedObject as? LayerMenuInvocation else { return }
        canvas.finishText()
        guard paintDocument.state.layers.contains(where: { $0.id == invocation.activeID }) else { return }
        paintDocument.state.activeID = invocation.activeID
        paintDocument.state.editingMask = invocation.editingMask && paintDocument.state.activeLayer.mask != nil
        refresh(selectedIDs: invocation.selectedIDs)
        let command = NSMenuItem(title: sender.title, action: invocation.action, keyEquivalent: "")
        command.representedObject = invocation.value
        NSApp.sendAction(invocation.action, to: self, from: command)
    }
    @objc private func contextVisibility() {
        paintDocument.edit("Layer Visibility") { $0.layers[$0.activeIndex].visible.toggle() }
    }
    @objc private func contextDisclosure() {
        guard paintDocument.state.activeLayer.isGroup else { return }
        canvas.finishText()
        paintDocument.state.layers[paintDocument.state.activeIndex].expanded.toggle()
        refresh()
    }
    @objc private func contextEditingTarget() {
        selectLayerTarget(paintDocument.state.activeID, mask: !paintDocument.state.isEditingMask)
    }
    @objc private func contextMoveToGroup(_ sender: NSMenuItem) { moveToGroup(sender) }

    func numberOfRows(in tableView: NSTableView) -> Int { displayedLayerIDs.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { LayerRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard displayedLayerIDs.indices.contains(row), let index = paintDocument.state.layers.firstIndex(where: { $0.id == displayedLayerIDs[row] }) else { return nil }
        let state = paintDocument.state, layer = state.layers[index]
        let cell = NSTableCellView()
        let eye = iconButton(layer.visible ? "eye" : "eye.slash", help: layer.visible ? "Hide Layer or Group" : "Show Layer or Group", action: #selector(toggleLayer(_:)))
        eye.tag = index
        eye.contentTintColor = layer.visible ? .secondaryLabelColor : .tertiaryLabelColor
        let active = layer.id == state.activeID
        let image = LayerThumbnailButton(layer: layer, mask: false, selected: active && !state.isEditingMask,
                                         target: self, action: #selector(thumbnailClicked(_:)))
        let name = label(layer.name, size: 12, weight: .medium)
        let unit = state.clippingUnits(parent: layer.parentID).first { $0.first == layer.id }
        if (unit?.count ?? 0) > 1 {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            name.attributedStringValue = NSAttributedString(string: layer.name, attributes: [.font: name.font!, .foregroundColor: NSColor.labelColor, .underlineStyle: NSUnderlineStyle.single.rawValue, .paragraphStyle: paragraph])
        }
        let count = state.children(of: layer.id).count
        let mode = active && state.isEditingMask ? "Mask" : (layer.text != nil ? "Text · editable" : (layer.effect != nil ? "Effect · editable" : (layer.isGroup ? "\(count) \(count == 1 ? "item" : "items")" : "Normal")))
        let detail = label(layer.visible ? "\(mode) · \(Int((layer.opacity * 100).rounded()))%\(layer.mask != nil && !layer.maskEnabled ? " · off" : "")" : "Hidden", size: 10, color: .secondaryLabelColor)
        // An unconstrained stack's intrinsic width can push long names outside
        // the row. Give the labels the exact remaining width of a plain view.
        let text = NSView(); text.translatesAutoresizingMaskIntoConstraints = false
        name.toolTip = layer.name
        for field in [name, detail] {
            field.translatesAutoresizingMaskIntoConstraints = false; text.addSubview(field)
            field.maximumNumberOfLines = 1; field.cell?.usesSingleLineMode = true
            field.cell?.wraps = false; field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.leadingAnchor.constraint(equalTo: text.leadingAnchor).isActive = true
            field.trailingAnchor.constraint(equalTo: text.trailingAnchor).isActive = true
        }
        NSLayoutConstraint.activate([text.heightAnchor.constraint(equalToConstant: 32), text.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
                                     name.topAnchor.constraint(equalTo: text.topAnchor), name.heightAnchor.constraint(equalToConstant: 16),
                                     detail.bottomAnchor.constraint(equalTo: text.bottomAnchor), detail.heightAnchor.constraint(equalToConstant: 12)])
        var elements: [NSView] = [eye]
        if layer.isGroup {
            let disclosure = NSButton(image: NSImage(systemSymbolName: layer.expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)!, target: self, action: #selector(toggleGroupDisclosure(_:)))
            disclosure.isBordered = false; disclosure.contentTintColor = .secondaryLabelColor; disclosure.tag = index
            disclosure.widthAnchor.constraint(equalToConstant: 12).isActive = true
            disclosure.setAccessibilityLabel(layer.expanded ? "Collapse \(layer.name)" : "Expand \(layer.name)")
            elements.append(disclosure)
        }
        if layer.isClipped {
            let marker = NSImageView(image: NSImage(systemSymbolName: "arrow.turn.down.right", accessibilityDescription: "Clipped to base layer")!)
            marker.contentTintColor = .secondaryLabelColor; marker.widthAnchor.constraint(equalToConstant: 10).isActive = true
            elements.append(marker)
        }
        elements.append(image)
        if layer.mask != nil {
            elements.append(LayerThumbnailButton(layer: layer, mask: true, selected: active && state.isEditingMask,
                                                 target: self, action: #selector(thumbnailClicked(_:))))
        }
        elements.append(text)
        let locked = state.isEffectivelyLocked(layer.id)
        let lock = NSButton(image: NSImage(systemSymbolName: locked ? "lock.fill" : "lock.open", accessibilityDescription: nil)!, target: self, action: #selector(toggleLockButton(_:)))
        lock.isBordered = false; lock.tag = index
        lock.contentTintColor = locked ? .labelColor : .tertiaryLabelColor
        lock.widthAnchor.constraint(equalToConstant: 16).isActive = true
        lock.setAccessibilityLabel("\(layer.isLocked ? "Unlock" : "Lock") \(layer.name)")
        lock.isEnabled = !state.ancestors(of: layer.id).contains(where: state.isEffectivelyLocked)
        lock.toolTip = lock.isEnabled ? "\(layer.isLocked ? "Unlock" : "Lock") layer content, mask, position, and deletion" : "Locked by a parent group"
        elements.append(lock)
        let rowStack = stack(elements, vertical: false, spacing: 4)
        rowStack.distribution = .fill
        rowStack.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(rowStack)
        let indent = min(30, state.ancestors(of: layer.id).count * 10)
        NSLayoutConstraint.activate([rowStack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: CGFloat(2 + indent)),
                                     rowStack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                                     rowStack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard displayedLayerIDs.indices.contains(row) else { return nil }
        let id = displayedLayerIDs[row]
        guard !paintDocument.state.expandedMovingIDs(selectedLayerIDs.union([id])).contains(where: paintDocument.state.isEffectivelyLocked) else { return nil }
        let item = NSPasteboardItem(); item.setString(id.uuidString, forType: LayerTableView.pasteboardType); return item
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        let ids = Set(rowIndexes.compactMap { displayedLayerIDs.indices.contains($0) ? displayedLayerIDs[$0] : nil })
        guard let first = rowIndexes.compactMap({ displayedLayerIDs.indices.contains($0) ? displayedLayerIDs[$0] : nil }).first else { return }
        canvas.finishText()
        if !ids.contains(paintDocument.state.activeID) { paintDocument.state.activeID = first }
        layerTable.selectRowIndexes(rowIndexes, byExtendingSelection: false)
        refresh(selectedIDs: ids, updateRows: false)
        window?.makeFirstResponder(layerTable)
    }
    /// Translate a visual top-to-bottom boundary into a sibling insertion in
    /// canonical bottom-to-top storage. A drop on a group appends inside it.
    func layerDropDestination(row: Int, operation: NSTableView.DropOperation) -> (parent: UUID?, before: UUID?)? {
        let state = paintDocument.state
        guard (0...displayedLayerIDs.count).contains(row) else { return nil }
        if operation == .on {
            guard displayedLayerIDs.indices.contains(row), let node = state.layers.first(where: { $0.id == displayedLayerIDs[row] }), node.isGroup else { return nil }
            return (node.id, nil)
        }
        if row == displayedLayerIDs.count { return (nil, state.children(of: nil).first?.id) }
        guard let node = state.layers.first(where: { $0.id == displayedLayerIDs[row] }) else { return nil }
        let units = state.clippingUnits(parent: node.parentID)
        guard let index = units.firstIndex(where: { $0.contains(node.id) }) else { return nil }
        return (node.parentID, index + 1 < units.count ? units[index + 1][0] : nil)
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard (info.draggingSource as? NSTableView) === layerTable,
              let destination = layerDropDestination(row: row, operation: operation) else { return [] }
        let ids = LayerTableView.draggedIDs(info.draggingPasteboard)
        guard !ids.isEmpty, (try? paintDocument.state.relocatingLayers(ids, into: destination.parent, before: destination.before)) != nil else { return [] }
        if operation == .above, displayedLayerIDs.indices.contains(row),
           let node = paintDocument.state.layers.first(where: { $0.id == displayedLayerIDs[row] }),
           let top = paintDocument.state.clippingUnits(parent: node.parentID).first(where: { $0.contains(node.id) })?.last,
           let boundary = displayedLayerIDs.firstIndex(of: top) { tableView.setDropRow(boundary, dropOperation: .above) }
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        guard self.tableView(tableView, validateDrop: info, proposedRow: row, proposedDropOperation: operation) == .move,
              let destination = layerDropDestination(row: row, operation: operation) else { return false }
        let ids = LayerTableView.draggedIDs(info.draggingPasteboard)
        do {
            try paintDocument.moveLayers(ids, into: destination.parent, before: destination.before)
            refresh(selectedIDs: ids); window?.makeFirstResponder(layerTable); return true
        } catch { return false }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshing, displayedLayerIDs.indices.contains(layerTable.selectedRow) else { return }
        let ids = selectedLayerIDs
        let clicked = layerTable.clickedRow
        let row = displayedLayerIDs.indices.contains(clicked) && ids.contains(displayedLayerIDs[clicked]) ? clicked : layerTable.selectedRow
        let selectedID = displayedLayerIDs[row]
        canvas.finishText()
        paintDocument.state.activeID = selectedID
        refresh(selectedIDs: ids, updateRows: false)
        // Reloading rows inside mouseDown destroys AppKit's drag tracking.
        // Update selection immediately and refresh controls after tracking ends.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            guard let self, self.paintDocument.state.activeID == selectedID, self.selectedLayerIDs == ids else { return }
            self.refresh(selectedIDs: ids)
        }
        window?.makeFirstResponder(layerTable)
    }
    @objc private func toggleLayer(_ sender: NSButton) {
        guard paintDocument.state.layers.indices.contains(sender.tag) else { return }
        paintDocument.edit("Layer Visibility") { $0.layers[sender.tag].visible.toggle() }
    }
    @objc private func toggleGroupDisclosure(_ sender: NSButton) {
        canvas.finishText()
        let index = sender.tag
        guard paintDocument.state.layers.indices.contains(index), paintDocument.state.layers[index].isGroup else { return }
        let id = paintDocument.state.layers[index].id
        paintDocument.state.layers[index].expanded.toggle()
        if !paintDocument.state.layers[index].expanded && paintDocument.state.ancestors(of: paintDocument.state.activeID).contains(id) { paintDocument.state.activeID = id }
        refresh()
    }
    @objc func addLayer() {
        guard paintDocument.state.layers.count < 32 else { showError(PaintError.tooManyLayers); return }
        paintDocument.edit("Add Layer") { state in
            state.insertLayer(PaintLayer(name: "Layer \(state.layers.count)", raster: Raster(width: state.width, height: state.height, format: state.format)))
        }
    }
    @objc func duplicateLayer() { do { try paintDocument.duplicateActiveNode() } catch { showError(error) } }
    @objc func removeLayer() { paintDocument.removeLayers(selectedLayerIDs) }
    @objc func toggleLayerLock() { paintDocument.toggleLayerLock(paintDocument.state.activeID) }
    @objc private func toggleLockButton(_ sender: NSButton) {
        guard paintDocument.state.layers.indices.contains(sender.tag) else { return }
        paintDocument.toggleLayerLock(paintDocument.state.layers[sender.tag].id)
    }
    @objc func layerUp() { paintDocument.reorderActiveNode(by: 1) }
    @objc func layerDown() { paintDocument.reorderActiveNode(by: -1) }
    @objc func renameLayer() {
        let alert = NSAlert(); alert.messageText = "Rename layer"; alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: paintDocument.state.activeLayer.name); field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            self.paintDocument.edit("Rename Layer") { $0.layers[$0.activeIndex].name = name }
        }
        alert.window.initialFirstResponder = field
    }
    @objc private func mergeSelected() { if paintDocument.state.activeLayer.isGroup { mergeGroup() } else { mergeDown() } }
    @objc func mergeDown() { paintDocument.mergeActiveDown() }
    @objc func mergeGroup() { paintDocument.mergeActiveGroup() }
    @objc func newGroup() { do { try paintDocument.createGroup() } catch { showError(error) } }
    @objc func groupSelected() { do { try paintDocument.createGroup(wrapping: selectedLayerIDs) } catch { showError(error) } }
    @objc func ungroup() { paintDocument.ungroupActive() }
    @objc func toggleClipping() { paintDocument.toggleClippingMask() }
    @objc private func moveToGroup(_ sender: NSMenuItem) {
        let parent = (sender.representedObject as? String).flatMap(UUID.init(uuidString:))
        do { try paintDocument.moveLayers(selectedLayerIDs, into: parent) } catch { showError(error) }
    }
    private func updateStructureMenu() {
        let state = paintDocument.state
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(withTitle: "Layers", action: nil, keyEquivalent: "")
        func command(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.isEnabled = enabled; menu.addItem(item)
        }
        let effect = NSMenuItem(title: "New Effect Layer", action: nil, keyEquivalent: ""); effect.submenu = effectMenu(); menu.addItem(effect)
        command(state.activeLayer.isLocked ? "Unlock Layer" : "Lock Layer", #selector(toggleLayerLock), enabled: !state.ancestors(of: state.activeID).contains(where: state.isEffectivelyLocked))
        command("Edit Text / Effect…", #selector(editLayerContent), enabled: !state.isEffectivelyLocked(state.activeID) && (state.activeLayer.text != nil || state.activeLayer.effect != nil))
        command("Rasterize Text Layer", #selector(rasterizeTextLayer), enabled: !state.isEffectivelyLocked(state.activeID) && state.activeLayer.text != nil)
        menu.addItem(.separator())
        command("New Group", #selector(newGroup), enabled: state.layers.count < 32)
        command("Group Selected Layers (⌘G)", #selector(groupSelected), enabled: state.layers.count < 32)
        command("Ungroup (⇧⌘G)", #selector(ungroup), enabled: state.canUngroupActive)
        menu.items.last?.toolTip = "Ungroup requires a visible 100% group without a mask, clipping, or unconfined effects. Merge Group preserves its appearance."
        command("Merge Group", #selector(mergeGroup), enabled: state.activeLayer.isGroup && state.canModifySubtree(state.activeID))
        menu.addItem(.separator())
        command(state.activeLayer.isClipped ? "Release Clipping Mask (⌥⌘G)" : "Create Clipping Mask (⌥⌘G)", #selector(toggleClipping), enabled: state.canClipActive)
        menu.addItem(.separator())
        let move = NSMenuItem(title: "Move to Group", action: nil, keyEquivalent: "")
        let destinations = NSMenu(); destinations.autoenablesItems = false
        let selected = selectedLayerIDs
        let excluded = selected.reduce(into: Set<UUID>()) { $0.formUnion(state.subtreeIDs($1)) }
        let top = NSMenuItem(title: "Top Level", action: #selector(moveToGroup(_:)), keyEquivalent: ""); top.target = self
        top.isEnabled = state.layers.contains { selected.contains($0.id) && $0.parentID != nil }; destinations.addItem(top)
        for group in state.layers.reversed() where group.isGroup && !excluded.contains(group.id) {
            let path = (state.ancestors(of: group.id).reversed().compactMap { id in state.layers.first { $0.id == id }?.name } + [group.name]).joined(separator: " / ")
            let item = NSMenuItem(title: path, action: #selector(moveToGroup(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = group.id.uuidString
            item.isEnabled = state.layers.contains { selected.contains($0.id) && $0.parentID != group.id }
            destinations.addItem(item)
        }
        move.submenu = destinations; menu.addItem(move); structureButton.menu = menu
    }
    func cropToSelection() {
        guard let selection = canvas.selection, !selection.isEmpty else { return }
        let rect = selection.bounds
        paintDocument.edit("Crop to Selection", protectLockedLayers: false) { state in
            for i in state.layers.indices {
                state.layers[i].raster = state.layers[i].raster.cropped(to: rect)
                if var text = state.layers[i].text {
                    text.transform(dx: -rect.minX, dy: -rect.minY); state.layers[i].text = text
                    state.layers[i].textClip = state.layers[i].textClip?.translated(dx: -Int(rect.minX), dy: -Int(rect.minY), width: state.layers[i].raster.width, height: state.layers[i].raster.height)
                }
                state.layers[i].mask = state.layers[i].mask?.translated(dx: -Int(rect.minX), dy: -Int(rect.minY), width: state.layers[i].raster.width, height: state.layers[i].raster.height)
            }
            state.width = state.layers[0].raster.width; state.height = state.layers[0].raster.height
            state.selection = nil
        }
        canvas.selection = nil; canvas.zoomToFit()
    }
    func showImageProperties() {
        canvas.finishText()
        let dialog = ImagePropertiesDialog(state: paintDocument.state)
        dialog.onApply = { [weak self] format, resolution, size, smooth in
            guard let self else { return }
            do {
                try self.paintDocument.applyColorSettings(format, resolution: resolution, pixelSize: size, smooth: smooth)
                if size != nil { self.canvas.zoomToFit() }
            } catch { self.showError(error) }
        }
        dialog.show(for: window!)
    }
    func resizeImage() { showSizeDialog(mode: .scale) }
    func resizeCanvas() { showSizeDialog(mode: .resize) }
    private func showSizeDialog(mode: CanvasSizeMode) {
        let dialog = CanvasSizeDialog(width: paintDocument.state.width, height: paintDocument.state.height,
                                      mode: mode, smooth: canvas.smooth)
        dialog.onApply = { [weak self] plan, mode, smooth in
            guard let self else { return }
            do {
                try self.paintDocument.applySize(plan, mode: mode, smooth: smooth)
                self.canvas.zoomToFit()
            } catch { self.showError(error) }
        }
        dialog.show(for: window!)
    }
    func applyAdjustment(_ filter: String, name: String) {
        canvas.finishText()
        guard paintDocument.state.activeEffectivelyVisible, paintDocument.state.canPaintTarget else { return }
        let original = paintDocument.state.editingRaster
        let image = original.ciImage.applyingFilter(filter)
        let output = paintDocument.renderer.cgImage(image, format: original.format)
        guard let raster = try? Raster(image: output, format: original.format) else { return }
        paintDocument.edit(name) { state in
            state.editingRaster = original.blending(raster, selection: state.selection)
        }
    }
    func copyPixels(cut: Bool = false) {
        canvas.finishText()
        guard canvas.selection?.isEmpty != true else { return }
        let state = paintDocument.state
        guard state.isEditingMask || state.activeLayer.effect == nil else { NSSound.beep(); return }
        guard !cut || (state.canPaintTarget && state.activeEffectivelyVisible) else { NSSound.beep(); return }
        let source: Raster
        if state.isEditingMask { source = state.editingRaster }
        else if state.activeLayer.isGroup {
            guard let image = try? Raster(image: paintDocument.renderer.contentImage(of: state.activeID, layers: state.layers, width: state.width, height: state.height)) else { return }
            source = image
        } else { source = state.activeLayer.displayRaster }
        let raster = canvas.selection.map { source.masked(using: $0).cropped(to: $0.bounds) } ?? source
        let pasteboard = NSPasteboard.general; pasteboard.clearContents()
        let image = NSImage(cgImage: raster.cgImage, size: NSSize(width: raster.width, height: raster.height))
        pasteboard.writeObjects([image])
        if cut { canvas.deletePixels() }
    }
    func pastePixels() {
        guard let data = NSPasteboard.general.data(forType: .png) ?? NSPasteboard.general.data(forType: .tiff) else { return }
        do { try importLayer(ProjectCodec.decodeImage(data), name: "Pasted Image") } catch { showError(error) }
    }
    func importLayer(_ raster: Raster, name: String) throws {
        guard paintDocument.state.layers.count < 32 else { throw PaintError.tooManyLayers }
        let raster = try raster.converted(to: paintDocument.state.format)
        let dx = max(0, (paintDocument.state.width - raster.width) / 2), dy = max(0, (paintDocument.state.height - raster.height) / 2)
        let placed = raster.resizedCanvas(width: paintDocument.state.width, height: paintDocument.state.height, offsetX: dx, offsetY: dy)
        paintDocument.edit("Import Layer") { state in
            let layer = PaintLayer(name: name, raster: placed)
            state.insertLayer(layer)
            state.selection = nil
        }
        canvas.selection = nil
    }
    @objc private func showZoomMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for percent in [25, 50, 75, 100, 150, 200, 400, 800] {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(zoomPreset(_:)), keyEquivalent: "")
            item.tag = percent; item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        let fit = NSMenuItem(title: "Fit to Window", action: #selector(fitCanvas), keyEquivalent: ""); fit.target = self; menu.addItem(fit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }
    @objc private func zoomPreset(_ sender: NSMenuItem) { canvas.setZoom(CGFloat(sender.tag) / 100) }
    @objc private func fitCanvas() { canvas.zoomToFit() }
    func showError(_ error: Error) { NSAlert(error: error).beginSheetModal(for: window!) }
}
