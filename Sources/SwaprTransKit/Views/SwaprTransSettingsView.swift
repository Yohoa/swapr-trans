import SwiftUI
import AppKit

/// Width of the right-hand control column, so every row lines up.
private let settingsControlWidth: CGFloat = 200

/// Grouped settings, laid out like macOS System Settings: titled sections of label / control rows.
public struct SwaprTransSettingsView: View {
    @ObservedObject public var config: SwaprTransConfig = SwaprTransConfig.shared
    @State private var modelDownloadWarning: String? = nil
    @AppStorage(SwaprLanguagePair.sourceKey) private var sourceLanguage: String = SwaprLanguagePair.storedSourceCode
    @AppStorage(SwaprLanguagePair.targetsKey) private var targetLanguages: String = SwaprLanguagePair.storedTargetCodes
    @AppStorage(TranslationClickAction.storageKey) private var clickAction: String = TranslationClickAction.replace.rawValue

    public init() {}

    // MARK: - Language state (read from the view's own storage so pickers never lag)

    private var targetCodes: [String] {
        let pair = SwaprLanguagePair(
            source: sourceLanguage == SwaprLanguagePair.autoCode ? nil : SwaprLanguage.byCode(sourceLanguage),
            targets: SwaprLanguagePair.decodeTargets(targetLanguages)
        )
        return pair.targets.map(\.code)
    }

    private func saveTargets(_ codes: [String]) {
        targetLanguages = SwaprLanguagePair.encodeTargets(codes)
    }

    /// Choices for a target picker: anything that is not the source or another target.
    private func targetChoices(excluding index: Int?) -> [SwaprLanguage] {
        let taken = Set(targetCodes.enumerated().filter { $0.offset != index }.map(\.element) + [sourceLanguage])
        return SwaprLanguage.all.filter { !taken.contains($0.code) }
    }

    private var sourceBinding: Binding<String> {
        Binding(
            get: { sourceLanguage },
            set: { code in
                let remaining = targetCodes.filter { $0 != code }
                sourceLanguage = code
                saveTargets(remaining.isEmpty ? [SwaprLanguage.all.first { $0.code != code }!.code] : remaining)
            }
        )
    }

    private func targetBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { targetCodes.indices.contains(index) ? targetCodes[index] : "" },
            set: { code in
                var codes = targetCodes
                guard codes.indices.contains(index) else { return }
                codes[index] = code
                saveTargets(codes)
            }
        )
    }

    private var providerBinding: Binding<TranslationProvider> {
        Binding(
            get: { config.provider },
            set: { newProvider in
                // Switch immediately; warn (without reverting) if Apple's models are missing
                config.provider = newProvider
                modelDownloadWarning = nil
                guard newProvider == .apple else { return }
                Task { @MainActor in
                    switch await AppleTranslationChecker.checkStatus() {
                    case .installed:
                        modelDownloadWarning = nil
                    case .notDownloaded:
                        modelDownloadWarning = "Some on-device models aren't downloaded; those languages use Microsoft until you add them in System Settings ➔ General ➔ Language & Region ➔ Translation Languages."
                    case .unsupported:
                        modelDownloadWarning = "Apple on-device translation needs macOS 15 or newer; Microsoft is used instead."
                    }
                }
            }
        )
    }

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection("General") {
                SettingsRow("Auto translation") {
                    Toggle("", isOn: Binding(get: { config.isEnabled }, set: { _ in config.toggleEnabled() }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingsRow("Shortcut") {
                    Picker("", selection: $config.shortcut) {
                        ForEach(TranslationShortcut.presets) { Text($0.label).tag($0) }
                    }
                    .settingsMenu()
                }
                if config.shortcut.isRhythm {
                    RhythmRecorderRow()
                }
                SettingsRow("Engine") {
                    Picker("", selection: providerBinding) {
                        ForEach(TranslationProvider.allCases) { Text($0.displayName).tag($0) }
                    }
                    .settingsMenu()
                }
                if let warning = modelDownloadWarning {
                    Notice(text: warning) { modelDownloadWarning = nil }
                }
            }

            SettingsSection("Languages") {
                SettingsRow("From") {
                    Picker("", selection: sourceBinding) {
                        Text("Auto Detect").tag(SwaprLanguagePair.autoCode)
                        Divider()
                        ForEach(SwaprLanguage.all) { Text($0.name).tag($0.code) }
                    }
                    .settingsMenu()
                }
                ForEach(Array(targetCodes.enumerated()), id: \.element) { index, code in
                    SettingsRow(index == 0 ? "To" : "") {
                        HStack(spacing: 6) {
                            Picker("", selection: targetBinding(index)) {
                                ForEach(targetChoices(excluding: index)) { Text($0.name).tag($0.code) }
                            }
                            .settingsMenu(width: settingsControlWidth - 24)
                            Button {
                                saveTargets(targetCodes.filter { $0 != code })
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(targetCodes.count == 1)
                            .opacity(targetCodes.count == 1 ? 0.3 : 1)
                            .help("Remove this language")
                        }
                    }
                }
                if targetCodes.count < SwaprLanguagePair.maxTargets {
                    SettingsRow("") {
                        Button {
                            if let next = targetChoices(excluding: nil).first { saveTargets(targetCodes + [next.code]) }
                        } label: {
                            Label("Add Language", systemImage: "plus")
                        }
                        .controlSize(.regular)
                        .help("Translate into up to \(SwaprLanguagePair.maxTargets) languages at once")
                    }
                }
            }

            SettingsSection("Window") {
                SettingsRow("Auto dismiss") {
                    Picker("", selection: $config.autoDismissSeconds) {
                        Text("Never").tag(0)
                        Text("5 seconds").tag(5)
                        Text("10 seconds").tag(10)
                        Text("15 seconds").tag(15)
                        Text("20 seconds").tag(20)
                        Text("30 seconds").tag(30)
                    }
                    .settingsMenu()
                }
                SettingsRow("Click on translation") {
                    Picker("", selection: $clickAction) {
                        ForEach(TranslationClickAction.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .settingsMenu()
                }
                SettingsRow("Background") {
                    HStack(spacing: 8) {
                        Slider(value: $config.hudOpacity, in: 0.3...1.0, step: 0.05)
                        Text("\(Int((config.hudOpacity * 100).rounded()))%")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    .frame(width: settingsControlWidth)
                }
                SettingsRow("") {
                    Button("Preview Window") { showPreview() }
                        .controlSize(.regular)
                }
            }

            Text("Select text in any app, then \(triggerHint) to translate. Press Return to replace the selection.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private var triggerHint: String {
        guard config.shortcut.isRhythm else { return "press \(config.shortcut.label)" }
        return "tap your rhythm on \(config.rhythm.keyLabel)"
    }

    private func showPreview() {
        SwaprPreview.show()
    }
}

/// Shows the translation window with sample text in the configured languages.
@MainActor
public enum SwaprPreview {
    public static func show() {
        let config = SwaprTransConfig.shared
        let targets = SwaprLanguagePair.current.targets
        let samples: [String: String] = [
            "zh-Hans": "这是翻译窗口的预览。", "zh-Hant": "這是翻譯視窗的預覽。", "en": "This is a preview of the translation window.",
            "nl": "Dit is een voorbeeld van het vertaalvenster.", "de": "Dies ist eine Vorschau des Übersetzungsfensters.",
            "fr": "Ceci est un aperçu de la fenêtre de traduction.", "es": "Esta es una vista previa de la ventana de traducción.",
            "it": "Questa è un'anteprima della finestra di traduzione.", "pt": "Esta é uma prévia da janela de tradução.",
            "ru": "Это предварительный просмотр окна перевода.", "ja": "これは翻訳ウィンドウのプレビューです。",
            "ko": "번역 창의 미리보기입니다.",
        ]
        let source = SwaprLanguagePair.current.source ?? SwaprLanguage.all.first { !targets.contains($0) }!
        let direction = SwaprDirection(from: source, to: targets).label
        let hud = TranslationHudController.shared
        hud.show(original: samples[source.code] ?? samples["en"]!, translated: "", direction: direction,
                 provider: config.provider.displayName, targetPid: 0, preview: true)
        hud.updateTranslation(
            results: targets.map { SwaprTranslation(language: $0, text: samples[$0.code] ?? "") },
            direction: direction,
            provider: config.provider.displayName
        )
    }
}

// MARK: - Building blocks

/// A titled, rounded group of rows (System Settings style).
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 10) {
                content
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
    }
}

/// Label on the left, control right-aligned.
struct SettingsRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 8)
            control
        }
        .frame(minHeight: 24)
    }
}

private extension View {
    /// Regular-size pop-up menu filling the row's control column.
    func settingsMenu(width: CGFloat = settingsControlWidth) -> some View {
        self.pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.regular)
            .fixedSize()
            .frame(width: width, alignment: .trailing)
    }
}

/// Inline warning with a dismiss button.
struct Notice: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.14)))
    }
}
