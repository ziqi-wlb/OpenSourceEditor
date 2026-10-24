import AppKit

// Original vector artwork. All icon sizes are drawn from this one representation.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}
func path(_ points: [(CGFloat, CGFloat)], close: Bool = false) -> NSBezierPath {
    let p = NSBezierPath(); p.move(to: NSPoint(x: points[0].0, y: points[0].1))
    for point in points.dropFirst() { p.line(to: NSPoint(x: point.0, y: point.1)) }
    if close { p.close() }; p.lineJoinStyle = .round; p.lineCapStyle = .round
    return p
}
func draw() {
    let plate = NSBezierPath(roundedRect: NSRect(x: 74, y: 74, width: 876, height: 876), xRadius: 194, yRadius: 194)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = color(0, 0, 0, 0.28)
    shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.set()
    NSGradient(starting: color(0.10, 0.15, 0.23), ending: color(0.025, 0.04, 0.09))!.draw(in: plate, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    color(0.35, 0.64, 0.87, 0.3).setStroke(); plate.lineWidth = 3; plate.stroke()

    NSGraphicsContext.saveGraphicsState()
    plate.addClip()
    color(0.20, 0.67, 0.86, 0.08).setStroke()
    for offset in stride(from: 200, through: 850, by: 90) {
        let horizontal = path([(100, CGFloat(offset)), (924, CGFloat(offset))]); horizontal.lineWidth = 1; horizontal.stroke()
        let vertical = path([(CGFloat(offset), 100), (CGFloat(offset), 924)]); vertical.lineWidth = 1; vertical.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()

    let hex = path([(512, 762), (728, 637), (728, 387), (512, 262), (296, 387), (296, 637)], close: true)
    color(0.04, 0.16, 0.25).setFill(); hex.fill()
    NSGraphicsContext.saveGraphicsState()
    let borderGlow = NSShadow(); borderGlow.shadowColor = color(0.10, 0.82, 1, 0.6); borderGlow.shadowBlurRadius = 30; borderGlow.set()
    color(0.16, 0.84, 1).setStroke(); hex.lineWidth = 8; hex.stroke()
    NSGraphicsContext.restoreGraphicsState()

    let angle = CGFloat.pi * 32 / 180
    let orbit = path((0...128).map { step in
        let theta = CGFloat(step) * .pi * 2 / 128
        let x = 341 * cos(theta), y = 150 * sin(theta)
        return (512 + x * cos(angle) - y * sin(angle), 512 + x * sin(angle) + y * cos(angle))
    }, close: true)
    color(0.50, 0.43, 1, 0.72).setStroke(); orbit.lineWidth = 6; orbit.stroke()
    for (x, y, shade) in [(CGFloat(235), CGFloat(325), color(0.65, 0.48, 1)), (CGFloat(791), CGFloat(694), color(0.24, 0.88, 1))] {
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow(); glow.shadowColor = shade; glow.shadowBlurRadius = 22; glow.set()
        shade.setFill(); NSBezierPath(ovalIn: NSRect(x: x - 16, y: y - 16, width: 32, height: 32)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.saveGraphicsState()
    let promptGlow = NSShadow(); promptGlow.shadowColor = color(0.22, 0.90, 1, 0.6); promptGlow.shadowBlurRadius = 18; promptGlow.set()
    color(0.66, 0.96, 1).setStroke()
    let prompt = path([(394, 606), (489, 512), (394, 418)]); prompt.lineWidth = 36; prompt.stroke()
    color(0.77, 0.63, 1).setStroke()
    let cursor = path([(550, 416), (640, 416)]); cursor.lineWidth = 34; cursor.stroke()
    NSGraphicsContext.restoreGraphicsState()
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let url = destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
