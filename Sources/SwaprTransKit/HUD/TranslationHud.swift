import SwiftUI
import AppKit
import Translation
import AVFoundation

public struct TranslationHudData: Identifiable {
    public let id = UUID()
    public let original: String
    public let translated: String
    public let direction: String
    public let provider: String
    public let targetPid: pid_t
}

@MainActor
public final class TranslationHudModel: ObservableObject {
    @Published public var original: String = ""
    @Published public var results: [SwaprTranslation] = []
    @Published public var selectedIndex: Int = 0
    @Published public var direction: String = ""
    @Published public var provider: String = ""
    @Published public var targetPid: pid_t = 0
    @Published public var isLoading: Bool = false
    @Published public var errorMessage: String? = nil
    /// Index of the result being read aloud, if any.
    @Published public var speakingIndex: Int? = nil
    /// Sample shown from Settings or the welcome guide: there is no selection to replace.
    @Published public var isPreview: Bool = false

    /// The result that Replace / Copy / Speak / Enter act on.
    public var selected: SwaprTranslation? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    public var translated: String { selected?.text ?? "" }

    public init(
        original: String = "",
        results: [SwaprTranslation] = [],
        direction: String = "",
        provider: String = "",
        targetPid: pid_t = 0,
        isLoading: Bool = false,
        errorMessage: String? = nil
    ) {
        self.original = original
        self.results = results
        self.direction = direction
        self.provider = provider
        self.targetPid = targetPid
        self.isLoading = isLoading
        self.errorMessage = errorMessage
    }
}

/// Core: Native floating panel that never steals focus
/// Ensures active text selection and cursor are preserved when clicking panel buttons!
final class NonActivatingPanel: AnchoredPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}

final class ClickThroughHostingView<Content: View>: AutoSizingHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

/// What clicking a translation's text does (chosen in Settings ➔ Window).
public enum TranslationClickAction: String, CaseIterable, Identifiable {
    case replace, copy
    public static let storageKey = "swapr_trans_click_action"
    public var id: String { rawValue }
    public var label: String { self == .replace ? "Replace" : "Copy" }
}

@MainActor
public final class TranslationHudController: NSObject, AVSpeechSynthesizerDelegate {
    public static let shared = TranslationHudController()

    public let model = TranslationHudModel()
    private var panel: NonActivatingPanel?
    private var hostingView: ClickThroughHostingView<TranslationHudView>?
    private var dismissTimer: Timer?
    private var speechSynthesizer: AVSpeechSynthesizer?
    private var currentUtterance: AVSpeechUtterance?
    /// Set from hide() until its fade-out finishes; a new show during the fade cancels the hide.
    private var isHiding = false
    private var isHovering = false

    private override init() {
        super.init()
        // Switching to another app dismisses the HUD, so Return there can't replace text back in the original app
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                let hud = TranslationHudController.shared
                guard let pid, hud.model.targetPid > 0, pid != hud.model.targetPid,
                      pid != ProcessInfo.processInfo.processIdentifier else { return }
                hud.hide()
            }
        }
    }

    /// Whether the translation window is on screen (and not fading out).
    public var isVisible: Bool {
        guard let p = panel else { return false }
        return p.isVisible && !isHiding
    }

    /// Whether a plain Return should replace the selection right now (checked by the event tap).
    public var acceptsReturn: Bool {
        guard let p = panel, p.isVisible, !isHiding else { return false }
        return !model.isPreview && !model.isLoading && model.errorMessage == nil
            && model.targetPid > 0 && !(model.selected?.text.isEmpty ?? true)
    }

    /// A voice for `language`, or nil when the system has none (the speak button is then hidden).
    public static func voice(for language: SwaprLanguage) -> AVSpeechSynthesisVoice? {
        // Voices are registered by region ("zh-CN"), not by script ("zh-Hans")
        let code = ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW"][language.code] ?? language.code
        if let v = AVSpeechSynthesisVoice(language: code) { return v }
        let base = String(code.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix(base) }
    }

    /// On macOS 15–25 Apple translation must run through SwiftUI's `translationTask`, which handles one
    /// known source and one target; everything else (incl. all of macOS 26+) goes through TranslationEngine.
    public nonisolated static func appleHandledByHud(direction: String) -> Bool {
        if #available(macOS 26.0, *) { return false }
        guard #available(macOS 15.0, *), SwaprTransConfig.storedProvider == .apple,
              let dir = SwaprDirection.parse(direction) else { return false }
        return dir.from != nil && dir.to.count == 1
    }

    /// Opacity is applied to the card background by TranslationHudView, which observes the config.
    public func updateOpacity(_ opacity: Double) {}

    /// Reads result `index` aloud in its own language, or stops it if it is the one already speaking.
    public func toggleSpeech(index: Int) {
        let synth = speechSynthesizer ?? {
            let s = AVSpeechSynthesizer()
            s.delegate = self
            speechSynthesizer = s
            return s
        }()
        let wasSpeaking = model.speakingIndex
        stopSpeech()
        guard wasSpeaking != index, model.results.indices.contains(index) else { return }
        let result = model.results[index]
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let voice = Self.voice(for: result.language) else { return }
        let utterance = AVSpeechUtterance(string: result.text)
        utterance.voice = voice
        model.speakingIndex = index
        currentUtterance = utterance
        synth.speak(utterance)
    }

    private func stopSpeech() {
        model.speakingIndex = nil
        currentUtterance = nil
        speechSynthesizer?.stopSpeaking(at: .immediate)
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        self.speechSynthesizer(synthesizer, didFinish: utterance)
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // The synthesizer may hand back a copy of the utterance, so match it by its text
        let text = utterance.speechString
        Task { @MainActor in
            // Ignore the end of an utterance that was already replaced by another one
            guard let current = self.currentUtterance, current.speechString == text else { return }
            self.currentUtterance = nil
            self.model.speakingIndex = nil
        }
    }

    /// Copies `text`, keeping the window open.
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.declareTypes([.string], owner: nil)
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// All results, one per line; labelled with their language when there are several.
    private func allResults(labelled: Bool) -> String {
        let multi = model.results.count > 1
        return model.results.map { labelled && multi ? "\($0.language.short): \($0.text)" : $0.text }.joined(separator: "\n")
    }

    private func createRootView() -> TranslationHudView {
        return TranslationHudView(
            model: model,
            onToggleDirection: {
                TranslateMonitor.shared.toggleDirectionAndRetranslate()
            },
            onReplace: { [weak self] index in
                guard let self = self, self.model.results.indices.contains(index) else { return }
                self.replaceSelection(with: self.model.results[index].text, in: self.model.targetPid)
            },
            onCopy: { [weak self] index in
                guard let self = self, self.model.results.indices.contains(index) else { return }
                self.copy(self.model.results[index].text)
            },
            onReplaceAll: { [weak self] in
                guard let self = self else { return }
                self.replaceSelection(with: self.allResults(labelled: false), in: self.model.targetPid)
            },
            onCopyAll: { [weak self] in
                guard let self = self else { return }
                self.copy(self.allResults(labelled: true))
            },
            onSpeak: { [weak self] index in
                self?.toggleSpeech(index: index)
            },
            onRetry: {
                TranslateMonitor.shared.retryTranslation()
            },
            onHover: { [weak self] inside in
                self?.isHovering = inside
            },
            onClose: { [weak self] in
                self?.hide()
            }
        )
    }

    private func ensurePanelCreated() {
        if panel == nil {
            let p = NonActivatingPanel(width: 380)
            p.level = .floating
            p.isMovableByWindowBackground = true
            // One hosting view for the panel's lifetime: it observes the model and resizes the panel itself,
            // so updates change the content in place instead of rebuilding the view (no flicker)
            let hv = ClickThroughHostingView(rootView: createRootView())
            p.host(hv)
            self.hostingView = hv
            self.panel = p
            // The panel grows/shrinks with its content after it appears; keep the global click monitor's
            // hit rect current, or clicks on the right side of a widened window count as "outside" and hide it
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                NotificationCenter.default.addObserver(forName: name, object: p, queue: .main) { [weak p] _ in
                    MainActor.assumeIsolated {
                        if let p, p.isVisible { TranslateMonitor.cachedHudFrame = p.frame }
                    }
                }
            }
        }
    }

    /// Instant feedback: Show HUD immediately with loading indicator (0ms latency)
    public func showLoading(original: String, targetPid: pid_t, forcedDirection: String? = nil, at point: CGPoint? = nil) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        stopSpeech()

        let direction = SwaprLanguagePair.current.resolve(text: original, forcedDirection: forcedDirection).label

        model.original = original
        model.results = []
        model.selectedIndex = 0
        model.direction = direction
        model.provider = "Translating..."
        model.targetPid = targetPid
        model.isLoading = true
        model.errorMessage = nil
        model.isPreview = false

        if let p = panel, p.isVisible, !isHiding {
            updatePanelContentAndGeometry()
        } else {
            presentPanel(at: point)
        }
    }

    /// Update HUD in-place when async translation completes, dynamically resizing window
    public func updateTranslation(results: [SwaprTranslation], direction: String, provider: String) {
        model.results = results
        model.selectedIndex = 0
        model.direction = direction
        model.provider = provider
        model.isLoading = false
        model.errorMessage = nil

        updatePanelContentAndGeometry()
        startAutoDismissTimer()
    }

    /// Show error message in-place with retry button
    public func showError(message: String) {
        model.isLoading = false
        model.errorMessage = message
        model.provider = "Failed"

        updatePanelContentAndGeometry()
    }

    /// Direct display without loading state (backwards compatibility)
    public func show(original: String, translated: String, direction: String, provider: String, targetPid: pid_t, at point: CGPoint? = nil, preview: Bool = false) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        stopSpeech()

        let language = SwaprDirection.parse(direction)?.to.first ?? SwaprLanguage.byCode("en")!
        model.original = original
        model.results = [SwaprTranslation(language: language, text: translated)]
        model.selectedIndex = 0
        model.direction = direction
        model.provider = provider
        model.targetPid = targetPid
        model.isLoading = false
        model.errorMessage = nil
        model.isPreview = preview

        if let p = panel, p.isVisible, !isHiding {
            updatePanelContentAndGeometry()
        } else {
            presentPanel(at: point)
        }
        startAutoDismissTimer()
    }

    private func presentPanel(at point: CGPoint? = nil) {
        ensurePanelCreated()
        guard let p = panel, let hv = hostingView else { return }
        // Cancels a fade-out still in progress, so its completion doesn't hide this new content
        isHiding = false

        hv.layoutSubtreeIfNeeded()
        let size = hv.fittingSize

        // Below-right of the cursor; flipped above it when there is no room underneath
        let mouseLoc = point ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLoc) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var top = mouseLoc.y - 15
        if top - size.height < screen.minY + 8 {
            top = min(mouseLoc.y + 25 + size.height, screen.maxY - 8)
        }
        p.anchorTopLeft = NSPoint(x: mouseLoc.x + 10, y: min(top, screen.maxY - 8))
        p.setFrame(NSRect(origin: .zero, size: size), display: true)

        // Smooth fade-in animation
        p.alphaValue = 0
        p.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }

        TranslateMonitor.isHudVisible = true
        TranslateMonitor.cachedHudFrame = p.frame
        TranslateMonitor.hudShownDate = Date()
    }

    /// The hosting view resizes the panel as the model changes; this just records the settled frame.
    public func updatePanelContentAndGeometry() {
        guard let p = panel, p.isVisible else { return }
        hostingView?.layoutSubtreeIfNeeded()
        TranslateMonitor.cachedHudFrame = p.frame
    }

    private func startAutoDismissTimer(after interval: Double? = nil) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        let delay = interval ?? Double(SwaprTransConfig.shared.autoDismissSeconds)
        guard delay > 0, let p = panel, p.isVisible, !isHiding else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Never cut off speech or close under the pointer: check again shortly
                if self.model.speakingIndex != nil || self.isHovering {
                    self.startAutoDismissTimer(after: 1)
                } else {
                    self.hide()
                }
            }
        }
        // .common keeps it running while a window is dragged or a menu is open
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }

    public func hide() {
        guard let p = panel, p.isVisible, !isHiding else { return }
        isHiding = true
        isHovering = false
        dismissTimer?.invalidate()
        dismissTimer = nil
        TranslateMonitor.isHudVisible = false
        TranslateMonitor.cachedHudFrame = .zero
        TranslateMonitor.shared.cancelCurrentTranslation()
        stopSpeech()

        // Smooth fade-out animation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A show() during the fade cleared isHiding and owns the panel now
                guard let self = self, self.isHiding else { return }
                self.isHiding = false
                p.orderOut(nil)
            }
        })
    }

    /// Supports pressing Enter to trigger replacement directly
    public func triggerReplaceFromEnterKey() {
        guard acceptsReturn else { return }
        replaceSelection(with: model.translated, in: model.targetPid)
    }

    private var isReplacing: Bool = false

    private func replaceSelection(with text: String, in pid: pid_t) {
        // Without the app the text came from, Cmd+V would land in whatever happens to be frontmost
        guard !isReplacing, !text.isEmpty, pid > 0, !model.isPreview else { return }
        isReplacing = true
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.isReplacing = false
            }
        }

        // 1. Hide HUD floating window first to yield screen overlay
        hide()

        // 2. Write translated text to system pasteboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.declareTypes([.string], owner: nil)
        NSPasteboard.general.setString(text, forType: .string)

        // 3. Ensure target frontmost application is active and focused
        if pid > 0, let app = NSRunningApplication(processIdentifier: pid) {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            }
        }

        // 4. Wait 60ms for focus transition, then post physical Cmd + V on background thread
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.postCmdVPaste()
        }
    }

    private nonisolated func postCmdVPaste() {
        let src = CGEventSource(stateID: .hidSystemState)

        // Command key down (0x37)
        let modDown = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: true)
        modDown?.flags = .maskCommand

        // V key down (0x09)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        vDown?.flags = .maskCommand

        // V key up (0x09)
        let vUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        vUp?.flags = .maskCommand

        // Command key up (0x37)
        let modUp = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: false)
        modUp?.flags = []

        // Post single Cmd + V sequence to system HID event tap
        modDown?.post(tap: .cghidEventTap)
        usleep(15_000)

        vDown?.post(tap: .cghidEventTap)
        usleep(25_000)

        vUp?.post(tap: .cghidEventTap)
        usleep(15_000)

        modUp?.post(tap: .cghidEventTap)
    }
}

public struct TranslationHudView: View {
    @ObservedObject var config = SwaprTransConfig.shared
    @ObservedObject var model: TranslationHudModel
    let onToggleDirection: () -> Void
    let onReplace: (Int) -> Void
    let onCopy: (Int) -> Void
    let onReplaceAll: () -> Void
    let onCopyAll: () -> Void
    let onSpeak: (Int) -> Void
    let onRetry: () -> Void
    let onHover: (Bool) -> Void
    let onClose: () -> Void

    @AppStorage(TranslationClickAction.storageKey) private var clickActionRaw: String = TranslationClickAction.replace.rawValue
    @State private var copiedIndex: Int? = nil
    @State private var copiedAll: Bool = false
    @State private var hoveredIndex: Int? = nil
    @State private var isHoveringDirection: Bool = false

    private static let resultFont = NSFont.systemFont(ofSize: 15, weight: .regular)
    private var isMulti: Bool { model.results.count > 1 }
    private var canAct: Bool { !model.isLoading && model.errorMessage == nil && !model.results.isEmpty }
    /// Previews have nothing to replace, so clicking copies there.
    private var clickAction: TranslationClickAction {
        model.isPreview ? .copy : (TranslationClickAction(rawValue: clickActionRaw) ?? .replace)
    }

    /// Fits the longest line of the shown text, between 340 and 540pt.
    private var cardWidth: CGFloat {
        let texts = (model.isLoading || model.results.isEmpty) ? [model.original] : model.results.map(\.text)
        var widest: CGFloat = 0
        for line in texts.flatMap({ $0.components(separatedBy: "\n") }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            widest = max(widest, (trimmed as NSString).size(withAttributes: [.font: Self.resultFont]).width)
        }
        let chrome: CGFloat = isMulti ? 32 + 56 : 32 + 16
        return max(340, min(540, ceil(widest) + chrome))
    }

    private var isLongText: Bool {
        let all = model.results.map(\.text).joined(separator: "\n")
        return all.count > 260 || all.components(separatedBy: "\n").count > 8
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            // Original text, one line
            Text(model.original.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            if isLongText {
                ScrollView(.vertical) { content }
                    .frame(maxHeight: 340)
            } else {
                content
            }

            if canAct && isMulti {
                allActions
            }
        }
        .padding(16)
        .frame(width: cardWidth)
        // The opacity setting controls only the background, so the text always stays fully legible
        .glassCard(.popover, solidity: config.hudOpacity)
        .onHover(perform: onHover)
        .applyAppleTranslation(model: model)
        .onChange(of: model.results.map(\.text)) { _, _ in
            copiedIndex = nil
            copiedAll = false
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            // Entire direction pill is clickable to reverse direction
            Button(action: onToggleDirection) {
                HStack(spacing: 6) {
                    Text(model.direction)
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isHoveringDirection ? Color.accentColor : .secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(isHoveringDirection ? 0.14 : 0.08)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringDirection = $0 }
            .help("Switch translation direction")
            .disabled(SwaprDirection.parse(model.direction)?.from == nil)

            Text(model.provider)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Translating…")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(minHeight: 28)
        } else if let errorMsg = model.errorMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(errorMsg)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Retry", action: onRetry)
                    .controlSize(.regular)
            }
        } else {
            VStack(alignment: .leading, spacing: isMulti ? 6 : 0) {
                ForEach(Array(model.results.enumerated()), id: \.offset) { index, result in
                    resultBlock(result, index: index)
                }
            }
        }
    }

    /// One translation: its text (clicking it runs the default action) and its own Speak / Copy / Replace.
    private func resultBlock(_ result: SwaprTranslation, index: Int) -> some View {
        // With several results, the highlighted one is what Return replaces
        let isSelected = isMulti && index == model.selectedIndex
        let isHovered = hoveredIndex == index
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if isMulti {
                    Text(result.language.short)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(isSelected ? Color.white : .secondary)
                        .frame(width: 30, height: 20)
                        .background(Capsule().fill(isSelected ? Color.accentColor : Color.primary.opacity(0.08)))
                }
                Text(result.text)
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture { runClickAction(index) }
            .help(clickAction == .replace ? "Click to replace the selection with this" : "Click to copy")

            HStack(spacing: 6) {
                if isMulti { Spacer().frame(width: 30) }
                if TranslationHudController.voice(for: result.language) != nil {
                    speakButton(index)
                }
                Button {
                    copy(index)
                } label: {
                    Label(copiedIndex == index ? "Copied" : "Copy", systemImage: copiedIndex == index ? "checkmark" : "doc.on.doc")
                }
                if !model.isPreview {
                    Button {
                        onReplace(index)
                    } label: {
                        Label("Replace", systemImage: "return")
                    }
                    .modifier(ProminentIf(isOn: !isMulti))
                    .help(!isMulti || isSelected ? "Replace the selection (Return)" : "Replace the selection with this")
                }
                Spacer()
            }
            .controlSize(.regular)
            .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, isMulti ? 8 : 0)
        .padding(.vertical, isMulti ? 8 : 0)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : (isMulti && isHovered ? Color.primary.opacity(0.05) : Color.clear))
        )
        .onHover { inside in
            hoveredIndex = inside ? index : (hoveredIndex == index ? nil : hoveredIndex)
            if inside && isMulti { model.selectedIndex = index }
        }
    }

    private func speakButton(_ index: Int) -> some View {
        let speaking = model.speakingIndex == index
        return Button {
            onSpeak(index)
        } label: {
            Image(systemName: speaking ? "stop.fill" : "speaker.wave.2.fill")
                .frame(width: 16)
        }
        .help(speaking ? "Stop" : "Read aloud")
    }

    private func copy(_ index: Int) {
        onCopy(index)
        copiedAll = false
        copiedIndex = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedIndex == index { copiedIndex = nil }
        }
    }

    private func runClickAction(_ index: Int) {
        switch clickAction {
        case .replace: onReplace(index)
        case .copy: copy(index)
        }
    }

    // MARK: All results

    private var allActions: some View {
        HStack(spacing: 8) {
            Text(model.isPreview ? "Preview" : "↵ replaces the highlighted line")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()

            Button {
                onCopyAll()
                copiedIndex = nil
                copiedAll = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedAll = false }
            } label: {
                Label(copiedAll ? "Copied" : "Copy All", systemImage: copiedAll ? "checkmark" : "doc.on.doc")
            }
            .controlSize(.large)

            if !model.isPreview {
                Button(action: onReplaceAll) {
                    Label("Replace All", systemImage: "text.badge.checkmark")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("Replace the selection with every translation, one per line")
            }
        }
        .font(.system(size: 13, weight: .medium))
    }
}

/// Bordered-prominent style only when `isOn`.
private struct ProminentIf: ViewModifier {
    let isOn: Bool
    func body(content: Content) -> some View {
        if isOn { content.buttonStyle(.borderedProminent) } else { content }
    }
}

// MARK: - Apple Native Translation (macOS 15.0+ Sequoia)
@available(macOS 15.0, *)
struct AppleTranslationModifier: ViewModifier {
    @ObservedObject var config = SwaprTransConfig.shared
    @ObservedObject var model: TranslationHudModel
    @State private var appleConfig: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(appleConfig) { session in
                guard TranslationHudController.appleHandledByHud(direction: model.direction), model.isLoading, !model.original.isEmpty else { return }
                do {
                    try await session.prepareTranslation()
                    let response = try await session.translate(model.original)
                    let target = SwaprDirection.parse(model.direction)?.to.first ?? SwaprLanguagePair.current.targets[0]
                    TranslationHudController.shared.updateTranslation(
                        results: [SwaprTranslation(language: target, text: response.targetText)],
                        direction: model.direction,
                        provider: "Apple (Native)"
                    )
                    SwaprTransConfig.shared.log("[Translation (Apple Native)] \"\(model.original.prefix(20))...\" ➔ \"\(response.targetText.prefix(20))...\"", level: .info)
                } catch {
                    SwaprTransConfig.shared.log("Apple translation unavailable (\(error.localizedDescription)), falling back to Microsoft...", level: .warning)
                    Task {
                        do {
                            let fallback = try await TranslationEngine.shared.translate(
                                text: model.original,
                                provider: .microsoft,
                                forcedDirection: model.direction
                            )
                            TranslationHudController.shared.updateTranslation(
                                results: fallback.results,
                                direction: fallback.direction,
                                provider: "\(fallback.actualProvider) (Fallback)"
                            )
                            SwaprTransConfig.shared.log("[Translation (\(fallback.actualProvider))] \"\(model.original.prefix(20))...\" ➔ \"\(fallback.results.first?.text.prefix(20) ?? "")...\"", level: .info)
                        } catch {
                            TranslationHudController.shared.showError(message: error.localizedDescription)
                            SwaprTransConfig.shared.log("Translation failed: \(error.localizedDescription)", level: .error)
                        }
                    }
                }
            }
            .onAppear {
                updateAppleConfig()
            }
            .onChange(of: model.isLoading) { _, loading in
                if loading {
                    updateAppleConfig()
                }
            }
            .onChange(of: model.direction) { _, _ in
                updateAppleConfig()
            }
            .onChange(of: config.provider) { _, _ in
                updateAppleConfig()
            }
    }

    private func updateAppleConfig() {
        guard TranslationHudController.appleHandledByHud(direction: model.direction), model.isLoading, !model.original.isEmpty,
              let parsed = SwaprDirection.parse(model.direction), let from = parsed.from else {
            appleConfig = nil
            return
        }
        let sourceLang = from.code
        let targetLang = parsed.to[0].code
        let newConfig = TranslationSession.Configuration(
            source: Locale.Language(identifier: sourceLang),
            target: Locale.Language(identifier: targetLang)
        )
        if appleConfig == nil {
            appleConfig = newConfig
        } else {
            appleConfig = newConfig
            appleConfig?.invalidate()
        }
    }
}

extension View {
    @ViewBuilder
    func applyAppleTranslation(model: TranslationHudModel) -> some View {
        if #available(macOS 15.0, *) {
            self.modifier(AppleTranslationModifier(model: model))
        } else {
            self
        }
    }
}
