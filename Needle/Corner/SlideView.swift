import AppKit
import CoreImage
import QuartzCore

/// The track in the corner, in Tape's Focus: the cover and the words each keep their place on a
/// grid; when the next track comes, the old one drifts up out of focus and the new one rises into
/// it, the cover first. Tracks from one album keep the cover still. A small clock face by the Dock
/// sweeps round as the track plays. Over the cover the pointer finds play and pause; two fingers
/// or the wheel skip; a click on the words opens the cover large.
final class SlideView: NSView {
    var onToggle: (() -> Void)?
    var onSkip: ((Bool) -> Void)?
    var onSelect: ((NSRect) -> Void)?
    var onMenu: ((NSEvent) -> NSMenu?)?
    /// The glass behind the slide and its corner radius, when there's glass, in this view's coordinates.
    var onPlatter: (((rect: CGRect, radius: CGFloat)?) -> Void)?
    /// Says when the last track has left, so the window can step aside.
    var onEmpty: ((Bool) -> Void)?

    var scrollToSkip = true
    var isPlaying = true { didSet { if isPlaying != oldValue { updatePlaying() } } }
    /// Which end the slide sits at: the one by the Dock.
    var alignsTrailing = true { didSet { if alignsTrailing != oldValue { needsLayout = true } } }
    var metrics = SlideMetrics(fontSize: 14) { didSet { if metrics != oldValue { needsLayout = true } } }
    /// The middle of the corner the slide sits in, in this view's coordinates.
    var centre: CGFloat? { didSet { if centre != oldValue { needsLayout = true } } }

    private let grid = CALayer()
    private let veil = CALayer()
    private var columns: [Slide.Column: CALayer] = [:]
    private let hover = CALayer()
    private let ring = CALayer()
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()
    private(set) var shown: Slide?
    private var hovering = false
    private var overCover = false
    private var trackingArea: NSTrackingArea?
    private var scrollAccumulator: CGFloat = 0
    private var lastSkip = Date.distantPast
    private var lastPlatter: [CGFloat]??
    private var hoverKey = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer = CALayer()
        grid.anchorPoint = .zero
        ring.anchorPoint = .zero
        veil.anchorPoint = .zero
        hover.anchorPoint = .zero
        hover.opacity = 0
        for shape in [track, fill] {
            shape.fillColor = nil
            shape.lineCap = .butt
            shape.anchorPoint = .zero
        }
        fill.strokeEnd = 0
        for layer in [grid, veil, ring, track, fill] {
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull(),
                             "path": NSNull(), "strokeColor": NSNull(), "strokeEnd": NSNull(), "lineWidth": NSNull(), "shadowOpacity": NSNull()]
        }
        hover.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        ring.addSublayer(track)
        ring.addSublayer(fill)
        grid.addSublayer(veil)
        grid.addSublayer(hover)
        layer?.addSublayer(grid)
        layer?.addSublayer(ring)
        ring.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Slides

    nonisolated enum Motion: Sendable {
        /// The first track, or one after silence.
        case appear
        /// The next track, or (backwards) the one before.
        case roll(forward: Bool)
        /// The same track, a little different: its cover arrived, or the text size changed.
        case settle

        var travel: CGFloat {
            switch self {
            case .appear, .settle: 0
            case .roll(let forward): forward ? 6 : -6
            }
        }

        var blur: Double {
            switch self {
            case .appear: 4
            case .roll: 5
            case .settle: 2.5
            }
        }

        var out: CFTimeInterval { if case .settle = self { 0.2 } else { 0.26 } }
        var into: CFTimeInterval { if case .settle = self { 0.38 } else { 0.52 } }
        var lag: CFTimeInterval { if case .settle = self { 0.05 } else { 0.09 } }
        /// Between the cover and the words.
        var stagger: CFTimeInterval { if case .roll = self { 0.05 } else { 0 } }
    }

    /// Shows `slide` (nil: the corner empties), moving only the columns that changed.
    func setSlide(_ slide: Slide?, motion: Motion) {
        guard let slide else {
            clear()
            return
        }
        let wasEmpty = shown == nil
        if let shown, shown.key == slide.key, shown.size == slide.size {
            self.shown = slide
            return
        }
        present(slide, wasEmpty ? .appear : motion)
        if wasEmpty { onEmpty?(false) }
    }

    private func clear() {
        guard shown != nil else { return }
        shown = nil
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (order, layer) in columns.sorted(by: { $0.key.rawValue < $1.key.rawValue }).map(\.value).enumerated() {
            leave(layer, .roll(forward: true), calm: calm, at: now + Double(order) * 0.05)
        }
        columns = [:]
        veil.contents = nil
        hover.opacity = 0
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = ring.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = 0.25
        ring.add(fade, forKey: "fade")
        ring.opacity = 0
        reportPlatter(nil)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(420))
            guard let self, self.shown == nil else { return }
            self.ring.isHidden = true
            self.ring.opacity = 1
            self.onEmpty?(true)
        }
    }

    private func present(_ slide: Slide, _ motion: Motion) {
        shown = slide
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeGrid()
        if veil.contents as! CGImage? !== slide.veil {
            veil.contents = slide.veil
            veil.contentsScale = slide.veil.map { CGFloat($0.width) / max(slide.veilFrame.width, 1) } ?? 1
        }
        veil.frame = slide.veilFrame
        let now = CACurrentMediaTime()
        // With Reduce Motion, columns cross-fade in place.
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (order, column) in Slide.Column.allCases.enumerated() {
            let part = slide.part(column)
            let old = columns[column]
            if let part, let old, old.value(forKey: "key") as? String == part.key {
                old.frame = part.frame
                continue
            }
            let delay = Double(order) * motion.stagger
            if let old { leave(old, motion, calm: calm, at: now + delay) }
            columns[column] = nil
            guard let part else { continue }
            let layer = CALayer()
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "opacity": NSNull(), "filters": NSNull()]
            layer.contents = part.image
            layer.contentsScale = CGFloat(part.image.width) / part.frame.width
            layer.frame = part.frame
            layer.setValue(part.key, forKey: "key")
            layer.opacity = restingOpacity(column)
            grid.insertSublayer(layer, below: hover)
            columns[column] = layer
            arrive(layer, motion, calm: calm, at: now + delay + (old == nil ? 0 : motion.lag))
        }
        updateHover(animated: false)
        CATransaction.commit()
    }

    /// The words and the clock step back while the music is paused; the cover stays as it is.
    private func restingOpacity(_ column: Slide.Column) -> Float {
        column == .identity && !isPlaying ? Float(SlideRenderer.pausedAlpha) : 1
    }

    private func updatePlaying() {
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (column, layer) in columns {
            let to = restingOpacity(column)
            guard layer.opacity != to, layer.animation(forKey: "arrive") == nil || calm else {
                layer.opacity = restingOpacity(column)
                continue
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
            fade.toValue = to
            fade.duration = 0.35
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: "dim")
            layer.opacity = to
        }
        let ringTo: Float = isPlaying ? 1 : Float(SlideRenderer.pausedAlpha)
        if ring.opacity != ringTo, !ring.isHidden {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = ring.presentation()?.opacity ?? ring.opacity
            fade.toValue = ringTo
            fade.duration = 0.35
            ring.add(fade, forKey: "dim")
        }
        ring.opacity = ringTo
        hoverKey = ""
        updateHover(animated: true)
    }

    private func leave(_ layer: CALayer, _ motion: Motion, calm: Bool, at begin: CFTimeInterval) {
        let blur = calm ? nil : Self.blurFilter()
        let travel = calm ? 0 : motion.travel
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.filters = blur.map { [$0] }
        layer.opacity = 0
        let group = CAAnimationGroup()
        group.animations = [
            Self.animation("opacity", from: from, to: 0),
            Self.animation("position.y", from: layer.position.y, to: layer.position.y + travel),
        ] + (blur == nil ? [] : [Self.animation("filters.blur.inputRadius", from: 0, to: motion.blur)])
        group.duration = motion.out
        group.beginTime = begin
        group.fillMode = .both
        group.isRemovedOnCompletion = false
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.85, 0.5)
        layer.add(group, forKey: "leave")
        let wait = begin - CACurrentMediaTime() + motion.out + 0.05
        Task { [weak layer] in
            try? await Task.sleep(for: .seconds(max(wait, 0)))
            layer?.removeFromSuperlayer()
        }
    }

    private func arrive(_ layer: CALayer, _ motion: Motion, calm: Bool, at begin: CFTimeInterval) {
        let blur = calm ? nil : Self.blurFilter()
        let travel = calm ? 0 : motion.travel
        layer.filters = blur.map { [$0] }
        let group = CAAnimationGroup()
        group.animations = [
            Self.animation("opacity", from: 0, to: layer.opacity),
            Self.animation("position.y", from: layer.position.y - travel, to: layer.position.y),
        ] + (blur == nil ? [] : [Self.animation("filters.blur.inputRadius", from: motion.blur, to: 0)])
        group.duration = motion.into
        group.beginTime = begin
        group.fillMode = .backwards
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        layer.add(group, forKey: "arrive")
        // Sharp again: drop the filter, so a still slide costs nothing to draw.
        let wait = begin - CACurrentMediaTime() + motion.into + 0.05
        Task { [weak layer] in
            try? await Task.sleep(for: .seconds(max(wait, 0)))
            layer?.filters = nil
        }
    }

    private static func animation(_ keyPath: String, from: Any, to: Any) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        return animation
    }

    private static func blurFilter() -> CIFilter? {
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.name = "blur"
        filter.setValue(0, forKey: kCIInputRadiusKey)
        return filter
    }

    // MARK: Clock

    /// How far through the track it is, and whether it's moving. The wedge then sweeps on by
    /// itself at the track's own pace, so nothing needs to tick.
    func setProgress(_ progress: Double?, remaining: TimeInterval, running: Bool) {
        guard let progress, let slide = shown, slide.clock else {
            ring.isHidden = true
            fill.removeAnimation(forKey: "play")
            return
        }
        ring.isHidden = false
        let current = Double(fill.presentation()?.strokeEnd ?? fill.strokeEnd)
        let target = min(max(progress, 0), 1)
        fill.removeAnimation(forKey: "play")
        // A jump (a new track, a seek) is shown as a quick wind to the new place.
        let jump = abs(current - target) > 0.01 ? 0.35 : 0
        let animation = CAKeyframeAnimation(keyPath: "strokeEnd")
        if running, remaining > 0.05 {
            let total = jump + remaining
            animation.values = [current, target, 1]
            animation.keyTimes = [0, NSNumber(value: jump / total), 1]
            animation.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear)]
            animation.duration = total
            fill.strokeEnd = 1
        } else {
            guard jump > 0 else {
                fill.strokeEnd = target
                return
            }
            animation.values = [current, target]
            animation.keyTimes = [0, 1]
            animation.timingFunctions = [CAMediaTimingFunction(name: .easeOut)]
            animation.duration = jump
            fill.strokeEnd = target
        }
        animation.isRemovedOnCompletion = true
        fill.add(animation, forKey: "play")
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeGrid()
        CATransaction.commit()
    }

    var placement: SlideMetrics.Layout? {
        guard let slide = shown else { return nil }
        return metrics.layout(in: bounds, gridWidth: slide.size.width, trailing: alignsTrailing, clock: slide.clock, tile: slide.tile, centre: centre)
    }

    private func placeGrid() {
        guard let placement, let slide = shown else { return }
        grid.frame = CGRect(origin: placement.grid.origin, size: slide.size)
        ring.frame = placement.ring
        let local = CGRect(origin: .zero, size: placement.ring.size)
        let line = metrics.ringLine * 0.75
        let colors = SlideRenderer.ringColors(dark: slide.isDark)
        let wedge = SlideRenderer.wedgeCircle(in: local, line: line)
        track.frame = local
        track.path = SlideRenderer.ringPath(in: local, line: line)
        track.lineWidth = line
        track.strokeColor = colors.track
        fill.frame = local
        fill.path = wedge.path
        fill.lineWidth = wedge.width
        fill.strokeColor = colors.fill
        // On the wallpaper the ring gets the same lift as the text; on glass it needs none.
        ring.shadowColor = CGColor(gray: 0, alpha: 1)
        ring.shadowOffset = CGSize(width: 0, height: -0.5)
        ring.shadowRadius = 1
        ring.shadowOpacity = slide.isDark && !metrics.glass ? 0.45 : 0
        if !slide.clock { ring.isHidden = true }
        hover.frame = slide.coverRect
        reportPlatter(metrics.glass ? (rect: placement.platter, radius: metrics.platterRadius(tile: slide.tile)) : nil)
    }

    private func reportPlatter(_ platter: (rect: CGRect, radius: CGFloat)?) {
        let key = platter.map { [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height, $0.radius] }
        guard lastPlatter != .some(key) else { return }
        lastPlatter = .some(key)
        onPlatter?(platter)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        matchScreenScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        matchScreenScale()
        hoverKey = ""
        updateHover(animated: false)
    }

    /// The clock is drawn by Core Animation from its path; at the layer's default scale of 1 it
    /// would be drawn at half the Retina screen's resolution and enlarged, soft at the edge.
    private func matchScreenScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for layer in [ring, track, fill] where layer.contentsScale != scale { layer.contentsScale = scale }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        trackPointer(event)
    }

    override func mouseMoved(with event: NSEvent) {
        trackPointer(event)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        overCover = false
        updateHover(animated: true)
    }

    private func trackPointer(_ event: NSEvent) {
        let over = coverHit(convert(event.locationInWindow, from: nil))
        guard over != overCover else { return }
        overCover = over
        updateHover(animated: true)
    }

    private func coverHit(_ point: CGPoint) -> Bool {
        guard let slide = shown, let placement else { return false }
        return slide.coverRect.offsetBy(dx: placement.grid.minX, dy: placement.grid.minY).insetBy(dx: -2, dy: -2).contains(point)
    }

    /// Play or pause over the cover, while the pointer is on it.
    private func updateHover(animated: Bool) {
        guard let slide = shown else { return }
        let scale = window?.backingScaleFactor ?? 2
        let key = "\(slide.coverRect.size)|\(isPlaying)|\(scale)"
        if key != hoverKey {
            hoverKey = key
            hover.contents = SlideRenderer.hoverImage(side: slide.coverRect.width, radius: slide.coverRadius, playing: isPlaying, scale: scale)
            hover.contentsScale = scale
        }
        let target: Float = overCover ? 1 : 0
        guard hover.opacity != target else { return }
        if animated {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = hover.presentation()?.opacity ?? hover.opacity
            fade.toValue = target
            fade.duration = overCover ? 0.14 : 0.22
            hover.add(fade, forKey: "fade")
        }
        hover.opacity = target
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard let slide = shown, let placement else { return }
        let point = convert(event.locationInWindow, from: nil)
        if coverHit(point) {
            onToggle?()
            return
        }
        guard placement.grid.insetBy(dx: -8, dy: 0).contains(point) || placement.platter.contains(point) else { return }
        _ = slide
        if let rect = screenRect() { onSelect?(rect) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = onMenu?(event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    /// Skip by hand: a deliberate swipe or a notch of the wheel is one track, at most one a moment.
    override func scrollWheel(with event: NSEvent) {
        guard scrollToSkip, shown != nil else { return }
        if event.phase == .began { scrollAccumulator = 0 }
        let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? -event.scrollingDeltaX : event.scrollingDeltaY
        scrollAccumulator += event.hasPreciseScrollingDeltas ? delta : delta * 30
        guard abs(scrollAccumulator) > 44, Date.now.timeIntervalSince(lastSkip) > 0.6 else { return }
        onSkip?(scrollAccumulator < 0)
        lastSkip = .now
        scrollAccumulator = 0
    }

    /// The slide's cover and words, on screen.
    func screenRect() -> NSRect? {
        guard let placement, let slide = shown else { return nil }
        let rect = convert(CGRect(x: placement.grid.minX, y: placement.grid.minY + slide.coverRect.minY, width: slide.size.width, height: slide.coverRect.height), to: nil)
        return window?.convertToScreen(rect)
    }
}
