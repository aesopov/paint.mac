import AppKit

enum ToolGroup: CaseIterable {
    case shapes, selections
    var title: String { self == .shapes ? "Shapes" : "Selections" }
    var tools: [PaintTool] { self == .shapes ? [.rectangle, .ellipse, .line] : [.selection, .ellipseSelect, .lasso] }
}

class ToolButton: NSButton {
    var selected = false { didSet { needsDisplay = true; contentTintColor = selected ? .white : .secondaryLabelColor } }
    override func draw(_ dirtyRect: NSRect) {
        if selected {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
        super.draw(dirtyRect)
    }
}

private final class ToolFlyoutContent: NSVisualEffectView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area; super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

private final class ToolFlyoutPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ToolVariantButton: NSButton {
    let tool: PaintTool
    let current: Bool
    var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    init(tool: PaintTool, current: Bool, target: AnyObject, action: Selector) {
        self.tool = tool; self.current = current
        super.init(frame: .zero)
        self.target = target; self.action = action; isBordered = false
        setAccessibilityLabel(tool.title); setAccessibilityValue(current ? "Current type" : "")
        toolTip = "\(tool.title) (\(tool.key.uppercased()))"
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area; super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted || current {
            NSColor.controlAccentColor.withAlphaComponent(hovered || isHighlighted ? 0.22 : 0.10).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        let font = NSFont.systemFont(ofSize: 12)
        if current { ("✓" as NSString).draw(at: NSPoint(x: 8, y: 8), withAttributes: [.font: font, .foregroundColor: NSColor.labelColor]) }
        EditorIcon.draw(tool.icon, in: NSRect(x: 27, y: 8, width: 16, height: 16))
        (tool.title as NSString).draw(at: NSPoint(x: 52, y: 8), withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
        (tool.key.uppercased() as NSString).draw(at: NSPoint(x: bounds.width - 20, y: 8), withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
    }
}

/// A nonactivating child panel keeps hovering out of the document's responder
/// chain. Native text focus and drafts change only when a type is chosen.
final class ToolGroupButton: ToolButton {
    private static weak var activeFlyoutButton: ToolGroupButton?
    let group: ToolGroup
    private(set) var currentTool: PaintTool
    var onChoose: ((PaintTool) -> Void)?
    private(set) var flyout: NSPanel?
    private var rows: [ToolVariantButton] = []
    private var tracking: NSTrackingArea?
    private var opening: DispatchWorkItem?
    private var closing: DispatchWorkItem?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var keyboardNavigation = false
    private var keyboardIndex = 0

    init(group: ToolGroup) {
        self.group = group; currentTool = group.tools[0]
        super.init(frame: .zero)
        target = self; action = #selector(activateCurrent)
        isBordered = false; imagePosition = .imageOnly; imageScaling = .scaleProportionallyDown
        setCurrentTool(currentTool)
    }
    required init?(coder: NSCoder) { fatalError() }
    func setCurrentTool(_ tool: PaintTool) {
        guard group.tools.contains(tool) else { return }
        currentTool = tool
        image = tool.icon
        setAccessibilityLabel("\(group.title): \(tool.title)")
        setAccessibilityHelp("Hover to show tool types on the right. Click to select \(tool.title).")
        toolTip = "\(group.title) · \(tool.title) (\(tool.key.uppercased())) · Hover or right-click for types"
        needsDisplay = true
    }
    @objc private func activateCurrent() { onChoose?(currentTool) }
    @objc private func chooseRow(_ sender: ToolVariantButton) { choose(sender.tool) }
    private func choose(_ tool: PaintTool) { dismissFlyout(); setCurrentTool(tool); onChoose?(tool) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        (selected ? NSColor.white : .secondaryLabelColor).setFill()
        let arrow = NSBezierPath(); arrow.move(to: NSPoint(x: bounds.maxX - 7, y: 5))
        arrow.line(to: NSPoint(x: bounds.maxX - 3, y: 8)); arrow.line(to: NSPoint(x: bounds.maxX - 7, y: 11)); arrow.close(); arrow.fill()
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area; super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) {
        closing?.cancel()
        guard window?.isKeyWindow == true, NSEvent.pressedMouseButtons == 0 else { return }
        opening?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showFlyout() }; opening = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    override func mouseExited(with event: NSEvent) { opening?.cancel(); scheduleDismissal() }
    private func scheduleDismissal() {
        closing?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            if self.flyout?.frame.contains(mouse) == true || self.screenFrame?.contains(mouse) == true { return }
            self.dismissFlyout()
        }
        closing = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    private var screenFrame: CGRect? { window.map { $0.convertToScreen(convert(bounds, to: nil)) } }
    func showFlyout(keyboard: Bool = false) {
        opening?.cancel(); closing?.cancel()
        if flyout != nil { keyboardNavigation = keyboardNavigation || keyboard; return }
        guard let window, window.isVisible, let anchor = screenFrame else { return }
        Self.activeFlyoutButton?.dismissFlyout(); Self.activeFlyoutButton = self
        keyboardNavigation = keyboard; keyboardIndex = group.tools.firstIndex(of: currentTool) ?? 0
        let panel = ToolFlyoutPanel(contentRect: NSRect(x: 0, y: 0, width: 214, height: 108),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = true; panel.appearance = window.appearance
        let content = ToolFlyoutContent(frame: NSRect(x: 0, y: 0, width: 214, height: 108))
        content.material = .popover; content.blendingMode = .behindWindow; content.state = .active
        content.wantsLayer = true; content.layer?.cornerRadius = 7; content.layer?.masksToBounds = true
        content.onEnter = { [weak self] in self?.closing?.cancel() }
        content.onExit = { [weak self] in self?.scheduleDismissal() }
        rows = group.tools.enumerated().map { index, tool in
            let row = ToolVariantButton(tool: tool, current: tool == currentTool, target: self, action: #selector(chooseRow(_:)))
            row.frame = NSRect(x: 4, y: 4 + (2 - index) * 33, width: 206, height: 33)
            content.addSubview(row); return row
        }
        panel.contentView = content
        let visible = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        panel.setFrameOrigin(NSPoint(x: min(anchor.maxX + 4, visible.maxX - panel.frame.width),
                                     y: max(visible.minY, min(anchor.maxY - panel.frame.height, visible.maxY - panel.frame.height))))
        flyout = panel; window.addChildWindow(panel, ordered: .above); panel.orderFront(nil)
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.dismissFlyout() })
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.dismissFlyout() })
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.dismissFlyout(); return nil }
                if self.keyboardNavigation {
                    if event.keyCode == 125 || event.keyCode == 126 {
                        self.keyboardIndex = (self.keyboardIndex + (event.keyCode == 125 ? 1 : self.rows.count - 1)) % self.rows.count
                        for (i, row) in self.rows.enumerated() { row.hovered = i == self.keyboardIndex }; return nil
                    }
                    if event.keyCode == 36 || event.keyCode == 76 { self.choose(self.group.tools[self.keyboardIndex]); return nil }
                }
                self.dismissFlyout(); return event
            }
            if event.window !== self.flyout { self.dismissFlyout() }
            return event
        }
    }
    func dismissFlyout() {
        if Self.activeFlyoutButton === self { Self.activeFlyoutButton = nil }
        opening?.cancel(); opening = nil; closing?.cancel(); closing = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll()
        if let flyout { flyout.parent?.removeChildWindow(flyout); flyout.close() }; flyout = nil; rows.removeAll()
    }
    override func rightMouseDown(with event: NSEvent) { showFlyout(keyboard: true) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 124 || event.keyCode == 125 { showFlyout(keyboard: true) }
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformShowMenu() -> Bool { showFlyout(keyboard: true); return flyout != nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { dismissFlyout() } }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        flyout?.close()
    }
}
