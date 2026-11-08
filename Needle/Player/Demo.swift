import CoreGraphics
import Foundation

/// Made-up records with covers drawn in code, for `-NeedleDemo YES`, the preview in Settings when
/// nothing plays, and screenshots that show nobody's library.
nonisolated enum Demo {
    struct Record: Sendable {
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var cover: Int
    }

    static let records: [Record] = [
        Record(title: "Undertow", artist: "Marina Vale", album: "Low Tide", duration: 221, cover: 0),
        Record(title: "Salt in the Air", artist: "Marina Vale", album: "Low Tide", duration: 245, cover: 0),
        Record(title: "Paper Moons", artist: "The Quiet Hours", album: "Paper Moons", duration: 198, cover: 1),
        Record(title: "Night Drive", artist: "Oslo Club", album: "Neon Coast", duration: 262, cover: 2),
        Record(title: "Slow Light", artist: "Ada Sun", album: "Golden Hour", duration: 236, cover: 3),
        Record(title: "Glasshouse", artist: "Fern & Field", album: "Greenhouse Sessions", duration: 207, cover: 4),
    ]

    static func track(_ index: Int, position: Double = 0, playing: Bool = true) -> NowPlaying {
        let record = records[(index % records.count + records.count) % records.count]
        var track = NowPlaying(title: record.title)
        track.artist = record.artist
        track.album = record.album
        track.duration = record.duration
        track.elapsed = position
        track.timestamp = .now
        track.rate = playing ? 1 : 0
        track.isPlaying = playing
        track.artworkID = "demo-\(record.cover)"
        track.hasArtwork = true
        track.bundleID = "com.apple.Music"
        track.mediaType = "MRMediaRemoteMediaTypeMusic"
        track.contentID = "demo-track-\(index)"
        return track
    }

    static func cover(_ index: Int, side: Int = 600) -> CGImage? {
        let s = CGFloat(side)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let c = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor { RGB(hex: hex).cgColor(alpha: alpha) }
        func linear(_ colors: [UInt32], from: CGPoint, to: CGPoint) {
            let gradient = CGGradient(colorsSpace: space, colors: colors.map { color($0) } as CFArray, locations: nil)!
            c.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        func radial(_ colors: [CGColor], at point: CGPoint, radius: CGFloat) {
            let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
            c.drawRadialGradient(gradient, startCenter: point, startRadius: 0, endCenter: point, endRadius: radius, options: [])
        }
        let full = CGRect(x: 0, y: 0, width: s, height: s)
        switch index % 5 {
        case 0:
            // Low Tide: a pale sun sinking into a teal sea, the swell drawn in fine lines.
            linear([0x0E3B47, 0x1D6F72, 0x7FB7A4], from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: s))
            radial([color(0xFFF1D6, 0.95), color(0xFFE2B0, 0.55), color(0xFFE2B0, 0)], at: CGPoint(x: s * 0.5, y: s * 0.46), radius: s * 0.3)
            c.setFillColor(color(0xFFF4E2))
            c.fillEllipse(in: CGRect(x: s * 0.37, y: s * 0.33, width: s * 0.26, height: s * 0.26))
            c.setFillColor(color(0x0E3B47))
            c.fill(CGRect(x: 0, y: 0, width: s, height: s * 0.42))
            for row in 0..<16 {
                let y = s * 0.42 - CGFloat(row) * s * 0.024 - CGFloat(row * row) * s * 0.0006
                c.setStrokeColor(color(0xBFE3D5, 0.5 - Double(row) * 0.028))
                c.setLineWidth(s * 0.004)
                let inset = s * (0.36 - CGFloat(row) * 0.02)
                c.move(to: CGPoint(x: max(0, inset), y: y))
                c.addLine(to: CGPoint(x: s - max(0, inset), y: y))
                c.strokePath()
            }
        case 1:
            // Paper Moons: two moons overlapping on warm paper.
            c.setFillColor(color(0xF1E6D2))
            c.fill(full)
            c.setBlendMode(.multiply)
            c.setFillColor(color(0xE8604C))
            c.fillEllipse(in: CGRect(x: s * 0.14, y: s * 0.28, width: s * 0.46, height: s * 0.46))
            c.setFillColor(color(0xE9B13B))
            c.fillEllipse(in: CGRect(x: s * 0.4, y: s * 0.26, width: s * 0.46, height: s * 0.46))
            c.setBlendMode(.normal)
            c.setFillColor(color(0x2B2A33))
            c.fill(CGRect(x: s * 0.14, y: s * 0.16, width: s * 0.72, height: s * 0.012))
        case 2:
            // Neon Coast: a magenta horizon over a dark road.
            linear([0x07061A, 0x1B0F3D, 0x6A1B6F, 0xF0517A, 0xFFB36B], from: CGPoint(x: 0, y: s * 0.98), to: CGPoint(x: 0, y: s * 0.42))
            c.setFillColor(color(0x07061A))
            c.fill(CGRect(x: 0, y: 0, width: s, height: s * 0.42))
            c.setStrokeColor(color(0xF0517A, 0.75))
            c.setLineWidth(s * 0.004)
            for line in -6...6 {
                c.move(to: CGPoint(x: s * 0.5 + CGFloat(line) * s * 0.012, y: s * 0.42))
                c.addLine(to: CGPoint(x: s * 0.5 + CGFloat(line) * s * 0.2, y: 0))
            }
            for row in 0..<7 {
                let y = s * 0.42 * pow(0.62, CGFloat(row + 1))
                c.move(to: CGPoint(x: 0, y: y))
                c.addLine(to: CGPoint(x: s, y: y))
            }
            c.strokePath()
            radial([color(0xFFD08A, 0.9), color(0xFF7A7A, 0)], at: CGPoint(x: s * 0.5, y: s * 0.44), radius: s * 0.22)
        case 3:
            // Golden Hour: low warm light, nothing else.
            linear([0x3A1530, 0xC2414C, 0xF59B54, 0xFBD38D], from: .zero, to: CGPoint(x: s * 0.4, y: s))
            radial([color(0xFFF3C4, 0.95), color(0xFFD27A, 0.4), color(0xFFD27A, 0)], at: CGPoint(x: s * 0.68, y: s * 0.62), radius: s * 0.42)
        default:
            // Greenhouse Sessions: panes of green glass.
            linear([0x0F2A1E, 0x1F5A3C, 0x6FA86A], from: .zero, to: CGPoint(x: s, y: s))
            c.setStrokeColor(color(0xD8F2C8, 0.35))
            c.setLineWidth(s * 0.006)
            for column in 1..<4 {
                let x = s * CGFloat(column) / 4
                c.move(to: CGPoint(x: x, y: 0))
                c.addLine(to: CGPoint(x: x, y: s * 0.78))
            }
            c.move(to: CGPoint(x: 0, y: s * 0.78))
            c.addLine(to: CGPoint(x: s * 0.5, y: s * 0.95))
            c.addLine(to: CGPoint(x: s, y: s * 0.78))
            c.strokePath()
            radial([color(0xE9FFD9, 0.55), color(0xE9FFD9, 0)], at: CGPoint(x: s * 0.3, y: s * 0.7), radius: s * 0.5)
        }
        // Grain, so the gradients read as print rather than as a screen.
        var seed: UInt64 = 0x9E3779B97F4A7C15 &+ UInt64(index)
        func next() -> CGFloat {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return CGFloat(seed % 10_000) / 10_000
        }
        let dot = max(1, s / 300)
        for _ in 0..<(side * side / 40) {
            let light = next() > 0.5
            c.setFillColor(CGColor(gray: light ? 1 : 0, alpha: 0.05 * next()))
            c.fill(CGRect(x: next() * s, y: next() * s, width: dot, height: dot))
        }
        return c.makeImage()
    }
}
