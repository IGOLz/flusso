import AppKit

// Draw at 2x while retaining a 640 × 400 point size for Finder on Retina displays.
let size = NSSize(width: 640, height: 400)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 800,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

func text(_ value: String, y: CGFloat, font: NSFont, color: NSColor) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    (value as NSString).draw(in: NSRect(x: 24, y: y, width: 592, height: 40),
        withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
}
text("Flusso", y: 309, font: .systemFont(ofSize: 30, weight: .semibold),
     color: NSColor(calibratedWhite: 0.13, alpha: 1))
text("Drag the app to Applications to install.", y: 270, font: .systemFont(ofSize: 16),
     color: NSColor(calibratedWhite: 0.38, alpha: 1))

// Icon centers in Finder are (170, 205) and (470, 205), measured from the top.
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 290, y: 195))
arrow.line(to: NSPoint(x: 350, y: 195))
arrow.move(to: NSPoint(x: 337, y: 208))
arrow.line(to: NSPoint(x: 350, y: 195))
arrow.line(to: NSPoint(x: 337, y: 182))
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(calibratedWhite: 0.55, alpha: 1).setStroke()
arrow.stroke()
text("Then open Flusso from Applications.", y: 35,
     font: .systemFont(ofSize: 13), color: NSColor(calibratedWhite: 0.4, alpha: 1))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .tiff, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
