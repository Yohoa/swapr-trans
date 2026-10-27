import Foundation
import NaturalLanguage

/// A language the translator can work with. `code` is the BCP-47 identifier used by
/// Apple's Translation framework, Microsoft Edge and NaturalLanguage; `google` is Google's variant.
public struct SwaprLanguage: Identifiable, Hashable, Sendable {
    public let code: String
    public let google: String
    public let short: String
    public let name: String
    public var id: String { code }

    public var isChinese: Bool { code == "zh-Hans" }

    public static let all: [SwaprLanguage] = [
        .init(code: "zh-Hans", google: "zh-CN", short: "ZH", name: "Chinese (Simplified)"),
        .init(code: "en", google: "en", short: "EN", name: "English"),
        .init(code: "nl", google: "nl", short: "NL", name: "Dutch"),
        .init(code: "de", google: "de", short: "DE", name: "German"),
        .init(code: "fr", google: "fr", short: "FR", name: "French"),
        .init(code: "es", google: "es", short: "ES", name: "Spanish"),
        .init(code: "it", google: "it", short: "IT", name: "Italian"),
        .init(code: "pt", google: "pt", short: "PT", name: "Portuguese"),
        .init(code: "ru", google: "ru", short: "RU", name: "Russian"),
        .init(code: "ja", google: "ja", short: "JA", name: "Japanese"),
        .init(code: "ko", google: "ko", short: "KO", name: "Korean"),
    ]

    public static func byCode(_ code: String) -> SwaprLanguage? { all.first { $0.code == code } }
    public static func byShort(_ short: String) -> SwaprLanguage? { all.first { $0.short == short } }

    /// The user's system languages that we support, used when auto-detected text
    /// is already in the only target language.
    static var systemPreferred: [SwaprLanguage] {
        Locale.preferredLanguages.compactMap { id in
            guard let base = Locale.Language(identifier: id).languageCode?.identifier else { return nil }
            return base == "zh" ? byCode("zh-Hans") : byCode(base)
        }
    }
}

/// A resolved translation direction: one source (nil = undetected, the service detects it) to 1–3 targets.
public struct SwaprDirection: Equatable, Sendable {
    public let from: SwaprLanguage?
    public let to: [SwaprLanguage]

    public init(from: SwaprLanguage?, to: [SwaprLanguage]) {
        self.from = from
        self.to = to
    }

    /// Label like "NL ➔ EN · DE"; "AUTO" when the source is undetected.
    public var label: String {
        "\(from?.short ?? SwaprLanguagePair.autoShort) ➔ \(to.map(\.short).joined(separator: " · "))"
    }

    /// Parses a label produced by `label` back into a direction.
    public static func parse(_ label: String) -> SwaprDirection? {
        let parts = label.components(separatedBy: " ➔ ")
        guard parts.count == 2 else { return nil }
        var from: SwaprLanguage? = nil
        if parts[0] != SwaprLanguagePair.autoShort {
            guard let f = SwaprLanguage.byShort(parts[0]) else { return nil }
            from = f
        }
        let to = parts[1].components(separatedBy: " · ").compactMap(SwaprLanguage.byShort)
        guard !to.isEmpty else { return nil }
        return SwaprDirection(from: from, to: to)
    }
}

/// The configured languages: a source (a fixed language, or nil for auto-detect) and 1–3 targets.
/// Defaults to the original Chinese ⇄ English behaviour.
///
/// - Fixed source S: text detected as one of the targets is translated back to S; anything else goes S ➔ targets.
/// - Auto source: the text's language is detected and it is translated into every target it is not already in.
public struct SwaprLanguagePair: Sendable {
    public static let sourceKey = "swapr_trans_source_language"
    public static let targetsKey = "swapr_trans_target_languages"
    public static let autoCode = "auto"
    public static let autoShort = "AUTO"
    public static let maxTargets = 3

    // Keys from the single-pair version, read as defaults so existing settings carry over.
    static let legacyPrimaryKey = "swapr_trans_primary_language"
    static let legacySecondaryKey = "swapr_trans_secondary_language"

    public let source: SwaprLanguage?
    public let targets: [SwaprLanguage]

    public var isAuto: Bool { source == nil }

    public init(source: SwaprLanguage?, targets: [SwaprLanguage]) {
        self.source = source
        var seen = Set<String>()
        var t = targets.filter { $0 != source && seen.insert($0.code).inserted }
        if t.isEmpty { t = [SwaprLanguage.all.first { $0 != source }!] }
        self.targets = Array(t.prefix(Self.maxTargets))
    }

    public static var storedSourceCode: String {
        let d = UserDefaults.standard
        return d.string(forKey: sourceKey) ?? d.string(forKey: legacyPrimaryKey) ?? "zh-Hans"
    }

    public static var storedTargetCodes: String {
        let d = UserDefaults.standard
        return d.string(forKey: targetsKey) ?? d.string(forKey: legacySecondaryKey) ?? "en"
    }

    public static var current: SwaprLanguagePair {
        let code = storedSourceCode
        let source = code == autoCode ? nil : (SwaprLanguage.byCode(code) ?? SwaprLanguage.byCode("zh-Hans")!)
        let targets = decodeTargets(storedTargetCodes)
        return SwaprLanguagePair(source: source, targets: targets.isEmpty ? [SwaprLanguage.byCode("en")!] : targets)
    }

    public static func decodeTargets(_ stored: String) -> [SwaprLanguage] {
        stored.split(separator: ",").compactMap { SwaprLanguage.byCode(String($0)) }
    }

    public static func encodeTargets(_ codes: [String]) -> String { codes.joined(separator: ",") }

    /// Decides the direction for `text`, honouring a direction forced from the HUD.
    public func resolve(text: String, forcedDirection: String? = nil) -> SwaprDirection {
        if let forced = forcedDirection, let parsed = SwaprDirection.parse(forced) { return parsed }

        if let source = source {
            if let d = Self.detect(text, among: [source] + targets), d != source, targets.contains(d) {
                return SwaprDirection(from: d, to: [source])
            }
            return SwaprDirection(from: source, to: targets)
        }

        guard let detected = Self.detect(text, among: SwaprLanguage.all) else {
            return SwaprDirection(from: nil, to: targets)
        }
        let remaining = targets.filter { $0 != detected }
        if !remaining.isEmpty { return SwaprDirection(from: detected, to: remaining) }
        // Text is already in the only target: fall back to the system language, then English, then Chinese.
        let fallback = (SwaprLanguage.systemPreferred + [SwaprLanguage.byCode("en")!, SwaprLanguage.byCode("zh-Hans")!])
            .first { $0 != detected }!
        return SwaprDirection(from: detected, to: [fallback])
    }

    /// The direction the HUD's switch button flips to: X ➔ [Y, …] becomes Y ➔ X, except that
    /// flipping back to the source restores all of its targets.
    public func reversed(_ label: String) -> String {
        guard let dir = SwaprDirection.parse(label), let oldFrom = dir.from, let newFrom = dir.to.first else { return label }
        // Flipping back to the source (the configured one, or a detected non-target one when auto)
        if newFrom == source || (isAuto && !targets.contains(newFrom)) {
            return SwaprDirection(from: newFrom, to: targets.filter { $0 != newFrom }).label
        }
        return SwaprDirection(from: newFrom, to: [oldFrom]).label
    }

    /// Detects which of `candidates` the text is written in.
    static func detect(_ text: String, among candidates: [SwaprLanguage]) -> SwaprLanguage? {
        var pool = candidates
        if let zh = pool.first(where: \.isChinese) {
            let hasKana = text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
            if hasKana, let ja = pool.first(where: { $0.code == "ja" }) { return ja }
            if !hasKana && TranslationEngine.isChineseDominant(text) { return zh }
            pool.removeAll(where: \.isChinese)
        }
        guard !pool.isEmpty else { return nil }
        if pool.count == 1 { return pool[0] }

        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = pool.map { NLLanguage(rawValue: $0.code) }
        recognizer.processString(text)
        let hyp = recognizer.languageHypotheses(withMaximum: pool.count)
        guard let best = hyp.max(by: { $0.value < $1.value }), best.value > 0 else { return nil }
        return SwaprLanguage.byCode(best.key.rawValue)
    }
}
