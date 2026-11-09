import AppKit
import CoreImage
import CoreText

// MARK: - What the slide shows

/// How the slide is drawn: its text size, the ground under it and the screen it's on.
nonisolated struct SlideStyle: Equatable, Sendable {
    var fontSize: CGFloat = 14
    var ground: Ground = .dark
    var glass = false
    var coverColors = true
    var showAlbum = true
    var scale: CGFloat = 2

    var isDark: Bool { ground == .dark }
    /// The ink for text: white on a dark ground, near black on a light one.
    var ink: RGB { isDark ? RGB(hex: 0xFFFFFF) : RGB(hex: 0x141416) }
    var metrics: SlideMetrics { SlideMetrics(fontSize: fontSize, glass: glass) }
}

/// One track, before it's drawn.
nonisolated struct SlideContent: @unchecked Sendable {
    nonisolated enum Kind: Sendable { case music, podcast, video }

    var title: String
    var artist: String?
    var album: String?
    var cover: CGImage?
    var palette: CoverPalette?
    /// Same key, same picture: tracks from one album keep their cover still.
    var coverKey: String
    var trackKey: String
    var kind: Kind = .music

    init(title: String, artist: String? = nil, album: String? = nil, cover: CGImage? = nil, palette: CoverPalette? = nil,
         coverKey: String, trackKey: String, kind: Kind = .music) {
        self.title = title
        self.artist = artist
        self.album = album
        self.cover = cover
        self.palette = palette
        self.coverKey = coverKey
        self.trackKey = trackKey
        self.kind = kind
    }

    init(_ track: NowPlaying, cover: Cover?) {
        self.init(
            title: Titles.title(track.title),
            artist: track.artist,
            album: track.album.map(Titles.album),
            cover: cover?.image,
            palette: cover?.palette,
            coverKey: cover.map { $0.key } ?? "placeholder|\(track.isVideo)|\(track.isPodcast)",
            trackKey: track.trackKey,
            kind: track.isVideo ? .video : track.isPodcast ? .podcast : .music
        )
    }
}

/// The track as Focus draws it: separate columns, the cover and the words, each of which can come
/// into focus on its own. A new track from the same album changes only the words.
nonisolated struct Slide: @unchecked Sendable {
    nonisolated enum Column: Int, CaseIterable, Sendable { case cover, identity }

    nonisolated struct Part: @unchecked Sendable {
        var column: Column
        var image: CGImage
        /// Where it sits on the slide, in points, with room around it for its shadow.
        var frame: CGRect
        /// Everything it shows: a column that hasn't changed stays still while the other moves.
        var key: String
    }

    var trackKey: String
    var parts: [Part]
    /// The grid: as wide as its columns and as tall as the window. Shadows spill past it.
    var size: CGSize
    /// The cover itself, on the grid: what a click plays or pauses.
    var coverRect: CGRect
    var coverRadius: CGFloat
    var isDark: Bool
    /// A soft shade behind the words, so they keep their contrast over a busy photograph.
    var veil: CGImage?
    var veilFrame: CGRect = .zero
    /// Whether there's room for the clock beside the slide.
    var clock = true
    /// The cover's side, which the glass's padding and corners follow.
    var tile: CGFloat

    var key: String { parts.map(\.key).joined(separator: "‖") }
    func part(_ column: Column) -> Part? { parts.first { $0.column == column } }
}

// MARK: - Geometry

/// The slide's sizes at a text size, and where the grid, the clock and the glass go. The same
/// proportions as Tape's Focus, with the logo's tile grown into a cover.
nonisolated struct SlideMetrics: Equatable, Sendable {
    let fontSize: CGFloat
    let height: CGFloat
    let cover: CGFloat
    let glass: Bool

    init(fontSize f: CGFloat, glass: Bool = false) {
        fontSize = f
        height = max(56, (f * 4).rounded())
        cover = (height * 0.71).rounded()
        self.glass = glass
    }

    /// A record sleeve's corner: rounder than a print, much squarer than an app icon, so a cover
    /// never passes for one of the Dock's apps.
    static func coverRadius(_ side: CGFloat) -> CGFloat { max(3, (side * 0.11 * 2).rounded() / 2) }
    /// Room around each column for its shadow, and for the blur it passes through.
    var room: CGFloat { (fontSize * 0.75).rounded(.up) }

    var titleFont: NSFont { Typeface.font((fontSize * 1.07).rounded(), .semibold) }
    var artistFont: NSFont { Typeface.font((fontSize * 0.86).rounded(), .regular) }
    var compactTitleFont: NSFont { Typeface.font((fontSize * 0.93).rounded(), .semibold) }
    var compactArtistFont: NSFont { Typeface.font((fontSize * 0.79).rounded(), .regular) }
    var compactCover: CGFloat { (height * 0.64).rounded() }

    var stackGap: CGFloat { (fontSize * 0.36).rounded() }
    var coverGap: CGFloat { (fontSize * 0.8).rounded() }

    // The clock: a small ring between the slide and the Dock that closes as the next track approaches.
    var ringDiameter: CGFloat { max(11, (fontSize * 0.86).rounded()) }
    var ringLine: CGFloat { 1.5 }
    var ringGap: CGFloat { (fontSize * 0.85).rounded() }

    // The glass, when there is one: as tall as the window allows, with corners concentric with the cover's.
    var platterInset: CGFloat { glass ? 4 : 0 }
    var platterHeight: CGFloat { height - platterInset * 2 }
    func platterPadding(tile: CGFloat) -> CGFloat { glass ? ((platterHeight - tile) / 2).rounded() : 0 }
    func platterRadius(tile: CGFloat) -> CGFloat { Self.coverRadius(tile) + platterPadding(tile: tile) }
    /// Room left at the Dock's end of the window: for the glass's shadow, or a pixel of air.
    private var dockEdge: CGFloat { glass ? 6 : 2 }
    private func ringPadding(tile: CGFloat) -> CGFloat { glass ? ((platterHeight - ringDiameter) / 2 * 0.62).rounded() : 0 }
    /// Room on the far side for the cover's shadow.
    private var outerRoom: CGFloat { glass ? 6 : 5 }

    /// How wide the grid can be in a window this wide, with or without the clock beside it.
    func gridRoom(in width: CGFloat, clock: Bool = true, tile: CGFloat? = nil) -> CGFloat {
        let tile = tile ?? cover
        let end = clock ? ringPadding(tile: tile) + ringDiameter + ringGap : platterPadding(tile: tile)
        let chrome = dockEdge + end + platterPadding(tile: tile) + outerRoom
        return max(0, width - chrome)
    }

    nonisolated struct Layout: Equatable {
        var grid: CGRect
        var ring: CGRect
        var platter: CGRect
    }

    /// With the Dock to the right (`trailing`), the slide ends at the Dock; otherwise it starts there.
    /// With a `centre` (the middle of the corner, between the screen's edge and the Dock's glass), a
    /// slide with room to spare sits in the middle of the corner, never closer to the Dock than the strip allows.
    func layout(in bounds: CGRect, gridWidth: CGFloat, trailing: Bool, clock: Bool = true, tile: CGFloat? = nil, centre: CGFloat? = nil) -> Layout {
        let placed = layout(in: bounds, gridWidth: gridWidth, trailing: trailing, clock: clock, tile: tile)
        guard let centre else { return placed }
        let lowest = bounds.minX + outerRoom - placed.platter.minX
        let highest = (bounds.maxX - dockEdge).rounded() - placed.platter.maxX
        guard lowest <= highest else { return placed }
        let shift = min(max((centre - placed.platter.midX).rounded(), lowest), highest)
        return Layout(grid: placed.grid.offsetBy(dx: shift, dy: 0), ring: placed.ring.offsetBy(dx: shift, dy: 0), platter: placed.platter.offsetBy(dx: shift, dy: 0))
    }

    private func layout(in bounds: CGRect, gridWidth: CGFloat, trailing: Bool, clock: Bool, tile: CGFloat?) -> Layout {
        let tile = tile ?? cover
        let padding = platterPadding(tile: tile)
        let ringY = (bounds.midY - ringDiameter / 2).rounded()
        let platterY = bounds.minY + platterInset
        let end = clock ? ringPadding(tile: tile) + ringDiameter + ringGap : padding
        if trailing {
            let platterMaxX = (bounds.maxX - dockEdge).rounded()
            let ring = CGRect(x: platterMaxX - ringPadding(tile: tile) - ringDiameter, y: ringY, width: ringDiameter, height: ringDiameter)
            let grid = CGRect(x: platterMaxX - end - gridWidth, y: bounds.minY, width: gridWidth, height: bounds.height)
            let platter = CGRect(x: grid.minX - padding, y: platterY, width: platterMaxX - grid.minX + padding, height: platterHeight)
            return Layout(grid: grid, ring: ring, platter: platter)
        }
        let platterMinX = (bounds.minX + dockEdge).rounded()
        let ring = CGRect(x: platterMinX + ringPadding(tile: tile), y: ringY, width: ringDiameter, height: ringDiameter)
        let grid = CGRect(x: platterMinX + end, y: bounds.minY, width: gridWidth, height: bounds.height)
        let platter = CGRect(x: platterMinX, y: platterY, width: grid.maxX + padding - platterMinX, height: platterHeight)
        return Layout(grid: grid, ring: ring, platter: platter)
    }
}

/// The columns' widths for a strip: the same for every track, so the cover keeps its place from
/// one song to the next.
nonisolated struct SlideGrid: Equatable, Sendable {
    var cover: CGFloat
    var gap: CGFloat
    /// Zero for the cover alone.
    var identity: CGFloat
    var compact: Bool
    var clock: Bool

    var identityX: CGFloat { cover + gap }
    var width: CGFloat { (identity > 0 ? identityX + identity : cover).rounded(.up) }

    /// The widest that fits `room`. On a wide strip: cover, title over artist, and the clock by the
    /// Dock, where the words give way first. Narrower, smaller words and a smaller cover; then the
    /// cover and the clock; narrowest, the cover alone, which the corner was made for.
    static func fitting(_ room: CGFloat, metrics m: SlideMetrics) -> SlideGrid {
        let f = m.fontSize
        let compactGap = (m.coverGap * 0.75).rounded()
        // Each tier takes the room it's given, between a width that still reads and one past which
        // more room is only air.
        let tiers: [(cover: CGFloat, gap: CGFloat, compact: Bool, clock: Bool, least: CGFloat, most: CGFloat)] = [
            (m.cover, m.coverGap, false, true, 7, 11),
            (m.compactCover, compactGap, true, true, 5.5, 7),
            (m.compactCover, compactGap, true, false, 5, 7),
        ]
        for tier in tiers {
            let available = (m.gridRoom(in: room, clock: tier.clock, tile: tier.cover) - tier.cover - tier.gap).rounded(.down)
            guard available >= (f * tier.least).rounded() else { continue }
            return SlideGrid(cover: tier.cover, gap: tier.gap, identity: min(available, (f * tier.most).rounded()), compact: tier.compact, clock: tier.clock)
        }
        let withClock = SlideGrid(cover: m.cover, gap: 0, identity: 0, compact: false, clock: true)
        if withClock.width <= m.gridRoom(in: room, clock: true, tile: m.cover) { return withClock }
        // The cover alone, as large as the strip allows.
        let side = min(m.cover, max(24, m.gridRoom(in: room, clock: false, tile: m.cover).rounded(.down)))
        return SlideGrid(cover: side, gap: 0, identity: 0, compact: true, clock: false)
    }
}

// MARK: - Drawing

nonisolated enum SlideRenderer {
    static func slide(for content: SlideContent, style: SlideStyle, room: CGFloat = .infinity) -> Slide {
        let m = style.metrics
        let grid = SlideGrid.fitting(room, metrics: m)
        return render(content, grid: grid, metrics: m, style: style)
    }

    static func render(_ content: SlideContent, grid: SlideGrid, metrics m: SlideMetrics, style: SlideStyle) -> Slide {
        let height = m.height, room = m.room
        let dark = style.isDark
        let ink = style.ink
        let styleKey = "\(style.fontSize)|\(style.scale)|\(dark)|\(style.glass)|\(grid.compact)"
        var parts: [Slide.Part] = []
        func part(_ column: Slide.Column, x: CGFloat, width: CGFloat, key: String, _ draw: (Bitmap) -> Void) {
            let frame = CGRect(x: x - room, y: 0, width: width + room * 2, height: height)
            guard let canvas = Bitmap(size: frame.size, scale: style.scale, smoothFonts: true) else { return }
            draw(canvas)
            guard let image = canvas.image() else { return }
            parts.append(.init(column: column, image: image, frame: frame, key: [key, styleKey, "\(frame.size)"].joined(separator: "|")))
        }

        let side = grid.cover
        let radius = SlideMetrics.coverRadius(side)
        let coverY = ((height - side) / 2).rounded()
        part(.cover, x: 0, width: side, key: "\(content.coverKey)|\(side)") { canvas in
            drawCover(content, in: CGRect(x: room, y: coverY, width: side, height: side), radius: radius, style: style, canvas: canvas)
        }

        if grid.identity > 0 {
            let titleFont = grid.compact ? m.compactTitleFont : m.titleFont
            let artistFont = grid.compact ? m.compactArtistFont : m.artistFont
            let titleColor = (style.coverColors ? content.palette?.accent : nil).map { Legibility.adjust($0, for: style.ground) } ?? ink
            let quiet = dark ? 0.64 : 0.6
            let title = truncated(content.title, font: titleFont, color: titleColor, alpha: 1, width: grid.identity)
            let subtitle = subtitle(for: content, font: artistFont, color: ink, alpha: quiet, width: grid.identity, showAlbum: style.showAlbum)
            let shadows = textShadows(dark: dark, glass: style.glass, fontSize: m.fontSize)
            let (titleBaseline, artistBaseline) = baselines(height: height, title: titleFont, artist: artistFont, gap: grid.compact ? (m.stackGap * 0.8).rounded() : m.stackGap, single: subtitle == nil)
            let key = "\(content.title)|\(content.artist ?? "")|\(content.album ?? "")|\(style.showAlbum)|\(titleColor.hexString)|\(grid.identity)"
            part(.identity, x: grid.identityX, width: grid.identity, key: key) { canvas in
                canvas.shadowed(shadows) {
                    canvas.draw(title, at: CGPoint(x: room, y: titleBaseline))
                    if let subtitle { canvas.draw(subtitle, at: CGPoint(x: room, y: artistBaseline)) }
                }
            }
        }

        let coverRect = CGRect(x: 0, y: coverY, width: side, height: side)
        var slide = Slide(trackKey: content.trackKey, parts: parts, size: CGSize(width: grid.width, height: height), coverRect: coverRect,
                          coverRadius: radius, isDark: dark, clock: grid.clock, tile: side)
        if !style.glass, grid.identity > 0 {
            let (veil, frame) = veil(from: grid.identityX - 4, width: grid.identity + 8, metrics: m, style: style)
            slide.veil = veil
            slide.veilFrame = frame
        }
        return slide
    }

    // MARK: Words

    /// "Artist · Album" while both fit, then the artist alone, then the artist cut short.
    static func subtitle(for content: SlideContent, font: NSFont, color: RGB, alpha: Double, width: CGFloat, showAlbum: Bool) -> CTLine? {
        let album = content.album.flatMap { $0.caseInsensitiveCompare(content.title) == .orderedSame ? nil : $0 }
        if showAlbum, let artist = content.artist, let album {
            let both = Typeface.line("\(artist) · \(album)", font, color, alpha: alpha)
            if Typeface.width(both) <= width { return both }
        }
        guard let text = content.artist ?? (showAlbum ? album : nil) else { return nil }
        return truncated(text, font: font, color: color, alpha: alpha, width: width)
    }

    /// Whole words where they fit ("Salt in the…"), letters only when even one word doesn't.
    static func truncated(_ text: String, font: NSFont, color: RGB, alpha: Double, width: CGFloat) -> CTLine {
        let full = Typeface.line(text, font, color, alpha: alpha)
        guard Typeface.width(full) > width else { return full }
        let words = text.split(separator: " ")
        for count in stride(from: words.count - 1, through: 1, by: -1) {
            let line = Typeface.line(words.prefix(count).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,·-–(&")) + "…", font, color, alpha: alpha)
            if Typeface.width(line) <= width, count > 1 || words[0].count > 3 { return line }
        }
        let ellipsis = Typeface.line("…", font, color, alpha: alpha)
        return CTLineCreateTruncatedLine(full, Double(width), .end, ellipsis) ?? full
    }

    /// Two lines centred as a block on their caps; one line centred alone.
    static func baselines(height: CGFloat, title: NSFont, artist: NSFont, gap: CGFloat, single: Bool) -> (title: CGFloat, artist: CGFloat) {
        guard !single else { return ((height / 2 - title.capHeight / 2).rounded(), 0) }
        let artistBaseline = (height / 2 - (title.capHeight + gap + artist.capHeight) / 2).rounded()
        return ((artistBaseline + artist.capHeight + gap).rounded(), artistBaseline)
    }

    static func textShadows(dark: Bool, glass: Bool, fontSize f: CGFloat) -> [Bitmap.Shadow] {
        if glass { return [Bitmap.Shadow(blur: f * 0.12, offset: CGSize(width: 0, height: -0.5), color: CGColor(gray: 0, alpha: 0.28))] }
        return dark
            ? [Bitmap.Shadow(blur: f * 0.16, offset: CGSize(width: 0, height: -0.5), color: CGColor(gray: 0, alpha: 0.55)), Bitmap.Shadow(blur: f * 0.8, color: CGColor(gray: 0, alpha: 0.3))]
            : [Bitmap.Shadow(blur: f * 0.3, color: CGColor(gray: 1, alpha: 0.7))]
    }

    /// A shade the shape of the words, blurred until it has no edge: dark under light text, pale under dark.
    static func veil(from x: CGFloat, width: CGFloat, metrics m: SlideMetrics, style: SlideStyle) -> (CGImage?, CGRect) {
        let margin: CGFloat = 26
        let size = CGSize(width: width + margin * 2, height: m.height)
        let dark = style.isDark
        // Its ends stay well inside the words, so its blur fades out before the window's edge.
        let core = CGRect(x: margin + 10, y: (m.height * 0.34).rounded(), width: max(1, width - 34), height: (m.height * 0.32).rounded())
        guard let canvas = Bitmap(size: size, scale: style.scale) else { return (nil, .zero) }
        canvas.fillCapsule(core, color: CGColor(gray: dark ? 0 : 1, alpha: dark ? 0.55 : 0.66))
        guard let sharp = canvas.image() else { return (nil, .zero) }
        let input = CIImage(cgImage: sharp)
        guard let blurred = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: input, kCIInputRadiusKey: m.height * 0.17 * style.scale])?.outputImage,
              let image = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]).createCGImage(blurred, from: input.extent)
        else { return (nil, .zero) }
        return (image, CGRect(x: x - margin, y: 0, width: size.width, height: size.height))
    }

    // MARK: Cover

    /// The cover, lifted off the wallpaper by a contact shadow and a soft one in its own colours.
    static func drawCover(_ content: SlideContent, in rect: CGRect, radius: CGFloat, style: SlideStyle, canvas: Bitmap) {
        let context = canvas.context
        let dark = style.isDark
        let shape = Shapes.continuous(rect, radius: radius)
        let px = 1 / style.scale
        let tone = content.palette?.average ?? RGB(hex: 0x2A2B30)
        let lab = tone.oklab
        let glow = Legibility.inGamut(l: min(lab.l, 0.5) * 0.7, chroma: lab.chroma * 1.2, hue: lab.hue)
        canvas.shadowed([
            Bitmap.Shadow(blur: 1.2, offset: CGSize(width: 0, height: -0.5), color: CGColor(gray: 0, alpha: dark ? 0.38 : 0.18)),
            Bitmap.Shadow(blur: rect.width * 0.16, offset: CGSize(width: 0, height: -rect.width * 0.06), color: glow.cgColor(alpha: dark ? 0.6 : 0.34)),
        ]) {
            context.addPath(shape)
            context.setFillColor(CGColor(gray: 0.12, alpha: 1))
            context.fillPath()
        }
        context.saveGState()
        context.addPath(shape)
        context.clip()
        if let image = content.cover {
            // Square covers fill the square; a video's frame is cropped to its middle.
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let scale = max(rect.width / w, rect.height / h)
            let drawn = CGRect(x: rect.midX - w * scale / 2, y: rect.midY - h * scale / 2, width: w * scale, height: h * scale)
            context.interpolationQuality = .high
            context.draw(image, in: drawn)
        } else {
            drawPlaceholder(content.kind, in: rect, canvas: canvas)
        }
        context.restoreGState()
        // A pixel-wide edge, so a black cover keeps its shape on a dark wallpaper.
        context.addPath(Shapes.continuous(rect.insetBy(dx: px / 2, dy: px / 2), radius: radius - px / 2))
        context.setStrokeColor(dark ? CGColor(gray: 1, alpha: 0.14) : CGColor(gray: 0, alpha: 0.12))
        context.setLineWidth(px)
        context.strokePath()
    }

    /// Until a picture arrives: graphite, lit from above, with a note (or a microphone, or a frame).
    static func drawPlaceholder(_ kind: SlideContent.Kind, in rect: CGRect, canvas: Bitmap) {
        let context = canvas.context
        let gradient = CGGradient(colorsSpace: nil, colors: [CGColor(srgbRed: 0.24, green: 0.245, blue: 0.27, alpha: 1), CGColor(srgbRed: 0.13, green: 0.135, blue: 0.15, alpha: 1)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
        let name = switch kind {
        case .music: "music.note"
        case .podcast: "mic.fill"
        case .video: "play.rectangle.fill"
        }
        guard let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 64, weight: .medium)) else { return }
        let aspect = glyph.size.width / max(glyph.size.height, 1)
        let box = rect.width * 0.4
        let size = aspect >= 1 ? CGSize(width: box, height: box / aspect) : CGSize(width: box * aspect, height: box)
        let frame = CGRect(x: canvas.snap(rect.midX - size.width / 2), y: canvas.snap(rect.midY - size.height / 2), width: size.width, height: size.height)
        tint(glyph, in: frame, color: CGColor(gray: 1, alpha: 0.82), context: context)
    }

    /// Draws a symbol from its outlines at this size, filled with one colour.
    static func tint(_ glyph: NSImage, in frame: CGRect, color: CGColor, context: CGContext) {
        context.saveGState()
        context.beginTransparencyLayer(in: frame.insetBy(dx: -1, dy: -1), auxiliaryInfo: nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        glyph.draw(in: frame)
        NSGraphicsContext.restoreGraphicsState()
        context.setBlendMode(.sourceIn)
        context.setFillColor(color)
        context.fill(frame.insetBy(dx: -1, dy: -1))
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// What the pointer sees over the cover: a shade, and the button it will press.
    static func hoverImage(side: CGFloat, radius: CGFloat, playing: Bool, scale: CGFloat) -> CGImage? {
        guard let canvas = Bitmap(size: CGSize(width: side, height: side), scale: scale) else { return nil }
        let context = canvas.context
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        context.addPath(Shapes.continuous(rect, radius: radius))
        context.setFillColor(CGColor(gray: 0, alpha: 0.38))
        context.fillPath()
        guard let glyph = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 64, weight: .bold)) else { return canvas.image() }
        let aspect = glyph.size.width / max(glyph.size.height, 1)
        let box = (side * 0.36).rounded()
        let size = aspect >= 1 ? CGSize(width: box, height: box / aspect) : CGSize(width: box * aspect, height: box)
        // The play triangle's weight sits left of its box; nudge it to look centred.
        let nudge: CGFloat = playing ? 0 : side * 0.025
        let frame = CGRect(x: canvas.snap(rect.midX - size.width / 2 + nudge), y: canvas.snap(rect.midY - size.height / 2), width: size.width, height: size.height)
        context.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 2, color: CGColor(gray: 0, alpha: 0.4))
        tint(glyph, in: frame, color: CGColor(gray: 1, alpha: 0.96), context: context)
        return canvas.image()
    }

    // MARK: Clock

    /// The clock is a clock face, as on Tape: a fine ring and, inside it, a wedge that sweeps round
    /// from twelve o'clock as the track plays.
    static func ringPath(in rect: CGRect, line: CGFloat) -> CGPath {
        CGPath(ellipseIn: rect.insetBy(dx: line / 2, dy: line / 2), transform: nil)
    }

    /// The wedge, drawn as a circle stroked as wide as it is round, so `strokeEnd` sweeps it.
    static func wedgeCircle(in rect: CGRect, line: CGFloat) -> (path: CGPath, width: CGFloat) {
        let radius = rect.width / 2 - line - 1
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius / 2, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        return (path, radius)
    }

    static func ringColors(dark: Bool) -> (track: CGColor, fill: CGColor) {
        (CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.55 : 0.4), CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.85 : 0.62))
    }

    /// The slide as the desktop shows it at rest, for stills: the columns, and the clock at `progress`.
    static func draw(_ slide: Slide, layout: SlideMetrics.Layout, metrics: SlideMetrics, progress: CGFloat?, dimmed: Bool = false, in context: CGContext) {
        if let veil = slide.veil {
            context.draw(veil, in: slide.veilFrame.offsetBy(dx: layout.grid.minX, dy: layout.grid.minY))
        }
        for part in slide.parts {
            context.saveGState()
            if dimmed, part.column == .identity { context.setAlpha(pausedAlpha) }
            context.draw(part.image, in: part.frame.offsetBy(dx: layout.grid.minX, dy: layout.grid.minY))
            context.restoreGState()
        }
        guard let progress, slide.clock else { return }
        let colors = ringColors(dark: slide.isDark)
        context.saveGState()
        if dimmed { context.setAlpha(pausedAlpha) }
        if slide.isDark, !metrics.glass { context.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 2, color: CGColor(gray: 0, alpha: 0.45)) }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setLineWidth(metrics.ringLine * 0.75)
        context.addPath(ringPath(in: layout.ring, line: metrics.ringLine * 0.75))
        context.setStrokeColor(colors.track)
        context.strokePath()
        let wedge = wedgeCircle(in: layout.ring, line: metrics.ringLine * 0.75)
        context.addPath(wedge.path.copy(dashingWithPhase: 0, lengths: [CGFloat.pi * wedge.width * progress, 1000]))
        context.setLineWidth(wedge.width)
        context.setStrokeColor(colors.fill)
        context.strokePath()
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// The words and the clock while the music is paused: still there, a step back.
    static let pausedAlpha: CGFloat = 0.5
}
