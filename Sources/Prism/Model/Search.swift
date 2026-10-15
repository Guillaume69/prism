import Foundation

extension String {
    /// Minuscules, sans accents ni différences de largeur, apostrophes et tirets typographiques ramenés à ceux du clavier :
    /// « Réglages » se trouve en tapant « reglages », « Store d’extensions » en tapant « store d'extensions ».
    var normalizedForSearch: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
    }
}

/// Recherche floue à la manière de Raycast : préfixe, début de mot, initiales, sous-chaîne, puis sous-séquence.
enum Fuzzy {
    /// `query` doit déjà être normalisée.
    static func score(_ query: String, _ target: String) -> Double? {
        guard !query.isEmpty else { return 0 }
        let text = target.normalizedForSearch
        if text == query { return 100 }
        if text.hasPrefix(query) {
            return 90 - Double(min(text.count - query.count, 20)) * 0.25
        }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.contains(where: { $0.hasPrefix(query) }) { return 78 }
        if query.count >= 2 {
            let initials = String(words.compactMap(\.first))
            if initials.hasPrefix(query) { return 74 }
        }
        if text.contains(query) { return 62 }
        guard query.count >= 3, sensitivity > 0 else { return nil }
        let characters = Array(text)
        let wanted = Array(query)
        // La sous-séquence la plus serrée : les lettres doivent rester proches (« tlgrm » dans Telegram),
        // pas éparpillées dans toute la phrase (« feu » dans « Faire une pause »).
        var best: (span: Int, bonus: Double)?
        for start in characters.indices where characters[start] == wanted[0] {
            var position = start
            var bonus = start == 0 || !characters[start - 1].isLetter ? 3.0 : 0
            var matched = 1
            var previous = start
            while matched < wanted.count {
                position += 1
                guard position < characters.count else { break }
                if characters[position] == wanted[matched] {
                    if position == previous + 1 { bonus += 2 }
                    if !characters[position - 1].isLetter { bonus += 3 }
                    previous = position
                    matched += 1
                }
            }
            guard matched == wanted.count else { break }
            let span = previous - start + 1
            if best == nil || span < best!.span { best = (span, bonus) }
        }
        guard let best, Double(best.span) <= maxSpan(for: wanted.count) else { return nil }
        return 30 + min(best.bonus, 25)
    }

    /// Sensibilité de la recherche : 0 faible (pas de sous-séquence), 1 moyenne, 2 élevée.
    nonisolated(unsafe) static var sensitivity = 1

    /// L'étendue permise d'une sous-séquence : serrée pour une saisie courte, plus large ensuite.
    private static func maxSpan(for count: Int) -> Double {
        if sensitivity >= 2 { return Double(count) * 3 }
        return count <= 4 ? Double(count + 1) : Double(count) * 1.7
    }
}

/// Fréquence et récence d'utilisation (« frecency ») : ce qu'on lance souvent remonte.
@MainActor
final class UsageStore {
    static let shared = UsageStore()

    private struct Entry: Codable {
        var count: Int
        var last: Date
    }

    private let defaultsKey = "usage.v1"
    private var entries: [String: Entry] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    func record(_ key: String) {
        var entry = entries[key] ?? Entry(count: 0, last: .now)
        entry.count += 1
        entry.last = .now
        entries[key] = entry
        save()
    }

    /// Toutes les entrées : clé, nombre de lancements, dernier lancement (statistiques).
    var allEntries: [(key: String, count: Int, last: Date)] {
        entries.map { ($0.key, $0.value.count, $0.value.last) }
    }

    func reset(_ key: String) {
        entries[key] = nil
        save()
    }

    func boost(_ key: String) -> Double {
        guard let entry = entries[key] else { return 0 }
        let days = -entry.last.timeIntervalSinceNow / 86_400
        let recency = max(0, 1 - days / 30)
        return min(Double(entry.count), 10) * 1.2 + recency * 6
    }

    func topKeys(prefix: String? = nil, limit: Int) -> [String] {
        entries.keys
            .filter { prefix.map($0.hasPrefix) ?? true }
            .sorted { boost($0) > boost($1) }
            .prefix(limit)
            .map { $0 }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
