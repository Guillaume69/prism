import Foundation
import NaturalLanguage

/// Une langue de traduction : code BCP 47 tel que l'attend Apple Translation, noms français et anglais.
struct TranslationLanguage: Hashable, Identifiable {
    /// « en », « zh-Hans », « pt-BR »…
    let code: String
    /// Nom français, en minuscules, comme dans une phrase : « japonais ».
    let french: String
    let english: String
    /// Autres noms reconnus par la recherche : « mandarin », « farsi »…
    var aliases: [String] = []

    var id: String { code }

    /// Le nom pour un titre ou un menu : « Japonais ».
    var title: String { french.prefix(1).uppercased() + french.dropFirst() }

    /// Le nom dans la langue elle-même : « 日本語 ».
    var nativeName: String {
        Locale(identifier: code).localizedString(forIdentifier: code) ?? english
    }

    /// Le code de langue sans région ni écriture : « zh », « pt ».
    var baseCode: String { String(code.prefix { $0 != "-" }) }

    var localeLanguage: Locale.Language { Locale.Language(identifier: code) }

    /// Tous les noms sous lesquels on peut la chercher, déjà normalisés.
    var searchNames: [String] { ([french, english] + aliases).map(\.normalizedForSearch) }
}

/// Les langues proposées : celles d'Apple Translation d'abord, puis d'autres, traduites par l'IA.
enum Languages {
    static let all: [TranslationLanguage] = [
        TranslationLanguage(code: "en", french: "anglais", english: "English"),
        TranslationLanguage(code: "fr", french: "français", english: "French"),
        TranslationLanguage(code: "de", french: "allemand", english: "German"),
        TranslationLanguage(code: "es", french: "espagnol", english: "Spanish", aliases: ["castillan"]),
        TranslationLanguage(code: "it", french: "italien", english: "Italian"),
        TranslationLanguage(code: "pt-BR", french: "portugais", english: "Portuguese", aliases: ["brésilien"]),
        TranslationLanguage(code: "nl", french: "néerlandais", english: "Dutch", aliases: ["hollandais", "flamand"]),
        TranslationLanguage(code: "ja", french: "japonais", english: "Japanese"),
        TranslationLanguage(code: "zh-Hans", french: "chinois simplifié", english: "Chinese Simplified", aliases: ["chinois", "chinese", "mandarin"]),
        TranslationLanguage(code: "zh-Hant", french: "chinois traditionnel", english: "Chinese Traditional", aliases: ["taïwanais"]),
        TranslationLanguage(code: "ko", french: "coréen", english: "Korean"),
        TranslationLanguage(code: "ru", french: "russe", english: "Russian"),
        TranslationLanguage(code: "uk", french: "ukrainien", english: "Ukrainian"),
        TranslationLanguage(code: "pl", french: "polonais", english: "Polish"),
        TranslationLanguage(code: "tr", french: "turc", english: "Turkish"),
        TranslationLanguage(code: "ar", french: "arabe", english: "Arabic"),
        TranslationLanguage(code: "hi", french: "hindi", english: "Hindi"),
        TranslationLanguage(code: "id", french: "indonésien", english: "Indonesian"),
        TranslationLanguage(code: "th", french: "thaï", english: "Thai", aliases: ["thai"]),
        TranslationLanguage(code: "vi", french: "vietnamien", english: "Vietnamese"),
        TranslationLanguage(code: "sv", french: "suédois", english: "Swedish"),
        TranslationLanguage(code: "da", french: "danois", english: "Danish"),
        TranslationLanguage(code: "nb", french: "norvégien", english: "Norwegian", aliases: ["bokmål"]),
        TranslationLanguage(code: "fi", french: "finnois", english: "Finnish", aliases: ["finlandais"]),
        TranslationLanguage(code: "cs", french: "tchèque", english: "Czech"),
        TranslationLanguage(code: "el", french: "grec", english: "Greek"),
        TranslationLanguage(code: "he", french: "hébreu", english: "Hebrew"),
        TranslationLanguage(code: "ro", french: "roumain", english: "Romanian"),
        TranslationLanguage(code: "hu", french: "hongrois", english: "Hungarian"),
        TranslationLanguage(code: "ca", french: "catalan", english: "Catalan"),
        TranslationLanguage(code: "fa", french: "persan", english: "Persian", aliases: ["farsi"]),
        TranslationLanguage(code: "ms", french: "malais", english: "Malay"),
        TranslationLanguage(code: "bg", french: "bulgare", english: "Bulgarian"),
        TranslationLanguage(code: "hr", french: "croate", english: "Croatian"),
        TranslationLanguage(code: "sk", french: "slovaque", english: "Slovak"),
        TranslationLanguage(code: "la", french: "latin", english: "Latin"),
    ]

    static func language(code: String?) -> TranslationLanguage? {
        guard let code else { return nil }
        if let exact = all.first(where: { $0.code == code }) { return exact }
        let base = String(code.prefix { $0 != "-" && $0 != "_" })
        // « zh-TW », « zh-HK » : chinois traditionnel ; « zh » seul : simplifié.
        if base == "zh" {
            let lowered = code.lowercased()
            return language(code: lowered.contains("hant") || lowered.hasSuffix("tw") || lowered.hasSuffix("hk") ? "zh-Hant" : "zh-Hans")
        }
        if base == "no" || base == "nn" { return language(code: "nb") }
        return all.first { $0.baseCode == base }
    }

    /// La langue du système, si elle est dans la liste ; l'anglais sinon.
    static var system: TranslationLanguage {
        for identifier in Locale.preferredLanguages {
            if let language = language(code: identifier) { return language }
        }
        return all[0]
    }

    /// La langue d'arrivée quand le texte est déjà dans la langue cible : celle du système, sinon l'anglais, sinon le français.
    static func alternate(for target: TranslationLanguage) -> TranslationLanguage {
        if system != target { return system }
        return target.code == "en" ? all[1] : all[0]
    }

    // MARK: - Recherche par nom

    /// Une langue nommée en toutes lettres dans une phrase (« in german », « en jap ») :
    /// trois caractères au moins, préfixe d'un nom français ou anglais. Les codes (« de ») ne comptent pas.
    static func named(_ text: String) -> TranslationLanguage? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).normalizedForSearch
        guard query.count >= 3, query.allSatisfy({ $0.isLetter || $0 == " " }) else { return nil }
        var best: (language: TranslationLanguage, score: Int)?
        for language in all {
            for name in language.searchNames {
                let score: Int
                if name == query {
                    score = 3
                } else if name.hasPrefix(query) {
                    score = 2
                } else if name.split(separator: " ").contains(where: { $0.hasPrefix(query) }) {
                    score = 1
                } else {
                    continue
                }
                if score > (best?.score ?? 0) { best = (language, score) }
            }
        }
        return best?.language
    }

    /// Recherche floue des menus de langue : « jap » trouve le japonais, « allem » l'allemand.
    static func search(_ text: String) -> [TranslationLanguage] {
        let query = text.normalizedForSearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        let scored: [(TranslationLanguage, Double)] = all.compactMap { language in
            var best: Double?
            for (index, name) in (language.searchNames + [language.nativeName.normalizedForSearch]).enumerated() {
                // Les noms français passent devant les noms anglais à score égal.
                if let score = Fuzzy.score(query, name).map({ $0 - Double(index) * 0.1 }), score > (best ?? -1) { best = score }
            }
            return best.map { (language, $0) }
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    // MARK: - Traduction en ligne

    /// Séparateurs entre le texte et la langue, du plus long au plus court.
    private static let separators = [" into ", " in ", " en "]

    /// « hello in german », « bonjour en anglais », « hola into french » : le texte et la langue cible.
    static func parseInline(_ query: String) -> (text: String, target: TranslationLanguage)? {
        var candidates: [Range<String.Index>] = []
        for separator in separators {
            var searchRange = query.startIndex..<query.endIndex
            while let range = query.range(of: separator, options: .caseInsensitive, range: searchRange) {
                candidates.append(range)
                searchRange = range.upperBound..<query.endIndex
            }
        }
        // La dernière occurrence d'abord : « made in france in german ».
        for range in candidates.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            let text = query[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"«»“”'"))
                .trimmingCharacters(in: .whitespaces)
            let languageName = String(query[range.upperBound...])
            guard !text.isEmpty, let language = named(languageName) else { continue }
            return (text, language)
        }
        return nil
    }

    // MARK: - Détection

    /// La langue d'un texte, par NaturalLanguage, en favorisant les langues de l'utilisateur sur les textes courts.
    static func detect(_ text: String) -> TranslationLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        let recognizer = NLLanguageRecognizer()
        var hints: [NLLanguage: Double] = [:]
        for language in all { hints[NLLanguage(rawValue: nlCode(language))] = 0.02 }
        hints[NLLanguage(rawValue: nlCode(system))] = 0.35
        hints[.english] = max(hints[.english] ?? 0, 0.3)
        recognizer.languageHints = hints
        recognizer.processString(trimmed)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence > 0.2 else { return nil }
        return self.language(code: language.rawValue)
    }

    private static func nlCode(_ language: TranslationLanguage) -> String {
        switch language.code {
        case "pt-BR": "pt"
        default: language.code
        }
    }
}

/// Mots et caractères d'un texte, pour l'en-tête de l'écran de traduction.
enum TextStats {
    static func words(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in count += 1 }
        return count
    }

    static func summary(_ text: String) -> String {
        let words = words(text)
        let characters = text.count
        return "\(words) mot\(words > 1 ? "s" : "") · \(characters) caractère\(characters > 1 ? "s" : "")"
    }
}
