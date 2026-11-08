import SwiftUI

/// What opens above the corner when the words are clicked: the cover as large as it deserves, the
/// track in full, where it is, and the three buttons that matter.
struct CoverCard: View {
    let model: AppModel
    var onClose: () -> Void = {}
    @Environment(\.colorScheme) private var scheme

    private var player: Player { model.player }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let track = player.track {
                artwork(track)
                words(track)
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    Scrubber(track: track, now: context.date, tint: tint) { player.seek(to: $0) }
                }
                controls(track)
                footer
            } else {
                Text("Nothing is playing").font(.headline)
                Text("Start something in Music, Spotify, Podcasts or a browser.").foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 284, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .padding(10)
    }

    private var tint: Color {
        guard let accent = player.cover?.palette?.accent else { return .primary }
        return Color(nsColor: Legibility.adjust(accent, for: scheme == .dark ? .dark : .light).nsColor())
    }

    private func artwork(_ track: NowPlaying) -> some View {
        let shade = player.cover?.palette?.average ?? RGB(hex: 0x202024)
        return ZStack {
            if let cover = player.cover {
                Image(decorative: cover.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(white: 0.25), Color(white: 0.13)], startPoint: .top, endPoint: .bottom)
                Image(systemName: track.isVideo ? "play.rectangle.fill" : track.isPodcast ? "mic.fill" : "music.note")
                    .font(.system(size: 64, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(width: 252, height: 252)
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: Color(nsColor: shade.nsColor()).opacity(0.55), radius: 14, y: 6)
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .onTapGesture { player.toggle() }
        .help(track.isPlaying ? "Pause" : "Play")
    }

    private func words(_ track: NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Titles.title(track.title))
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
            Text([track.artist, track.album.map(Titles.album)].compactMap(\.self).joined(separator: " — "))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .textSelection(.enabled)
    }

    private func controls(_ track: NowPlaying) -> some View {
        HStack(spacing: 30) {
            Spacer(minLength: 0)
            CardButton(symbol: "backward.fill", size: 17, help: "Previous") { player.previous() }
            CardButton(symbol: track.isPlaying ? "pause.fill" : "play.fill", size: 25, help: track.isPlaying ? "Pause" : "Play") { player.toggle() }
            CardButton(symbol: "forward.fill", size: 17, help: "Next") { player.next() }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let icon = player.appIcon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            }
            Text(player.appName.map { "Playing in \($0)" } ?? "Now Playing")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let name = player.appName, player.appURL != nil {
                Button {
                    player.openApp()
                    onClose()
                } label: {
                    HStack(spacing: 3) {
                        Text("Open \(name)")
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
    }
}

/// A transport button: just the symbol, a touch brighter under the pointer.
private struct CardButton: View {
    let symbol: String
    let size: CGFloat
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 34)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(hovering ? 1 : 0.86)
        .scaleEffect(hovering ? 1.06 : 1)
        .animation(.smooth(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Where the track is: a line to drag along, the time gone and the time left.
private struct Scrubber: View {
    let track: NowPlaying
    let now: Date
    let tint: Color
    let seek: (Double) -> Void
    @State private var dragging: Double?
    @State private var hovering = false

    var body: some View {
        let duration = track.duration ?? 0
        let position = dragging ?? track.position(at: now)
        let fraction = duration > 0 ? min(max(position / duration, 0), 1) : 0
        VStack(spacing: 5) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let thick: CGFloat = hovering || dragging != nil ? 6 : 4
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.16))
                    Capsule().fill(tint.opacity(0.95)).frame(width: max(thick, width * fraction))
                }
                .frame(height: thick)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        dragging = min(max(value.location.x / width, 0), 1) * duration
                    }
                    .onEnded { _ in
                        if let dragging { seek(dragging) }
                        dragging = nil
                    })
                .animation(.smooth(duration: 0.15), value: thick)
            }
            .frame(height: 12)
            .onHover { hovering = $0 }
            .disabled(duration <= 0 || track.isLive)
            HStack {
                Text(Self.time(position))
                Spacer()
                Text(track.isLive || duration <= 0 ? "Live" : "−" + Self.time(max(0, duration - position)))
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}
