import AppKit

/// Un snippet : un texte réutilisable, collé depuis la recherche ou développé en tapant son mot-clé.
struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var text: String
    var keyword: String?
    var tags: [String] = []
    var isPinned = false
    var createdAt = Date()
    var updatedAt = Date()
    var useCount = 0
    var lastUsedAt: Date?

    init(id: UUID = UUID(), name: String, text: String, keyword: String? = nil, tags: [String] = [], isPinned: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.text = text
        self.keyword = keyword
        self.tags = tags
        self.isPinned = isPinned
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    /// Lecture tolérante : un fichier écrit à la main ou par une version antérieure reste lisible.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        text = try container.decode(String.self, forKey: .text)
        keyword = try container.decodeIfPresent(String.self, forKey: .keyword)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        useCount = try container.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }
}

/// Règles de saisie des snippets, comme celles de Raycast.
enum SnippetRules {
    static let maxLength = 65_000

    /// Caractères refusés dans un mot-clé : espaces, guillemets, apostrophes et accents graves.
    private static let forbidden: Set<Character> = ["\"", "'", "`", "’", "‘", "“", "”", "«", "»"]

    /// Le message d'erreur d'un mot-clé, `nil` s'il est valable (un mot-clé vide l'est).
    static func keywordError(_ keyword: String) -> String? {
        guard !keyword.isEmpty else { return nil }
        if keyword.contains(where: { $0.isWhitespace || $0.isNewline }) { return "Le mot-clé ne peut pas contenir d’espace" }
        if keyword.contains(where: { forbidden.contains($0) }) { return "Le mot-clé ne peut pas contenir de guillemet, d’apostrophe ni d’accent grave" }
        if keyword.count > 64 { return "Le mot-clé est trop long (64 caractères au plus)" }
        return nil
    }

    /// « Travail, perso , » → ["Travail", "perso"], sans doublon.
    static func parseTags(_ text: String) -> [String] {
        var result: [String] = []
        for part in text.split(separator: ",") {
            let tag = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tag.isEmpty, !result.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { result.append(tag) }
        }
        return result
    }

    /// Le nom donné à un snippet sans nom : sa première ligne, raccourcie.
    static func defaultName(for text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "Snippet"
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }
}

// MARK: - Correspondance des mots-clés

enum ExpansionMode: String, CaseIterable {
    /// Dès que le dernier caractère du mot-clé est tapé.
    case immediate
    /// Après un délimiteur : espace, ponctuation, retour, tabulation.
    case delimiter
}

struct KeywordMatch: Equatable {
    let keyword: String
    /// Caractères déjà reçus par l'application, à effacer (la touche qui déclenche est retenue).
    let charactersToDelete: Int
    /// Le délimiteur tapé, retenu lui aussi (mode « après un délimiteur »).
    let delimiter: Character?
}

/// Cherche un mot-clé à la fin du tampon des caractères tapés. Logique pure, vérifiée par les autotests.
enum KeywordMatcher {
    static func isDelimiter(_ character: Character) -> Bool {
        character.isWhitespace || character.isNewline || character.isPunctuation
    }

    /// `buffer` : les caractères déjà tapés ; `typed` : celui qui arrive, pas encore transmis à l'application.
    static func match(buffer: String, typed: Character, keywords: [String], mode: ExpansionMode, insideWords: Bool) -> KeywordMatch? {
        let candidates = keywords.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        switch mode {
        case .immediate:
            let text = buffer + String(typed)
            for keyword in candidates where text.hasSuffix(keyword) {
                if isAtBoundary(text.dropLast(keyword.count), keyword: keyword, insideWords: insideWords) {
                    return KeywordMatch(keyword: keyword, charactersToDelete: keyword.count - 1, delimiter: nil)
                }
            }
        case .delimiter:
            guard isDelimiter(typed) else { return nil }
            for keyword in candidates where buffer.hasSuffix(keyword) {
                if isAtBoundary(buffer.dropLast(keyword.count), keyword: keyword, insideWords: insideWords) {
                    return KeywordMatch(keyword: keyword, charactersToDelete: keyword.count, delimiter: typed)
                }
            }
        }
        return nil
    }

    /// Un mot-clé qui commence par une lettre ou un chiffre doit commencer un mot ; « ;sig » ou « !date »
    /// se développent partout, comme dans Raycast.
    private static func isAtBoundary(_ before: Substring, keyword: String, insideWords: Bool) -> Bool {
        guard !insideWords, let first = keyword.first, first.isLetter || first.isNumber, let previous = before.last else { return true }
        return !(previous.isLetter || previous.isNumber)
    }
}

// MARK: - Import et export

/// Le format d'échange de Raycast : un tableau d'objets `name`, `text`, `keyword` facultatif.
struct SnippetExchange: Codable, Equatable {
    var name: String?
    var text: String
    var keyword: String?
    var tags: [String]?
}

enum SnippetTransfer {
    struct Report {
        var added: [Snippet]
        var skipped: Int
    }

    enum Failure: Error { case unreadable }

    /// Un tableau d'objets, ou un objet `{ "snippets": [...] }`.
    static func decode(_ data: Data) throws -> [SnippetExchange] {
        if let list = try? JSONDecoder().decode([SnippetExchange].self, from: data) { return list }
        struct Wrapped: Decodable { let snippets: [SnippetExchange] }
        if let wrapped = try? JSONDecoder().decode(Wrapped.self, from: data) { return wrapped.snippets }
        throw Failure.unreadable
    }

    /// Ajoute ce qui est nouveau : sont ignorés les doublons (même nom, texte et mot-clé), les mots-clés déjà pris
    /// et les entrées invalides.
    static func merge(_ incoming: [SnippetExchange], into existing: [Snippet], now: Date = Date()) -> Report {
        func key(_ name: String, _ text: String, _ keyword: String?) -> String { name + "\u{1F}" + text + "\u{1F}" + (keyword ?? "") }
        var seen = Set(existing.map { key($0.name, $0.text, $0.keyword) })
        var keywords = Set(existing.compactMap(\.keyword))
        var report = Report(added: [], skipped: 0)
        for entry in incoming {
            let text = entry.text
            let keyword = entry.keyword?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let trimmedName = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = trimmedName.isEmpty ? SnippetRules.defaultName(for: text) : trimmedName
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= SnippetRules.maxLength,
                  SnippetRules.keywordError(keyword ?? "") == nil,
                  !seen.contains(key(name, text, keyword)),
                  keyword.map({ !keywords.contains($0) }) ?? true else {
                report.skipped += 1
                continue
            }
            seen.insert(key(name, text, keyword))
            if let keyword { keywords.insert(keyword) }
            report.added.append(Snippet(name: name, text: text, keyword: keyword, tags: entry.tags ?? [], createdAt: now))
        }
        return report
    }

    static func export(_ snippets: [Snippet]) -> Data {
        let entries = snippets.map { SnippetExchange(name: $0.name, text: $0.text, keyword: $0.keyword, tags: $0.tags.isEmpty ? nil : $0.tags) }
        return (try? JSONEncoder.prism.encode(entries)) ?? Data("[]".utf8)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Données

/// Les snippets, gardés dans `snippets.json`. Sans interface (`--selftest`, `--snapshot`), rien n'est écrit :
/// les données réelles restent intactes, et des exemples remplacent un fichier absent.
@MainActor
final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()

    @Published private(set) var snippets: [Snippet]
    private let file: JSONStore<[Snippet]>?

    static var isHeadless: Bool {
        CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--snapshot")
    }

    private init() {
        let store = JSONStore("snippets.json", default: [Snippet]())
        if Self.isHeadless {
            file = nil
            snippets = FileManager.default.fileExists(atPath: store.url.path) ? store.value : Self.examples
        } else {
            file = store
            snippets = store.value
        }
    }

    private func commit(_ change: (inout [Snippet]) -> Void) {
        change(&snippets)
        if let file {
            file.value = snippets
        } else {
            NotificationCenter.default.post(name: .prismDataDidChange, object: nil)
        }
    }

    func snippet(id: UUID) -> Snippet? { snippets.first { $0.id == id } }

    func snippet(keyword: String) -> Snippet? { snippets.first { $0.keyword == keyword } }

    /// Pour `{snippet name="…"}` : le nom, sans tenir compte de la casse.
    func snippet(named name: String) -> Snippet? {
        snippets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    var keywords: [String] { snippets.compactMap(\.keyword) }

    var allTags: [String] {
        var tags: [String] = []
        for tag in snippets.flatMap(\.tags) where !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            tags.append(tag)
        }
        return tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func save(_ snippet: Snippet) {
        commit { list in
            var snippet = snippet
            snippet.updatedAt = Date()
            if let index = list.firstIndex(where: { $0.id == snippet.id }) {
                list[index] = snippet
            } else {
                list.append(snippet)
            }
        }
    }

    func delete(_ id: UUID) {
        commit { $0.removeAll { $0.id == id } }
    }

    func togglePin(_ id: UUID) {
        commit { list in
            if let index = list.firstIndex(where: { $0.id == id }) { list[index].isPinned.toggle() }
        }
    }

    func recordUse(_ id: UUID) {
        commit { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            list[index].useCount += 1
            list[index].lastUsedAt = Date()
        }
    }

    func add(_ new: [Snippet]) {
        guard !new.isEmpty else { return }
        commit { $0 += new }
    }

    /// Écrit tout de suite, avant un export.
    func flush() { file?.flush() }

    /// Exemples des rendus hors écran, quand aucun fichier n'existe.
    private static let examples: [Snippet] = [
        Snippet(name: "Signature", text: "Bien cordialement,\n\nCamille Martin\nResponsable produit · Exemple SAS\n01 23 45 67 89", keyword: ";sig", tags: ["Travail"], isPinned: true),
        Snippet(name: "Réponse à un message", text: "Bonjour {argument name=\"prénom\"},\n\nMerci pour votre message. Je reviens vers vous {argument name=\"délai\" options=\"aujourd’hui, demain, cette semaine\"}.\n\n{cursor}\n\nBien cordialement,\nCamille", keyword: ";rep", tags: ["Travail"]),
        Snippet(name: "Adresse e-mail", text: "camille.martin@exemple.fr", keyword: "@@", tags: ["Perso"]),
        Snippet(name: "Date du jour", text: "{date format=\"d MMMM yyyy\"}", keyword: "!date"),
        Snippet(name: "Lien de visioconférence", text: "Voici le lien de la réunion : https://meet.exemple.fr/{clipboard | trim}", keyword: ";visio", tags: ["Travail"]),
        Snippet(name: "Adresse postale", text: "12 rue des Lilas\n75011 Paris\nFrance", keyword: ";adr", tags: ["Perso"]),
    ]
}
