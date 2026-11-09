import AppKit
import Observation

/// A borderless, see-through panel at the Dock's level, on every Space but not over full-screen apps.
final class CornerPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Puts the track beside the Dock and keeps it in step with the music and the settings. When
/// nothing plays (or the music has been paused a while), the corner empties and the window steps aside.
final class CornerController {
    private let model: AppModel
    private let panel = CornerPanel()
    private let stage = Stage()
    private let card: CardController

    private var observation: Task<Void, Never>?
    private var windowObservers: [NSObjectProtocol] = []
    private var isShown = false
    /// The strip's width and the screen's scale the slide was last drawn for.
    private var drawnFor: (width: CGFloat, scale: CGFloat)?
    private var wallpaperKey: String?
    private var lastTrackKey: String?
    /// A new track whose cover hasn't come yet: wait a moment, rather than show it without.
    private var waitingForCover: (key: String, until: Date)?
    private var coverWait: Task<Void, Never>?
    private var pauseCheck: Task<Void, Never>?

    private var slide: SlideView { stage.slide }

    init(model: AppModel) {
        self.model = model
        card = CardController(model: model)
        panel.contentView = stage
        slide.onToggle = { [weak self] in self?.model.player.toggle() }
        slide.onSkip = { [weak self] forward in forward ? self?.model.player.next() : self?.model.player.previous() }
        slide.onSelect = { [weak self] rect in self?.toggleCard(at: rect) }
        slide.onMenu = { [weak self] _ in self?.model.menu() }
        slide.onEmpty = { [weak self] empty in
            guard let self else { return }
            if empty {
                self.panel.orderOut(nil)
                self.isShown = false
            } else {
                self.place()
            }
        }
    }

    func start() {
        model.dock.onChange = { [weak self] in self?.place() }
        // Arriving on a screen with another scale (the laptop's Retina panel after a 1× monitor).
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            })
        }
        observation = Task { [weak self] in
            guard let model = self?.model else { return }
            let changes = Observations { @MainActor in
                // Everything the drawing depends on.
                _ = (model.player.track, model.player.cover?.key, model.ground)
                let settings = model.settings
                _ = (settings.fontSize, settings.contrast, settings.coverColors, settings.showAlbum, settings.glass)
                _ = (settings.side, settings.dockGap, settings.whenPaused, settings.scrollToSkip)
            }
            for await _ in changes {
                self?.refresh()
            }
        }
        place()
        refresh()
    }

    /// Where the corner's window is, while it shows.
    var cornerFrame: CGRect? { isShown ? panel.frame : nil }

    /// Where the window would be, shown or not: for the preview in Settings.
    var stripFrame: CGRect? {
        model.dock.layout.flatMap { Self.frame(for: $0, side: model.settings.side, gap: model.settings.dockGap, height: style.metrics.height) }
    }

    // MARK: Placement

    func place() {
        guard let layout = model.dock.layout,
              let frame = Self.frame(for: layout, side: model.settings.side, gap: model.settings.dockGap, height: style.metrics.height) else {
            hide()
            return
        }
        slide.centre = Self.corner(for: layout, side: model.settings.side).map { $0 - frame.minX }
        sampleWallpaper(for: frame)
        let scale = panel.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if let drawn = drawnFor, drawn.scale != scale || abs(drawn.width - frame.width) >= 1 {
            drawnFor = nil
            refresh()
            return
        }
        guard slide.shown != nil else { return }
        let target = model.dock.isRevealed ? frame : frame.offsetBy(dx: 0, dy: -frame.height - 8)
        let visible = model.dock.isRevealed
        if !isShown {
            panel.setFrame(target, display: true)
            panel.alphaValue = visible ? 1 : 0
            panel.orderFrontRegardless()
            isShown = true
        } else if panel.frame != target || (panel.alphaValue == 1) != visible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = visible == (panel.alphaValue == 1) ? 0.32 : 0.24
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = visible ? 1 : 0
            }
        }
    }

    private func hide() {
        guard isShown else { return }
        panel.orderOut(nil)
        isShown = false
    }

    /// The narrowest strip worth showing: room for a cover. A long Dock on a laptop leaves about 74 points.
    static let minimumWidth: CGFloat = 40

    /// The middle of the corner beside the Dock, between the screen's edge and the glass, in screen
    /// coordinates; nil when the Dock is on a side and the slide sits along the bottom.
    static func corner(for layout: DockLayout, side: DockSide) -> CGFloat? {
        guard layout.edge == .bottom else { return nil }
        return switch side {
        case .left: (layout.screenFrame.minX + layout.tiles.minX) / 2
        case .right: (layout.tiles.maxX + layout.screenFrame.maxX) / 2
        }
    }

    /// The strip between the screen's edge and the Dock, centred on the Dock's icons.
    static func frame(for layout: DockLayout, side: DockSide, gap: CGFloat, height: CGFloat) -> CGRect? {
        let margin: CGFloat = 14
        let screen = layout.screenFrame
        switch layout.edge {
        case .bottom:
            // An auto-hiding Dock is measured while it may be out of sight; centre on where it shows.
            let midY = layout.autohides ? screen.minY + (layout.tileSize + 14) / 2 : layout.tiles.midY
            var minX: CGFloat, maxX: CGFloat
            switch side {
            case .left:
                minX = screen.minX + margin
                maxX = (layout.tiles.minX - gap).rounded(.down)
                // Beside a long Dock every point counts: take some of the screen's margin back.
                if maxX - minX < 100 { minX = screen.minX + margin / 2 }
            case .right:
                minX = (layout.tiles.maxX + gap).rounded(.up)
                maxX = screen.maxX - margin
                if maxX - minX < 100 { maxX = screen.maxX - margin / 2 }
            }
            guard maxX - minX >= Self.minimumWidth else { return nil }
            return CGRect(x: minX, y: max(screen.minY, (midY - height / 2).rounded()), width: maxX - minX, height: height)
        case .left, .right:
            // With the Dock on a side, the slide sits in the bottom corner on the chosen side instead.
            let visible = layout.visibleFrame
            let width = min(visible.width - margin * 2, 360)
            let x = side == .left ? visible.minX + margin : visible.maxX - margin - width
            return CGRect(x: x, y: screen.minY + 8, width: width, height: height)
        }
    }

    // MARK: Wallpaper

    private func sampleWallpaper(for frame: CGRect) {
        guard model.settings.contrast == .automatic else { return }
        guard let screen = panel.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) }),
              let url = Wallpaper.imageURL(for: screen) else { return }
        let region = frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(modified)|\(region.integral)"
        guard key != wallpaperKey else { return }
        wallpaperKey = key
        let size = screen.frame.size
        let scaling = Wallpaper.scaling(for: screen)
        Task { [weak self] in
            let sample = await Task.detached(priority: .utility) {
                Wallpaper.sample(imageAt: url, screenSize: size, region: region, scaling: scaling)
            }.value
            guard let self, let sample, sample.ground != self.model.ground else { return }
            self.model.ground = sample.ground
        }
    }

    /// The wallpaper can change without telling anyone; look again now and then.
    func recheckWallpaper() {
        wallpaperKey = nil
        if let frame = stripFrame { sampleWallpaper(for: frame) }
    }

    // MARK: Drawing

    var style: SlideStyle {
        model.slideStyle(scale: panel.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
    }

    func refresh() {
        let style = self.style
        let width = stripFrame?.width ?? 360
        drawnFor = (width, style.scale)
        stage.configure(glass: style.glass, scale: style.scale)
        slide.metrics = style.metrics
        slide.alignsTrailing = model.settings.side == .left
        slide.scrollToSkip = model.settings.scrollToSkip

        guard let track = model.player.track, shouldShow(track) else {
            lastTrackKey = nil
            waitingForCover = nil
            slide.setSlide(nil, motion: .appear)
            card.close()
            return
        }
        let changed = track.trackKey != lastTrackKey
        var cover = model.player.cover
        if cover?.key != track.artworkID { cover = nil }
        // A new track's cover usually comes with it, sometimes a moment later: wait for it briefly.
        if changed, track.hasArtwork || track.artworkID != nil, cover == nil {
            if waitingForCover?.key != track.trackKey {
                waitingForCover = (track.trackKey, Date.now.addingTimeInterval(0.6))
                coverWait?.cancel()
                coverWait = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(620))
                    guard !Task.isCancelled else { return }
                    self?.refresh()
                }
            }
            if let wait = waitingForCover, wait.key == track.trackKey, Date.now < wait.until { return }
        }
        waitingForCover = nil
        let content = SlideContent(track, cover: cover)
        let rendered = SlideRenderer.slide(for: content, style: style, room: width)
        let motion: SlideView.Motion
        if changed, lastTrackKey != nil {
            let skip = model.player.lastSkip
            let forward = skip.map { Date.now.timeIntervalSince($0.at) < 4 ? $0.forward : true } ?? true
            motion = .roll(forward: forward)
        } else {
            motion = .settle
        }
        lastTrackKey = track.trackKey
        slide.isPlaying = track.isPlaying
        slide.setSlide(rendered, motion: motion)
        let position = track.position()
        let remaining = track.duration.map { max(0, $0 - position) / max(track.effectiveRate, 0.01) } ?? 0
        slide.setProgress(track.progress(), remaining: remaining, running: track.isPlaying)
        place()
        card.refresh()
    }

    /// Paused for longer than the person wants to see it: the corner empties until the music plays again.
    private func shouldShow(_ track: NowPlaying) -> Bool {
        pauseCheck?.cancel()
        guard !track.isPlaying, let limit = model.settings.whenPaused.seconds else { return true }
        if card.isOpen { return true }
        // The player says when it paused; a track paused this morning doesn't come back at login.
        let since = track.timestamp
        let left = limit - Date.now.timeIntervalSince(since)
        guard left > 0 else { return false }
        pauseCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(left + 0.1))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
        return true
    }

    // MARK: Card

    private func toggleCard(at rect: NSRect) {
        if card.isOpen {
            card.close()
            return
        }
        showCard(at: rect)
    }

    func showCard(at rect: NSRect? = nil) {
        guard let rect = rect ?? slide.screenRect() else { return }
        card.show(above: rect, cornerFrame: panel.frame)
    }

    var isShowingTrack: Bool { slide.shown != nil }
}
