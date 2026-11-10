// Renders ComfyDraw.iconset (all sizes) into the directory given as argv[1].
// Usage: swiftc -O Tools/make-icon.swift -o /tmp/make-icon && /tmp/make-icon out.iconset
import AppKit

func sparkle(center: NSPoint, radius: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    let k = radius * 0.16
    p.move(to: NSPoint(x: center.x, y: center.y + radius))
    p.curve(to: NSPoint(x: center.x + radius, y: center.y),
            controlPoint1: NSPoint(x: center.x + k, y: center.y + k),
            controlPoint2: NSPoint(x: center.x + k, y: center.y + k))
    p.curve(to: NSPoint(x: center.x, y: center.y - radius),
            controlPoint1: NSPoint(x: center.x + k, y: center.y - k),
            controlPoint2: NSPoint(x: center.x + k, y: center.y - k))
    p.curve(to: NSPoint(x: center.x - radius, y: center.y),
            controlPoint1: NSPoint(x: center.x - k, y: center.y - k),
            controlPoint2: NSPoint(x: center.x - k, y: center.y - k))
    p.curve(to: NSPoint(x: center.x, y: center.y + radius),
            controlPoint1: NSPoint(x: center.x - k, y: center.y + k),
            controlPoint2: NSPoint(x: center.x - k, y: center.y + k))
    p.close()
    return p
}

func render(_ s: CGFloat) -> Data? {
    let size = NSSize(width: s, height: s)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = context

    let inset = s * 0.045
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let body = NSBezierPath(roundedRect: rect, xRadius: s * 0.225, yRadius: s * 0.225)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.20, green: 0.14, blue: 0.42, alpha: 1),
        NSColor(srgbRed: 0.52, green: 0.25, blue: 0.82, alpha: 1)
    ])
    gradient?.draw(in: body, angle: -55)

    let glow = NSBezierPath(ovalIn: NSRect(x: s * 0.12, y: s * 0.42, width: s * 0.76, height: s * 0.76))
    NSColor(srgbRed: 0.85, green: 0.55, blue: 1.0, alpha: 0.18).setFill()
    glow.fill()

    NSColor.white.setFill()
    sparkle(center: NSPoint(x: s * 0.45, y: s * 0.54), radius: s * 0.235).fill()
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.82).setFill()
    sparkle(center: NSPoint(x: s * 0.71, y: s * 0.31), radius: s * 0.095).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let dir = CommandLine.arguments[1]
let variants: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in variants {
    guard let data = render(px) else { fatalError("render failed \(name)") }
    try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
}
print("ok")
