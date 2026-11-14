// Renders the CcinnMysql app icon (all macOS iconset sizes) with AppKit.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func renderIcon(pixels: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let scale = CGFloat(pixels) / 1024
    let body = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let radius = 186 * scale

        // Drop shadow under the squircle.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 28 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSColor(srgbRed: 0.03, green: 0.25, blue: 0.30, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Tide-teal gradient.
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.23, green: 0.79, blue: 0.86, alpha: 1),
        NSColor(srgbRed: 0.04, green: 0.45, blue: 0.52, alpha: 1),
        NSColor(srgbRed: 0.02, green: 0.20, blue: 0.26, alpha: 1),
    ], atLocations: [0, 0.55, 1], colorSpace: .sRGB)
    gradient?.draw(in: shape, angle: -65)

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    // Soft top highlight.
    let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.20), NSColor.white.withAlphaComponent(0)])
    highlight?.draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    // Two waves across the lower third.
    for (index, alpha) in [0.18, 0.10].enumerated() {
        let wave = NSBezierPath()
        let baseY = body.minY + (210 - CGFloat(index) * 70) * scale
        wave.move(to: NSPoint(x: body.minX, y: baseY))
        var x = body.minX
        let step = body.width / 4
        var up = true
        while x < body.maxX {
            wave.curve(to: NSPoint(x: x + step, y: baseY), controlPoint1: NSPoint(x: x + step * 0.3, y: baseY + (up ? 46 : -46) * scale),
                       controlPoint2: NSPoint(x: x + step * 0.7, y: baseY + (up ? 46 : -46) * scale))
            x += step
            up.toggle()
        }
        wave.line(to: NSPoint(x: body.maxX, y: body.minY))
        wave.line(to: NSPoint(x: body.minX, y: body.minY))
        wave.close()
        NSColor.white.withAlphaComponent(alpha).setFill()
        wave.fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    // A database cylinder: three stacked discs drawn as rounded slabs with elliptic tops.
    let cylinderShadow = NSShadow()
    cylinderShadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    cylinderShadow.shadowBlurRadius = 20 * scale
    cylinderShadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    NSGraphicsContext.saveGraphicsState()
    cylinderShadow.set()
    let width = 440 * scale
    let ellipseHeight = 120 * scale
    let left = body.midX - width / 2
    let slabHeight = 112 * scale
    let gap = 26 * scale
    let topY = body.midY + 150 * scale
    // Bottom disc first, so each upper disc sits on the one below it.
    for index in (0..<3).reversed() {
        let top = topY - CGFloat(index) * (slabHeight + gap)
        let slab = NSBezierPath(ovalIn: NSRect(x: left, y: top - slabHeight - ellipseHeight / 2, width: width, height: ellipseHeight))
        slab.append(NSBezierPath(rect: NSRect(x: left, y: top - slabHeight, width: width, height: slabHeight)))
        NSColor.white.withAlphaComponent(0.96 - CGFloat(index) * 0.10).setFill()
        slab.fill()
        // Top face of each slab, slightly tinted so the discs read as separate.
        let face = NSBezierPath(ovalIn: NSRect(x: left, y: top - ellipseHeight / 2, width: width, height: ellipseHeight))
        NSColor(srgbRed: 0.80, green: 0.96, blue: 0.98, alpha: 1).setFill()
        face.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
return bitmap.representation(using: .png, properties: [:])
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, pixels) in sizes {
    guard let data = renderIcon(pixels: pixels) else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent(name))
}
print("wrote \(sizes.count) images to \(outputDirectory.path)")
