// Renders the DMG window background (1x + 2x in one TIFF) and a PNG preview.
//   swift Scripts/make-dmg-background.swift Distribution
//
// Layout matches Scripts/release.sh: a 660 × 400 content area (window 660 × 428 with its
// title bar), app icon centred at (180, 190), Applications at (480, 190), from the top-left.
//
// The stage is light on purpose: Finder draws icon labels in black over picture
// backgrounds, even in Dark Mode. The bottom 30 pt stay empty for Finder's path bar.
import AppKit

let size = CGSize(width: 660, height: 400)
let appCenter = CGPoint(x: 180, y: 190)
let appsCenter = CGPoint(x: 480, y: 190)
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Distribution")

/// Top-left coordinates → Core Graphics (bottom-left) coordinates.
func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: size.height - y) }

func render(pixelScale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * pixelScale), pixelsHigh: Int(size.height * pixelScale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    // points-sized rep: AppKit applies the pixel scale itself
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let space = CGColorSpaceCreateDeviceRGB()

    // Stage: soft silver, lit from above
    let stage = CGGradient(colorsSpace: space, colors: [NSColor(white: 0.985, alpha: 1).cgColor,
                                                        NSColor(white: 0.905, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(stage, start: p(0, 0), end: p(0, size.height), options: [])
    let topLight = CGGradient(colorsSpace: space, colors: [NSColor(white: 1, alpha: 0.9).cgColor,
                                                           NSColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(topLight, startCenter: p(size.width / 2, -60), startRadius: 0,
                           endCenter: p(size.width / 2, -60), endRadius: 460, options: [])

    // Soft pads under the two icons
    for center in [appCenter, appsCenter] {
        let pad = CGGradient(colorsSpace: space, colors: [NSColor(white: 0, alpha: 0.045).cgColor,
                                                          NSColor(white: 0, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(pad, startCenter: p(center.x, center.y), startRadius: 0,
                               endCenter: p(center.x, center.y), endRadius: 105, options: [])
    }

    // Orbit ring: a tilted ellipse sweeping from the app to Applications
    let mid = CGPoint(x: (appCenter.x + appsCenter.x) / 2, y: appCenter.y)
    let rx: CGFloat = 205, ry: CGFloat = 58
    ctx.saveGState()
    ctx.translateBy(x: mid.x, y: size.height - mid.y)
    ctx.rotate(by: -0.06)
    let ring = CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2)
    ctx.setLineWidth(1.2)
    ctx.setStrokeColor(NSColor(white: 0, alpha: 0.10).cgColor)
    ctx.strokeEllipse(in: ring)
    ctx.restoreGState()

    // brighter front arc between the icons, with the moon heading to Applications

    ctx.saveGState()
    ctx.translateBy(x: mid.x, y: size.height - mid.y)
    ctx.rotate(by: -0.06)
    ctx.scaleBy(x: rx, y: ry)
    let arc = CGMutablePath()
    arc.addArc(center: .zero, radius: 1, startAngle: .pi * 1.22, endAngle: .pi * 1.78, clockwise: false)
    ctx.addPath(arc)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setLineWidth(1.6)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(NSColor(white: 0, alpha: 0.32).cgColor)
    ctx.strokePath()
    ctx.restoreGState()

    // Moon on the front arc, just short of Applications
    let angle = CGFloat.pi * 1.57
    let local = CGPoint(x: cos(angle) * rx, y: sin(angle) * ry)
    let rot: CGFloat = -0.06
    let moon = CGPoint(x: mid.x + local.x * cos(rot) - local.y * sin(rot),
                       y: (size.height - mid.y) + local.x * sin(rot) + local.y * cos(rot))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: NSColor(white: 0, alpha: 0.25).cgColor)
    ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: moon.x - 4.5, y: moon.y - 4.5, width: 9, height: 9))
    ctx.restoreGState()

    // Typography
    func text(_ string: String, size fontSize: CGFloat, weight: NSFont.Weight, alpha: CGFloat, top: CGFloat, tracking: CGFloat = 0) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: NSColor(white: 0.11, alpha: alpha),
            .kern: tracking,
            .paragraphStyle: paragraph,
        ]
        let s = NSAttributedString(string: string, attributes: attrs)
        let h = s.size().height
        s.draw(in: CGRect(x: 0, y: size.height - top - h, width: size.width, height: h))
    }
    text("Orbit", size: 24, weight: .semibold, alpha: 0.95, top: 30, tracking: -0.3)
    text("Virtual machines at native speed", size: 12.5, weight: .regular, alpha: 0.5, top: 61)
    text("DRAG ORBIT INTO APPLICATIONS", size: 9.5, weight: .semibold, alpha: 0.42, top: 326, tracking: 1.6)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let image = NSImage(size: size)
image.addRepresentation(render(pixelScale: 1))
image.addRepresentation(render(pixelScale: 2))
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try image.tiffRepresentation(using: .lzw, factor: 0)!.write(to: out.appendingPathComponent("dmg-background.tiff"))
try render(pixelScale: 2).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("dmg-background-preview.png"))
print("wrote \(out.path)/dmg-background.tiff")
