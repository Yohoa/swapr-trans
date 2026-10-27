import SwiftUI
import AppKit

/// Records a rhythm on ⌥ Option (left or right): the first Option press picks the key, each further
/// press of it adds a tap, and recording ends 1.5 s after the last tap (or at the maximum tap count).
/// Other keys are swallowed and only produce a hint.
@MainActor
final class RhythmRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var keyLabel: String?
    @Published private(set) var taps: [Double] = []
    /// Set briefly when a key other than ⌥ Option was pressed.
    @Published private(set) var wrongKey = false

    private var keyCode: Int64?
    private var monitor: Any?
    private var finishWork: DispatchWorkItem?
    private var wrongKeyWork: DispatchWorkItem?
    private var onFinish: ((SwaprRhythm) -> Void)?

    static let silenceToFinish = 1.5

    func start(onFinish: @escaping (SwaprRhythm) -> Void) {
        cancel()
        self.onFinish = onFinish
        isRecording = true
        TranslateMonitor.shared.isRecordingRhythm = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func cancel() {
        stop()
        keyCode = nil
        keyLabel = nil
        taps = []
    }

    /// Returns true when the event was consumed by recording.
    private func handle(_ event: NSEvent) -> Bool {
        let code = Int64(event.keyCode)
        if event.type == .keyDown {
            if event.keyCode == 53 {
                cancel()  // Esc cancels
            } else if !event.isARepeat {
                flagWrongKey()
            }
            return true
        }
        // flagsChanged: count presses of an Option key, not releases
        guard let flag = SwaprKeys.modifierFlag(for: code),
              CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)).contains(flag) else { return false }
        guard SwaprKeys.optionKeyCodes.contains(code) else {
            flagWrongKey()
            return false
        }

        if keyCode == nil {
            keyCode = code
            keyLabel = SwaprKeys.label(for: code, characters: nil)
        }
        // The other Option key doesn't continue a rhythm started on this one
        guard code == keyCode else {
            flagWrongKey()
            return true
        }
        // The same press can reach a local monitor twice
        guard event.timestamp - (taps.last ?? 0) > 0.03 else { return true }

        taps.append(event.timestamp)
        if taps.count >= SwaprRhythm.maxTaps {
            finish()
        } else {
            scheduleFinish()
        }
        return true
    }

    private func flagWrongKey() {
        wrongKey = true
        wrongKeyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.wrongKey = false }
        wrongKeyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func scheduleFinish() {
        finishWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish() }
        finishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.silenceToFinish, execute: work)
    }

    private func finish() {
        let recorded = taps
        let code = keyCode
        let label = keyLabel
        stop()
        guard let code = code, let label = label, recorded.count >= SwaprRhythm.minTaps else {
            cancel()
            return
        }
        let intervals = zip(recorded.dropFirst(), recorded).map { $0 - $1 }
        onFinish?(SwaprRhythm(keyCode: code, keyLabel: label, intervals: intervals))
        keyCode = nil
        keyLabel = nil
        taps = []
    }

    private func stop() {
        finishWork?.cancel()
        finishWork = nil
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        isRecording = false
        wrongKey = false
        TranslateMonitor.shared.isRecordingRhythm = false
    }
}

extension SwaprRhythm {
    /// Tap times relative to the first tap.
    var offsets: [Double] { intervals.reduce(into: [0.0]) { $0.append($0.last! + $1) } }
}

/// Recorder-style timeline: a seconds scale starting at 0, tap dots at their real times, and
/// (while recording) a playhead plus the silence window after the last tap that ends recording.
struct RhythmTimeline: View {
    /// Tap times relative to the first tap.
    let offsets: [Double]
    /// Playhead position in seconds; nil hides the playhead.
    var elapsed: Double? = nil
    var recording: Bool = false
    /// Number of leading dots drawn lit (playback and practice); nil lights none.
    var lit: Int? = nil

    /// Visible seconds: at least 4, growing so the silence window after the last tap always fits.
    static func span(lastTap: Double) -> Double {
        max(4, (lastTap + RhythmRecorder.silenceToFinish).rounded(.up))
    }

    private let inset: CGFloat = 6
    private let trackY: CGFloat = 10

    var body: some View {
        let last = offsets.last ?? 0
        let span = Self.span(lastTap: last)
        GeometryReader { geo in
            let usable = geo.size.width - inset * 2
            let x = { (t: Double) -> CGFloat in inset + CGFloat(min(max(t / span, 0), 1)) * usable }

            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: usable, height: 4)
                    .offset(x: inset, y: trackY - 2)

                if recording, let elapsed {
                    // Recorded part of the tape
                    Capsule()
                        .fill(Color.red.opacity(0.25))
                        .frame(width: max(x(elapsed) - inset, 0), height: 4)
                        .offset(x: inset, y: trackY - 2)
                    // Silence window: recording stops when the playhead reaches its end
                    if !offsets.isEmpty {
                        let start = x(last), end = x(last + RhythmRecorder.silenceToFinish)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.red.opacity(0.10))
                            .frame(width: end - start, height: 14)
                            .offset(x: start, y: trackY - 7)
                        Rectangle()
                            .fill(Color.red.opacity(0.6))
                            .frame(width: 2, height: 14)
                            .offset(x: end - 1, y: trackY - 7)
                    }
                }

                ForEach(Array(offsets.enumerated()), id: \.offset) { i, t in
                    let isLit = recording || i < (lit ?? 0)
                    Circle()
                        .fill(isLit ? Color.accentColor : Color.primary.opacity(lit == nil ? 0.75 : 0.25))
                        .frame(width: 10, height: 10)
                        .scaleEffect(isLit && lit != nil ? 1.25 : 1)
                        .animation(.spring(duration: 0.2), value: isLit)
                        .offset(x: x(t) - 5, y: trackY - 5)
                }

                if let elapsed {
                    Capsule()
                        .fill(recording ? Color.red : Color.accentColor)
                        .frame(width: 2, height: 20)
                        .offset(x: x(elapsed) - 1, y: trackY - 10)
                }

                // Seconds scale
                ForEach(0...Int(span), id: \.self) { s in
                    VStack(spacing: 1) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.25))
                            .frame(width: 1, height: 4)
                        Text(s == 0 ? "0" : "\(s)s")
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .frame(width: 24)
                    .offset(x: x(Double(s)) - 12, y: trackY + 9)
                }
            }
            .animation(.easeOut(duration: 0.25), value: span)
        }
        .frame(height: 36)
    }
}

/// A saved rhythm on its timeline with a Play button that sweeps a playhead across it,
/// lighting each dot and ticking as it passes.
struct RhythmPlayback: View {
    let rhythm: SwaprRhythm
    @State private var startedAt: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                play()
            } label: {
                Image(systemName: startedAt == nil ? "play.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Play this rhythm")

            TimelineView(.animation(paused: startedAt == nil)) { _ in
                let elapsed = startedAt.map { max(ProcessInfo.processInfo.systemUptime - $0, 0) }
                RhythmTimeline(
                    offsets: rhythm.offsets,
                    elapsed: elapsed,
                    lit: elapsed.map { e in rhythm.offsets.filter { $0 <= e }.count }
                )
            }
        }
    }

    private func play() {
        // The playhead follows the audio clock: it reaches each dot as its click is heard
        let start = RhythmClick.shared.play(offsets: rhythm.offsets)
        startedAt = start
        DispatchQueue.main.asyncAfter(deadline: .now() + (start - ProcessInfo.processInfo.systemUptime) + rhythm.duration + 0.6) {
            if startedAt == start { startedAt = nil }
        }
    }
}

/// Live recording display: header with tap count and elapsed time, and the recorder timeline.
struct RhythmRecordingPanel: View {
    @ObservedObject var recorder: RhythmRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(.animation(paused: recorder.taps.isEmpty)) { _ in
                let first = recorder.taps.first
                let elapsed = first.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle")
                            .foregroundStyle(.red)
                            .symbolEffect(.pulse)
                        Text(recorder.keyLabel.map { "\($0) · \(recorder.taps.count) taps" } ?? "Tap a rhythm on ⌥ Option…")
                            .font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 4)
                        Text(String(format: "%.1f s", elapsed))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    RhythmTimeline(offsets: recorder.taps.map { $0 - (first ?? 0) }, elapsed: elapsed, recording: true)
                }
            }
            Text(recorder.wrongKey ? "Use the same ⌥ Option key for every tap — other keys don't count." : "Stops 1.5 s after your last tap · Esc to cancel")
                .font(.system(size: 11, weight: recorder.wrongKey ? .semibold : .regular))
                .foregroundStyle(recorder.wrongKey ? Color.orange : Color.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.08)))
    }
}

/// Settings row for the Rhythm Tap shortcut: shows the current rhythm and records a new one.
struct RhythmRecorderRow: View {
    @ObservedObject var config = SwaprTransConfig.shared
    @StateObject private var recorder = RhythmRecorder()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Rhythm")
                    .font(.system(size: 13))
                Spacer(minLength: 8)
                if recorder.isRecording {
                    Button("Cancel") { recorder.cancel() }
                        .controlSize(.regular)
                } else {
                    if config.rhythm != .builtIn {
                        Button("Reset") { config.rhythm = .builtIn }
                            .controlSize(.regular)
                            .help("Go back to the built-in rhythm")
                    }
                    Button("Record…") {
                        recorder.start { config.rhythm = $0 }
                    }
                    .controlSize(.regular)
                }
            }

            if recorder.isRecording {
                RhythmRecordingPanel(recorder: recorder)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(config.rhythm.summary + (config.rhythm == .builtIn ? " · built-in" : ""))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    RhythmPlayback(rhythm: config.rhythm)
                }
            }
        }
        .onDisappear { recorder.cancel() }
    }
}
