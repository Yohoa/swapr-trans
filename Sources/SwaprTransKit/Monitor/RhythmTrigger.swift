import Foundation
import AppKit
import CoreGraphics

/// A recorded tap rhythm on one key: the gaps (seconds) between consecutive taps.
public struct SwaprRhythm: Codable, Equatable, Sendable {
    public var keyCode: Int64
    public var keyLabel: String
    public var intervals: [Double]

    public static let minTaps = 2
    public static let maxTaps = 8

    public init(keyCode: Int64, keyLabel: String, intervals: [Double]) {
        self.keyCode = keyCode
        self.keyLabel = keyLabel
        self.intervals = intervals
    }

    public var tapCount: Int { intervals.count + 1 }
    public var duration: Double { intervals.reduce(0, +) }
    public var isModifierKey: Bool { SwaprKeys.modifierFlag(for: keyCode) != nil }
    public var isOptionKey: Bool { SwaprKeys.optionKeyCodes.contains(keyCode) }

    /// Rhythm used until the user records their own: five taps on Right ⌥ (ta — ta-ta-ta — ta).
    public static let builtIn = SwaprRhythm(keyCode: 61, keyLabel: "Right ⌥", intervals: [0.42, 0.23, 0.12, 0.38])

    /// e.g. "Right ⌥ · 3 taps · 0.9 s"
    public var summary: String {
        "\(keyLabel) · \(tapCount) taps · \(String(format: "%.1f", duration)) s"
    }
}

/// Matches live taps against a rhythm, tolerating an overall tempo change.
///
/// The live gaps are compared after scaling the whole pattern by the tempo the user is tapping at
/// (0.4×–2.5×: the same rhythm tapped much faster or slower still counts); each gap must then be within ±30% (at least ±60 ms) of its scaled recorded gap.
public struct RhythmMatcher: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Still a possible match; `dropped` earlier taps fell out of the pattern and can be released.
        case pending(dropped: Int)
        /// The last tap completed the rhythm (after dropping `dropped` earlier taps that were not part of it).
        case matched(dropped: Int)
    }

    public let pattern: [Double]
    public private(set) var taps: [Double] = []

    static let tempoRange = 0.4...2.5
    static let relativeTolerance = 0.30
    static let absoluteTolerance = 0.06

    public init(pattern: [Double]) {
        self.pattern = pattern
    }

    public mutating func tap(at time: Double) -> Outcome {
        taps.append(time)
        var dropped = 0
        while !isValidPrefix(taps) {
            taps.removeFirst()
            dropped += 1
        }
        if taps.count == pattern.count + 1 {
            taps.removeAll()
            return .matched(dropped: dropped)
        }
        return .pending(dropped: dropped)
    }

    /// Clears the taps in progress, returning how many there were.
    @discardableResult
    public mutating func reset() -> Int {
        defer { taps.removeAll() }
        return taps.count
    }

    /// Latest time the next tap may arrive and still continue the rhythm; nil when idle.
    public var deadline: Double? {
        guard let last = taps.last, taps.count <= pattern.count else { return nil }
        let k = taps.count - 1
        let next = pattern[k]
        let tempo = k == 0 ? Self.tempoRange.upperBound : scale(of: taps)
        return last + next * tempo * (1 + Self.relativeTolerance) + Self.absoluteTolerance
    }

    private func scale(of taps: [Double]) -> Double {
        let k = taps.count - 1
        let live = taps.last! - taps.first!
        let expected = pattern[0..<k].reduce(0, +)
        return expected > 0 ? live / expected : 1
    }

    private func isValidPrefix(_ taps: [Double]) -> Bool {
        let k = taps.count - 1
        guard k > 0 else { return true }
        guard k <= pattern.count else { return false }
        let s = scale(of: taps)
        // Early on the tempo is estimated from one or two gaps and is noisy, so it gets the same tolerance as
        // a gap; the complete rhythm, measured over its whole length, must be within the range itself
        let slack = k == pattern.count ? 0.005 : Self.relativeTolerance
        guard s >= Self.tempoRange.lowerBound * (1 - slack), s <= Self.tempoRange.upperBound * (1 + slack) else { return false }
        for i in 0..<k {
            let live = taps[i + 1] - taps[i]
            let expected = pattern[i] * s
            if abs(live - expected) > max(expected * Self.relativeTolerance, Self.absoluteTolerance) { return false }
        }
        return true
    }
}

/// Key names and modifier flags for the keys a rhythm can be recorded on.
public enum SwaprKeys {
    private static let modifiers: [Int64: (String, CGEventFlags)] = [
        54: ("Right ⌘", .maskCommand), 55: ("Left ⌘", .maskCommand),
        56: ("Left ⇧", .maskShift), 60: ("Right ⇧", .maskShift),
        58: ("Left ⌥", .maskAlternate), 61: ("Right ⌥", .maskAlternate),
        59: ("Left ⌃", .maskControl), 62: ("Right ⌃", .maskControl),
        63: ("Fn", .maskSecondaryFn),
    ]

    private static let named: [Int64: String] = [
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 76: "Enter",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    public static func modifierFlag(for keyCode: Int64) -> CGEventFlags? { modifiers[keyCode]?.1 }

    /// Rhythms may only be tapped on ⌥ Option (left or right): it types nothing on its own.
    public static let optionKeyCodes: Set<Int64> = [58, 61]

    /// Every modifier flag a rhythm tap on a modifier key may carry (anything else means a chord, not a tap).
    static let allModifierFlags: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn]

    public static func label(for keyCode: Int64, characters: String?) -> String {
        if let m = modifiers[keyCode] { return m.0 }
        if let n = named[keyCode] { return n }
        let c = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return c.isEmpty ? "Key \(keyCode)" : c
    }
}
