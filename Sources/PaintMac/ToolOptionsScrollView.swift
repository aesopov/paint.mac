import AppKit

/// Keep every tool setting reachable when the window is narrower than its
/// options row, without compressing controls or covering the editor panels.
final class ToolOptionsScrollView: NSScrollView {
    private let options: NSStackView
    init(options: NSStackView) {
        self.options = options
        super.init(frame: .zero)
        drawsBackground = false; hasHorizontalScroller = true
        autohidesScrollers = true; scrollerStyle = .overlay
        let document = NSView(); documentView = document
        options.translatesAutoresizingMaskIntoConstraints = true
        document.addSubview(options)
        setAccessibilityLabel("Tool options")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let size = options.fittingSize
        documentView?.frame = CGRect(x: 0, y: 0, width: max(contentSize.width, size.width + 40), height: contentSize.height)
        options.frame = CGRect(x: 20, y: (contentSize.height - size.height) / 2, width: size.width, height: size.height)
    }
    func settingsChanged() {
        contentView.scroll(to: .zero)
        needsLayout = true
    }
}
