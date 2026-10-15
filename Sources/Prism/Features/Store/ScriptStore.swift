import AppKit
import SwiftUI

/// Le Store : les script commands publiques de la communauté Raycast (dépôt `raycast/script-commands`),
/// compatibles avec Prism, à installer d'un geste. L'équivalent du Store d'extensions de Raycast.
struct StoreScript: Codable, Identifiable, Hashable {
    struct Author: Codable, Hashable {
        var name: String?
        var url: String?
    }

    struct Icon: Codable, Hashable {
        var light: String?
        var dark: String?
    }

    var identifier: String
    var title: String
    var description: String?
    var filename: String
    var path: String
    var packageName: String?
    var language: String?
    var mode: String?
    var isTemplate: Bool?
    var hasArguments: Bool?
    var authors: [Author]?
    var icon: Icon?
    var updatedAt: String?
    /// Le groupe (« Ai › Gemini »), renseigné à la lecture de l'index.
    var group: String?

    var id: String { identifier }

    var rawURL: URL? {
        URL(string: "https://raw.githubusercontent.com/raycast/script-commands/master/commands/" + path + filename)
    }

    var pageURL: URL? {
        URL(string: "https://github.com/raycast/script-commands/blob/master/commands/" + path + filename)
    }

    /// Une icône emoji, ou l'adresse de l'image dans le dépôt.
    var itemIcon: ItemIcon? {
        guard let value = icon?.light ?? icon?.dark, !value.isEmpty else { return nil }
        if value.hasPrefix("http") { return URL(string: value).map { .remote($0, fallback: "terminal.fill") } }
        if value.contains("/") || value.contains(".") {
            let relative = value.hasPrefix("./") ? String(value.dropFirst(2)) : value
            return URL(string: "https://raw.githubusercontent.com/raycast/script-commands/master/commands/" + path + relative)
                .map { .remote($0, fallback: "terminal.fill") }
        }
        return .emoji(value)
    }

    var authorNames: String {
        (authors ?? []).compactMap(\.name).joined(separator: ", ")
    }
}

/// L'index du dépôt, gardé en cache un jour, et les scripts installés.
@MainActor
final class ScriptStore {
    static let shared = ScriptStore()

    static let indexURL = URL(string: "https://raw.githubusercontent.com/raycast/script-commands/master/commands/extensions.json")!

    private(set) var scripts: [StoreScript] = []
    private(set) var isLoading = false
    private(set) var lastError: String?
    private var cacheURL: URL { StoreLocation.file("store-index.json") }

    /// Les scripts installés depuis le Store : un sous-dossier des scripts de Prism.
    static var installDirectory: URL {
        StoreLocation.subdirectory("Scripts").appendingPathComponent("Store", isDirectory: true)
    }

    private init() {
        if let data = try? Data(contentsOf: cacheURL) {
            scripts = (try? Self.parse(data)) ?? []
        }
    }

    var groups: [String] {
        Array(Set(scripts.compactMap { $0.group?.components(separatedBy: " › ").first })).sorted()
    }

    func installedURL(for script: StoreScript) -> URL {
        Self.installDirectory.appendingPathComponent(script.path, isDirectory: true).appendingPathComponent(script.filename)
    }

    func isInstalled(_ script: StoreScript) -> Bool {
        FileManager.default.fileExists(atPath: installedURL(for: script).path)
    }

    /// Relit l'index s'il a plus d'un jour (ou s'il est forcé).
    func refresh(force: Bool = false, completion: @escaping @MainActor () -> Void) {
        let age = (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow } ?? .infinity
        guard force || scripts.isEmpty || age > 86_400, !isLoading else { return }
        isLoading = true
        lastError = nil
        let cacheURL = cacheURL
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: Self.indexURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let parsed = try Self.parse(data)
                try? data.write(to: cacheURL, options: .atomic)
                scripts = parsed
            } catch {
                lastError = "Index du Store indisponible : \(error.localizedDescription)"
            }
            isLoading = false
            completion()
        }
    }

    /// L'index est un arbre de groupes et de sous-groupes ; on l'aplatit.
    nonisolated static func parse(_ data: Data) throws -> [StoreScript] {
        struct Group: Decodable {
            var name: String
            var scriptCommands: [StoreScript]?
            var subGroups: [Group]?
        }
        struct Index: Decodable { var groups: [Group] }
        let index = try JSONDecoder().decode(Index.self, from: data)
        var result: [StoreScript] = []
        func visit(_ group: Group, path: [String]) {
            let names = path + [group.name]
            for var script in group.scriptCommands ?? [] {
                script.group = names.joined(separator: " › ")
                result.append(script)
            }
            for child in group.subGroups ?? [] { visit(child, path: names) }
        }
        index.groups.forEach { visit($0, path: []) }
        // Les modèles de génération (« {{commandtitle}} ») ne sont pas des scripts à installer.
        return result.filter { !$0.title.contains("{") && !$0.title.contains("$") }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func install(_ script: StoreScript) async throws -> URL {
        guard let url = script.rawURL else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { throw URLError(.badServerResponse) }
        let destination = installedURL(for: script)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        NotificationCenter.default.post(name: .prismScriptsDidChange, object: nil)
        return destination
    }

    func uninstall(_ script: StoreScript) {
        let url = installedURL(for: script)
        NSWorkspace.shared.recycle([url]) { _, _ in
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .prismScriptsDidChange, object: nil)
                NotificationCenter.default.post(name: .prismDataDidChange, object: nil)
            }
        }
    }

    /// Le code source, pour le relire avant d'installer.
    func source(of script: StoreScript) async -> String? {
        guard let url = script.rawURL, let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension Notification.Name {
    /// Un script a été ajouté ou retiré : les script commands relisent leurs dossiers.
    static let prismScriptsDidChange = Notification.Name("PrismScriptsDidChange")
}

/// L'écran du Store : liste filtrable par groupe, détail du script à droite.
@MainActor
final class StoreScreen: LauncherScreen {
    private var sources: [String: String] = [:]
    private var loadingSource: String?

    init() {
        super.init(id: "store", title: "Store", placeholder: "Rechercher des script commands…", icon: .symbol("bag.fill", Palette.indigo))
        layout = .split(listWidth: 330)
        updateFilter()
    }

    private func updateFilter() {
        let selected = filter?.selected ?? "all"
        filter = ScreenFilter(
            options: [ScreenFilter.Option(id: "all", title: "Tous les groupes"), ScreenFilter.Option(id: "installed", title: "Installés")]
                + ScriptStore.shared.groups.map { ScreenFilter.Option(id: $0, title: $0) },
            selected: selected
        )
    }

    override func didAppear() {
        let store = ScriptStore.shared
        isLoading = store.scripts.isEmpty
        store.refresh { [weak self] in
            guard let self else { return }
            self.isLoading = false
            self.updateFilter()
            self.reload()
        }
    }

    override func emptyState(query: String) -> (symbol: String, message: String) {
        if isLoading { return ("hourglass", "Chargement du Store…") }
        if let error = ScriptStore.shared.lastError { return ("wifi.exclamationmark", error) }
        return ("magnifyingglass", "Aucun script pour « \(query) »")
    }

    override func sections(query: String) -> [ResultSection] {
        let store = ScriptStore.shared
        let normalized = query.normalizedForSearch
        let selected = filter?.selected ?? "all"
        let matches = store.scripts.filter { script in
            switch selected {
            case "all": break
            case "installed": guard store.isInstalled(script) else { return false }
            default: guard script.group?.hasPrefix(selected) == true else { return false }
            }
            guard !normalized.isEmpty else { return true }
            return Fuzzy.score(normalized, script.title) != nil
                || Fuzzy.score(normalized, script.packageName ?? "") != nil
                || (script.description ?? "").normalizedForSearch.contains(normalized)
        }
        let items = matches.prefix(300).map(item)
        return items.isEmpty ? [] : [ResultSection(id: "store", title: normalized.isEmpty ? "\(matches.count) script commands" : "Résultats", items: Array(items))]
    }

    private func item(_ script: StoreScript) -> ResultItem {
        let store = ScriptStore.shared
        let installed = store.isInstalled(script)
        var metadata: [(label: String, value: String)] = [
            ("Groupe", script.group ?? "—"),
            ("Langage", script.language ?? "—"),
            ("Mode", script.mode ?? "—"),
        ]
        if !script.authorNames.isEmpty { metadata.append(("Auteurs", script.authorNames)) }
        if script.hasArguments == true { metadata.append(("Arguments", "Oui")) }
        if script.isTemplate == true { metadata.append(("Modèle", "À configurer après l’installation")) }
        metadata.append(("Installé", installed ? "Oui" : "Non"))

        var text = script.description ?? ""
        if let source = sources[script.id] {
            text += "\n\n```\(script.language ?? "")\n\(source.prefix(4_000))\n```"
        } else {
            text += "\n\n_⌘Y pour lire le code avant d’installer._"
        }

        var actions: [ItemAction] = []
        if installed {
            actions.append(ItemAction(title: "Ouvrir le script", symbol: "doc.text") {
                NSWorkspace.shared.open(store.installedURL(for: script))
                return .close
            })
            actions.append(ItemAction(title: "Afficher dans le Finder", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([store.installedURL(for: script)])
                return .close
            })
            actions.append(ItemAction(title: "Désinstaller", symbol: "trash", shortcut: .removeEntry, isDestructive: true) { [weak self] in
                store.uninstall(script)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.reload() }
                return .toast("« \(script.title) » désinstallé")
            })
        } else {
            actions.append(ItemAction(title: "Installer", symbol: "arrow.down.circle") { [weak self] in
                self?.install(script)
                return .stay
            })
        }
        actions.append(ItemAction(title: "Lire le code", symbol: "chevron.left.forwardslash.chevron.right", shortcut: .quickLook) { [weak self] in
            self?.loadSource(script)
            return .stay
        })
        if let page = script.pageURL {
            actions.append(ItemAction(title: "Voir sur GitHub", symbol: "safari") {
                NSWorkspace.shared.open(page)
                return .close
            })
        }
        return ResultItem(
            id: "store:" + script.id,
            title: script.title,
            subtitle: script.packageName,
            icon: script.itemIcon ?? .symbol("terminal.fill", Palette.gray),
            accessory: installed ? "✓ Installé" : script.language,
            detail: ItemDetail(text: text, metadata: metadata, isMarkdown: true),
            usageKey: "",
            actions: actions
        )
    }

    private func loadSource(_ script: StoreScript) {
        guard sources[script.id] == nil else { return }
        isLoading = true
        Task {
            let source = await ScriptStore.shared.source(of: script)
            sources[script.id] = source ?? "Code indisponible."
            isLoading = false
            reload()
        }
    }

    private func install(_ script: StoreScript) {
        isLoading = true
        Task {
            do {
                let url = try await ScriptStore.shared.install(script)
                isLoading = false
                reload()
                host?.showToast(script.isTemplate == true ? "Installé : à configurer avant usage" : "« \(script.title) » installé", isError: false)
                if script.isTemplate == true { NSWorkspace.shared.open(url) }
            } catch {
                isLoading = false
                host?.showToast("Installation impossible : \(error.localizedDescription)")
            }
        }
    }
}

@MainActor
enum StoreFeature: PrismFeature {
    static var commands: [ResultItem] {
        [Command.screen("store", "Store", subtitle: "Script commands de la communauté", symbol: "bag.fill", color: Palette.indigo, keywords: ["store", "extensions", "scripts", "installer", "boutique"]) { StoreScreen() }]
    }

    static func handle(url: URL) -> Bool {
        guard url.host == "store" else { return false }
        CommandRunner.run(id: "command:store")
        return true
    }

    static func selfTest(_ check: (Bool, String) -> Void) {
        let sample = """
        {"groups":[{"name":"Ai","path":"ai","scriptCommands":[],"subGroups":[{"name":"Gemini","path":"gemini","scriptCommands":[
        {"identifier":"x1","title":"Ask Gemini","filename":"gemini.js","path":"ai/gemini/","language":"node","mode":"silent"}]}]},
        {"name":"Apps","path":"apps","scriptCommands":[{"identifier":"x2","title":"Bonjour","filename":"hello.sh","path":"apps/"}]}]}
        """
        let parsed = (try? ScriptStore.parse(Data(sample.utf8))) ?? []
        check(parsed.count == 2, "index du Store aplati")
        check(parsed.first { $0.id == "x1" }?.group == "Ai › Gemini", "groupe et sous-groupe")
        check(parsed.first { $0.id == "x1" }?.rawURL?.absoluteString.hasSuffix("commands/ai/gemini/gemini.js") == true, "adresse du script brut")
    }
}
