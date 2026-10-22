// swift scripts/make-icon.swift  →  Resources/AppIcon.icns + docs/icon.png
// The app icon in the pill's language: ink squircle, hairline, the listening waveform in mint.
import AppKit

let ink0 = NSColor(red: 0.165, green: 0.178, blue: 0.250, alpha: 1)   // top: one step lighter than the pill
let ink1 = NSColor(red: 0.095, green: 0.103, blue: 0.155, alpha: 1)   // bottom
let mint = NSColor(red: 0.62, green: 0.91, blue: 0.69, alpha: 1)      // #9FE7AF
let line = NSColor(white: 1, alpha: 0.10)

func render(_ size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let S = CGFloat(size)
    // Apple's macOS icon grid: the squircle fills 824/1024 of the canvas.
    let body = CGRect(x: S * 0.0977, y: S * 0.0977, width: S * 0.8047, height: S * 0.8047)
    let radius = body.width * 0.2237
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    // Drop shadow like system icons.
    NSGraphicsContext.current?.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor(white: 0, alpha: 0.28); sh.shadowBlurRadius = S * 0.012; sh.shadowOffset = NSSize(width: 0, height: -S * 0.006)
    sh.set()
    ink1.setFill(); shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(starting: ink0, ending: ink1)!.draw(in: shape, angle: -90)
    // Hairline, inset so it reads at small sizes too.
    let inset = max(1, S * 0.004)
    let hair = NSBezierPath(roundedRect: body.insetBy(dx: inset / 2, dy: inset / 2), xRadius: radius - inset / 2, yRadius: radius - inset / 2)
    hair.lineWidth = inset; line.setStroke(); hair.stroke()
    // The waveform: nine bars, the pill's listening state frozen mid-word.
    let heights: [CGFloat] = [0.16, 0.34, 0.58, 0.82, 0.48, 0.70, 0.30, 0.44, 0.16]
    let barW = body.width * 0.052, gap = body.width * 0.044, maxH = body.height * 0.56
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = body.midX - total / 2
    mint.setFill()
    for h in heights {
        let bh = max(barW, maxH * h)
        NSBezierPath(roundedRect: CGRect(x: x, y: body.midY - bh / 2, width: barW, height: bh), xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let iconset = "/tmp/Speakhold.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    write(render(base), "\(iconset)/icon_\(base)x\(base).png")
    write(render(base * 2), "\(iconset)/icon_\(base)x\(base)@2x.png")
}
write(render(512), "docs/icon.png")
let p = Process(); p.launchPath = "/usr/bin/iconutil"; p.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print("wrote Resources/AppIcon.icns and docs/icon.png", p.terminationStatus == 0 ? "ok" : "iconutil failed")
