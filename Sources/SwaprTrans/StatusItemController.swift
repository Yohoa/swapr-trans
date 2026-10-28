import SwiftUI
import AppKit
import Combine
import SwaprTransKit

/// Popup panel for the menu bar item; takes key so its pickers and keyboard shortcuts work.
final class PopupPanel: AnchoredPanel {
    override var canBecomeKey: Bool { true }
}

/// Menu bar icon plus the rounded popup it toggles.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var panel: PopupPanel?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var isClosing = false
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopup)
        }
        let config = SwaprTransConfig.shared
        config.$isEnabled.combineLatest(config.$hasAccessibilityPermission, UpdateManager.shared.$phase)
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled, permitted, phase in
                var hasUpdate = false
                if case .available = phase { hasUpdate = true }
                self?.updateIcon(active: enabled && permitted, badge: hasUpdate)
            }
            .store(in: &cancellables)
        // Switching to another app dismisses the popup, like a menu
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.closePopup() }
            .store(in: &cancellables)
        // Another of our windows (the welcome guide) taking focus dismisses it too
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] note in
                guard let self = self, let w = note.object as? NSWindow, w !== self.panel, !(w is NSPanel) else { return }
                self.closePopup()
            }
            .store(in: &cancellables)
    }

    private func updateIcon(active: Bool, badge: Bool) {
        guard let symbol = NSImage(systemSymbolName: "translate", accessibilityDescription: "SwaprTrans") else { return }
        var image = symbol
        if badge {
            // A dot in the corner: an update is waiting in the popup
            image = NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                let d = rect.width * 0.38
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)).fill()
                return true
            }
        }
        image.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !active
        statusItem.button?.toolTip = badge ? "SwaprTrans — update available" : "SwaprTrans"
    }

    @objc private func togglePopup() {
        if let p = panel, p.isVisible, !isClosing {
            closePopup()
        } else {
            showPopup()
        }
    }

    private func makePanel() -> PopupPanel {
        let p = PopupPanel(width: 400)
        p.level = .statusBar
        p.delegate = self
        p.host(AutoSizingHostingView(rootView: StandaloneMenuBarPopup()))
        return p
    }

    private func showPopup() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let p = panel ?? makePanel()
        panel = p

        p.contentView?.layoutSubtreeIfNeeded()
        let size = p.contentView?.fittingSize ?? NSSize(width: 400, height: 500)
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        // Centered under the icon, kept 8pt inside the screen edges, 6pt below the menu bar
        var x = buttonFrame.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let top = buttonFrame.minY - 6
        p.anchorTopLeft = NSPoint(x: x, y: top)
        p.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)

        isClosing = false
        if !p.isVisible { p.alphaValue = 0 }
        NSApp.activate()
        p.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }

        removeMonitors()
        // Close when clicking anywhere outside, like a menu
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePopup() }
        }
        // Esc closes it too
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self = self, let p = self.panel, p.isKeyWindow,
                  !TranslateMonitor.shared.isRecordingRhythm else { return event }
            self.closePopup()
            return nil
        }
    }

    /// Fades the popup out, then hides it (reopening during the fade cancels the hide).
    private func closePopup() {
        guard let p = panel, p.isVisible, !isClosing else { return }
        isClosing = true
        removeMonitors()
        statusItem.button?.highlight(false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self = self, self.isClosing else { return }
                p.orderOut(nil)
                self.isClosing = false
            }
        })
    }

    private func removeMonitors() {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
        keyMonitor = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        // Menus opened from the popup's own pickers take key briefly; only close if focus left the app
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let p = self.panel, p.isVisible else { return }
            if NSApp.keyWindow == nil && !NSApp.isActive { self.closePopup() }
        }
    }
}
