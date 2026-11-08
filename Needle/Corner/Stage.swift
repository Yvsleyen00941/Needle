import AppKit

/// Everything inside the corner's window: the slide and, when chosen, a pane of glass behind it
/// that follows the slide rather than filling the window.
final class Stage: NSView {
    let slide = SlideView()

    private(set) var glassOn = false
    private var scale: CGFloat = 2
    private var platter: (rect: CGRect, radius: CGFloat)?
    private let shadowView = NSView()
    private let glass = NSVisualEffectView()
    private let edge = NSView()
    private var edgeKey = ""

    /// In Settings the glass blurs what's in the window (the wallpaper preview), not the desktop.
    init(preview: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        shadowView.wantsLayer = true
        edge.wantsLayer = true
        glass.material = .hudWindow
        glass.blendingMode = preview ? .withinWindow : .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        for view in [shadowView, glass, edge, slide] as [NSView] { addSubview(view) }
        slide.onPlatter = { [weak self] platter in self?.place(platter) }
        place(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(glass: Bool, scale: CGFloat) {
        guard glass != glassOn || scale != self.scale else { return }
        glassOn = glass
        self.scale = scale
        place(platter)
    }

    override func layout() {
        super.layout()
        slide.frame = bounds
        place(platter)
    }

    private func place(_ platter: (rect: CGRect, radius: CGFloat)?) {
        self.platter = platter
        guard glassOn, let platter else {
            for view in [glass, edge, shadowView] { view.isHidden = true }
            return
        }
        for view in [glass, edge, shadowView] {
            view.isHidden = false
            view.frame = platter.rect
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let local = CGRect(origin: .zero, size: platter.rect.size)
        if let layer = shadowView.layer {
            layer.shadowPath = Shapes.continuous(local, radius: platter.radius)
            layer.shadowColor = CGColor(gray: 0, alpha: 1)
            layer.shadowOpacity = 0.28
            layer.shadowRadius = 7
            layer.shadowOffset = CGSize(width: 0, height: -2)
        }
        glass.maskImage = Self.mask(height: platter.rect.height, radius: platter.radius)
        let key = "\(platter.rect.size)|\(platter.radius)|\(scale)"
        if key != edgeKey {
            edgeKey = key
            edge.layer?.contents = Self.glassEdge(size: platter.rect.size, radius: platter.radius, scale: scale)
            edge.layer?.contentsScale = scale
        }
    }

    /// The glass's outline as a stretchable image: corners kept, the middle stretched.
    private static func mask(height: CGFloat, radius: CGFloat) -> NSImage {
        let corner = (radius * 1.53).rounded(.up)
        let image = NSImage(size: NSSize(width: corner * 2 + 1, height: height), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(cgPath: Shapes.continuous(rect, radius: radius)).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: 0, left: corner, bottom: 0, right: corner)
        image.resizingMode = .stretch
        return image
    }

    /// What makes blur read as glass: a lit rim, a catch-light along the top, a darker lower edge.
    static func glassEdge(size: CGSize, radius: CGFloat, scale: CGFloat) -> CGImage? {
        guard let canvas = Bitmap(size: size, scale: scale) else { return nil }
        let context = canvas.context
        let rect = CGRect(origin: .zero, size: size)
        context.saveGState()
        context.addPath(Shapes.continuous(rect, radius: radius))
        context.clip()
        let tint = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0.02), CGColor(gray: 0, alpha: 0.08)] as CFArray, locations: [0, 0.5, 1])!
        context.drawLinearGradient(tint, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
        context.restoreGState()
        let px = 1 / scale
        context.addPath(Shapes.continuous(rect.insetBy(dx: px / 2, dy: px / 2), radius: radius - px / 2))
        context.setLineWidth(px)
        context.replacePathWithStrokedPath()
        context.clip()
        let rim = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 1, alpha: 0.5), CGColor(gray: 1, alpha: 0.12), CGColor(gray: 1, alpha: 0.22)] as CFArray, locations: [0, 0.5, 1])!
        context.drawLinearGradient(rim, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
        return canvas.image()
    }
}
