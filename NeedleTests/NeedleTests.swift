import AppKit
import Foundation
import Testing
@testable import Needle

// MARK: Bridge

@Suite struct BridgeDecoding {
    /// One line as the bridge writes it for a paused track in Music, with a 2×2 PNG for a cover.
    static let line = #"""
    {"album":"Low Tide (Deluxe Edition)","artist":"Marina Vale","artwork":"iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGM4YeMGRAwQCgAmLgUp3nfO3wAAAABJRU5ErkJggg==","artworkID":"art-1","artworkMIME":"image/png","bundle":"com.apple.Music","contentID":"42345::42363","duration":221.5,"elapsed":72.25,"hasArtwork":1,"live":0,"mediaType":"MRMediaRemoteMediaTypeMusic","pid":3622,"playing":0,"rate":0,"timestamp":1794130855.5,"title":"Undertow - 2011 Remaster","type":"info","uniqueID":-7371827763143463216}
    """#

    @Test func readsATrack() throws {
        let message = try #require(BridgeMessage.decode(Data(Self.line.utf8)))
        guard case .info(let track, let artwork) = message else {
            Issue.record("Expected a track, got \(message)")
            return
        }
        #expect(track.title == "Undertow - 2011 Remaster")
        #expect(track.artist == "Marina Vale")
        #expect(track.album == "Low Tide (Deluxe Edition)")
        #expect(track.duration == 221.5)
        #expect(track.elapsed == 72.25)
        #expect(!track.isPlaying)
        #expect(track.bundleID == "com.apple.Music")
        #expect(track.pid == 3622)
        #expect(track.artworkID == "art-1")
        #expect(track.hasArtwork)
        #expect(track.timestamp == Date(timeIntervalSince1970: 1794130855.5))
        #expect(track.trackKey == "u-7371827763143463216")
        let data = try #require(artwork)
        #expect(Player.decode(data)?.width == 2)
    }

    @Test func readsNothingAndErrors() {
        #expect(BridgeMessage.decode(Data(#"{"type":"none"}"#.utf8)) == BridgeMessage.none)
        #expect(BridgeMessage.decode(Data(#"{"type":"error","reason":"MediaRemote has changed"}"#.utf8)) == .error("MediaRemote has changed"))
        // A track without a title is nothing a person could read.
        #expect(BridgeMessage.decode(Data(#"{"type":"info","title":"  "}"#.utf8)) == BridgeMessage.none)
        #expect(BridgeMessage.decode(Data("not json".utf8)) == nil)
    }

    @Test func theBridgeScriptLoadsTheLibrary() {
        #expect(Bridge.script.contains("needle_bridge_run"))
        #expect(Bridge.script.contains("$ARGV[0]"))
    }
}

// MARK: Position

@Suite struct Position {
    let start = Date(timeIntervalSince1970: 1_000_000)

    func track(playing: Bool, rate: Double = 1, elapsed: Double = 30, duration: Double? = 200) -> NowPlaying {
        var track = NowPlaying(title: "Undertow")
        track.isPlaying = playing
        track.rate = playing ? rate : 0
        track.elapsed = elapsed
        track.timestamp = start
        track.duration = duration
        return track
    }

    @Test func movesWhilePlaying() {
        #expect(track(playing: true).position(at: start.addingTimeInterval(10)) == 40)
        #expect(track(playing: true, rate: 2).position(at: start.addingTimeInterval(10)) == 50)
        // Some players report a rate of zero while they play.
        #expect(track(playing: true, rate: 0).position(at: start.addingTimeInterval(10)) == 40)
    }

    @Test func standsStillWhilePaused() {
        #expect(track(playing: false).position(at: start.addingTimeInterval(500)) == 30)
    }

    @Test func staysInsideTheTrack() {
        #expect(track(playing: true).position(at: start.addingTimeInterval(1000)) == 200)
        #expect(track(playing: true).progress(at: start.addingTimeInterval(70)) == 0.5)
        #expect(track(playing: true, duration: nil).progress(at: start) == nil)
    }

    @Test func pausingKeepsThePlace() {
        let paused = track(playing: true).moved(to: 42, playing: false, at: start)
        #expect(!paused.isPlaying)
        #expect(paused.position(at: start.addingTimeInterval(60)) == 42)
    }

    @Test func tracksFromOneAlbumShareACover() {
        var first = track(playing: true)
        first.artworkID = "album"
        first.contentID = "1"
        var second = first
        second.title = "Salt in the Air"
        second.contentID = "2"
        #expect(first.coverKey == second.coverKey)
        #expect(first.trackKey != second.trackKey)
    }
}

// MARK: Titles

@Suite struct TitleCleanUp {
    @Test(arguments: [
        ("Undertow - 2011 Remaster", "Undertow"),
        ("Undertow - Remastered 2011", "Undertow"),
        ("Undertow (Remastered)", "Undertow"),
        ("Undertow [Deluxe Edition]", "Undertow"),
        ("Undertow - Radio Edit", "Undertow"),
        ("Undertow (feat. Ada Sun)", "Undertow (feat. Ada Sun)"),
        ("Undertow - Live at Vorst", "Undertow - Live at Vorst"),
        ("Re-Make/Re-Model", "Re-Make/Re-Model"),
        ("(What's the Story) Morning Glory?", "(What's the Story) Morning Glory?"),
    ])
    func titles(_ raw: String, _ clean: String) {
        #expect(Titles.title(raw) == clean)
    }

    @Test func albums() {
        #expect(Titles.album("Low Tide (Deluxe Edition)") == "Low Tide")
        #expect(Titles.album("Low Tide (25th Anniversary Edition)") == "Low Tide")
        #expect(Titles.album("Undertow - Single") == "Undertow")
        #expect(Titles.album("Nothing Was The Same (Deluxe)") == "Nothing Was The Same")
    }
}

// MARK: Layout

@Suite struct Layout {
    let metrics = SlideMetrics(fontSize: 14)

    @Test(arguments: [56.0, 74, 96, 129, 160, 240, 368, 900])
    func everyStripFits(_ strip: Double) {
        let grid = SlideGrid.fitting(strip, metrics: metrics)
        #expect(grid.width <= metrics.gridRoom(in: strip, clock: grid.clock, tile: grid.cover) + 0.5)
        #expect(grid.cover >= 24)
    }

    @Test func wideStripsShowEverything() {
        let grid = SlideGrid.fitting(368, metrics: metrics)
        #expect(!grid.compact)
        #expect(grid.clock)
        #expect(grid.identity == 154)
        // The words stop growing once there's only air to gain.
        #expect(SlideGrid.fitting(900, metrics: metrics) == grid)
    }

    @Test func aLaptopWithALongDockKeepsTheCover() {
        // About what a 1512-point screen leaves beside seventeen icons.
        let grid = SlideGrid.fitting(74, metrics: metrics)
        #expect(grid.identity == 0)
        #expect(grid.cover == metrics.cover)
        #expect(grid.clock)
        #expect(SlideGrid.fitting(56, metrics: metrics).clock == false)
    }

    @Test func theCoverStaysPutFromTrackToTrack() {
        let style = SlideStyle(scale: 2)
        let a = SlideRenderer.slide(for: SlideContent(title: "Undertow", artist: "Marina Vale", coverKey: "a", trackKey: "1"), style: style, room: 240)
        let b = SlideRenderer.slide(for: SlideContent(title: "A much, much longer title than the first one", artist: "Somebody Else", coverKey: "a", trackKey: "2"), style: style, room: 240)
        #expect(a.size == b.size)
        #expect(a.coverRect == b.coverRect)
        #expect(a.part(.cover)?.key == b.part(.cover)?.key)
        #expect(a.part(.identity)?.key != b.part(.identity)?.key)
    }

    @Test func centredInTheCorner() {
        let bounds = CGRect(x: 0, y: 0, width: 368, height: 56)
        let placed = metrics.layout(in: bounds, gridWidth: 200, trailing: true, centre: 184)
        #expect(abs(placed.platter.midX - 184) <= 1)
    }
}

// MARK: Words

@Suite struct Words {
    let font = SlideMetrics(fontSize: 14).artistFont
    let ink = RGB(hex: 0xFFFFFF)

    @Test func theAlbumGivesWayFirst() {
        let content = SlideContent(title: "Undertow", artist: "Marina Vale", album: "Low Tide", coverKey: "a", trackKey: "1")
        let both = SlideRenderer.subtitle(for: content, font: font, color: ink, alpha: 1, width: 400, showAlbum: true)
        let narrow = SlideRenderer.subtitle(for: content, font: font, color: ink, alpha: 1, width: 80, showAlbum: true)
        let off = SlideRenderer.subtitle(for: content, font: font, color: ink, alpha: 1, width: 400, showAlbum: false)
        #expect(both.map(Typeface.width) ?? 0 > off.map(Typeface.width) ?? 0)
        #expect(narrow.map(Typeface.width) ?? 0 <= 80)
        #expect(off.map(Typeface.width) == Typeface.width(Typeface.line("Marina Vale", font, ink)))
    }

    @Test func anAlbumNamedLikeTheTrackIsntRepeated() {
        let content = SlideContent(title: "Paper Moons", artist: "The Quiet Hours", album: "Paper Moons", coverKey: "a", trackKey: "1")
        let line = SlideRenderer.subtitle(for: content, font: font, color: ink, alpha: 1, width: 400, showAlbum: true)
        #expect(line.map(Typeface.width) == Typeface.width(Typeface.line("The Quiet Hours", font, ink)))
    }

    @Test func longTitlesBreakOnWords() {
        let line = SlideRenderer.truncated("Salt in the Air Tonight", font: font, color: ink, alpha: 1, width: 70)
        #expect(Typeface.width(line) <= 70)
    }
}

// MARK: Colour

@Suite struct Colour {
    func image(_ draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: 48, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
        return context.makeImage()!
    }

    @Test func aColourfulCoverGivesItsHue() throws {
        let cover = image { c in
            c.setFillColor(CGColor(gray: 0.05, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
            c.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.25, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: 48, height: 16))
        }
        let palette = try #require(CoverPalette.of(cover))
        let accent = try #require(palette.accent)
        #expect(accent.r > accent.g && accent.r > accent.b)
    }

    @Test func aBlackAndWhiteCoverHasNone() throws {
        let cover = image { c in
            c.setFillColor(CGColor(gray: 0.9, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
            c.setFillColor(CGColor(gray: 0.1, alpha: 1))
            c.fillEllipse(in: CGRect(x: 8, y: 8, width: 32, height: 32))
        }
        #expect(try #require(CoverPalette.of(cover)).accent == nil)
    }

    @Test func theDemoCoversAreDrawn() {
        for index in 0..<5 {
            #expect(Demo.cover(index, side: 64)?.width == 64)
        }
    }
}

// MARK: Placement

@Suite struct Placement {
    func layout(tilesMinX: CGFloat = 600, width: CGFloat = 700) -> DockLayout {
        DockLayout(edge: .bottom, autohides: false, screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                   visibleFrame: CGRect(x: 0, y: 95, width: 1920, height: 960), tiles: CGRect(x: tilesMinX, y: 5, width: width, height: 85),
                   tileSize: 67, isExact: true)
    }

    @Test func betweenTheEdgeAndTheDock() throws {
        let frame = try #require(CornerController.frame(for: layout(), side: .left, gap: 22, height: 56))
        #expect(frame.minX == 14)
        #expect(frame.maxX == 578)
        #expect(abs(frame.midY - 47.5) <= 0.5)
        let right = try #require(CornerController.frame(for: layout(), side: .right, gap: 22, height: 56))
        #expect(right.minX == 1322)
        #expect(right.maxX == 1906)
    }

    @Test func aDockThatLeavesNoRoomHidesTheCorner() {
        #expect(CornerController.frame(for: layout(tilesMinX: 60), side: .left, gap: 22, height: 56) == nil)
    }

    @Test func theCornersMiddle() {
        #expect(CornerController.corner(for: layout(), side: .left) == 300)
        #expect(CornerController.corner(for: layout(), side: .right) == 1610)
    }
}
