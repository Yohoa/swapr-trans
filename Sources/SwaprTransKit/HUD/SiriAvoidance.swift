import AppKit

/// Keeps the translation window off Siri's windows (the Siri chat panel, its settings window, ...).
/// The window sits next to the Siri window instead of on top of it.
enum SiriAvoidance {
    /// Smallest Siri window worth avoiding; tiny helper windows are ignored.
    private static let minimumSize = NSSize(width: 100, height: 60)
    private static let gap: CGFloat = 8

    /// On-screen windows of Siri in Cocoa screen coordinates.
    static func windowFrames() -> [NSRect] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        // CG coordinates start at the top-left of the primary display; Cocoa's start at its bottom-left
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let ownPid = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard let owner = info[kCGWindowOwnerName as String] as? String, owner.hasPrefix("Siri"),
                  (info[kCGWindowOwnerPID as String] as? Int32) != ownPid,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
                  let w = bounds["Width"] as? Double, let h = bounds["Height"] as? Double,
                  w >= minimumSize.width, h >= minimumSize.height else { return nil }
            return NSRect(x: x, y: primaryHeight - (y + h), width: w, height: h)
        }
    }

    /// Where `frame` should go so it doesn't cover a Siri window, or nil when it already doesn't
    /// (or no free spot inside `screen` exists, in which case it stays where it is).
    static func adjusted(_ frame: NSRect, screen: NSRect, avoiding windows: [NSRect] = windowFrames()) -> NSRect? {
        let blocked = windows.map { $0.insetBy(dx: -gap, dy: -gap) }
        let hit = blocked.filter { $0.intersects(frame) }
        guard !hit.isEmpty else { return nil }

        let usable = screen.insetBy(dx: 8, dy: 8)
        var best: NSRect?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for r in hit {
            let candidates = [
                frame.offsetBy(dx: 0, dy: r.maxY - frame.minY),   // above it
                frame.offsetBy(dx: 0, dy: r.minY - frame.maxY),   // below it
                frame.offsetBy(dx: r.minX - frame.maxX, dy: 0),   // to its left
                frame.offsetBy(dx: r.maxX - frame.minX, dy: 0),   // to its right
            ]
            for c in candidates where usable.contains(c) && !blocked.contains(where: { $0.intersects(c) }) {
                let distance = hypot(c.minX - frame.minX, c.minY - frame.minY)
                if distance < bestDistance {
                    best = c
                    bestDistance = distance
                }
            }
        }
        return best
    }
}
