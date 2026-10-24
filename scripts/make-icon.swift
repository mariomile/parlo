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

    // Speech bubble with a tail at the bottom left.
    let bubble = NSRect(x: 232, y: 330, width: 560, height: 400)
    let bubblePath = NSBezierPath(roundedRect: bubble, xRadius: 150, yRadius: 150)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 330, y: 360))
    tail.curve(to: NSPoint(x: 268, y: 238), controlPoint1: NSPoint(x: 330, y: 300), controlPoint2: NSPoint(x: 305, y: 262))
    tail.curve(to: NSPoint(x: 440, y: 338), controlPoint1: NSPoint(x: 350, y: 250), controlPoint2: NSPoint(x: 410, y: 290))
    tail.close()
    bubblePath.append(tail)

    color(0xEDEDED).setFill()
    bubblePath.fill()

    // Waveform bars inside the bubble, in the body's black.
    let heights: [CGFloat] = [0.38, 0.72, 1.0, 0.6, 0.85, 0.45]
    let barWidth: CGFloat = 46, gap: CGFloat = 30, maxHeight: CGFloat = 250
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    let bars = NSBezierPath()
    for (i, h) in heights.enumerated() {
        let height = maxHeight * h
        let x = bubble.midX - totalWidth / 2 + CGFloat(i) * (barWidth + gap)
        bars.append(NSBezierPath(roundedRect: NSRect(x: x, y: bubble.midY - height / 2, width: barWidth, height: height),
                                 xRadius: barWidth / 2, yRadius: barWidth / 2))
    }
    color(0x000000).setFill()
    bars.fill()

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
