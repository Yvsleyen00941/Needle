import AppKit
import CoreImage

/// Still images of the corner over the wallpaper behind it, for the README and for checking the
/// drawing without a screen recording:
///   `Needle -NeedleRender <file.png>`      what's playing now (or a demo record with `-NeedleDemo YES`)
///   `Needle -NeedleRenderSet <folder>`     the demo records at several strip widths, clear and on glass
///   `-NeedleScale 1`                       at 1× instead of 2×
///   `-NeedleStrip 74`                      as if the Dock left a strip that wide
///   `Needle -NeedleDockInfo <file.txt>`    what Needle measures of the Dock (open it with `open`, so
///                                          it runs with Needle's own Accessibility access)
/// The glass is simulated with a blur of the same wallpaper; on the desktop the system does it.
enum Preview {
    static func runIfAsked(model: AppModel) -> Bool {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: "NeedleDockInfo") {
            try? DockLocator.report().write(toFile: path, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
            return true
        }
        if let path = defaults.string(forKey: "NeedleRender") {
            Task {
                model.player.start()
                for _ in 0..<40 where model.player.track == nil || (model.player.track?.hasArtwork == true && model.player.cover == nil) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let track = model.player.track ?? Demo.track(0, position: 72)
                let cover = model.player.track == nil ? demoCover(0) : model.player.cover
                let strip = CGFloat(defaults.double(forKey: "NeedleStrip"))
                render(model, track: track, cover: cover, strip: strip > 0 ? strip : nil, to: URL(fileURLWithPath: path))
                NSApp.terminate(nil)
            }
            return true
        }
        if let path = defaults.string(forKey: "NeedleRenderSet") {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let glass = model.settings.glass
            for strip in [368.0, 240, 160, 129, 96, 74, 56] {
                for onGlass in [false, true] {
                    model.settings.glass = onGlass
                    for index in [0, 2, 3] {
                        let record = Demo.records[index]
                        render(model, track: Demo.track(index, position: record.duration * 0.38), cover: demoCover(record.cover), strip: strip,
                               to: folder.appending(path: "strip-\(Int(strip))-\(onGlass ? "glass" : "clear")-\(index).png"))
                    }
                }
            }
            model.settings.glass = glass
            NSApp.terminate(nil)
            return true
        }
        return false
    }

    static func demoCover(_ index: Int) -> Cover? {
        Demo.cover(index).map { Cover(key: "demo-\(index)", image: $0, palette: CoverPalette.of($0)) }
    }

    static func render(_ model: AppModel, track: NowPlaying, cover: Cover?, strip: CGFloat?, to url: URL) {
        let asked = CGFloat(UserDefaults.standard.double(forKey: "NeedleScale"))
        let scale: CGFloat = asked > 0 ? asked : 2
        guard var layout = DockLocator.locate(),
              let screen = NSScreen.screens.first(where: { $0.frame == layout.screenFrame }) ?? NSScreen.main else { return }
        if let strip, layout.edge == .bottom {
            if model.settings.side == .left {
                layout.tiles.origin.x = layout.screenFrame.minX + 14 + strip + model.settings.dockGap
            } else {
                layout.tiles.origin.x = layout.screenFrame.maxX - 14 - strip - model.settings.dockGap - layout.tiles.width
            }
        }
        var style = model.slideStyle(scale: scale)
        let metrics = style.metrics
        guard let frame = CornerController.frame(for: layout, side: model.settings.side, gap: model.settings.dockGap, height: metrics.height) else { return }
        let local = frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let wallpaperURL = Wallpaper.imageURL(for: screen)
        let scaling = Wallpaper.scaling(for: screen)
        if !style.glass, model.settings.contrast == .automatic, let wallpaperURL,
           let sample = Wallpaper.sample(imageAt: wallpaperURL, screenSize: screen.frame.size, region: local, scaling: scaling) {
            model.ground = sample.ground
            style = model.slideStyle(scale: scale)
        }

        // The corner of the screen: the slide, and the start of the Dock beside it.
        let tiles = layout.tiles.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let left = model.settings.side == .left
        let region = left
            ? CGRect(x: 0, y: 0, width: min(screen.frame.width, local.maxX + 200), height: max(local.maxY, tiles.maxY) + 22)
            : CGRect(x: max(0, local.minX - 200), y: 0, width: screen.frame.width - max(0, local.minX - 200), height: max(local.maxY, tiles.maxY) + 22)
        let width = Int(region.width * scale), height = Int(region.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -region.minX, y: 0)
        let wallpaper = wallpaperURL.flatMap {
            Wallpaper.crop(imageAt: $0, screenSize: screen.frame.size, region: region, scaling: scaling, scale: scale)
        }
        if let wallpaper { context.draw(wallpaper, in: region) }
        drawDock(tiles, in: context)

        let content = SlideContent(track, cover: cover)
        let slide = SlideRenderer.slide(for: content, style: style, room: local.width)
        let centre = CornerController.corner(for: layout, side: model.settings.side).map { $0 - screen.frame.minX }
        let placed = metrics.layout(in: local, gridWidth: slide.size.width, trailing: left, clock: slide.clock, tile: slide.tile, centre: centre)
        if metrics.glass {
            drawGlass(placed.platter, radius: metrics.platterRadius(tile: slide.tile), wallpaper: wallpaper, region: region, scale: scale, in: context)
        }
        let progress = track.progress().map { CGFloat($0) }
        SlideRenderer.draw(slide, layout: placed, metrics: metrics, progress: progress, dimmed: !track.isPlaying, in: context)
        guard let image = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// A stand-in for the Dock's glass, so the still shows where the corner ends.
    static func drawDock(_ tiles: CGRect, in context: CGContext) {
        let path = CGPath(roundedRect: tiles, cornerWidth: 26, cornerHeight: 26, transform: nil)
        context.saveGState()
        context.addPath(path)
        context.setFillColor(CGColor(gray: 1, alpha: 0.16))
        context.fillPath()
        context.addPath(CGPath(roundedRect: tiles.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 25.5, cornerHeight: 25.5, transform: nil))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.32))
        context.setLineWidth(1)
        context.strokePath()
        let colors: [UInt32] = [0x2E8BF6, 0xDADADF, 0xFA2D48, 0x3D7BF7, 0xF2A33A]
        let tile = min(65, tiles.height - 14)
        for (index, hex) in colors.enumerated() {
            let rect = CGRect(x: tiles.minX + 10 + CGFloat(index) * (tile + 4), y: tiles.midY - tile / 2, width: tile, height: tile)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: tile * 0.23, cornerHeight: tile * 0.23, transform: nil))
            context.setFillColor(RGB(hex: hex).cgColor())
            context.fillPath()
        }
        context.restoreGState()
    }

    /// What the system's glass shows: the wallpaper behind, blurred, deepened and more saturated, under a lit rim.
    static func drawGlass(_ rect: CGRect, radius: CGFloat, wallpaper: CGImage?, region: CGRect, scale: CGFloat, in context: CGContext) {
        let shape = Shapes.continuous(rect, radius: radius)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 7, color: CGColor(gray: 0, alpha: 0.28))
        context.addPath(shape)
        context.setFillColor(CGColor(gray: 0, alpha: 0.01))
        context.fillPath()
        context.restoreGState()
        if let wallpaper, let blurred = blur(wallpaper, scale: scale) {
            context.saveGState()
            context.addPath(shape)
            context.clip()
            context.draw(blurred, in: region)
            context.setFillColor(CGColor(gray: 0.08, alpha: 0.42))
            context.fill(rect)
            context.restoreGState()
        }
        if let edge = Stage.glassEdge(size: rect.size, radius: radius, scale: scale) {
            context.draw(edge, in: rect)
        }
    }

    static func blur(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image).clampedToExtent()
        guard let blurred = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: input, kCIInputRadiusKey: 16 * scale])?.outputImage,
              let saturated = CIFilter(name: "CIColorControls", parameters: [kCIInputImageKey: blurred, kCIInputSaturationKey: 1.5])?.outputImage
        else { return nil }
        return CIContext().createCGImage(saturated, from: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
}
