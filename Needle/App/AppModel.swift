import AppKit
import Observation
import ServiceManagement

/// Wires Needle together: settings, the player, the Dock, the corner and its menus.
@Observable
final class AppModel {
    let settings: Settings
    let player: Player
    @ObservationIgnored let dock = DockWatcher()

    /// What the wallpaper behind the corner looks like, when contrast is automatic.
    var ground: Ground = .dark

    @ObservationIgnored private(set) var corner: CornerController!
    @ObservationIgnored private var statusItem: NSStatusItem?
    @ObservationIgnored private var settingsWindow: SettingsWindowController?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var menuBarObservation: Task<Void, Never>?
    @ObservationIgnored private var wallpaperTimer: Timer?

    init(settings: Settings = .shared, player: Player = Player()) {
        self.settings = settings
        self.player = player
    }

    func start() {
        corner = CornerController(model: self)
        player.start()
        dock.start()
        corner.start()

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.corner.recheckWallpaper() }
        })
        wallpaperTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.corner.recheckWallpaper() }
        }
        wallpaperTimer?.tolerance = 30

        menuBarObservation = Task { [weak self] in
            guard let settings = self?.settings else { return }
            for await show in Observations({ @MainActor in settings.showMenuBarIcon }) {
                self?.updateStatusItem(visible: show)
            }
        }

        if !settings.hasLaunchedBefore {
            settings.hasLaunchedBefore = true
            openSettings(.appearance)
        }
    }

    // MARK: Drawing

    func slideStyle(scale: CGFloat) -> SlideStyle {
        var ground: Ground = switch settings.contrast {
        case .automatic: self.ground
        case .lightText: .dark
        case .darkText: .light
        }
        // On glass, the ground is the glass.
        if settings.glass { ground = .dark }
        return SlideStyle(fontSize: settings.fontSize, ground: ground, glass: settings.glass, coverColors: settings.coverColors,
                          showAlbum: settings.showAlbum, scale: scale)
    }

    // MARK: Commands

    func openSettings(_ tab: SettingsTab = .appearance) {
        let controller = settingsWindow ?? SettingsWindowController(model: self)
        settingsWindow = controller
        controller.show(tab)
    }

    var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSSound.beep()
            }
        }
    }

    /// The track and its controls, then settings and quit: the corner's menu and the menu bar's.
    func menu() -> NSMenu {
        let menu = NSMenu()
        if let track = player.track {
            let title = NSMenuItem(title: Titles.title(track.title), action: nil, keyEquivalent: "")
            title.isEnabled = false
            title.attributedTitle = NSAttributedString(string: Titles.title(track.title), attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)])
            menu.addItem(title)
            if let line = [track.artist, track.album.map(Titles.album)].compactMap(\.self).joined(separator: " — ").nonEmpty {
                let artist = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                artist.isEnabled = false
                menu.addItem(artist)
            }
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.make(track.isPlaying ? "Pause" : "Play", key: " ", modifiers: []) { [weak self] in self?.player.toggle() })
            menu.addItem(NSMenuItem.make("Next Track", key: "]", modifiers: .command) { [weak self] in self?.player.next() })
            menu.addItem(NSMenuItem.make("Previous Track", key: "[", modifiers: .command) { [weak self] in self?.player.previous() })
            menu.addItem(.separator())
            if corner.isShowingTrack {
                menu.addItem(NSMenuItem.make("Show the Cover") { [weak self] in self?.corner.showCard() })
            }
            if let name = player.appName, player.appURL != nil {
                menu.addItem(NSMenuItem.make("Open \(name)") { [weak self] in self?.player.openApp() })
            }
        } else {
            let status = NSMenuItem(title: player.problem ?? "Nothing is playing", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }
        if !DockLocator.canReadDock {
            menu.addItem(NSMenuItem.make("Fit Exactly to the Dock…") { [weak self] in self?.openSettings(.placement) })
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.make("Settings…", key: ",") { [weak self] in self?.openSettings(.appearance) })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.make("Quit Needle", key: "q") { NSApp.terminate(nil) })
        return menu
    }

    // MARK: Menu bar

    private func updateStatusItem(visible: Bool) {
        guard visible else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Mark.templateImage()
        item.button?.toolTip = "Needle"
        let menu = NSMenu()
        menu.delegate = StatusMenuDelegate.shared
        StatusMenuDelegate.shared.model = self
        item.menu = menu
        statusItem = item
    }
}

/// Rebuilds the menu bar menu each time it opens, so it always says what's true right now.
final class StatusMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = StatusMenuDelegate()
    weak var model: AppModel?

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model else { return }
        for item in model.menu().items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }
}

/// Menu items that run a closure.
extension NSMenuItem {
    static func make(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, handler: @escaping () -> Void) -> NSMenuItem {
        let target = MenuHandler(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuHandler.run), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        // The target is weak; the represented object keeps the handler alive as long as the item.
        item.representedObject = target
        return item
    }
}

private final class MenuHandler: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }
}

extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
