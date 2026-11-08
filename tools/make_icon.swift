// Renders Needle's app icon into an AppIcon.appiconset: Tape's graphite, a record with its
// grooves catching the light, a brushed-silver arm, and Tape's mint dot where the needle sits.
// Full bleed; macOS draws the rounded square itself.
// Usage: swift tools/make_icon.swift Needle/Resources/Assets.xcassets/AppIcon.appiconset [preview.png]
import AppKit
import CoreGraphics

let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
let preview = CommandLine.arguments.dropFirst(2).first.map { URL(fileURLWithPath: $0) }
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(side: Int) -> CGImage {
    let s = CGFloat(side)
    let c = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high

    // Ground: graphite, lit softly from the top left (as Tape's).
    let ground = CGGradient(colorsSpace: space, colors: [rgb(0x2C2D33), rgb(0x16171B), rgb(0x0B0B0E)] as CFArray, locations: [0, 0.55, 1])!
    c.drawLinearGradient(ground, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    let light = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.13), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(light, startCenter: CGPoint(x: s * 0.18, y: s * 0.95), startRadius: 0,
                         endCenter: CGPoint(x: s * 0.18, y: s * 0.95), endRadius: s * 0.9, options: [])

    // The record, lifted off the ground.
    let centre = CGPoint(x: s * 0.44, y: s * 0.43)
    let r = s * 0.35
    let disc = CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -s * 0.018), blur: s * 0.05, color: rgb(0x000000, 0.6))
    c.setFillColor(rgb(0x0D0D10))
    c.fillEllipse(in: disc)
    c.restoreGState()
    c.saveGState()
    c.addEllipse(in: disc)
    c.clip()
    let body = CGGradient(colorsSpace: space, colors: [rgb(0x1C1C21), rgb(0x0E0E11)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(body, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: r, options: [])
    // Grooves.
    if side >= 64 {
        let step = max(1, s * 0.0085)
        var radius = r * 0.42
        var index = 0
        while radius < r * 0.97 {
            c.setStrokeColor(rgb(0xFFFFFF, index % 3 == 0 ? 0.05 : 0.025))
            c.setLineWidth(max(0.5, s * 0.0016))
            c.strokeEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
            radius += step
            index += 1
        }
    }
    // The light catching the grooves: two opposite fans that fade in and out, as on a real record.
    for start in [CGFloat.pi * 0.12, CGFloat.pi * 1.12] {
        let span = CGFloat.pi * 0.36
        let slices = 48
        for slice in 0..<slices {
            let t = (CGFloat(slice) + 0.5) / CGFloat(slices)
            let strength = pow(sin(t * .pi), 2)
            c.saveGState()
            let wedge = CGMutablePath()
            wedge.move(to: centre)
            let a0 = start + span * CGFloat(slice) / CGFloat(slices)
            wedge.addArc(center: centre, radius: r, startAngle: a0, endAngle: a0 + span / CGFloat(slices) + 0.002, clockwise: false)
            wedge.closeSubpath()
            c.addPath(wedge)
            c.clip()
            let sheen = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0), rgb(0xFFFFFF, 0.13 * strength), rgb(0xFFFFFF, 0.05 * strength)] as CFArray, locations: [0, 0.62, 1])!
            c.drawRadialGradient(sheen, startCenter: centre, startRadius: r * 0.34, endCenter: centre, endRadius: r, options: [])
            c.restoreGState()
        }
    }
    // The rim.
    c.setStrokeColor(rgb(0xFFFFFF, 0.14))
    c.setLineWidth(max(1, s * 0.003))
    c.strokeEllipse(in: disc.insetBy(dx: s * 0.0015, dy: s * 0.0015))
    c.restoreGState()

    // The label: graphite, with the spindle.
    let label = r * 0.33
    let labelRect = CGRect(x: centre.x - label, y: centre.y - label, width: label * 2, height: label * 2)
    c.saveGState()
    c.addEllipse(in: labelRect)
    c.clip()
    let labelFill = CGGradient(colorsSpace: space, colors: [rgb(0x45464E), rgb(0x2A2B31)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(labelFill, start: CGPoint(x: 0, y: labelRect.maxY), end: CGPoint(x: 0, y: labelRect.minY), options: [])
    c.restoreGState()
    c.setStrokeColor(rgb(0xFFFFFF, 0.1))
    c.setLineWidth(max(1, s * 0.002))
    c.strokeEllipse(in: labelRect.insetBy(dx: label * 0.3, dy: label * 0.3))
    let hole = s * 0.014
    c.setFillColor(rgb(0x0A0A0C))
    c.fillEllipse(in: CGRect(x: centre.x - hole, y: centre.y - hole, width: hole * 2, height: hole * 2))
    c.setStrokeColor(rgb(0xDCDCDA, 0.7))
    c.setLineWidth(max(0.6, s * 0.003))
    c.strokeEllipse(in: CGRect(x: centre.x - hole, y: centre.y - hole, width: hole * 2, height: hole * 2))

    // Where the needle rests: a third of the way in from the edge, upper right.
    let angle = CGFloat.pi * 0.24
    let tip = CGPoint(x: centre.x + cos(angle) * r * 0.78, y: centre.y + sin(angle) * r * 0.78)
    let pivot = CGPoint(x: s * 0.83, y: s * 0.83)

    // The tip's glow sits under everything else.
    let dot = s * 0.034
    let glow = CGGradient(colorsSpace: space, colors: [rgb(0x3EE6A8, 0.38), rgb(0x3EE6A8, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(glow, startCenter: tip, startRadius: dot * 0.6, endCenter: tip, endRadius: dot * 3.2, options: [])

    // The arm, in brushed silver with a soft shadow beneath (Tape's step, bent into an arm).
    let width = s * 0.042
    let arm = CGMutablePath()
    arm.move(to: pivot)
    arm.addLine(to: tip)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -s * 0.014), blur: s * 0.035, color: rgb(0x000000, 0.6))
    c.setLineWidth(width)
    c.setLineCap(.round)
    c.setStrokeColor(rgb(0xDCDCDA))
    c.addPath(arm)
    c.strokePath()
    c.restoreGState()
    c.saveGState()
    c.setLineWidth(width)
    c.setLineCap(.round)
    c.addPath(arm)
    c.replacePathWithStrokedPath()
    c.clip()
    let silver = CGGradient(colorsSpace: space, colors: [rgb(0xFAFAF8), rgb(0xDCDCDA), rgb(0xA9A9A7)] as CFArray, locations: [0, 0.5, 1])!
    c.drawLinearGradient(silver, start: CGPoint(x: pivot.x, y: pivot.y + width), end: CGPoint(x: pivot.x + width * 0.6, y: pivot.y - width * 0.6),
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()

    // The pivot: a silver boss.
    let boss = s * 0.058
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: rgb(0x000000, 0.55))
    c.setFillColor(rgb(0xC9C9C7))
    c.fillEllipse(in: CGRect(x: pivot.x - boss, y: pivot.y - boss, width: boss * 2, height: boss * 2))
    c.restoreGState()
    c.saveGState()
    c.addEllipse(in: CGRect(x: pivot.x - boss, y: pivot.y - boss, width: boss * 2, height: boss * 2))
    c.clip()
    c.drawLinearGradient(silver, start: CGPoint(x: pivot.x, y: pivot.y + boss), end: CGPoint(x: pivot.x, y: pivot.y - boss), options: [])
    c.restoreGState()
    c.setFillColor(rgb(0x2A2B31))
    c.fillEllipse(in: CGRect(x: pivot.x - boss * 0.3, y: pivot.y - boss * 0.3, width: boss * 0.6, height: boss * 0.6))

    // The needle: Tape's mint, glowing.
    let mint = CGGradient(colorsSpace: space, colors: [rgb(0x7DF5C6), rgb(0x2FCF96)] as CFArray, locations: [0, 1])!
    c.saveGState()
    c.addEllipse(in: CGRect(x: tip.x - dot, y: tip.y - dot, width: dot * 2, height: dot * 2))
    c.clip()
    c.drawLinearGradient(mint, start: CGPoint(x: tip.x, y: tip.y + dot), end: CGPoint(x: tip.x, y: tip.y - dot), options: [])
    c.restoreGState()

    return c.makeImage()!
}

func write(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
var images: [[String: String]] = []
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try write(render(side: points * scale), to: folder.appending(path: name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appending(path: "Contents.json"))
if let preview { try write(render(side: 1024), to: preview) }
print("Wrote \(images.count) icons to \(folder.path)")
