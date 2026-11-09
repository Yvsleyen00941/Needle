import Foundation
import Observation

/// Which side of the Dock the slide sits on.
nonisolated enum DockSide: String, CaseIterable, Codable, Sendable {
    case left, right
}

/// Whether the text is drawn for a dark or a light wallpaper.
nonisolated enum Contrast: String, CaseIterable, Codable, Sendable {
    case automatic, lightText, darkText
}

/// What happens to the corner when the music stops.
nonisolated enum PausedBehaviour: Int, CaseIterable, Codable, Sendable {
    case keep = -1
    case rightAway = 3
    case afterAMinute = 60
    case afterFiveMinutes = 300

    var seconds: TimeInterval? { self == .keep ? nil : TimeInterval(rawValue) }

    var title: String {
        switch self {
        case .keep: "Keep showing it"
        case .rightAway: "Clear the corner right away"
        case .afterAMinute: "Clear the corner after a minute"
        case .afterFiveMinutes: "Clear the corner after five minutes"
        }
    }
}

/// Everything the person can change, kept in UserDefaults.
@Observable
final class Settings {
    static let shared = Settings()

    @ObservationIgnored private let defaults: UserDefaults

    var side: DockSide { didSet { defaults.set(side.rawValue, forKey: Key.side) } }
    /// Points between the slide's window and the Dock's glass.
    var dockGap: Double { didSet { defaults.set(dockGap, forKey: Key.dockGap) } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: Key.fontSize) } }
    var contrast: Contrast { didSet { defaults.set(contrast.rawValue, forKey: Key.contrast) } }
    /// The title in its cover's colour.
    var coverColors: Bool { didSet { defaults.set(coverColors, forKey: Key.coverColors) } }
    var showAlbum: Bool { didSet { defaults.set(showAlbum, forKey: Key.showAlbum) } }
    /// On a pane of glass, rather than straight on the wallpaper.
    var glass: Bool { didSet { defaults.set(glass, forKey: Key.glass) } }
    var whenPaused: PausedBehaviour { didSet { defaults.set(whenPaused.rawValue, forKey: Key.whenPaused) } }
    /// Two fingers or the wheel over the slide skip tracks.
    var scrollToSkip: Bool { didSet { defaults.set(scrollToSkip, forKey: Key.scrollToSkip) } }
    var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) } }
    var hasLaunchedBefore: Bool { didSet { defaults.set(hasLaunchedBefore, forKey: Key.hasLaunchedBefore) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Right of the Dock: Tape takes the left, so the two share the Dock between them.
        side = defaults.string(forKey: Key.side).flatMap(DockSide.init(rawValue:)) ?? .right
        dockGap = defaults.object(forKey: Key.dockGap) as? Double ?? 22
        fontSize = defaults.object(forKey: Key.fontSize) as? Double ?? 14
        contrast = defaults.string(forKey: Key.contrast).flatMap(Contrast.init(rawValue:)) ?? .automatic
        coverColors = defaults.object(forKey: Key.coverColors) as? Bool ?? true
        showAlbum = defaults.object(forKey: Key.showAlbum) as? Bool ?? true
        glass = defaults.object(forKey: Key.glass) as? Bool ?? false
        whenPaused = (defaults.object(forKey: Key.whenPaused) as? Int).flatMap(PausedBehaviour.init(rawValue:)) ?? .afterFiveMinutes
        scrollToSkip = defaults.object(forKey: Key.scrollToSkip) as? Bool ?? true
        showMenuBarIcon = defaults.object(forKey: Key.showMenuBarIcon) as? Bool ?? true
        hasLaunchedBefore = defaults.bool(forKey: Key.hasLaunchedBefore)
    }

    func resetAppearance() {
        fontSize = 14
        contrast = .automatic
        coverColors = true
        showAlbum = true
        glass = false
    }

    private enum Key {
        static let side = "side"
        static let dockGap = "dockGap"
        static let fontSize = "fontSize"
        static let contrast = "contrast"
        static let coverColors = "coverColors"
        static let showAlbum = "showAlbum"
        static let glass = "glass"
        static let whenPaused = "whenPaused"
        static let scrollToSkip = "scrollToSkip"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let hasLaunchedBefore = "hasLaunchedBefore"
    }
}
