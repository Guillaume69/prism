import AppKit
import Foundation
#if canImport(Translation)
import Translation
#endif

/// Les réglages de la traduction, dans UserDefaults (« translate.… »).
@MainActor
final class TranslatePreferences: ObservableObject {
    static let shared = TranslatePreferences()

    enum PrimaryAction: String, CaseIterable {
        case copy, paste
    }

    enum Engine: String, CaseIterable {
        /// Apple Translation quand la paire est installée, l'IA sinon.
        case automatic
        case apple
        case ai

        var title: String {
            switch self {
            case .automatic: "Automatique (Apple, sinon l’IA)"
            case .apple: "Apple Translation uniquement"
            case .ai: "IA uniquement"
            }
        }
    }

    private let defaults = UserDefaults.standard

    @Published var primaryAction: PrimaryAction {
        didSet { defaults.set(primaryAction.rawValue, forKey: "translate.primaryAction") }
    }

    @Published var engine: Engine {
        didSet { defaults.set(engine.rawValue, forKey: "translate.engine") }
    }

    /// Langue source par défaut : `nil` pour la détection automatique.
    @Published var defaultSource: String? {
        didSet { defaults.set(defaultSource ?? "auto", forKey: "translate.defaultSource") }
    }

    @Published var defaultTarget: String {
        didSet { defaults.set(defaultTarget, forKey: "translate.defaultTarget") }
    }

    /// Reprendre la dernière langue cible choisie plutôt que celle par défaut.
    @Published var rememberLastTarget: Bool {
        didSet { defaults.set(rememberLastTarget, forKey: "translate.rememberLastTarget") }
    }

    @Published var lastTarget: String? {
        didSet { defaults.set(lastTarget, forKey: "translate.lastTarget") }
    }

    /// Lancée par un raccourci, la commande part du texte sélectionné dans l'app au premier plan.
    @Published var useSelection: Bool {
        didSet { defaults.set(useSelection, forKey: "translate.useSelection") }
    }

    /// « hello in german » dans la recherche principale.
    @Published var inlineTranslation: Bool {
        didSet { defaults.set(inlineTranslation, forKey: "translate.inline") }
    }

    private init() {
        primaryAction = PrimaryAction(rawValue: defaults.string(forKey: "translate.primaryAction") ?? "") ?? .copy
        engine = Engine(rawValue: defaults.string(forKey: "translate.engine") ?? "") ?? .automatic
        let source = defaults.string(forKey: "translate.defaultSource")
        defaultSource = source == "auto" ? nil : Languages.language(code: source)?.code
        defaultTarget = Languages.language(code: defaults.string(forKey: "translate.defaultTarget"))?.code ?? Languages.system.code
        rememberLastTarget = defaults.object(forKey: "translate.rememberLastTarget") as? Bool ?? true
        lastTarget = defaults.string(forKey: "translate.lastTarget")
        useSelection = defaults.object(forKey: "translate.useSelection") as? Bool ?? true
        inlineTranslation = defaults.object(forKey: "translate.inline") as? Bool ?? true
    }

    /// La langue cible à l'ouverture de l'écran.
    var initialTarget: TranslationLanguage {
        let code = rememberLastTarget ? (lastTarget ?? defaultTarget) : defaultTarget
        return Languages.language(code: code) ?? Languages.system
    }

    var initialSource: TranslationLanguage? { Languages.language(code: defaultSource) }
}

/// Le résultat d'une traduction, avec le moteur qui l'a produite.
struct TranslationOutput: Equatable {
    enum Engine: Equatable {
        case apple
        case ai
        /// Rendu hors écran sans moteur disponible.
        case demo

        var label: String {
            switch self {
            case .apple: "Apple Translation · sur l’appareil"
            case .ai: "IA"
            case .demo: "Démonstration"
            }
        }

        var symbol: String {
            switch self {
            case .apple: "apple.logo"
            case .ai: "sparkles"
            case .demo: "theatermasks"
            }
        }
    }

    var text: String
    var source: TranslationLanguage?
    var target: TranslationLanguage
    var engine: Engine
}

/// Pourquoi une traduction n'a pas abouti, avec de quoi y remédier.
enum TranslationIssue: Error, Equatable {
    /// La paire est prise en charge par Apple mais ses langues ne sont pas téléchargées.
    case notInstalled(TranslationLanguage, TranslationLanguage)
    /// Apple ne traduit pas cette paire, et l'IA n'est pas là.
    case unsupported(TranslationLanguage, TranslationLanguage)
    /// macOS trop ancien pour Apple Translation, et pas d'IA.
    case noEngine
    /// Impossible de reconnaître la langue du texte.
    case undetectable
    case failed(String)

    var message: String {
        switch self {
        case .notInstalled(let source, let target):
            "Les langues \(source.french) et \(target.french) ne sont pas encore téléchargées pour la traduction sur l’appareil."
        case .unsupported(let source, let target):
            "Apple Translation ne traduit pas du \(source.french) vers le \(target.french). Activez l’IA pour cette paire."
        case .noEngine:
            "Aucun moteur de traduction : Apple Translation demande macOS 26, et l’IA n’est pas configurée."
        case .undetectable:
            "Langue du texte introuvable. Choisissez la langue source (⇧⌘P)."
        case .failed(let reason):
            reason
        }
    }
}

/// Traduit avec Apple Translation sur l'appareil quand c'est possible, sinon avec l'IA de Prism.
@MainActor
enum Translator {
    /// L'état d'une paire de langues dans Apple Translation.
    enum PairStatus: Equatable {
        case installed
        case downloadable
        case unsupported
        /// Le système ne propose pas `TranslationSession(installedSource:target:)`.
        case unavailable
    }

    static var isAppleAvailable: Bool {
        if #available(macOS 26, *) { return canImportTranslation }
        return false
    }

    private static var canImportTranslation: Bool {
        #if canImport(Translation)
        true
        #else
        false
        #endif
    }

    static var isAIAvailable: Bool { AppHooks.aiComplete != nil }

    static func status(from source: TranslationLanguage, to target: TranslationLanguage) async -> PairStatus {
        #if canImport(Translation)
        if #available(macOS 26, *) {
            switch await LanguageAvailability().status(from: source.localeLanguage, to: target.localeLanguage) {
            case .installed: return .installed
            case .supported: return .downloadable
            case .unsupported: return .unsupported
            @unknown default: return .unsupported
            }
        }
        #endif
        return .unavailable
    }

    /// Traduit `text` de `source` (détectée si `nil`) vers `target`.
    static func translate(_ text: String, from source: TranslationLanguage?, to target: TranslationLanguage) async throws -> TranslationOutput {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationIssue.failed("Rien à traduire") }
        let key = cacheKey(trimmed, source, target)
        if let cached = cache[key] { return cached }

        let detected = source ?? Languages.detect(trimmed)
        let engine = TranslatePreferences.shared.engine
        var appleIssue: TranslationIssue?

        if engine != .ai, let detected {
            switch await status(from: detected, to: target) {
            case .installed:
                if let output = try await translateWithApple(trimmed, from: detected, to: target) {
                    store(output, for: key)
                    return output
                }
            case .downloadable:
                appleIssue = .notInstalled(detected, target)
            case .unsupported:
                appleIssue = .unsupported(detected, target)
            case .unavailable:
                appleIssue = .noEngine
            }
        }

        if engine != .apple, isAIAvailable {
            let output = try await translateWithAI(trimmed, from: detected, to: target)
            store(output, for: key)
            return output
        }
        if detected == nil { throw TranslationIssue.undetectable }
        if engine == .ai { throw TranslationIssue.failed("L’IA n’est pas configurée : choisissez un autre moteur dans les réglages de la traduction.") }
        throw appleIssue ?? TranslationIssue.noEngine
    }

    /// Le résultat déjà en mémoire, pour l'afficher sans attendre (traduction en ligne).
    static func cached(_ text: String, from source: TranslationLanguage?, to target: TranslationLanguage) -> TranslationOutput? {
        cache[cacheKey(text.trimmingCharacters(in: .whitespacesAndNewlines), source, target)]
    }

    // MARK: - Moteurs

    private static func translateWithApple(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage) async throws -> TranslationOutput? {
        #if canImport(Translation)
        if #available(macOS 26, *) {
            let session = TranslationSession(installedSource: source.localeLanguage, target: target.localeLanguage)
            do {
                let response = try await session.translate(text)
                return TranslationOutput(text: response.targetText, source: source, target: target, engine: .apple)
            } catch {
                throw TranslationIssue.failed("Apple Translation : \(error.localizedDescription)")
            }
        }
        #endif
        return nil
    }

    static func aiPrompt(from source: TranslationLanguage?, to target: TranslationLanguage) -> String {
        let from = source.map { " from \($0.english)" } ?? ""
        return """
        You are a translation engine. Translate the user's text\(from) into \(target.english). \
        Reply with the translation only: no quotes, no notes, no explanations, no transliteration. \
        Keep the meaning, tone, formatting, line breaks, emojis, URLs, code and proper nouns. \
        If the text is already in \(target.english), return it unchanged.
        """
    }

    private static func translateWithAI(_ text: String, from source: TranslationLanguage?, to target: TranslationLanguage) async throws -> TranslationOutput {
        guard let complete = AppHooks.aiComplete else { throw TranslationIssue.noEngine }
        do {
            var answer = try await complete(text, aiPrompt(from: source, to: target)).trimmingCharacters(in: .whitespacesAndNewlines)
            // Certains modèles entourent la réponse de guillemets que le texte n'avait pas.
            for (open, close) in [("\"", "\""), ("«", "»"), ("“", "”")] where answer.hasPrefix(open) && answer.hasSuffix(close) && !text.hasPrefix(open) && answer.count > 2 {
                answer = String(answer.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
            return TranslationOutput(text: answer, source: source, target: target, engine: .ai)
        } catch {
            throw TranslationIssue.failed("IA : \(error.localizedDescription)")
        }
    }

    // MARK: - Cache

    private static var cache: [String: TranslationOutput] = [:]
    private static var cacheOrder: [String] = []

    private static func cacheKey(_ text: String, _ source: TranslationLanguage?, _ target: TranslationLanguage) -> String {
        "\(source?.code ?? "auto")>\(target.code)|\(text)"
    }

    private static func store(_ output: TranslationOutput, for key: String) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = output
        if cacheOrder.count > 300 { cache[cacheOrder.removeFirst()] = nil }
    }

    // MARK: - Langues

    /// Les réglages de macOS où l'on télécharge les langues de traduction.
    static func openLanguageSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Localization-Settings.extension?translation",
            "x-apple.systempreferences:com.apple.Localization-Settings.extension",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }
}

/// `Prism --translate-test "texte" [code cible]` : traduit sur l'appareil, sans interface ni téléchargement.
@MainActor
enum TranslateCommandLineTest {
    static func run(arguments: [String]) -> Int32 {
        guard let index = arguments.firstIndex(of: "--translate-test"), index + 1 < arguments.count else {
            print("Usage : Prism --translate-test \"texte\" [code cible]")
            return 1
        }
        let text = arguments[index + 1]
        let target = Languages.language(code: index + 2 < arguments.count ? arguments[index + 2] : nil) ?? Languages.language(code: "fr") ?? Languages.system
        var exitCode: Int32 = 1
        var done = false
        Task { @MainActor in
            let detected = Languages.detect(text)
            print("Détecté : \(detected?.french ?? "inconnu")")
            if let detected {
                print("État de la paire \(detected.code) → \(target.code) : \(await Translator.status(from: detected, to: target))")
            }
            for code in ["en", "fr", "de", "es", "ja"] {
                guard let language = Languages.language(code: code), language != target else { continue }
                print("  \(code) → \(target.code) : \(await Translator.status(from: language, to: target))")
            }
            do {
                let output = try await Translator.translate(text, from: nil, to: target)
                print("[\(output.engine.label)] \(output.text)")
                exitCode = 0
            } catch let issue as TranslationIssue {
                print("Échec : \(issue.message)")
            } catch {
                print("Échec : \(error.localizedDescription)")
            }
            done = true
        }
        let deadline = Date().addingTimeInterval(30)
        while !done, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return exitCode
    }
}
