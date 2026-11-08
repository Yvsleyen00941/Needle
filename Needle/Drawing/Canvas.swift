import AppKit
import CoreText

/// A bitmap to draw one part of the slide into, in points, at the screen's scale.
nonisolated struct Bitmap {
    let context: CGContext
    let size: CGSize
    /// Pixels per point.
    let scale: CGFloat

    /// `smoothFonts` draws text as macOS draws its own, with the strokes filled out a little, when
    /// the Mac has font smoothing on (System Settings → Appearance; it is on unless turned off).
    init?(size: CGSize, scale: CGFloat, smoothFonts: Bool = false) {
        let wide = Int((size.width * scale).rounded(.up)), high = Int((size.height * scale).rounded(.up))
        guard wide > 0, high > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: wide, height: high, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let smooth = smoothFonts && Typeface.systemSmoothsFonts
        context.setAllowsFontSmoothing(smooth)
        context.setShouldSmoothFonts(smooth)
        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)
        context.interpolationQuality = .high
        self.context = context
        self.size = size
        self.scale = scale
    }

    func image() -> CGImage? { context.makeImage() }

    /// Text starts on a whole pixel, so stems and baselines land on the grid rather than between
    /// two rows of pixels; the glyphs within the line keep their own subpixel spacing.
    func draw(_ line: CTLine, at point: CGPoint) {
        context.textPosition = CGPoint(x: snap(point.x), y: snap(point.y))
        CTLineDraw(line, context)
    }

    /// The nearest whole pixel, in points.
    func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }

    /// Shadows composited once over everything `body` draws, innermost first.
    func shadowed(_ shadows: [Shadow], _ body: () -> Void) {
        for shadow in shadows.reversed() {
            context.setShadow(offset: shadow.offset, blur: shadow.blur, color: shadow.color)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        body()
        for _ in shadows { context.endTransparencyLayer() }
    }

    func fillCapsule(_ rect: CGRect, radius: CGFloat? = nil, color: CGColor) {
        context.setFillColor(color)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius ?? rect.height / 2, cornerHeight: radius ?? rect.height / 2, transform: nil))
        context.fillPath()
    }

    nonisolated struct Shadow {
        var blur: CGFloat
        var offset: CGSize = .zero
        var color: CGColor
    }
}

/// Shapes the designs share.
nonisolated enum Shapes {
    /// A rounded rectangle with continuous corners, like an app icon's: the curve starts further
    /// out and eases in, so there's no visible seam where the straight edge meets the arc.
    static func continuous(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = min(radius, min(rect.width, rect.height) / 2 / 1.52866483)
        guard r > 0 else { return CGPath(rect: rect, transform: nil) }
        let path = CGMutablePath()
        // Each corner: the corner point, the way back along the edge we arrive on, and the way on.
        let corners: [(CGPoint, CGVector, CGVector)] = [
            (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
            (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
            (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
            (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
        ]
        for (index, (corner, back, on)) in corners.enumerated() {
            func p(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
                CGPoint(x: corner.x + (back.dx * a + on.dx * b) * r, y: corner.y + (back.dy * a + on.dy * b) * r)
            }
            if index == 0 { path.move(to: p(1.52866483, 0)) } else { path.addLine(to: p(1.52866483, 0)) }
            path.addCurve(to: p(0.63149399, 0.07491100), control1: p(1.08849323, 0), control2: p(0.86840689, 0))
            path.addCurve(to: p(0.07491100, 0.63149399), control1: p(0.37282392, 0.16251680), control2: p(0.16251680, 0.37282392))
            path.addCurve(to: p(0, 1.52866483), control1: p(0, 0.86840689), control2: p(0, 1.08849323))
        }
        path.closeSubpath()
        return path
    }
}

/// Type for the designs: SF Pro in its default, rounded, serif (New York) and mono cuts.
nonisolated enum Typeface {
    /// Whether the Mac smooths text: on unless "Use font smoothing when available" is off.
    static var systemSmoothsFonts: Bool {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        if (global["CGFontRenderingFontSmoothingDisabled"] as? NSNumber)?.boolValue == true { return false }
        if let level = global["AppleFontSmoothing"] as? NSNumber { return level.intValue > 0 }
        return true
    }

    static func font(_ size: CGFloat, _ weight: NSFont.Weight, design: NSFontDescriptor.SystemDesign = .default, tabular: Bool = false) -> NSFont {
        var font: NSFont
        if design == .monospaced {
            font = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        } else {
            font = NSFont.systemFont(ofSize: size, weight: weight)
            if design != .default, let descriptor = font.fontDescriptor.withDesign(design) {
                font = NSFont(descriptor: descriptor, size: size) ?? font
            }
        }
        guard tabular else { return font }
        let feature: [NSFontDescriptor.FeatureKey: Int] = [
            .typeIdentifier: kNumberSpacingType,
            .selectorIdentifier: kMonospacedNumbersSelector,
        ]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [feature]])
        return NSFont(descriptor: descriptor, size: size) ?? font
    }

    static func line(_ text: String, _ font: NSFont, _ color: RGB, alpha: Double = 1, kern: CGFloat = 0) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.nsColor(alpha: alpha), .kern: kern]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    static func width(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

