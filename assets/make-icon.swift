// Renders the app icon (terminal prompt + quota bar) to an .iconset directory.
// build-dmg.sh runs this when assets/AppIcon.icns is missing; to regenerate manually:
//   swift assets/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o assets/AppIcon.icns
import AppKit

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func roundedRect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: height / 2, yRadius: height / 2).fill()
}

/// Draws on a 1024pt canvas (macOS icon grid: 824pt tile, 185pt corner radius). Flat colors only.
func drawIcon() {
    let paper = color(0xF2F1EC)
    color(0x0E0F11).setFill()
    NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185).fill()

    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: 290, y: 680))
    chevron.line(to: NSPoint(x: 420, y: 570))
    chevron.line(to: NSPoint(x: 290, y: 460))
    chevron.lineWidth = 62
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    paper.setStroke()
    chevron.stroke()

    roundedRect(476, 440, 230, 60, paper)                 // cursor
    roundedRect(290, 300, 444, 48, color(0xFFFFFF, 0.14)) // quota track
    roundedRect(290, 300, 300, 48, color(0x12A150))       // remaining quota
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            fatalError("Could not allocate \(pixels)px bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        drawIcon()
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outputDir)/\(name)"))
    }
}
