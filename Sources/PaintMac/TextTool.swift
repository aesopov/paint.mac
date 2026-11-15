import AppKit

struct TextStyle: Equatable, Codable {
    var family = "Helvetica Neue"
    var size: Double = 48
    var bold = false
    var italic = false

    var font: NSFont {
        let manager = NSFontManager.shared
        var font = manager.font(withFamily: family, traits: [], weight: 5, size: size) ?? .systemFont(ofSize: size)
        if bold { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }
}

/// Native text input supplies caret, selection, IME and undo behavior, but never
/// draws glyphs. CanvasView displays the rasterized layer preview underneath it.
final class CanvasTextEditor: NSView {
    private let textSystem = TextRasterLayout()
    let textView: DraftTextView
    private let moveBar = TextBoxHandle()
    private let resizeHandle = TextBoxHandle()
    private(set) var imageBounds: CGRect
    private let canvasSize: CGSize
    private let allowsOutsideCanvas: Bool
    var horizontalScale: Double = 1
    private var zoom: CGFloat = 1
    private var startingBounds = CGRect.zero
    var onApply: (() -> Void)?
    var onCancel: (() -> Void)?
    var onTextChange: (() -> Void)?
    var onGeometryChange: (() -> Void)?
    var onScroll: ((NSEvent) -> Void)? { didSet { textView.onScroll = onScroll } }
    var onMagnify: ((NSEvent) -> Void)? { didSet { textView.onMagnify = onMagnify } }
    var onOtherMouseEvent: ((NSEvent) -> Void)? { didSet { textView.onOtherMouseEvent = onOtherMouseEvent } }
    override var isFlipped: Bool { true }

    init(rect: CGRect, canvasSize: CGSize, allowsOutsideCanvas: Bool = false) {
        imageBounds = rect; self.canvasSize = canvasSize; self.allowsOutsideCanvas = allowsOutsideCanvas
        textView = DraftTextView(frame: .zero, textContainer: textSystem.container)
        super.init(frame: .zero)
        setImageBounds(rect)
        wantsLayer = true
        textView.isRichText = false; textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = false; textView.isHorizontallyResizable = false
        textView.minSize = .zero; textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = .zero; textView.clipsToBounds = true
        textView.textColor = .clear; textView.insertionPointColor = .controlAccentColor
        textView.setAccessibilityLabel("Canvas text")
        textView.onApply = { [weak self] in self?.onApply?() }
        textView.onCancel = { [weak self] in self?.onCancel?() }
        textView.onTextChange = { [weak self] in self?.onTextChange?() }
        addSubview(textView); addSubview(moveBar); addSubview(resizeHandle)
        moveBar.title = "Move text"; moveBar.setAccessibilityLabel("Move text box")
        resizeHandle.title = "◢"; resizeHandle.setAccessibilityLabel("Resize text box")
        moveBar.onBegin = { [weak self] in self?.startingBounds = self?.imageBounds ?? .zero }
        resizeHandle.onBegin = moveBar.onBegin
        moveBar.onDrag = { [weak self] delta in
            guard let self else { return }
            self.setImageBounds(self.startingBounds.offsetBy(dx: (delta.x / self.zoom).rounded(), dy: (delta.y / self.zoom).rounded()))
        }
        resizeHandle.onDrag = { [weak self] delta in
            guard let self else { return }
            var rect = self.startingBounds
            rect.size.width += (delta.x / self.zoom).rounded(); rect.size.height += (delta.y / self.zoom).rounded()
            self.setImageBounds(rect)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func setImageBounds(_ rect: CGRect) {
        if allowsOutsideCanvas {
            imageBounds = CGRect(x: rect.minX, y: rect.minY, width: min(32768, max(1.0 / 32768, rect.width)), height: min(32768, max(1.0 / 32768, rect.height)))
            onGeometryChange?(); return
        }
        let minWidth = min(16, canvasSize.width), minHeight = min(16, canvasSize.height)
        let w = min(canvasSize.width, max(minWidth, rect.width.rounded()))
        let h = min(canvasSize.height, max(minHeight, rect.height.rounded()))
        imageBounds = CGRect(x: min(max(0, rect.minX.rounded()), canvasSize.width - w),
                             y: min(max(0, rect.minY.rounded()), canvasSize.height - h), width: w, height: h)
        onGeometryChange?()
    }
    func place(at point: CGPoint, zoom: CGFloat) {
        self.zoom = zoom
        let textRect = CGRect(origin: point, size: CGSize(width: imageBounds.width * zoom, height: imageBounds.height * zoom))
        let viewport = superview?.bounds ?? .zero
        let bar = CGRect(x: max(0, min(point.x, viewport.width - 106)),
                         y: max(0, min(point.y - 27, viewport.height - 26)), width: 106, height: 26)
        frame = textRect.union(bar)
        let localText = textRect.offsetBy(dx: -frame.minX, dy: -frame.minY)
        textView.frame = localText
        // Input geometry uses image pixels too; zoom scales the view, not fonts
        // or line wrapping. There is no enclosing scroll view to move the text.
        textView.bounds = CGRect(origin: .zero, size: CGSize(width: imageBounds.width / horizontalScale, height: imageBounds.height))
        textSystem.container.containerSize = CGSize(width: imageBounds.width / horizontalScale, height: CGFloat.greatestFiniteMagnitude)
        textView.caretWidth = 1 / zoom
        let localBar = bar.offsetBy(dx: -frame.minX, dy: -frame.minY)
        moveBar.frame = localBar
        resizeHandle.frame = CGRect(x: localText.maxX - 14, y: localText.maxY - 14, width: 14, height: 14)
        needsDisplay = true; textView.needsDisplay = true
    }
    func update(style: TextStyle) {
        if textView.font != style.font { textView.font = style.font }
        textView.needsDisplay = true
    }
    func focus() { window?.makeFirstResponder(textView) }
    override func otherMouseDown(with event: NSEvent) { onOtherMouseEvent?(event) }
    override func otherMouseDragged(with event: NSEvent) { onOtherMouseEvent?(event) }
    override func otherMouseUp(with event: NSEvent) { onOtherMouseEvent?(event) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: textView.frame.insetBy(dx: -0.5, dy: -0.5)); path.lineWidth = 1; path.stroke()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

final class DraftTextView: NSTextView {
    var onApply: (() -> Void)?
    var onCancel: (() -> Void)?
    var onTextChange: (() -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    var onMagnify: ((NSEvent) -> Void)?
    var onOtherMouseEvent: ((NSEvent) -> Void)?
    var caretWidth: CGFloat = 1
    private let draftUndo = UndoManager()
    override var undoManager: UndoManager? { draftUndo }
    override func didChangeText() { super.didChangeText(); onTextChange?(); needsDisplay = true }
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
    override func magnify(with event: NSEvent) { onMagnify?(event) }
    override func otherMouseDown(with event: NSEvent) { onOtherMouseEvent?(event) }
    override func otherMouseDragged(with event: NSEvent) { onOtherMouseEvent?(event) }
    override func otherMouseUp(with event: NSEvent) { onOtherMouseEvent?(event) }
    override func scrollRangeToVisible(_ range: NSRange) {} // Overflow remains cropped at the box's top-left.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        if (event.keyCode == 36 || event.keyCode == 76) && event.modifierFlags.contains(.command) { onApply?(); return }
        super.keyDown(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        // Deliberately omit super.draw: text glyphs are already in the canvas's
        // raster preview. Only native input adornments are drawn over the pixels.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.clip(to: bounds)
        guard let manager = layoutManager, let container = textContainer else { return }
        manager.ensureLayout(for: container)
        let selected = selectedRange()
        if selected.length > 0 {
            let glyphs = manager.glyphRange(forCharacterRange: selected, actualCharacterRange: nil)
            NSColor.selectedTextBackgroundColor.withAlphaComponent(0.28).setFill()
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: container) { rect, _ in rect.fill() }
        } else if window?.firstResponder === self, let window {
            let screen = firstRect(forCharacterRange: NSRange(location: selected.location, length: 0), actualRange: nil)
            let rect = convert(window.convertFromScreen(screen), from: nil)
            insertionPointColor.setFill()
            CGRect(x: rect.minX, y: rect.minY, width: caretWidth, height: rect.height).fill()
        }
        if hasMarkedText() {
            let glyphs = manager.glyphRange(forCharacterRange: markedRange(), actualCharacterRange: nil)
            NSColor.controlAccentColor.setFill()
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: container) { rect, _ in
                CGRect(x: rect.minX, y: rect.maxY - self.caretWidth, width: rect.width, height: self.caretWidth).fill()
            }
        }
    }
}

private final class TextBoxHandle: NSView {
    var title = ""
    var onBegin: (() -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    private var start = CGPoint.zero
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: title == "◢" ? .crosshair : .openHand) }
    override func mouseDown(with event: NSEvent) { start = event.locationInWindow; onBegin?() }
    override func mouseDragged(with event: NSEvent) {
        onDrag?(CGPoint(x: event.locationInWindow.x - start.x, y: start.y - event.locationInWindow.y))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill(); bounds.fill()
        (title as NSString).draw(in: bounds.insetBy(dx: 6, dy: 5), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white])
    }
}
