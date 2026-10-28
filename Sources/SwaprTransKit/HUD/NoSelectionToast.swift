import SwiftUI
import AppKit

/// Small hint next to the mouse when the shortcut fired but there was no selected text,
/// so a trigger never ends in nothing happening at all.
@MainActor
public final class NoSelectionToast {
    public static let shared = NoSelectionToast()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private static let visibleFor = 1.6

    private init() {}

    public func show(at point: NSPoint = NSEvent.mouseLocation) {
        // A translation window already on screen is feedback enough
        guard !TranslationHudController.shared.isVisible else { return }

        let p = panel ?? makePanel()
        panel = p
        let size = p.contentView?.fittingSize ?? NSSize(width: 240, height: 44)
        var origin = NSPoint(x: point.x + 14, y: point.y - size.height - 14)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            // Not enough room below the pointer: show it above
            if origin.y < visible.minY + 8 { origin.y = point.y + 14 }
            origin.y = min(origin.y, visible.maxY - size.height - 8)
        }
        p.setFrame(NSRect(origin: origin, size: size), display: true)

        if !p.isVisible { p.alphaValue = 0 }
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 1
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleFor, execute: work)
    }

    private func hide() {
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            p.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                // Shown again while fading out: keep it
                if p.alphaValue == 0 { p.orderOut(nil) }
            }
        })
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let host = NSHostingView(rootView: NoSelectionToastView())
        host.wantsLayer = true
        host.layer?.cornerRadius = 12
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        p.contentView = host
        return p
    }
}

struct NoSelectionToastView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.cursor")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("No text selected")
                    .font(.system(size: 12, weight: .semibold))
                Text("Select some text first, then trigger again.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .fixedSize()
        .background(
            ZStack {
                VisualEffectView(material: .popover, blendingMode: .behindWindow, cornerRadius: 12)
                Color(nsColor: .windowBackgroundColor).opacity(0.5)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
    }
}
