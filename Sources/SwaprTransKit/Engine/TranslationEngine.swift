import Foundation
import AppKit
import Translation

public enum AppleModelStatus: Equatable {
    case installed
    case notDownloaded
    case unsupported
}

@MainActor
public final class AppleTranslationChecker {
    /// Installed when every target has an installed model from the source (any source when auto-detecting).
    public static func checkStatus() async -> AppleModelStatus {
        if #available(macOS 15.0, *) {
            let availability = LanguageAvailability()
            let pair = SwaprLanguagePair.current
            let sources = pair.source.map { [$0] } ?? SwaprLanguage.all
            var allInstalled = true
            var anySupported = false
            for target in pair.targets {
                var installed = false
                for source in sources where source != target {
                    let status = await availability.status(from: Locale.Language(identifier: source.code), to: Locale.Language(identifier: target.code))
                    if status == .installed { installed = true; break }
                    if status == .supported { anySupported = true }
                }
                if !installed { allInstalled = false }
            }
            if allInstalled { return .installed }
            return anySupported ? .notDownloaded : .unsupported
        } else {
            return .unsupported
        }
    }
}

/// One translated result, for one target language.
public struct SwaprTranslation: Equatable, Sendable {
    public let language: SwaprLanguage
    public let text: String

    public init(language: SwaprLanguage, text: String) {
        self.language = language
        self.text = text
    }
}

public enum TranslationProvider: String, CaseIterable, Identifiable, Codable {
    case apple = "apple"
    /// Apple's on-device language model (macOS 26+, Apple silicon, Apple Intelligence turned on).
    case appleIntelligence = "apple_intelligence"
    case microsoft = "microsoft"
    case google = "google"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .apple: return "Apple (Native)"
        case .appleIntelligence: return "Apple Intelligence"
        case .microsoft: return "Microsoft (Edge)"
        case .google: return "Google Translate"
        }
    }
}

public actor TranslationEngine {
    public static let shared = TranslationEngine()

    private var cache: [String: (text: String, provider: String)] = [:]
    private let maxCacheSize = 200

    /// Dedicated ephemeral session: no disk caching/cookies, strict fast-fail timeouts for seamless failover
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3.5
        config.timeoutIntervalForResource = 5.0
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    private init() {}

    /// Determines whether the text should be primarily treated as Chinese based on weighted character density
    /// Chinese ideographs have roughly 2.8x higher semantic density than Latin letters
    public static func isChineseDominant(_ text: String) -> Bool {
        var hanCount = 0
        var latinCount = 0

        for scalar in text.unicodeScalars {
            // CJK Unified Ideographs (0x4E00...0x9FFF) and Extension A (0x3400...0x4DBF)
            if (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) {
                hanCount += 1
            } else if (0x0041...0x005A).contains(scalar.value) || (0x0061...0x007A).contains(scalar.value) {
                latinCount += 1
            }
        }

        // No Chinese at all -> English/Foreign dominant
        guard hanCount > 0 else { return false }
        // Has Chinese and no Latin -> pure Chinese
        guard latinCount > 0 else { return true }

        // An average English word contains ~5 characters.
        // 1 Chinese character roughly corresponds to 2.5-3 Latin characters in semantic weight.
        return Double(hanCount) * 2.8 >= Double(latinCount)
    }

    public func containsChinese(_ text: String) -> Bool {
        return TranslationEngine.isChineseDominant(text)
    }

    /// Main translation entry point: translates into every target of the resolved direction in parallel,
    /// each with automatic fallback between providers.
    public func translate(
        text: String,
        provider: TranslationProvider = .microsoft,
        forcedDirection: String? = nil
    ) async throws -> (results: [SwaprTranslation], direction: String, actualProvider: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pair = SwaprLanguagePair.current
        let direction = pair.resolve(text: trimmed, forcedDirection: forcedDirection)
        guard !trimmed.isEmpty else { return ([], direction.label, provider.displayName) }

        let outcomes = try await withThrowingTaskGroup(of: (Int, String, String).self) { group in
            for (index, target) in direction.to.enumerated() {
                group.addTask {
                    let (result, used) = try await self.translateOne(text: trimmed, from: direction.from, to: target, provider: provider)
                    return (index, result, used)
                }
            }
            var collected: [(Int, String, String)] = []
            for try await outcome in group { collected.append(outcome) }
            return collected.sorted { $0.0 < $1.0 }
        }

        let results = outcomes.map { SwaprTranslation(language: direction.to[$0.0], text: $0.1) }
        let providers = Array(Set(outcomes.map(\.2)))
        return (results, direction.label, providers.count == 1 ? providers[0] : providers.sorted().joined(separator: " + "))
    }

    /// Translates into a single target language. `from == nil` lets the service detect the source.
    private func translateOne(text: String, from: SwaprLanguage?, to: SwaprLanguage, provider: TranslationProvider) async throws -> (String, String) {
        let cacheKey = "\(provider.rawValue):\(from?.code ?? "auto"):\(to.code):\(text)"
        if let cached = cache[cacheKey] {
            return (cached.text, cached.provider)
        }

        let fromLang = from?.code ?? ""
        let fromGoogle = from?.google ?? "auto"
        var translatedText = ""
        var usedProvider = provider.displayName

        if provider == .appleIntelligence, let written = try? await AppleIntelligenceTranslator.translate(text: text, from: from, to: to) {
            translatedText = written
        } else if provider == .apple || provider == .appleIntelligence {
            // Apple Intelligence also lands here when it can't help (not enabled, language unsupported, error)
            if #available(macOS 26.0, *), let from = from, let native = try? await withTimeout(seconds: 4, { try await self.translateViaApple(text: text, from: from.code, to: to.code) }) {
                translatedText = native
                usedProvider = TranslationProvider.apple.displayName
            } else {
                do {
                    translatedText = try await translateViaMicrosoftEdge(text: text, from: fromLang, to: to.code)
                    usedProvider = "Microsoft (Edge)"
                } catch {
                    translatedText = try await translateViaGoogle(text: text, from: fromGoogle, to: to.google)
                    usedProvider = "Google (Fallback)"
                }
            }
        } else if provider == .microsoft {
            do {
                translatedText = try await translateViaMicrosoftEdge(text: text, from: fromLang, to: to.code)
            } catch {
                // Fallback to Google if Microsoft fails
                translatedText = try await translateViaGoogle(text: text, from: fromGoogle, to: to.google)
                usedProvider = "Google (Fallback)"
            }
        } else {
            do {
                translatedText = try await translateViaGoogle(text: text, from: fromGoogle, to: to.google)
            } catch {
                translatedText = try await translateViaMicrosoftEdge(text: text, from: fromLang, to: to.code)
                usedProvider = "Microsoft (Fallback)"
            }
        }

        if cache.count >= maxCacheSize, let firstKey = cache.keys.first {
            cache.removeValue(forKey: firstKey)
        }
        cache[cacheKey] = (translatedText, usedProvider)
        return (translatedText, usedProvider)
    }

    // MARK: - Apple On-Device Translation (macOS 26+, installed models only)
    @available(macOS 26.0, *)
    private func translateViaApple(text: String, from: String, to: String) async throws -> String {
        let session = TranslationSession(installedSource: Locale.Language(identifier: from), target: Locale.Language(identifier: to))
        let response = try await session.translate(text)
        return response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Microsoft Edge Translation (Fast API without Key)
    private func translateViaMicrosoftEdge(text: String, from: String, to: String) async throws -> String {
        guard let url = URL(string: "https://edge.microsoft.com/translate/translatetext?from=\(from)&to=\(to)&isEnterpriseClient=false") else {
            throw NSError(domain: "TranslationEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 3.5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0", forHTTPHeaderField: "User-Agent")
        req.setValue("https://edge.microsoft.com", forHTTPHeaderField: "Referer")
        req.httpBody = try JSONSerialization.data(withJSONObject: [text])

        let (data, response) = try await session.data(for: req)
        guard let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 else {
            throw NSError(domain: "TranslationEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Microsoft Edge HTTP status not 200"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = json.first,
              let translations = first["translations"] as? [[String: Any]],
              let result = translations.first?["text"] as? String else {
            throw NSError(domain: "TranslationEngine", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to parse Microsoft response"])
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Google Chrome Extension Translate (Fallback API)
    private func translateViaGoogle(text: String, from: String, to: String) async throws -> String {
        guard let encodedText = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://clients5.google.com/translate_a/t?client=dict-chrome-ex&sl=\(from)&tl=\(to)&q=\(encodedText)") else {
            throw NSError(domain: "TranslationEngine", code: -4, userInfo: [NSLocalizedDescriptionKey: "Invalid Google URL"])
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 3.5
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: req)
        guard let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 else {
            throw NSError(domain: "TranslationEngine", code: -5, userInfo: [NSLocalizedDescriptionKey: "Google HTTP status not 200"])
        }

        let json = try JSONSerialization.jsonObject(with: data)
        if let list = json as? [Any] {
            var combined = ""
            for item in list {
                if let str = item as? String {
                    combined += str
                } else if let subList = item as? [Any], let firstStr = subList.first as? String {
                    combined += firstStr
                }
            }
            if !combined.isEmpty {
                return combined.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        throw NSError(domain: "TranslationEngine", code: -6, userInfo: [NSLocalizedDescriptionKey: "Failed to parse Google response"])
    }
}
