import AppKit

/// Needle's mark: a record, and the arm that rests on it, ending in the needle. Tape's mark is a
/// line that ends in a dot; so is this one.
enum Mark {
    /// In a unit square (origin bottom left).
    static let record = CGPoint(x: 0.42, y: 0.42)
    static let recordRadius: CGFloat = 0.36
    static let pivot = CGPoint(x: 0.88, y: 0.88)
    static let needle = CGPoint(x: 0.6, y: 0.55)
    static let lineWidth: CGFloat = 0.11
    static let dotDiameter: CGFloat = 0.17

    /// A template image for the menu bar.
    static func templateImage(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            func p(_ point: CGPoint) -> CGPoint { CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height) }
            let r = recordRadius * rect.width
            let centre = p(record)
            // The record: its rim and its label.
            context.setLineWidth(rect.width * 0.09)
            context.setStrokeColor(NSColor.black.cgColor)
            context.strokeEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
            context.setFillColor(NSColor.black.cgColor)
            let label = r * 0.32
            context.fillEllipse(in: CGRect(x: centre.x - label, y: centre.y - label, width: label * 2, height: label * 2))
            // The arm, cut out of the record where it crosses, so the two read apart.
            context.setBlendMode(.clear)
            context.setLineWidth(lineWidth * rect.width * 2.4)
            context.setLineCap(.round)
            context.move(to: p(pivot))
            context.addLine(to: p(needle))
            context.strokePath()
            context.setBlendMode(.normal)
            context.setLineWidth(lineWidth * rect.width)
            context.move(to: p(pivot))
            context.addLine(to: p(needle))
            context.strokePath()
            let d = dotDiameter * rect.width
            context.fillEllipse(in: CGRect(x: p(needle).x - d / 2, y: p(needle).y - d / 2, width: d, height: d))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Needle"
        return image
    }
}
