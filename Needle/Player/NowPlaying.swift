import Foundation

/// What's playing on the Mac, as the system's Now Playing service (Control Center's) knows it.
nonisolated struct NowPlaying: Equatable, Sendable {
    var title: String
    var artist: String?
    var album: String?
    /// Seconds; nil for a live stream or when the player doesn't say.
    var duration: Double?
    /// Where playback was at `timestamp`, in seconds.
    var elapsed: Double = 0
    var timestamp: Date = .now
    var rate: Double = 0
    var isPlaying = false
    var artworkID: String?
    var hasArtwork = false
    var bundleID: String?
    var parentBundleID: String?
    var pid: Int32?
    var isLive = false
    var mediaType: String?
    var contentID: String?
    var uniqueID: Int64?

    /// How fast the position moves: the player's rate while it plays, standing still otherwise.
    var effectiveRate: Double { isPlaying ? (rate > 0 ? rate : 1) : 0 }

    /// Where playback is at `date`, kept inside the track.
    func position(at date: Date = .now) -> Double {
        let moved = elapsed + max(0, date.timeIntervalSince(timestamp)) * effectiveRate
        guard let duration, duration > 0 else { return max(0, moved) }
        return min(max(0, moved), duration)
    }

    /// How far through the track, 0…1, or nil when it has no length.
    func progress(at date: Date = .now) -> Double? {
        guard let duration, duration > 0, !isLive else { return nil }
        return position(at: date) / duration
    }

    /// The same track, whatever its position: a new one gets a new slide.
    var trackKey: String {
        if let uniqueID { return "u\(uniqueID)" }
        if let contentID { return "c\(contentID)" }
        return [title, artist ?? "", album ?? ""].joined(separator: "|")
    }

    /// The same picture: tracks from one album keep their cover still.
    var coverKey: String {
        artworkID ?? [artist ?? "", album ?? "", hasArtwork ? "art" : "none"].joined(separator: "|")
    }

    var isVideo: Bool { mediaType?.localizedCaseInsensitiveContains("video") ?? false }
    var isPodcast: Bool { mediaType?.localizedCaseInsensitiveContains("podcast") ?? false }

    /// The app to bring forward: the browser for a web player, not its media helper.
    var appBundleID: String? { parentBundleID ?? bundleID }

    /// The same track a moment later, moved to `position` (a seek, or a pause where it stood).
    func moved(to position: Double, playing: Bool? = nil, at date: Date = .now) -> NowPlaying {
        var copy = self
        copy.elapsed = position
        copy.timestamp = date
        if let playing {
            copy.isPlaying = playing
            copy.rate = playing ? max(rate, 1) : 0
        }
        return copy
    }
}

/// One line from the bridge.
nonisolated enum BridgeMessage: Equatable, Sendable {
    case info(NowPlaying, artwork: Data?)
    case none
    case error(String)

    static func decode(_ line: Data) -> BridgeMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = object["type"] as? String else { return nil }
        switch type {
        case "none": return BridgeMessage.none
        case "error": return .error(object["reason"] as? String ?? "Unknown")
        case "info":
            guard let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return BridgeMessage.none }
            func text(_ key: String) -> String? {
                guard let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
                return value
            }
            func number(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
            var track = NowPlaying(title: title)
            track.artist = text("artist")
            track.album = text("album")
            if let duration = number("duration"), duration.isFinite, duration > 0 { track.duration = duration }
            track.elapsed = max(0, number("elapsed") ?? 0)
            track.timestamp = number("timestamp").map { Date(timeIntervalSince1970: $0) } ?? .now
            track.rate = number("rate") ?? 0
            track.isPlaying = (object["playing"] as? NSNumber)?.boolValue ?? (track.rate > 0)
            track.artworkID = text("artworkID")
            track.hasArtwork = (object["hasArtwork"] as? NSNumber)?.boolValue ?? false
            track.bundleID = text("bundle")
            track.parentBundleID = text("parentBundle")
            track.pid = (object["pid"] as? NSNumber).map { Int32(truncating: $0) }
            track.isLive = (object["live"] as? NSNumber)?.boolValue ?? false
            track.mediaType = text("mediaType")
            track.contentID = text("contentID")
            track.uniqueID = (object["uniqueID"] as? NSNumber)?.int64Value
            let artwork = (object["artwork"] as? String).flatMap { Data(base64Encoded: $0) }
            return .info(track, artwork: artwork)
        default:
            return nil
        }
    }
}

/// Titles as a person would say them: without "– Remastered 2011" or "(Deluxe Edition)".
nonisolated enum Titles {
    private static let noise = [
        "remaster", "remastered", "deluxe", "expanded", "anniversary", "edition", "bonus track", "mono", "stereo",
        "single version", "album version", "radio edit", "explicit", "clean", "digital", "version",
    ]

    static func title(_ text: String) -> String { strip(text, keepFeatured: true) }

    static func album(_ text: String) -> String {
        var name = strip(text, keepFeatured: true)
        for suffix in [" - Single", " - EP", " – Single", " – EP"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Drops trailing "(…)", "[…]" and " - …" parts that only say which pressing it is.
    private static func strip(_ text: String, keepFeatured: Bool) -> String {
        var name = text.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            // "Song (Remastered 2011)", "Song [Deluxe Edition]"
            for (open, close) in [("(", ")"), ("[", "]")] where name.hasSuffix(close) {
                guard let start = name.range(of: " " + open, options: .backwards), start.lowerBound > name.startIndex else { continue }
                let inside = name[start.upperBound..<name.index(before: name.endIndex)].lowercased()
                if isNoise(inside) {
                    name = String(name[..<start.lowerBound]).trimmingCharacters(in: .whitespaces)
                    changed = true
                }
            }
            // "Song - Remastered 2011", "Song - 2011 Remaster", "Song – Radio Edit"
            for dash in [" - ", " – ", " — "] {
                guard let start = name.range(of: dash, options: .backwards), start.lowerBound > name.startIndex else { continue }
                let tail = name[start.upperBound...].lowercased()
                if isNoise(tail) {
                    name = String(name[..<start.lowerBound]).trimmingCharacters(in: .whitespaces)
                    changed = true
                }
            }
        }
        return name.isEmpty ? text : name
    }

    /// "25th", "3rd".
    private static func isOrdinal(_ word: String) -> Bool {
        let digits = word.prefix(while: \.isNumber)
        return !digits.isEmpty && ["st", "nd", "rd", "th"].contains(word.dropFirst(digits.count))
    }

    private static func isNoise(_ part: String) -> Bool {
        let words = part.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty, words.count <= 6 else { return false }
        // Every word is a year, a number or edition talk ("2011 Remaster", "Deluxe Edition", "Live").
        let text = words.joined(separator: " ")
        let fillers: Set = ["the", "of", "and", "year", "super", "special", "version", "radio", "edit", "single", "album", "original"]
        return words.allSatisfy { word in
            word.allSatisfy(\.isNumber) || noise.contains(word) || fillers.contains(word) || isOrdinal(word)
        } && noise.contains(where: { text.contains($0) })
    }
}
