// Draws Daybook's app icon: a calendar page with a check, on the blue gradient
// my other projects use (homebase, go-sentinel, repo-radar: #6D95F6 to #2A5BD7).
// Run with `make icon`. Writes the iPhone icon (full-bleed square; iOS rounds the
// corners) and the Mac icon set (its own rounded square, with the usual margin).
import AppKit

func draw(size: CGFloat, mac: Bool) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)
    // Work top-down, like the design.
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)

    let light = NSColor(srgbRed: 0x6D / 255.0, green: 0x95 / 255.0, blue: 0xF6 / 255.0, alpha: 1)
    let blue = NSColor(srgbRed: 0x2A / 255.0, green: 0x5B / 255.0, blue: 0xD7 / 255.0, alpha: 1)

    // Background. The Mac draws its own rounded square inside a margin.
    let tile = mac ? CGRect(x: 100, y: 100, width: 824, height: 824) : CGRect(x: 0, y: 0, width: 1024, height: 1024)
    ctx.saveGState()
    if mac {
        ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
        ctx.setFillColor(blue.cgColor)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
        ctx.clip()
    }
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [light.cgColor, blue.cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
    ctx.restoreGState()

    // Everything else is laid out for the full square, then shrunk into the Mac tile.
    if mac {
        ctx.translateBy(x: tile.minX, y: tile.minY)
        ctx.scaleBy(x: tile.width / 1024, y: tile.height / 1024)
    }

    // The calendar page, with a soft shadow.
    let page = CGRect(x: 232, y: 262, width: 560, height: 540)
    let pagePath = CGPath(roundedRect: page, cornerWidth: 96, cornerHeight: 96, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 40, color: NSColor(srgbRed: 0.08, green: 0.16, blue: 0.45, alpha: 0.35).cgColor)
    ctx.addPath(pagePath)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Its header band.
    ctx.saveGState()
    ctx.addPath(pagePath)
    ctx.clip()
    ctx.setFillColor(blue.cgColor)
    ctx.fill(CGRect(x: page.minX, y: page.minY, width: page.width, height: 132))
    ctx.restoreGState()

    // Binder rings.
    ctx.setFillColor(NSColor(srgbRed: 0.90, green: 0.93, blue: 1.00, alpha: 1).cgColor)
    for x in [372.0, 612.0] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: 214, width: 40, height: 104), cornerWidth: 20, cornerHeight: 20, transform: nil))
        ctx.fillPath()
    }

    // The check.
    ctx.setStrokeColor(blue.cgColor)
    ctx.setLineWidth(70)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 378, y: 562))
    ctx.addLine(to: CGPoint(x: 472, y: 656))
    ctx.addLine(to: CGPoint(x: 650, y: 470))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let ios = "Resources/Assets.xcassets/AppIcon.appiconset"
try fm.createDirectory(atPath: ios, withIntermediateDirectories: true)
try draw(size: 1024, mac: false).write(to: URL(fileURLWithPath: "\(ios)/AppIcon.png"))

let iconset = "Resources/AppIcon.iconset"
try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try draw(size: CGFloat(points), mac: true).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(points)x\(points).png"))
    try draw(size: CGFloat(points * 2), mac: true).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(points)x\(points)@2x.png"))
}
