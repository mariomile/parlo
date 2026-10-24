// Renders the Parlo app icon into App/Assets.xcassets/AppIcon.appiconset.
// Run from the repo root: swift scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Body: macOS icon grid, 824 pt rounded square centered on a 1024 canvas.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    color(0x000000).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Hairline edge, so the black body still reads on a dark Dock.
    let edge = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
    edge.lineWidth = 4
    color(0xFFFFFF, 0.14).setStroke()
    edge.stroke()

    // The mark, a lowercase p: a ring and a stem, drawn on the 100-unit grid of assets/parlo-mark.svg.
    let scale: CGFloat = 4.6
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: body.midX + (x - 50) * scale, y: body.midY - (y - 50) * scale)
    }
    let mark = NSBezierPath()
    mark.appendArc(withCenter: point(50, 40), radius: 28 * scale, startAngle: 0, endAngle: 360)
    mark.move(to: point(22, 40))
    mark.line(to: point(22, 88))
    mark.lineWidth = 16 * scale
    mark.lineCapStyle = .round
    color(0xFFFFFF).setStroke()
    mark.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let master = render().representation(using: .png, properties: [:])!
let masterURL = dir.appendingPathComponent("icon_1024.png")
try master.write(to: masterURL)

var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = size * scale
        let name = "icon_\(px).png"
        if px != 1024 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
            p.arguments = ["-z", "\(px)", "\(px)", masterURL.path, "--out", dir.appendingPathComponent(name).path]
            p.standardOutput = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
        }
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: dir.appendingPathComponent("Contents.json"))
try #"{"info":{"author":"xcode","version":1}}"#.write(
    to: dir.deletingLastPathComponent().appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Icon written to \(dir.path)")
