import AppKit
import SwiftUI

/// The cover card's own see-through panel, floating just above the corner.
final class CardController {
    private let model: AppModel
    private var panel: NSPanel?
    private var hosting: NSHostingView<CoverCard>?
    private var monitors: [Any] = []
    private(set) var isOpen = false

    init(model: AppModel) {
        self.model = model
    }

    func show(above item: NSRect, cornerFrame: NSRect) {
        let panel = self.panel ?? makePanel()
        let view = hosting ?? NSHostingView(rootView: CoverCard(model: model, onClose: { [weak self] in self?.close() }))
        view.sizingOptions = [.intrinsicContentSize]
        if panel.contentView !== view { panel.contentView = view }
        hosting = view
        let size = view.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(cornerFrame) } ?? NSScreen.main
        let bounds = screen?.frame ?? cornerFrame
        // Over the cover, so it reads as the cover grown large.
        var origin = CGPoint(x: (item.minX + 20 - size.width / 2).rounded(), y: cornerFrame.maxY - 4)
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - size.width - 4)
        let frame = CGRect(origin: origin, size: size)
        isOpen = true
        panel.setFrame(frame.offsetBy(dx: 0, dy: -10), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
        watchForOutsideClicks()
    }

    func close() {
        guard isOpen, let panel else { return }
        isOpen = false
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: -6), display: true)
        } completionHandler: {
            MainActor.assumeIsolated {
                if !self.isOpen { panel.orderOut(nil) }
            }
        }
    }

    /// Keeps the card's size right when its contents change (a longer title wraps to two lines).
    func refresh() {
        guard isOpen, let panel, let hosting else { return }
        guard model.player.track != nil else {
            close()
            return
        }
        let size = hosting.fittingSize
        guard size != panel.frame.size else { return }
        var frame = panel.frame
        frame.origin.x += (frame.width - size.width) / 2
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        self.panel = panel
        return panel
    }

    private func watchForOutsideClicks() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                // A click on the corner decides for itself (on the words it closes the card).
                if event.window !== panel, !(event.window is CornerPanel) { self.close() }
            }
            return event
        }) {
            monitors.append(local)
        }
    }
}
