import SwiftUI
import AppKit
import Combine

/// First-run guide: explains Rhythm Tap, asks for Accessibility, lets the user keep or record a rhythm,
/// and has them try it once.
@MainActor
public final class WelcomeWindowController: NSObject, NSWindowDelegate {
    public static let shared = WelcomeWindowController()
    private var window: NSWindow?

    public func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: WelcomeView { [weak self] in self?.window?.close() })
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        SwaprTransConfig.shared.hasOnboarded = true
        // Dropping the hosting view makes SwiftUI run onDisappear, which stops any practice/recording monitor
        window?.contentView = nil
        window = nil
        TranslateMonitor.shared.isRecordingRhythm = false
    }
}

/// Listens for the user's rhythm inside the welcome window (no Accessibility needed) and reports progress.
@MainActor
final class RhythmPractice: ObservableObject {
    @Published private(set) var lit = 0
    @Published private(set) var matched = false
    @Published private(set) var wrongKey = false

    private var matcher: RhythmMatcher?
    private var keyCode: Int64 = 0
    private var monitor: Any?
    private var resetWork: DispatchWorkItem?
    private var lastTap: Double = 0

    func start(rhythm: SwaprRhythm) {
        stop()
        matcher = RhythmMatcher(pattern: rhythm.intervals)
        keyCode = rhythm.keyCode
        lit = 0
        matched = false
        // Keep the global trigger quiet while practising here
        TranslateMonitor.shared.isRecordingRhythm = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        resetWork?.cancel()
        TranslateMonitor.shared.isRecordingRhythm = false
    }

    private func handle(_ event: NSEvent) {
        let code = Int64(event.keyCode)
        guard event.type == .flagsChanged, let flag = SwaprKeys.modifierFlag(for: code) else {
            if event.type == .keyDown { wrongKey = true }
            return
        }
        // Count presses only
        guard CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)).contains(flag) else { return }
        guard code == keyCode else {
            wrongKey = true
            matcher?.reset()
            lit = 0
            return
        }
        wrongKey = false
        let now = event.timestamp
        // The same press can reach a local monitor twice
        guard now - lastTap > 0.03 else { return }
        lastTap = now
        if let deadline = matcher?.deadline, now > deadline { matcher?.reset() }
        switch matcher?.tap(at: now) {
        case .matched:
            lit = Int.max
            matched = true
            NSSound(named: "Glass")?.play()
            SwaprPreview.show()
            scheduleReset(after: 1.2)
        case .pending:
            matched = false
            lit = matcher?.taps.count ?? 0
            scheduleReset(after: (matcher?.deadline ?? now) - ProcessInfo.processInfo.systemUptime + 0.15)
        case nil:
            break
        }
    }

    /// Clears the lit dots once the rhythm can no longer continue (the matcher itself drops stale taps
    /// by their timestamps on the next press).
    private func scheduleReset(after delay: Double) {
        resetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.lit = 0 }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.1), execute: work)
    }
}

struct WelcomeView: View {
    enum Page: Int, CaseIterable { case intro, permission, rhythm, practice }

    let onClose: () -> Void
    @ObservedObject private var config = SwaprTransConfig.shared
    @State private var page: Page = .intro
    @StateObject private var recorder = RhythmRecorder()
    @StateObject private var practice = RhythmPractice()
    @State private var everMatched = false
    private let permissionTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case .intro: intro
                case .permission: permission
                case .rhythm: rhythmPage
                case .practice: practicePage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 40)
            .padding(.top, 44)

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
        }
        .frame(width: 560, height: 520)
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
        .onReceive(permissionTimer) { _ in
            if page == .permission { config.checkPermission() }
        }
        .onChange(of: page) { _, newPage in
            recorder.cancel()
            if newPage == .practice { practice.start(rhythm: config.rhythm) } else { practice.stop() }
        }
        .onChange(of: practice.matched) { _, m in if m { everMatched = true } }
        .onDisappear {
            recorder.cancel()
            practice.stop()
        }
    }

    // MARK: Pages

    private var intro: some View {
        VStack(spacing: 18) {
            Image(systemName: "translate")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.accentColor.gradient))
            VStack(spacing: 6) {
                Text("Welcome to SwaprTrans")
                    .font(.system(size: 24, weight: .bold))
                Text("Translate selected text in any app with a tap rhythm on ⌥ Option.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 14) {
                step("text.cursor", "Select text", "In any app — mail, chat, browser, notes.")
                step("option", "Tap your rhythm on ⌥", "Option types nothing, so the rhythm never gets in the way of your typing.")
                step("return", "Read or replace", "The translation pops up. Press Return to replace the selection with it.")
            }
            .padding(.top, 8)
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Allow Accessibility", "SwaprTrans needs Accessibility access to hear your rhythm in other apps, read the selected text and replace it. Nothing leaves your Mac except the text you translate.")
            HStack(spacing: 12) {
                Image(systemName: config.hasAccessibilityPermission ? "checkmark.seal.fill" : "lock.shield.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(config.hasAccessibilityPermission ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(config.hasAccessibilityPermission ? "Access granted" : "Not allowed yet")
                        .font(.system(size: 14, weight: .semibold))
                    Text(config.hasAccessibilityPermission ? "You're all set." : "Click Allow, then switch SwaprTrans on in System Settings ➔ Privacy & Security ➔ Accessibility.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if !config.hasAccessibilityPermission {
                    Button("Allow…") { config.requestPermission() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
            .padding(14)
            .background(card)
            Text("You can finish this guide without it and allow access later from the menu bar.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var rhythmPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Your rhythm", "This is the rhythm that opens the translation. Press Play to hear it, keep it, or record your own on either ⌥ Option key.")
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(config.rhythm.summary + (config.rhythm == .builtIn ? " · built-in" : ""))
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    if recorder.isRecording {
                        Button("Cancel") { recorder.cancel() }
                    } else {
                        if config.rhythm != .builtIn {
                            Button("Use Built-in") { config.rhythm = .builtIn }
                        }
                        Button("Record My Own…") { recorder.start { config.rhythm = $0 } }
                    }
                }
                .controlSize(.regular)
                if recorder.isRecording {
                    RhythmRecordingPanel(recorder: recorder)
                } else {
                    RhythmPlayback(rhythm: config.rhythm)
                }
            }
            .padding(14)
            .background(card)
            Text("Tip: a rhythm of 3–6 taps that you don't tap by accident works best. Only ⌥ Option is allowed — keys that type (like Space) would get in the way.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var practicePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Try it", "Tap your rhythm on \(config.rhythm.keyLabel) now. Each tap lights a dot; when the whole rhythm matches, the translation window pops up with a sample.")
            VStack(spacing: 14) {
                RhythmTimeline(offsets: config.rhythm.offsets, lit: min(practice.lit, config.rhythm.tapCount))
                HStack(spacing: 8) {
                    Image(systemName: practice.matched || everMatched ? "checkmark.circle.fill" : "hand.tap")
                        .foregroundStyle(practice.matched || everMatched ? .green : .secondary)
                    Text(practiceStatus)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(practice.wrongKey ? .orange : .primary)
                    Spacer()
                    Button("Hear It") { playRhythm() }
                        .controlSize(.regular)
                }
            }
            .padding(14)
            .background(card)
            if everMatched {
                Text("That's it. From now on: select text anywhere, tap the rhythm, and press Return to replace it. You can change the rhythm any time from the menu bar icon.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var practiceStatus: String {
        if practice.matched { return "Matched! That's your rhythm." }
        if practice.wrongKey { return "Use \(config.rhythm.keyLabel) — other keys don't count." }
        if practice.lit > 0 { return "\(practice.lit) of \(config.rhythm.tapCount) taps…" }
        return everMatched ? "Nice. Try again, faster or slower — the tempo can vary." : "Waiting for \(config.rhythm.keyLabel)…"
    }

    private func playRhythm() {
        RhythmClick.shared.play(offsets: config.rhythm.offsets)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(Page.allCases, id: \.self) { p in
                    Capsule()
                        .fill(p == page ? Color.accentColor : Color.primary.opacity(0.18))
                        .frame(width: p == page ? 18 : 7, height: 7)
                }
            }
            .animation(.easeOut(duration: 0.2), value: page)
            Spacer()
            if page != .intro {
                Button("Back") { go(-1) }
                    .controlSize(.large)
            }
            if page == .practice {
                Button(everMatched ? "Done" : "Skip") { finish() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(page == .intro ? "Get Started" : "Continue") { go(1) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func go(_ delta: Int) {
        guard let next = Page(rawValue: page.rawValue + delta) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { page = next }
    }

    private func finish() {
        practice.stop()
        recorder.cancel()
        config.shortcut = .rhythm
        config.checkPermission()
        if config.hasAccessibilityPermission && !config.isEnabled { config.isEnabled = true }
        config.hasOnboarded = true
        onClose()
    }

    // MARK: Pieces

    private var card: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }

    private func header(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
