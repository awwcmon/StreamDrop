import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let size = points * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(size) / 1024)
    transform.concat()
    let tile = NSBezierPath(roundedRect: NSRect(x: 90, y: 90, width: 844, height: 844), xRadius: 190, yRadius: 190)
    NSGradient(starting: NSColor(srgbRed: 0.48, green: 0.25, blue: 0.88, alpha: 1), ending: NSColor(srgbRed: 0.72, green: 0.51, blue: 1, alpha: 1))!.draw(in: tile, angle: 75)
    NSColor.white.withAlphaComponent(0.25).setStroke()
    tile.lineWidth = 4
    tile.stroke()
    NSColor.white.setStroke()
    let arrow = NSBezierPath()
    arrow.lineWidth = 67
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 512, y: 728))
    arrow.line(to: NSPoint(x: 512, y: 365))
    arrow.move(to: NSPoint(x: 360, y: 495))
    arrow.line(to: NSPoint(x: 512, y: 343))
    arrow.line(to: NSPoint(x: 664, y: 495))
    arrow.stroke()
    let tray = NSBezierPath()
    tray.lineWidth = 53
    tray.lineCapStyle = .round
    tray.move(to: NSPoint(x: 328, y: 278))
    tray.line(to: NSPoint(x: 696, y: 278))
    tray.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(filename))
}
