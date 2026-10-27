import AVFoundation

/// Plays a rhythm as clicks rendered into one audio buffer, so every click lands at its exact
/// offset (timers and NSSound drift by tens of milliseconds and fall out of step with the playhead).
@MainActor
final class RhythmClick {
    static let shared = RhythmClick()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    /// Delay before the first click, so playback can be scheduled ahead on the audio clock.
    private let lead = 0.08

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// One short woodblock-like tick.
    private lazy var tick: [Float] = {
        let rate = format.sampleRate
        return (0..<Int(rate * 0.04)).map { i in
            let t = Double(i) / rate
            let envelope = exp(-t * 110)
            return Float(envelope * (0.55 * sin(2 * .pi * 1_900 * t) + 0.3 * sin(2 * .pi * 950 * t)))
        }
    }()

    /// Plays clicks at `offsets` (seconds) and returns the system uptime at which the first click is heard.
    @discardableResult
    func play(offsets: [Double]) -> Double {
        let now = ProcessInfo.processInfo.systemUptime
        guard let last = offsets.last else { return now }
        if !engine.isRunning { try? engine.start() }
        player.stop()

        let rate = format.sampleRate
        let frames = AVAudioFrameCount((last + 0.1) * rate) + AVAudioFrameCount(tick.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return now }
        buffer.frameLength = frames
        for i in 0..<Int(frames) { samples[i] = 0 }
        for offset in offsets {
            let start = Int(offset * rate)
            for (j, v) in tick.enumerated() where start + j < Int(frames) {
                samples[start + j] += v
            }
        }

        player.scheduleBuffer(buffer, at: nil)
        player.play(at: AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: lead)))
        return now + lead + engine.outputNode.presentationLatency
    }
}
