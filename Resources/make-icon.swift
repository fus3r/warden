import AppKit
import Foundation

// A lit lantern on a night-blue tile, drawn on Apple's 824 point icon grid.
guard CommandLine.arguments.count == 2,
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                    bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

/// Rounded rectangle with continuous corners, like the system icon shape.
func tile(_ rect: NSRect, radius r: CGFloat) -> NSBezierPath {
    let corners = [
        (NSPoint(x: rect.maxX, y: rect.maxY), NSPoint(x: -1, y: 0), NSPoint(x: 0, y: -1)),
        (NSPoint(x: rect.maxX, y: rect.minY), NSPoint(x: 0, y: 1), NSPoint(x: -1, y: 0)),
        (NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: 1, y: 0), NSPoint(x: 0, y: 1)),
        (NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: 0, y: -1), NSPoint(x: 1, y: 0))
    ]
    let path = NSBezierPath()
    path.move(to: NSPoint(x: rect.minX + 1.52866483 * r, y: rect.maxY))
    for (corner, back, ahead) in corners {
        func point(_ a: CGFloat, _ b: CGFloat) -> NSPoint {
            NSPoint(x: corner.x + (a * back.x + b * ahead.x) * r, y: corner.y + (a * back.y + b * ahead.y) * r)
        }
        path.line(to: point(1.52866483, 0))
        path.curve(to: point(0.66993427, 0.06549600), controlPoint1: point(1.08849323, 0), controlPoint2: point(0.86840689, 0))
        path.line(to: point(0.63149399, 0.07491100))
        path.curve(to: point(0.07491100, 0.63149399), controlPoint1: point(0.37282392, 0.16905700),
                   controlPoint2: point(0.16905700, 0.37282392))
        path.line(to: point(0.06549600, 0.66993427))
        path.curve(to: point(0, 1.52866483), controlPoint1: point(0, 0.86840689), controlPoint2: point(0, 1.08849323))
    }
    path.close()
    return path
}

/// Candle flame, widest a third of the way up, with the tip leaning slightly.
func flame(x: CGFloat, bottom b: CGFloat, height h: CGFloat, width w: CGFloat, lean: CGFloat) -> NSBezierPath {
    let tip = NSPoint(x: x + w * lean, y: b + h)
    let path = NSBezierPath()
    path.move(to: tip)
    path.curve(to: NSPoint(x: x + w / 2, y: b + h * 0.34), controlPoint1: NSPoint(x: tip.x + w * 0.1, y: b + h * 0.8),
               controlPoint2: NSPoint(x: x + w / 2, y: b + h * 0.6))
    path.curve(to: NSPoint(x: x, y: b), controlPoint1: NSPoint(x: x + w / 2, y: b + h * 0.13),
               controlPoint2: NSPoint(x: x + w * 0.29, y: b))
    path.curve(to: NSPoint(x: x - w / 2, y: b + h * 0.34), controlPoint1: NSPoint(x: x - w * 0.29, y: b),
               controlPoint2: NSPoint(x: x - w / 2, y: b + h * 0.13))
    path.curve(to: tip, controlPoint1: NSPoint(x: x - w / 2, y: b + h * 0.58),
               controlPoint2: NSPoint(x: tip.x - w * 0.16, y: b + h * 0.78))
    path.close()
    return path
}

let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = tile(body, radius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = color(0, 0, 0, 0.3)
shadow.shadowBlurRadius = 20
shadow.shadowOffset = NSSize(width: 0, height: -8)
shadow.set()
color(0.07, 0.09, 0.17).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSGradient(colors: [color(0.15, 0.22, 0.43), color(0.04, 0.07, 0.17)])?.draw(in: body, angle: -90)
// Lamplight added onto the night, so it brightens instead of turning the blue muddy.
let lampCenter = NSPoint(x: 512, y: 470)
NSGraphicsContext.current?.compositingOperation = .plusLighter
NSGradient(colors: [color(1, 0.72, 0.35, 0.42), color(1, 0.62, 0.28, 0.12), color(1, 0.55, 0.25, 0)],
           atLocations: [0, 0.4, 1], colorSpace: .sRGB)?
    .draw(fromCenter: lampCenter, radius: 0, toCenter: lampCenter, radius: 420, options: [])
NSGraphicsContext.restoreGraphicsState()

// The lantern, drawn at 1.1 scale around the tile center.
let scale = NSAffineTransform()
scale.translateX(by: 512, yBy: 515)
scale.scale(by: 1.1)
scale.translateX(by: -512, yBy: -515)
scale.concat()

let metal = color(0.98, 0.95, 0.89)
metal.setStroke()
metal.setFill()
let ring = NSBezierPath(ovalIn: NSRect(x: 466, y: 672, width: 92, height: 92))
ring.lineWidth = 24
ring.stroke()

let roof = NSBezierPath()
roof.move(to: NSPoint(x: 382, y: 620))
roof.line(to: NSPoint(x: 642, y: 620))
roof.line(to: NSPoint(x: 571, y: 668))
roof.line(to: NSPoint(x: 453, y: 668))
roof.close()
roof.lineWidth = 32
roof.lineJoinStyle = .round
roof.fill()
roof.stroke()

let glassRect = NSRect(x: 392, y: 318, width: 240, height: 286)
let glass = NSBezierPath(roundedRect: glassRect, xRadius: 50, yRadius: 50)
NSGraphicsContext.saveGraphicsState()
glass.addClip()
let glowCenter = NSPoint(x: 512, y: 420)
NSGradient(colors: [color(1, 0.9, 0.62), color(1, 0.71, 0.3), color(0.92, 0.46, 0.15)],
           atLocations: [0, 0.5, 1], colorSpace: .sRGB)?
    .draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: 240, options: [.drawsAfterEndingLocation])
NSGraphicsContext.restoreGraphicsState()
glass.lineWidth = 26
glass.stroke()

NSGraphicsContext.saveGraphicsState()
let halo = NSShadow()
halo.shadowColor = color(1, 0.95, 0.75)
halo.shadowBlurRadius = 40
halo.set()
color(1, 0.93, 0.66).setFill()
flame(x: 512, bottom: 366, height: 196, width: 104, lean: 0.06).fill()
NSGraphicsContext.restoreGraphicsState()
color(1, 1, 0.97).setFill()
flame(x: 512, bottom: 374, height: 118, width: 62, lean: 0.03).fill()

let base = NSBezierPath(roundedRect: NSRect(x: 358, y: 254, width: 308, height: 64), xRadius: 26, yRadius: 26)
NSGradient(colors: [metal, color(0.88, 0.82, 0.72)])?.draw(in: base, angle: -90)

NSGraphicsContext.current = nil
guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(2) }
try png.write(to: output)
