import AppKit

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)

func drawIcon(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let shape = NSBezierPath(roundedRect: NSRect(x: 44, y: 44, width: 936, height: 936), xRadius: 216, yRadius: 216)
    NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.49, blue: 1, alpha: 1),
               ending: NSColor(srgbRed: 0.38, green: 0.22, blue: 0.82, alpha: 1))!.draw(in: shape, angle: -60)
    let paper = NSBezierPath(roundedRect: NSRect(x: 224, y: 230, width: 576, height: 600), xRadius: 66, yRadius: 66)
    NSColor.white.withAlphaComponent(0.97).setFill(); paper.fill()
    let colors: [NSColor] = [.init(srgbRed: 0.26, green: 0.50, blue: 0.96, alpha: 1),
                             .init(srgbRed: 0.98, green: 0.42, blue: 0.51, alpha: 1),
                             .init(srgbRed: 1, green: 0.73, blue: 0.29, alpha: 1)]
    for (index, color) in colors.enumerated() {
        let path = NSBezierPath()
        let y = CGFloat(670 - index * 138)
        path.move(to: NSPoint(x: 330, y: y - 18))
        path.curve(to: NSPoint(x: 690, y: y + 18), controlPoint1: NSPoint(x: 450, y: y + 90), controlPoint2: NSPoint(x: 570, y: y - 90))
        path.lineWidth = 65; path.lineCapStyle = .round
        color.setStroke(); path.stroke()
    }
    let dot = NSBezierPath(ovalIn: NSRect(x: 631, y: 156, width: 176, height: 176))
    NSColor(srgbRed: 0.11, green: 0.16, blue: 0.32, alpha: 1).setFill(); dot.fill()
    if let symbol = NSImage(systemSymbolName: "paintbrush.pointed.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 120, weight: .medium)) {
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect); NSColor.white.setFill(); rect.fill(using: .sourceAtop); return true
        }
        tinted.draw(in: NSRect(x: 668, y: 193, width: 102, height: 102))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try drawIcon(size: size).write(to: URL(fileURLWithPath: destination).appendingPathComponent("icon_\(size)x\(size).png"))
    try drawIcon(size: size * 2).write(to: URL(fileURLWithPath: destination).appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
