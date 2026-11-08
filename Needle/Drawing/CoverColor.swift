import CoreGraphics

/// What a cover is remembered by: the most vivid hue that covers a real part of it, for the title,
/// and its overall tone, for the shadow it casts. (Tape colours names after their logos the same way.)
nonisolated struct CoverPalette: Equatable, Sendable {
    /// The cover's own colour, or nil when it's black and white (the title is then drawn in ink).
    var accent: RGB?
    /// The mean of the whole picture, for its coloured shadow.
    var average: RGB

    static func of(_ image: CGImage) -> CoverPalette? {
        let side = 48
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let raw = context.data else { return nil }
        let pixels = raw.bindMemory(to: UInt8.self, capacity: side * side * 4)

        let binCount = 36
        var weight = [Double](repeating: 0, count: binCount)
        var sumL = [Double](repeating: 0, count: binCount)
        var sumA = [Double](repeating: 0, count: binCount)
        var sumB = [Double](repeating: 0, count: binCount)
        var total = OKLab(l: 0, a: 0, b: 0)
        var opaque = 0.0
        var colored = 0.0

        for index in 0..<(side * side) {
            let alpha = Double(pixels[index * 4 + 3]) / 255
            guard alpha > 0.5 else { continue }
            let rgb = RGB(
                r: Double(pixels[index * 4]) / 255 / alpha,
                g: Double(pixels[index * 4 + 1]) / 255 / alpha,
                b: Double(pixels[index * 4 + 2]) / 255 / alpha
            ).clamped
            let lab = rgb.oklab
            opaque += 1
            total.l += lab.l
            total.a += lab.a
            total.b += lab.b
            guard lab.chroma > 0.06, lab.l > 0.2, lab.l < 0.97 else { continue }
            colored += 1
            let bin = Int(lab.hue / 360 * Double(binCount)) % binCount
            let w = lab.chroma
            weight[bin] += w
            sumL[bin] += lab.l * w
            sumA[bin] += lab.a * w
            sumB[bin] += lab.b * w
        }
        guard opaque > 0 else { return nil }
        let average = RGB(OKLab(l: total.l / opaque, a: total.a / opaque, b: total.b / opaque)).clamped
        // A few coloured pixels in a black-and-white photograph are noise, not its colour.
        guard colored / opaque > 0.04 else { return CoverPalette(accent: nil, average: average) }

        // Merge each bin with its neighbours so a hue split across a bin edge still wins.
        var best = 0
        var bestWeight = 0.0
        for bin in 0..<binCount {
            let sum = weight[(bin + binCount - 1) % binCount] + weight[bin] + weight[(bin + 1) % binCount]
            if sum > bestWeight {
                bestWeight = sum
                best = bin
            }
        }
        var w = 0.0, l = 0.0, a = 0.0, b = 0.0
        for bin in [(best + binCount - 1) % binCount, best, (best + 1) % binCount] {
            w += weight[bin]
            l += sumL[bin]
            a += sumA[bin]
            b += sumB[bin]
        }
        guard w > 0 else { return CoverPalette(accent: nil, average: average) }
        return CoverPalette(accent: RGB(OKLab(l: l / w, a: a / w, b: b / w)).clamped, average: average)
    }
}
