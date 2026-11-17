import AppKit

/// Square toolbar swatches with native color-panel ownership and color actions.
/// Modern AppKit draws circular wells even in the default style, so supply only
/// the face and activation behavior here; NSColorWell still manages the picker.
final class SquareColorWell: NSColorWell {
    override var wantsUpdateLayer: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let face = bounds.insetBy(dx: 3, dy: 3)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: face).addClip()
        NSColor.white.setFill(); face.fill()
        NSColor(white: 0.78, alpha: 1).setFill()
        for y in 0..<Int(ceil(face.height / 4)) { for x in 0..<Int(ceil(face.width / 4)) where (x + y) % 2 == 0 {
            NSRect(x: face.minX + CGFloat(x * 4), y: face.minY + CGFloat(y * 4), width: 4, height: 4).fill()
        } }
        color.setFill(); face.fill()
        NSGraphicsContext.restoreGraphicsState()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        NSColor.labelColor.withAlphaComponent(0.55).setStroke(); border.lineWidth = 1; border.stroke()
        if isActive {
            NSColor.controlAccentColor.setStroke()
            let active = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5)); active.lineWidth = 1; active.stroke()
        }
    }

    private func showPicker() {
        activate(true)
        NSColorPanel.shared.orderFront(nil)
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) { showPicker() }
    override func performClick(_ sender: Any?) { showPicker() }
    override func accessibilityPerformPress() -> Bool { showPicker(); return true }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.charactersIgnoringModifiers == "\r" { showPicker() }
        else { super.keyDown(with: event) }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}
