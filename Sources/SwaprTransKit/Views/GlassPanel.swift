import SwiftUI
import AppKit

/// Corner radius shared by the HUD and the menu bar popup, matching macOS menus.
public let swaprCornerRadius: CGFloat = 16

/// Borderless floating panel whose top-left corner stays put while its SwiftUI content
/// grows or shrinks (the hosting view drives the size), kept inside the visible screen.
open class AnchoredPanel: NSPanel {
    public var anchorTopLeft: NSPoint?

    public init(width: CGFloat) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Dragging the panel moves its anchor with it
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, self.anchorTopLeft != nil else { return }
                self.anchorTopLeft = NSPoint(x: self.frame.minX, y: self.frame.maxY)
            }
        }
    }

    /// Hosts `view` clipped to the rounded card shape, sized by its SwiftUI content.
    public func host<Content: View>(_ hostingView: NSHostingView<Content>) {
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = swaprCornerRadius
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        contentView = hostingView
    }

    open override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if let anchor = anchorTopLeft {
            frame.origin = NSPoint(x: anchor.x, y: anchor.y - frame.height)
            // Clamp to the screen the anchor is on, not the one the panel was last shown on
            let anchorScreen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.x, y: anchor.y - 1)) }
            if let visible = (anchorScreen ?? screen ?? NSScreen.main)?.visibleFrame {
                frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - frame.width - 8)
                frame.origin.y = max(frame.minY, visible.minY + 8)
            }
        }
        super.setFrame(frame, display: flag)
        invalidateShadow()
    }
}

/// Hosting view that resizes its window to the SwiftUI content's ideal size whenever that changes
/// (an AnchoredPanel then keeps the top-left corner fixed).
open class AutoSizingHostingView<Content: View>: NSHostingView<Content> {
    private var resizeScheduled = false

    open override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.resizeScheduled = false
            self?.resizeWindowToFit()
        }
    }

    public func resizeWindowToFit() {
        guard let window = window else { return }
        let size = fittingSize
        guard size.width > 0, size.height > 0, window.frame.size != size else { return }
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
    }
}

/// Frosted rounded card used as the background of the HUD and the popup.
public struct GlassCard: ViewModifier {
    var material: NSVisualEffectView.Material
    /// 0 = pure frosted glass, 1 = solid window background
    var solidity: Double

    public func body(content: Content) -> some View {
        content
            .focusEffectDisabled()
            .background(
                ZStack {
                    VisualEffectView(material: material, blendingMode: .behindWindow, cornerRadius: swaprCornerRadius)
                    // Tint so busy content behind the window doesn't compete with the text
                    Color(nsColor: .windowBackgroundColor).opacity(solidity)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: swaprCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: swaprCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
    }
}

extension View {
    public func glassCard(_ material: NSVisualEffectView.Material = .popover, solidity: Double = 0.55) -> some View {
        modifier(GlassCard(material: material, solidity: solidity))
    }
}

public struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    var cornerRadius: CGFloat = 0

    public init(material: NSVisualEffectView.Material, blendingMode: NSVisualEffectView.BlendingMode, cornerRadius: CGFloat = 0) {
        self.material = material
        self.blendingMode = blendingMode
        self.cornerRadius = cornerRadius
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.wantsLayer = true
        updateNSView(view, context: context)
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.layer?.cornerRadius = cornerRadius
        nsView.layer?.cornerCurve = .continuous
        nsView.layer?.masksToBounds = cornerRadius > 0
    }
}
