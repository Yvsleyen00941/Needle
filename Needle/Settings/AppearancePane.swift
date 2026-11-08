import SwiftUI

struct AppearancePane: View {
    @Bindable var settings: Settings
    let model: AppModel

    init(model: AppModel) {
        self.model = model
        settings = model.settings
    }

    var body: some View {
        Form {
            Section {
                CornerPreview(model: model)
                    .listRowInsets(EdgeInsets())
            }
            Section("Look") {
                Picker("Background", selection: $settings.glass) {
                    Text("Clear").tag(false)
                    Text("Glass").tag(true)
                }
                .pickerStyle(.segmented)
                LabeledContent("Size") {
                    HStack(spacing: 8) {
                        Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                        Slider(value: $settings.fontSize, in: 11...20, step: 0.5)
                        Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                    }
                }
                if !settings.glass {
                    Picker("Contrast", selection: $settings.contrast) {
                        Text("Follow the wallpaper").tag(Contrast.automatic)
                        Text("Light text").tag(Contrast.lightText)
                        Text("Dark text").tag(Contrast.darkText)
                    }
                }
            }
            Section("Words") {
                Toggle("Colour titles like their covers", isOn: $settings.coverColors)
                Toggle("Show the album when there's room", isOn: $settings.showAlbum)
            }
            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { settings.resetAppearance() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The corner as it looks right now, on the piece of wallpaper it sits on. With nothing playing,
/// one of the demo records stands in.
struct CornerPreview: View {
    let model: AppModel
    @State private var backdrop: NSImage?

    private static let demoCover: Cover? = Demo.cover(0).map { Cover(key: "demo-0", image: $0, palette: CoverPalette.of($0)) }

    var body: some View {
        let style = model.slideStyle(scale: NSScreen.main?.backingScaleFactor ?? 2)
        let room = min(model.corner?.stripFrame?.width ?? 360, 480)
        let track = model.player.track ?? Demo.track(0, position: 72)
        let content = model.player.track == nil ? SlideContent(track, cover: Self.demoCover) : SlideContent(track, cover: model.player.cover)
        let slide = SlideRenderer.slide(for: content, style: style, room: room)
        let height = max(84, style.metrics.height + 28)
        StageView(slide: slide, style: style, track: track, trailing: model.settings.side == .left)
            .frame(width: room)
            .frame(height: style.metrics.height)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background {
                if let backdrop {
                    Image(nsImage: backdrop)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(colors: [Color(white: 0.28), Color(white: 0.16)], startPoint: .top, endPoint: .bottom)
                }
            }
            .clipped()
            .task(id: model.corner?.stripFrame?.integral.debugDescription) { await loadBackdrop() }
    }

    private func loadBackdrop() async {
        guard let frame = model.corner?.stripFrame,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }),
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        // A slice as wide as the pane, centred on the corner.
        let width: CGFloat = 520
        let height: CGFloat = 100
        var region = CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
        region = region.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        region.origin.x = min(max(region.minX, 0), screen.frame.width - width)
        region.origin.y = max(region.minY, 0)
        let size = screen.frame.size
        let scaling = Wallpaper.scaling(for: screen)
        let scale = screen.backingScaleFactor
        let image = await Task.detached(priority: .userInitiated) {
            Wallpaper.crop(imageAt: url, screenSize: size, region: region, scaling: scaling, scale: scale)
        }.value
        if let image { backdrop = NSImage(cgImage: image, size: region.size) }
    }
}

/// The real stage, as on the desktop, with its glass blurring the preview's wallpaper.
private struct StageView: NSViewRepresentable {
    let slide: Slide
    let style: SlideStyle
    let track: NowPlaying
    let trailing: Bool

    func makeNSView(context: Context) -> Stage {
        let stage = Stage(preview: true)
        stage.slide.scrollToSkip = false
        return stage
    }

    func updateNSView(_ stage: Stage, context: Context) {
        stage.configure(glass: style.glass, scale: style.scale)
        stage.slide.metrics = style.metrics
        stage.slide.alignsTrailing = trailing
        stage.slide.isPlaying = track.isPlaying
        stage.slide.setSlide(slide, motion: .settle)
        let position = track.position()
        let remaining = track.duration.map { max(0, $0 - position) / max(track.effectiveRate, 0.01) } ?? 0
        stage.slide.setProgress(track.progress(), remaining: remaining, running: track.isPlaying)
    }
}
