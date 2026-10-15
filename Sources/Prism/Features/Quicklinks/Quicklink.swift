import AppKit

/// Un lien rapide : une adresse, un fichier, un lien profond ou une recherche avec placeholders,
/// ouvert depuis la recherche principale (« yt lofi »).
struct Quicklink: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var link: String
    /// Chemin de l'application qui l'ouvre, `nil` pour celle par défaut.
    var openWith: String?
    /// Symbole SF ; `nil` : favicon pour le web, icône du fichier ou de l'application sinon.
    var iconName: String?
    var tags: [String] = []
    var isPinned = false
    var createdAt = Date()
    var updatedAt = Date()

    init(id: UUID = UUID(), name: String, link: String, openWith: String? = nil, iconName: String? = nil, tags: [String] = []) {
        self.id = id
        self.name = name
        self.link = link
        self.openWith = openWith
        self.iconName = iconName
        self.tags = tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        link = try container.decode(String.self, forKey: .link)
        openWith = try container.decodeIfPresent(String.self, forKey: .openWith)
        iconName = try container.decodeIfPresent(String.self, forKey: .iconName)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    /// L'identifiant de la commande dans la recherche principale (alias, raccourci, favoris).
    var commandID: String { "quicklink:" + id.uuidString }
}

/// Le modèle d'un lien : placeholders, encodage, adresse finale. Logique pure, vérifiée par les autotests.
enum QuicklinkTemplate {
    /// `{query}` des anciens liens de Raycast devient un argument nommé « Recherche ».
    static func normalized(_ link: String) -> String {
        link.replacingOccurrences(of: "{query}", with: #"{argument name="Recherche"}"#, options: .caseInsensitive)
    }

    static func arguments(_ link: String) -> [ItemArgument] {
        Placeholders.arguments(in: normalized(link))
    }

    static func isFilePath(_ link: String) -> Bool {
        let trimmed = link.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/") || trimmed.hasPrefix("~")
    }

    /// Le lien développé : les valeurs sont encodées pour une adresse, pas pour un chemin de fichier.
    static func expand(_ link: String, values: [String], context: Placeholders.Context) -> String {
        let template = normalized(link)
        var context = context
        context.usage = isFilePath(template) ? .plain : .quicklink
        context.arguments = Placeholders.argumentValues(values, for: template)
        return Placeholders.expand(template, context: context).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// L'adresse à ouvrir : chemin, lien avec un schéma (`https:`, `mailto:`, `spotify:`…), ou domaine nu (https).
    static func url(for expanded: String) -> URL? {
        guard !expanded.isEmpty else { return nil }
        if isFilePath(expanded) {
            return URL(fileURLWithPath: (expanded as NSString).expandingTildeInPath)
        }
        if expanded.contains("://") || expanded.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:(?![0-9])"#, options: .regularExpression) != nil {
            return URL(string: expanded) ?? expanded.addingPercentEncoding(withAllowedCharacters: .urlLinkAllowed).flatMap(URL.init(string:))
        }
        let candidate = "https://" + expanded
        return URL(string: candidate) ?? candidate.addingPercentEncoding(withAllowedCharacters: .urlLinkAllowed).flatMap(URL.init(string:))
    }

    /// Une adresse représentative, sans valeur d'argument ni lecture du presse-papiers : pour l'icône et « Ouvrir avec ».
    static func sampleURL(_ link: String) -> URL? {
        var context = Placeholders.Context()
        context.clipboard = { _ in nil }
        context.browserTab = { nil }
        return url(for: expand(link, values: [], context: context))
    }

    /// Ce qu'on affiche du lien : le domaine pour le web, le chemin abrégé pour un fichier.
    static func display(_ link: String) -> String {
        if isFilePath(link) { return (link as NSString).abbreviatingWithTildeInPath }
        if let url = sampleURL(link), let host = url.host, url.scheme?.hasPrefix("http") == true {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return link
    }
}

extension CharacterSet {
    /// Caractères gardés tels quels quand on encode un lien entier saisi à la main.
    static let urlLinkAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.insert(charactersIn: "#%")
        return set
    }()
}

// MARK: - Bibliothèque par défaut

enum QuicklinkLibrary {
    struct Entry {
        let id: String
        let name: String
        let link: String
        let alias: String
    }

    private static let search = #"{argument name="Recherche"}"#

    /// Identifiants fixes : les alias posés au premier lancement restent valables.
    static let entries: [Entry] = [
        Entry(id: "51C4A001-0000-4000-8000-000000000001", name: "Google", link: "https://www.google.com/search?q=" + search, alias: "g"),
        Entry(id: "51C4A001-0000-4000-8000-000000000002", name: "YouTube", link: "https://www.youtube.com/results?search_query=" + search, alias: "yt"),
        Entry(id: "51C4A001-0000-4000-8000-000000000003", name: "GitHub", link: "https://github.com/search?q=" + search, alias: "gh"),
        Entry(id: "51C4A001-0000-4000-8000-000000000004", name: "Wikipédia", link: "https://fr.wikipedia.org/w/index.php?search=" + search, alias: "wiki"),
        Entry(id: "51C4A001-0000-4000-8000-000000000005", name: "Plans", link: "https://maps.apple.com/?q=" + #"{argument name="Lieu"}"#, alias: "maps"),
        Entry(id: "51C4A001-0000-4000-8000-000000000006", name: "DuckDuckGo", link: "https://duckduckgo.com/?q=" + search, alias: "ddg"),
        Entry(id: "51C4A001-0000-4000-8000-000000000007", name: "Google Traduction", link: "https://translate.google.com/?sl=auto&tl=fr&op=translate&text=" + #"{argument name="Texte"}"#, alias: "tr"),
        Entry(id: "51C4A001-0000-4000-8000-000000000008", name: "MDN", link: "https://developer.mozilla.org/fr/search?q=" + search, alias: "mdn"),
        Entry(id: "51C4A001-0000-4000-8000-000000000009", name: "Amazon", link: "https://www.amazon.fr/s?k=" + search, alias: "amz"),
        Entry(id: "51C4A001-0000-4000-8000-00000000000A", name: "Stack Overflow", link: "https://stackoverflow.com/search?q=" + search, alias: "so"),
    ]

    static var links: [Quicklink] {
        entries.map { entry in
            Quicklink(id: UUID(uuidString: entry.id) ?? UUID(), name: entry.name, link: entry.link, tags: ["Recherche web"])
        }
    }

    /// Les alias par défaut, sans écraser un alias existant ni en prendre un déjà utilisé.
    @MainActor
    static func installAliases() {
        let config = CommandConfigStore.shared
        let used = Set(config.data.commands.values.compactMap(\.alias))
        for entry in entries where !used.contains(entry.alias) {
            guard let id = UUID(uuidString: entry.id) else { continue }
            let commandID = "quicklink:" + id.uuidString
            if config.alias(for: commandID) == nil {
                config.update(commandID) { $0.alias = entry.alias }
            }
        }
    }
}

// MARK: - Import et export

struct QuicklinkExchange: Codable, Equatable {
    var name: String?
    var link: String
    var openWith: String?
    var iconName: String?
    var tags: [String]?
}

enum QuicklinkTransfer {
    struct Report {
        var added: [Quicklink]
        var skipped: Int
    }

    enum Failure: Error { case unreadable }

    static func decode(_ data: Data) throws -> [QuicklinkExchange] {
        if let list = try? JSONDecoder().decode([QuicklinkExchange].self, from: data) { return list }
        struct Wrapped: Decodable { let quicklinks: [QuicklinkExchange] }
        if let wrapped = try? JSONDecoder().decode(Wrapped.self, from: data) { return wrapped.quicklinks }
        throw Failure.unreadable
    }

    /// Ajoute ce qui est nouveau : un lien déjà présent (même adresse) est ignoré, comme une entrée sans lien.
    /// `resolveApp` transforme `openWith` (chemin, identifiant de paquet ou nom) en chemin d'application.
    static func merge(_ incoming: [QuicklinkExchange], into existing: [Quicklink], resolveApp: (String) -> String? = { _ in nil }) -> Report {
        var links = Set(existing.map { $0.link.trimmingCharacters(in: .whitespacesAndNewlines) })
        var report = Report(added: [], skipped: 0)
        for entry in incoming {
            let link = entry.link.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !link.isEmpty, !links.contains(link) else {
                report.skipped += 1
                continue
            }
            links.insert(link)
            let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? QuicklinkTemplate.display(link)
            let app = entry.openWith?.nilIfEmpty.flatMap(resolveApp)
            report.added.append(Quicklink(name: name, link: link, openWith: app, iconName: entry.iconName?.nilIfEmpty, tags: entry.tags ?? []))
        }
        return report
    }

    static func export(_ links: [Quicklink]) -> Data {
        let entries = links.map {
            QuicklinkExchange(name: $0.name, link: $0.link, openWith: $0.openWith, iconName: $0.iconName, tags: $0.tags.isEmpty ? nil : $0.tags)
        }
        return (try? JSONEncoder.prism.encode(entries)) ?? Data("[]".utf8)
    }

    /// Un chemin d'application, un identifiant de paquet ou un nom (« Safari »).
    @MainActor
    static func resolveApp(_ value: String) -> String? {
        let fileManager = FileManager.default
        if value.hasSuffix(".app"), fileManager.fileExists(atPath: (value as NSString).expandingTildeInPath) {
            return (value as NSString).expandingTildeInPath
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: value) { return url.path }
        for folder in ["/Applications", "/System/Applications", "/Applications/Utilities", "/System/Applications/Utilities"] {
            let path = folder + "/" + value + ".app"
            if fileManager.fileExists(atPath: path) { return path }
        }
        return nil
    }
}

// MARK: - Données

/// Les liens rapides, gardés dans `quicklinks.json`. Au premier lancement, la bibliothèque par défaut est créée
/// avec ses alias. Sans interface (`--selftest`, `--snapshot`), rien n'est écrit.
@MainActor
final class QuicklinkStore: ObservableObject {
    static let shared = QuicklinkStore()

    @Published private(set) var links: [Quicklink]
    private let file: JSONStore<[Quicklink]>?

    private init() {
        let store = JSONStore("quicklinks.json", default: [Quicklink]())
        let exists = FileManager.default.fileExists(atPath: store.url.path)
        if SnippetStore.isHeadless {
            file = nil
            links = exists ? store.value : QuicklinkLibrary.links
        } else {
            file = store
            if exists {
                links = store.value
            } else {
                links = QuicklinkLibrary.links
                store.value = links
                QuicklinkLibrary.installAliases()
            }
        }
    }

    private func commit(_ change: (inout [Quicklink]) -> Void) {
        change(&links)
        if let file {
            file.value = links
        } else {
            NotificationCenter.default.post(name: .prismDataDidChange, object: nil)
        }
    }

    func link(id: UUID) -> Quicklink? { links.first { $0.id == id } }

    var allTags: [String] {
        var tags: [String] = []
        for tag in links.flatMap(\.tags) where !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            tags.append(tag)
        }
        return tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func save(_ link: Quicklink) {
        commit { list in
            var link = link
            link.updatedAt = Date()
            if let index = list.firstIndex(where: { $0.id == link.id }) {
                list[index] = link
            } else {
                list.append(link)
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

    func add(_ new: [Quicklink]) {
        guard !new.isEmpty else { return }
        commit { $0 += new }
    }

    /// Remet les liens de la bibliothèque par défaut qui manquent, et leurs alias. Le nombre de liens remis.
    @discardableResult
    func restoreLibrary() -> Int {
        let missing = QuicklinkLibrary.links.filter { link in !links.contains { $0.id == link.id || $0.link == link.link } }
        add(missing)
        if file != nil { QuicklinkLibrary.installAliases() }
        return missing.count
    }

    func flush() { file?.flush() }
}
