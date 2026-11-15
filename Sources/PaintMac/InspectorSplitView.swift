import AppKit

/// The inspector keeps a user-chosen width while window resizing gives the
/// remaining space to the canvas. A smaller window temporarily clamps it.
final class InspectorSplitView: NSSplitView, NSSplitViewDelegate {
    static let defaultInspectorWidth: CGFloat = 252
    static let minimumCanvasWidth: CGFloat = 320
    static let widthPreferenceKey = "PaintMacInspectorWidth"
    private let preferences: UserDefaults
    private(set) var preferredInspectorWidth: CGFloat

    init(canvas: NSView, inspector: NSView, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let saved = preferences.double(forKey: Self.widthPreferenceKey)
        preferredInspectorWidth = saved.isFinite && saved >= Self.defaultInspectorWidth ? saved : Self.defaultInspectorWidth
        super.init(frame: .zero)
        isVertical = true; dividerStyle = .thin; delegate = self
        setAccessibilityLabel("Canvas and Colors & Layers inspector")
        inspector.setAccessibilityLabel("Colors & Layers inspector")
        for view in [canvas, inspector] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addArrangedSubview(view)
        }
        layoutPanes()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func layoutPanes() {
        guard arrangedSubviews.count == 2 else { return }
        let available = max(0, bounds.width - dividerThickness)
        let maximum = max(Self.defaultInspectorWidth, available - Self.minimumCanvasWidth)
        let width = min(available, min(maximum, preferredInspectorWidth))
        arrangedSubviews[0].frame = CGRect(x: 0, y: 0, width: available - width, height: bounds.height)
        arrangedSubviews[1].frame = CGRect(x: available - width + dividerThickness, y: 0, width: width, height: bounds.height)
    }
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) { layoutPanes() }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, Self.minimumCanvasWidth)
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, bounds.width - dividerThickness - Self.defaultInspectorWidth)
    }
    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let position = min(max(Self.minimumCanvasWidth, proposedPosition), bounds.width - dividerThickness - Self.defaultInspectorWidth)
        preferredInspectorWidth = bounds.width - dividerThickness - position
        preferences.set(Double(preferredInspectorWidth), forKey: Self.widthPreferenceKey)
        return position
    }
    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        drawnRect.insetBy(dx: -3, dy: 0)
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, let canvas = arrangedSubviews.first, abs(point.x - canvas.frame.maxX) <= 4 {
            setPosition(bounds.width - dividerThickness - Self.defaultInspectorWidth, ofDividerAt: 0)
            return
        }
        super.mouseDown(with: event)
    }
}
