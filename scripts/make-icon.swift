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

    // The mark, the island: a pill with level bars cut out, on the 100-unit grid of assets/parlo-mark.svg.
    let scale: CGFloat = 5.2
    func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
        NSRect(x: body.midX + (x - 50) * scale, y: body.midY - (y + height - 50) * scale, width: width * scale, height: height * scale)
    }
    color(0xFFFFFF).setFill()
    NSBezierPath(roundedRect: rect(2, 24, 96, 52), xRadius: 26 * scale, yRadius: 26 * scale).fill()
    color(0x000000).setFill()
    for (x, y, height) in [(25, 42, 16), (39, 35, 30), (53, 38, 24), (67, 44, 12)] as [(CGFloat, CGFloat, CGFloat)] {
        NSBezierPath(roundedRect: rect(x, y, 8, height), xRadius: 4 * scale, yRadius: 4 * scale).fill()
    }

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
