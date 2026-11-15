import AppKit

/// One TextKit layout configuration for input geometry and pixel rendering.
/// Layout continues below the box; only painting is clipped, so partial glyphs
/// remain visible even when a full line is taller than the rectangle.
final class TextRasterLayout {
    let storage = NSTextStorage()
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: 1, height: CGFloat.greatestFiniteMagnitude))

    init() {
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false; container.heightTracksTextView = false
        container.lineBreakMode = .byWordWrapping
        manager.usesFontLeading = true
        manager.addTextContainer(container); storage.addLayoutManager(manager)
    }
    convenience init(text: String, font: NSFont, color: PixelColor, width: CGFloat) {
        self.init()
        container.containerSize = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color.nsColor]))
        manager.ensureLayout(for: container)
    }
}
