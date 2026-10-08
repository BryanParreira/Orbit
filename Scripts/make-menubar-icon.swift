// Renders the menu bar template icons (planet + orbit ring, like the app icon).
//   swift Scripts/make-menubar-icon.swift Orbit/Resources/Assets.xcassets
// MenuBarIcon: idle. MenuBarIconActive: a moon on the ring while machines run.
import AppKit

let catalog = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Orbit/Resources/Assets.xcassets")
let points = CGSize(width: 22, height: 18)

func render(scale: CGFloat, moon: Bool) -> Data {
    let w = Int(points.width * scale), h = Int(points.height * scale)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    ctx.setShouldAntialias(true)
    let c = CGPoint(x: points.width / 2, y: points.height / 2)
    let r: CGFloat = 5.5
    let tilt: CGFloat = 0.35 // radians, rising to the right like the app icon
    // proportions of the app icon: ring 1.7× the planet, flattened to about a quarter
    let rx: CGFloat = 9.6, ry: CGFloat = 2.6
    let black = CGColor(gray: 0, alpha: 1)

    func ringPath() -> CGPath {
        var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: tilt)
        return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2), transform: &t)
    }
    /// Points of the ellipse below its major axis (the half that passes in front of the planet).
    func frontHalf() -> CGPath {
        let path = CGMutablePath()
        let steps = 48
        for i in 0...steps {
            let a = CGFloat.pi + CGFloat.pi * CGFloat(i) / CGFloat(steps) // lower half
            let x = cos(a) * rx, y = sin(a) * ry
            let p = CGPoint(x: c.x + x * cos(tilt) - y * sin(tilt), y: c.y + x * sin(tilt) + y * cos(tilt))
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        return path
    }

    // back ring
    ctx.addPath(ringPath())
    ctx.setStrokeColor(black)
    ctx.setLineWidth(1.3)
    ctx.strokePath()
    // planet hides the back of the ring
    ctx.setFillColor(black)
    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    // knock a gap out of the planet where the front ring crosses it
    ctx.saveGState()
    ctx.setBlendMode(.clear)
    ctx.addPath(frontHalf())
    ctx.setLineWidth(2.5)
    ctx.setLineCap(.round)
    ctx.strokePath()
    ctx.restoreGState()
    // front ring
    ctx.addPath(frontHalf())
    ctx.setStrokeColor(black)
    ctx.setLineWidth(1.3)
    ctx.setLineCap(.round)
    ctx.strokePath()

    if moon {
        let a = CGFloat.pi * 1.86
        let x = cos(a) * rx, y = sin(a) * ry
        let m = CGPoint(x: c.x + x * cos(tilt) - y * sin(tilt), y: c.y + x * sin(tilt) + y * cos(tilt))
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: m.x - 2.9, y: m.y - 2.9, width: 5.8, height: 5.8))
        ctx.restoreGState()
        ctx.fillEllipse(in: CGRect(x: m.x - 1.9, y: m.y - 1.9, width: 3.8, height: 3.8))
    }

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for (name, moon) in [("MenuBarIcon", false), ("MenuBarIconActive", true)] {
    let dir = catalog.appendingPathComponent("\(name).imageset")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var images: [[String: String]] = []
    for scale in [1, 2, 3] {
        let file = "\(name)@\(scale)x.png"
        try render(scale: CGFloat(scale), moon: moon).write(to: dir.appendingPathComponent(file))
        images.append(["idiom": "universal", "scale": "\(scale)x", "filename": file])
    }
    let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1],
                               "properties": ["template-rendering-intent": "template"]]
    try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]).write(to: dir.appendingPathComponent("Contents.json"))
}
print("wrote menu bar icons")
