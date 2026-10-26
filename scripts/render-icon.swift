import AppKit

// Code-native headphone mark; no Bose artwork or logos.
let destination = CommandLine.arguments[1]
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedRed: 0.08, green: 0.34, blue: 0.29, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
NSColor(calibratedRed: 0.94, green: 0.95, blue: 0.88, alpha: 1).setStroke()
let arch = NSBezierPath()
arch.move(to: NSPoint(x: 277, y: 445))
arch.curve(to: NSPoint(x: 747, y: 445), controlPoint1: NSPoint(x: 277, y: 866), controlPoint2: NSPoint(x: 747, y: 866))
arch.lineWidth = 55
arch.lineCapStyle = .round
arch.stroke()
NSColor(calibratedRed: 0.94, green: 0.95, blue: 0.88, alpha: 1).setFill()
for x in [246.0, 642.0] {
    NSBezierPath(roundedRect: NSRect(x: x, y: 278, width: 136, height: 262), xRadius: 60, yRadius: 60).fill()
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))

