import AppKit
import ImageIO
import Observation

/// A cover, decoded once, with the colours the slide draws it with.
nonisolated struct Cover: @unchecked Sendable {
    var key: String
    var image: CGImage
    var palette: CoverPalette?
}

/// What's playing and the remote control for it, fed by the bridge (or by the demo records).
@Observable
final class Player {
    private(set) var track: NowPlaying?
    /// The cover of the track, once its picture has arrived.
    private(set) var cover: Cover?
    /// Why nothing can be shown, when the bridge can't run.
    private(set) var problem: String?
    /// Which way the last skip went, when Needle made it, so the slide rolls the same way.
    @ObservationIgnored private(set) var lastSkip: (forward: Bool, at: Date)?

    let isDemo: Bool

    @ObservationIgnored private let bridge = Bridge()
    @ObservationIgnored private var covers: [String: Cover] = [:]
    @ObservationIgnored private var coverOrder: [String] = []
    @ObservationIgnored private var demoIndex = 0
    @ObservationIgnored private var demoTimer: Timer?

    init(demo: Bool = UserDefaults.standard.bool(forKey: "NeedleDemo")) {
        isDemo = demo
    }

    func start() {
        if isDemo {
            startDemo()
            return
        }
        bridge.onMessage = { [weak self] message in self?.receive(message) }
        bridge.onFailure = { [weak self] reason in self?.problem = reason }
        bridge.start()
    }

    // MARK: Commands

    func toggle() {
        guard let track else { return }
        let position = track.position()
        self.track = track.moved(to: position, playing: !track.isPlaying)
        if !isDemo { bridge.send("toggle") }
    }

    func next() {
        lastSkip = (true, .now)
        if isDemo { showDemo(demoIndex + 1) } else { bridge.send("next") }
    }

    func previous() {
        lastSkip = (false, .now)
        // Like the system's own button: back to the start first, then to the track before.
        if isDemo {
            if let track, track.position() > 3 { self.track = track.moved(to: 0) } else { showDemo(demoIndex - 1) }
        } else {
            bridge.send("previous")
        }
    }

    func seek(to seconds: Double) {
        guard let track else { return }
        self.track = track.moved(to: seconds)
        if !isDemo { bridge.send("seek \(String(format: "%.2f", seconds))") }
    }

    // MARK: The app that plays

    var appURL: URL? {
        guard let id = track?.appBundleID else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    var appName: String? {
        if let url = appURL { return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "") }
        if let pid = track?.pid { return NSRunningApplication(processIdentifier: pid)?.localizedName }
        return nil
    }

    var appIcon: NSImage? {
        appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    func openApp() {
        guard let url = appURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Bridge

    private func receive(_ message: BridgeMessage) {
        switch message {
        case .info(let fresh, let artwork):
            problem = nil
            if let artwork, let key = fresh.artworkID { store(artwork, key: key) }
            if fresh != track { track = fresh }
            let matching = fresh.artworkID.flatMap { covers[$0] }
            if matching?.key != cover?.key { cover = matching }
        case .none:
            problem = nil
            track = nil
            cover = nil
        case .error(let reason):
            problem = reason
        }
    }

    private func store(_ data: Data, key: String) {
        guard covers[key] == nil, let image = Self.decode(data) else { return }
        covers[key] = Cover(key: key, image: image, palette: CoverPalette.of(image))
        coverOrder.append(key)
        // A few albums back is plenty: skipping back and forth stays instant.
        while coverOrder.count > 12 { covers[coverOrder.removeFirst()] = nil }
    }

    nonisolated static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: Demo

    private func startDemo() {
        showDemo(0, position: 72)
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let track = self.track, let duration = track.duration else { return }
                if track.isPlaying, track.position() >= duration - 0.05 { self.showDemo(self.demoIndex + 1) }
            }
        }
    }

    private func showDemo(_ index: Int, position: Double = 0) {
        let count = Demo.records.count
        demoIndex = (index % count + count) % count
        let playing = track?.isPlaying ?? true
        let fresh = Demo.track(demoIndex, position: position, playing: playing)
        let record = Demo.records[demoIndex]
        if let key = fresh.artworkID, covers[key] == nil, let image = Demo.cover(record.cover) {
            covers[key] = Cover(key: key, image: image, palette: CoverPalette.of(image))
        }
        track = fresh
        cover = fresh.artworkID.flatMap { covers[$0] }
    }
}
