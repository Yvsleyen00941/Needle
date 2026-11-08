#if DEBUG
import AppKit
import ScreenCaptureKit

/// Debug builds only. Opened with `-NeedleShots <folder>` (best with `-NeedleDemo YES`), Needle
/// photographs its own windows (the corner over the wallpaper behind it, a skip as it happens, the
/// cover card, each settings pane) and quits. Only Needle's own windows are captured, so no
/// screen-recording permission is needed. `-NeedleShotsAlpha YES` keeps the transparency, to lay
/// the pictures over a real screenshot (an Aerial wallpaper is a video, not the picture macOS reports).
enum Shots {
    static func runIfAsked(model: AppModel) -> Bool {
        guard let path = UserDefaults.standard.string(forKey: "NeedleShots") else { return false }
        Task { await run(model, into: URL(fileURLWithPath: path, isDirectory: true)) }
        return true
    }

    private static var alpha: Bool { UserDefaults.standard.bool(forKey: "NeedleShotsAlpha") }

    private static func run(_ model: AppModel, into folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.start()
        for _ in 0..<40 where model.player.track == nil { await pause(0.25) }
        await pause(2.5)

        if let corner = NSApp.windows.first(where: { $0 is CornerPanel && $0.isVisible }) {
            if let screen = corner.screen {
                let f = corner.frame, s = screen.frame
                let line = "\(f.minX - s.minX) \(s.maxY - f.maxY) \(f.width) \(f.height) \(s.width) \(s.height) \(screen.backingScaleFactor)\n"
                try? line.write(to: folder.appendingPathComponent("corner-frame.txt"), atomically: true, encoding: .utf8)
            }
            await shoot(corner, "corner", into: folder)
            // A skip, photographed as it happens.
            let start = Date()
            model.player.next()
            for frame in 0..<12 {
                await shoot(corner, String(format: "skip-%02d-%03.0fms", frame, Date().timeIntervalSince(start) * 1000), into: folder)
                await pause(0.05)
            }
            await pause(1)
            await shoot(corner, "corner-next", into: folder)
            model.player.toggle()
            await pause(0.8)
            await shoot(corner, "corner-paused", into: folder)
            model.player.toggle()
            let glass = model.settings.glass
            model.settings.glass = true
            await pause(1.2)
            await shoot(corner, "corner-glass", into: folder)
            model.settings.glass = glass
            await pause(1)

            model.corner.showCard()
            await pause(1.2)
            if let card = NSApp.windows.first(where: { $0.level.rawValue == Int(CGWindowLevelForKey(.dockWindow)) + 1 && $0.isVisible }) {
                await shoot(card, "card", into: folder)
            }
        }

        for tab in SettingsTab.allCases {
            model.openSettings(tab)
            await pause(1.2)
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                await capture(window, "settings-\(tab.title.lowercased())", into: folder, background: nil)
            }
        }
        NSApp.terminate(nil)
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Transparent windows are composited onto the wallpaper that's really behind them.
    private static func shoot(_ window: NSWindow, _ name: String, into folder: URL) async {
        guard !alpha, let screen = window.screen ?? NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            await capture(window, name, into: folder, background: nil)
            return
        }
        let region = window.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let backdrop = Wallpaper.crop(imageAt: url, screenSize: screen.frame.size, region: region,
                                      scaling: Wallpaper.scaling(for: screen), scale: screen.backingScaleFactor)
        await capture(window, name, into: folder, background: backdrop)
    }

    private static func capture(_ window: NSWindow, _ name: String, into folder: URL, background: CGImage?) async {
        do {
            let content = try await SCShareableContent.currentProcess
            guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return }
            let scale = window.screen?.backingScaleFactor ?? 2
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = background != nil
            config.colorSpaceName = CGColorSpace.sRGB
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
            var output = image
            if let background, let space = CGColorSpace(name: CGColorSpace.sRGB),
               let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                context.draw(background, in: rect)
                context.draw(image, in: rect)
                output = context.makeImage() ?? image
            }
            try NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])?
                .write(to: folder.appendingPathComponent("\(name).png"))
        } catch {
            NSLog("Shots: \(name) failed: \(error)")
        }
    }
}
#endif
