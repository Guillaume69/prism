import AppKit
import SwiftUI

/// L'équipe, à la place de Raycast Teams : un dossier partagé (iCloud Drive partagé, Dropbox, serveur de fichiers…)
/// où chacun publie des snippets, des liens rapides, des commandes d'IA et des agents. Ils apparaissent chez tous
/// les membres dans la recherche principale, marqués « Équipe », et se copient dans ses propres données.
@MainActor
final class TeamLibrary {
    static let shared = TeamLibrary()

    static let folderKey = "team.folder"
    static let memberKey = "team.member"

    private(set) var snippets: [Snippet] = []
    private(set) var quicklinks: [Quicklink] = []
    private(set) var commands: [AICommandDefinition] = []
    private(set) var agents: [AIPreset] = []
    /// Identifiant → membre qui l'a partagé.
    private(set) var authors: [String: String] = [:]
    private var stamps: [String: Date] = [:]

    var folder: URL? {
        guard let path = UserDefaults.standard.string(forKey: Self.folderKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    var member: String {
        let name = UserDefaults.standard.string(forKey: Self.memberKey) ?? ""
        return name.isEmpty ? NSFullUserName() : name
    }

    enum File: String, CaseIterable {
        case snippets = "snippets.json", quicklinks = "quicklinks.json", commands = "ai-commands.json", agents = "ai-presets.json", authors = "shared-by.json"
    }

    /// Relit les fichiers qui ont changé (appelé à chaque recherche : un simple `stat` par fichier).
    func reloadIfChanged() {
        guard let folder else {
            if !stamps.isEmpty || !snippets.isEmpty { clear() }
            return
        }
        var changed = false
        for file in File.allCases {
            let url = folder.appendingPathComponent(file.rawValue)
            let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            if stamps[file.rawValue] != date {
                stamps[file.rawValue] = date
                changed = true
            }
        }
        guard changed else { return }
        snippets = read(.snippets) ?? []
        quicklinks = read(.quicklinks) ?? []
        commands = read(.commands) ?? []
        agents = read(.agents) ?? []
        authors = read(.authors) ?? [:]
    }

    private func clear() {
        snippets = []
        quicklinks = []
        commands = []
        agents = []
        authors = [:]
        stamps = [:]
    }

    private func read<T: Decodable>(_ file: File) -> T? {
        guard let folder, let data = try? Data(contentsOf: folder.appendingPathComponent(file.rawValue)) else { return nil }
        return try? JSONDecoder.prism.decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to file: File) throws {
        guard let folder else { throw TeamError.noFolder }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(file.rawValue)
        var coordinationError: NSError?
        var writeError: Error?
        let data = try JSONEncoder.prism.encode(value)
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let failure = writeError ?? coordinationError { throw failure }
        stamps[file.rawValue] = nil
        reloadIfChanged()
    }

    enum TeamError: LocalizedError {
        case noFolder
        var errorDescription: String? { "Choisissez d’abord le dossier de l’équipe (Réglages › Équipe)" }
    }

    // MARK: - Partager, retirer

    private func signed(_ id: String) throws {
        var all = authors
        all[id] = member
        try write(all, to: .authors)
    }

    func share(_ snippet: Snippet) throws {
        reloadIfChanged()
        try write(snippets.filter { $0.id != snippet.id } + [snippet], to: .snippets)
        try signed(snippet.id.uuidString)
    }

    func share(_ link: Quicklink) throws {
        reloadIfChanged()
        try write(quicklinks.filter { $0.id != link.id } + [link], to: .quicklinks)
        try signed(link.id.uuidString)
    }

    func share(_ command: AICommandDefinition) throws {
        reloadIfChanged()
        var copy = command
        copy.isBuiltIn = false
        try write(commands.filter { $0.id != command.id } + [copy], to: .commands)
        try signed(command.id)
    }

    func share(_ agent: AIPreset) throws {
        reloadIfChanged()
        var copy = agent
        copy.builtIn = nil
        try write(agents.filter { $0.id != agent.id } + [copy], to: .agents)
        try signed(agent.id.uuidString)
    }

    func unshare(snippet id: UUID) throws { try write(snippets.filter { $0.id != id }, to: .snippets) }
    func unshare(link id: UUID) throws { try write(quicklinks.filter { $0.id != id }, to: .quicklinks) }
    func unshare(command id: String) throws { try write(commands.filter { $0.id != id }, to: .commands) }
    func unshare(agent id: UUID) throws { try write(agents.filter { $0.id != id }, to: .agents) }

    func author(_ id: String) -> String? { authors[id] }
}

@MainActor
enum TeamFeature: PrismFeature {
    static var commands: [ResultItem] {
        let library = TeamLibrary.shared
        library.reloadIfChanged()
        var items: [ResultItem] = [
            Command.screen("team.browse", "Équipe", subtitle: "Partagé avec l’équipe", symbol: "person.3.fill", color: Palette.teal,
                           keywords: ["team", "teams", "équipe", "partagé", "shared"]) { browseScreen() },
            Command.screen("team.share", "Partager avec l’équipe", subtitle: "Équipe", symbol: "square.and.arrow.up.on.square", color: Palette.teal,
                           keywords: ["team", "share", "partager", "équipe"]) { shareScreen() },
        ]
        guard library.folder != nil else { return items }
        // Les liens rapides, snippets et commandes d'IA de l'équipe, comme les siens, dans la recherche principale.
        items += library.quicklinks.map(teamItem)
        items += library.snippets.map(teamItem)
        items += library.commands.map(teamItem)
        return items
    }

    // MARK: - Éléments de l'équipe

    private static func tagged(_ item: ResultItem, id: String, sharedID: String, extra: [ItemAction]) -> ResultItem {
        // Les actions d'édition visent ses propres données : retirées des éléments de l'équipe.
        let editing: Set<String> = ["Snippet", "Lien rapide", "Commande d’IA", "Commande"]
        let kept = item.actions.filter { action in action.section.map { !editing.contains($0) } ?? true }
        let author = TeamLibrary.shared.author(sharedID)
        return ResultItem(id: "team:" + id, title: item.title, subtitle: item.subtitle.map { s in author.map { "\(s) · \($0)" } ?? s } ?? author,
                          icon: item.icon, accessory: item.accessory, tags: ["Équipe"] + item.tags, style: item.style,
                          keywords: item.keywords + ["équipe", "team"], detail: item.detail, usageKey: "team:" + id,
                          actions: kept + extra, arguments: item.arguments, runWithArguments: item.runWithArguments, isConfigurable: false)
    }

    static func teamItem(_ link: Quicklink) -> ResultItem {
        tagged(QuicklinksFeature.item(for: link), id: "quicklink:" + link.id.uuidString, sharedID: link.id.uuidString, extra: [
            ItemAction(title: "Copier dans mes liens rapides", symbol: "plus.square.on.square", section: "Équipe") {
                var copy = link
                copy.id = UUID()
                QuicklinkStore.shared.add([copy])
                return .toast("« \(link.name) » ajouté à vos liens rapides")
            },
            ItemAction(title: "Retirer de l’équipe", symbol: "person.badge.minus", isDestructive: true, section: "Équipe") {
                attempt("« \(link.name) » retiré de l’équipe") { try TeamLibrary.shared.unshare(link: link.id) }
            },
        ])
    }

    static func teamItem(_ snippet: Snippet) -> ResultItem {
        tagged(SnippetsFeature.item(for: snippet), id: "snippet:" + snippet.id.uuidString, sharedID: snippet.id.uuidString, extra: [
            ItemAction(title: "Copier dans mes snippets", symbol: "plus.square.on.square", section: "Équipe") {
                var copy = snippet
                copy.id = UUID()
                SnippetStore.shared.add([copy])
                return .toast("« \(snippet.name) » ajouté à vos snippets")
            },
            ItemAction(title: "Retirer de l’équipe", symbol: "person.badge.minus", isDestructive: true, section: "Équipe") {
                attempt("« \(snippet.name) » retiré de l’équipe") { try TeamLibrary.shared.unshare(snippet: snippet.id) }
            },
        ])
    }

    static func teamItem(_ command: AICommandDefinition) -> ResultItem {
        tagged(AICommandRunner.item(command), id: "aicommand:" + command.id, sharedID: command.id, extra: [
            ItemAction(title: "Copier dans mes commandes d’IA", symbol: "plus.square.on.square", section: "Équipe") {
                var copy = command
                copy.id = UUID().uuidString
                AICommandStore.shared.content.custom.append(copy)
                return .toast("« \(command.name) » ajoutée à vos commandes d’IA")
            },
            ItemAction(title: "Retirer de l’équipe", symbol: "person.badge.minus", isDestructive: true, section: "Équipe") {
                attempt("« \(command.name) » retirée de l’équipe") { try TeamLibrary.shared.unshare(command: command.id) }
            },
        ])
    }

    static func teamItem(_ agent: AIPreset) -> ResultItem {
        let author = TeamLibrary.shared.author(agent.id.uuidString)
        return ResultItem(id: "team:agent:" + agent.id.uuidString, title: agent.name, subtitle: author.map { "Agent · \($0)" } ?? "Agent",
                          icon: .symbol(agent.symbol, Palette.violet), tags: ["Équipe"], keywords: ["agent", "équipe"], usageKey: "", actions: [
            ItemAction(title: "Ajouter à mes agents", symbol: "plus.square.on.square") {
                var copy = agent
                copy.id = UUID()
                AIPresetStore.shared.presets.append(copy)
                return .toast("« \(agent.name) » ajouté à vos agents")
            },
            Actions.copy(agent.instructions, title: "Copier les instructions", symbol: "doc.on.doc", hud: "Instructions copiées"),
            ItemAction(title: "Retirer de l’équipe", symbol: "person.badge.minus", isDestructive: true, section: "Équipe") {
                attempt("« \(agent.name) » retiré de l’équipe") { try TeamLibrary.shared.unshare(agent: agent.id) }
            },
        ])
    }

    private static func attempt(_ done: String, _ body: () throws -> Void) -> ActionOutcome {
        do {
            try body()
            return .then(.refresh, .toast(done))
        } catch {
            return .toast(error.localizedDescription)
        }
    }

    // MARK: - Écrans

    static func browseScreen() -> LauncherScreen {
        ListScreen(id: "team.browse", title: "Équipe", placeholder: "Rechercher dans l’équipe…", icon: .symbol("person.3.fill", Palette.teal),
                   empty: { _ in
                       TeamLibrary.shared.folder == nil
                           ? ("person.3", "Choisissez le dossier partagé de l’équipe dans Réglages › Équipe.")
                           : ("tray", "Rien de partagé pour l’instant : « Partager avec l’équipe » publie vos snippets, liens, commandes et agents.")
                   }) { query in
            let library = TeamLibrary.shared
            library.reloadIfChanged()
            func filter(_ items: [ResultItem]) -> [ResultItem] {
                query.isEmpty ? items : items.filter { item in Fuzzy.score(query.normalizedForSearch, item.title) != nil || item.keywords.contains { Fuzzy.score(query.normalizedForSearch, $0) != nil } }
            }
            return [
                ResultSection(id: "links", title: "Liens rapides", items: filter(library.quicklinks.map(teamItem))),
                ResultSection(id: "snippets", title: "Snippets", items: filter(library.snippets.map(teamItem))),
                ResultSection(id: "commands", title: "Commandes d’IA", items: filter(library.commands.map(teamItem))),
                ResultSection(id: "agents", title: "Agents", items: filter(library.agents.map(teamItem))),
            ].filter { !$0.items.isEmpty }
        }
    }

    /// Ses propres snippets, liens, commandes d'IA personnalisées et agents, à publier pour l'équipe.
    static func shareScreen() -> LauncherScreen {
        ListScreen(id: "team.share", title: "Partager avec l’équipe", placeholder: "Rechercher ce que vous voulez partager…",
                   icon: .symbol("square.and.arrow.up.on.square", Palette.teal),
                   empty: { _ in ("person.3", TeamLibrary.shared.folder == nil ? "Choisissez d’abord le dossier de l’équipe dans Réglages › Équipe." : "Rien à partager") }) { query in
            let library = TeamLibrary.shared
            library.reloadIfChanged()
            guard library.folder != nil else { return [] }
            func matches(_ text: String) -> Bool { query.isEmpty || Fuzzy.score(query.normalizedForSearch, text) != nil }
            func shareItem(id: String, title: String, subtitle: String, icon: ItemIcon, shared: Bool, run: @escaping () throws -> Void) -> ResultItem {
                ResultItem(id: "share:" + id, title: title, subtitle: subtitle, icon: icon, tags: shared ? ["Déjà partagé"] : [], usageKey: "", actions: [
                    ItemAction(title: shared ? "Mettre à jour dans l’équipe" : "Partager avec l’équipe", symbol: "square.and.arrow.up") {
                        attempt("« \(title) » partagé avec l’équipe", run)
                    },
                ])
            }
            let links = QuicklinkStore.shared.links.filter { matches($0.name) }.map { link in
                shareItem(id: "link:" + link.id.uuidString, title: link.name, subtitle: "Lien rapide", icon: .symbol("link", Palette.blue),
                          shared: library.quicklinks.contains { $0.id == link.id }) { try library.share(link) }
            }
            let snippets = SnippetStore.shared.snippets.filter { matches($0.name) }.map { snippet in
                shareItem(id: "snippet:" + snippet.id.uuidString, title: snippet.name, subtitle: "Snippet", icon: .symbol("text.badge.plus", Palette.orange),
                          shared: library.snippets.contains { $0.id == snippet.id }) { try library.share(snippet) }
            }
            let commands = AICommandStore.shared.content.custom.filter { matches($0.name) }.map { command in
                shareItem(id: "command:" + command.id, title: command.name, subtitle: "Commande d’IA", icon: .symbol(command.symbol, Palette.violet),
                          shared: library.commands.contains { $0.id == command.id }) { try library.share(command) }
            }
            let agents = AIPresetStore.shared.presets.filter { !$0.isBuiltIn && matches($0.name) }.map { agent in
                shareItem(id: "agent:" + agent.id.uuidString, title: agent.name, subtitle: "Agent", icon: .symbol(agent.symbol, Palette.violet),
                          shared: library.agents.contains { $0.id == agent.id }) { try library.share(agent) }
            }
            return [
                ResultSection(id: "links", title: "Liens rapides", items: links),
                ResultSection(id: "snippets", title: "Snippets", items: snippets),
                ResultSection(id: "commands", title: "Commandes d’IA", items: commands),
                ResultSection(id: "agents", title: "Agents", items: agents),
            ].filter { !$0.items.isEmpty }
        }
    }

    // MARK: - Réglages

    static var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "team", title: "Équipe", symbol: "person.3.fill", color: Palette.teal, order: 78) { AnyView(TeamSettingsView()) }]
    }

    // MARK: - Autotests

    static func selfTest(_ check: (Bool, String) -> Void) {
        let defaults = UserDefaults.standard
        let previousFolder = defaults.string(forKey: TeamLibrary.folderKey)
        let previousMember = defaults.string(forKey: TeamLibrary.memberKey)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("prism-team-\(UUID().uuidString)", isDirectory: true)
        defaults.set(folder.path, forKey: TeamLibrary.folderKey)
        defaults.set("Léa", forKey: TeamLibrary.memberKey)
        defer {
            try? FileManager.default.removeItem(at: folder)
            defaults.set(previousFolder, forKey: TeamLibrary.folderKey)
            defaults.set(previousMember, forKey: TeamLibrary.memberKey)
            TeamLibrary.shared.reloadIfChanged()
        }
        let library = TeamLibrary.shared
        let snippet = Snippet(name: "Signature d’équipe", text: "L’équipe Prism", keyword: ";sig")
        let link = Quicklink(name: "Wiki interne", link: "https://wiki.exemple.fr/?q={argument}")
        do {
            try library.share(snippet)
            try library.share(link)
            try library.share(snippet)
        } catch {
            check(false, "équipe : partage (\(error.localizedDescription))")
            return
        }
        library.reloadIfChanged()
        check(library.snippets.count == 1 && library.snippets.first?.text == "L’équipe Prism", "équipe : snippet partagé, sans doublon")
        check(library.author(snippet.id.uuidString) == "Léa", "équipe : auteur retenu")
        let item = teamItem(link)
        check(item.tags.first == "Équipe" && item.id.hasPrefix("team:") && !item.actions.contains { $0.title.hasPrefix("Modifier") },
              "équipe : élément marqué, sans édition personnelle")
        check(commands.contains { $0.id == "team:quicklink:" + link.id.uuidString }, "équipe : lien dans la recherche principale")
        try? library.unshare(snippet: snippet.id)
        check(library.snippets.isEmpty, "équipe : snippet retiré")
    }
}

struct TeamSettingsView: View {
    @AppStorage(TeamLibrary.folderKey) private var folder = ""
    @AppStorage(TeamLibrary.memberKey) private var member = ""

    var body: some View {
        Form {
            Section("Dossier de l’équipe") {
                HStack {
                    Text(folder.isEmpty ? "Aucun" : (folder as NSString).abbreviatingWithTildeInPath).foregroundStyle(folder.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("Choisir…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        panel.prompt = "Choisir"
                        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
                    }
                    if !folder.isEmpty { Button("Retirer") { folder = "" } }
                }
                Text("Un dossier que toute l’équipe voit : dossier iCloud Drive partagé, Dropbox, OneDrive, partage réseau… Les snippets, liens rapides, commandes d’IA et agents qu’on y publie apparaissent chez chacun, marqués « Équipe ».")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Vous") {
                TextField("Nom affiché sur vos partages", text: $member, prompt: Text(NSFullUserName()))
            }
        }
        .formStyle(.grouped)
    }
}
