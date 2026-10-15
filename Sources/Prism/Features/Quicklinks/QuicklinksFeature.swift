import AppKit
import SwiftUI

/// Réglages des liens rapides (clés « quicklinks. »).
@MainActor
final class QuicklinkSettings: ObservableObject {
    static let shared = QuicklinkSettings()
    private let defaults = UserDefaults.standard

    /// Lancé par un raccourci avec un seul argument : le texte sélectionné le remplit.
    @Published var selectionAsArgument: Bool { didSet { defaults.set(selectionAsArgument, forKey: "quicklinks.selectionAsArgument") } }
    @Published var confirmDelete: Bool { didSet { defaults.set(confirmDelete, forKey: "quicklinks.confirmDelete") } }
    /// Passe à l'onglet déjà ouvert sur l'adresse plutôt que d'en ouvrir un nouveau (Safari, Chrome, Arc, Brave, Edge).
    @Published var preferExistingTabs: Bool { didSet { defaults.set(preferExistingTabs, forKey: "quicklinks.preferExistingTabs") } }

    private init() {
        preferExistingTabs = defaults.bool(forKey: "quicklinks.preferExistingTabs")
        selectionAsArgument = defaults.object(forKey: "quicklinks.selectionAsArgument") as? Bool ?? true
        confirmDelete = defaults.object(forKey: "quicklinks.confirmDelete") as? Bool ?? true
    }
}

/// Liens rapides, comme les « quicklinks » de Raycast : chaque lien est une commande de la recherche principale,
/// avec ses arguments (« yt lofi » par l'alias), son icône et l'application qui l'ouvre.
@MainActor
enum QuicklinksFeature: PrismFeature {
    static let symbol = "link"
    static let color = Palette.blue
    static var icon: ItemIcon { .symbol(symbol, color) }

    private static var store: QuicklinkStore { QuicklinkStore.shared }
    private static var settings: QuicklinkSettings { QuicklinkSettings.shared }

    static func start() {
        _ = QuicklinkStore.shared
        AppHooks.createQuicklink = { link, name in .push(formScreen(editing: nil, link: link, name: name, after: .pop)) }
    }

    static var commands: [ResultItem] {
        [
            Command.screen("quicklinks.search", "Rechercher des liens rapides", subtitle: "Liens rapides", symbol: symbol, color: color,
                           keywords: ["search quicklinks", "quicklink", "lien rapide", "favoris web"]) { searchScreen() },
            Command.screen("quicklinks.create", "Créer un lien rapide", subtitle: "Liens rapides", symbol: "plus.square.fill", color: color,
                           keywords: ["create quicklink", "nouveau lien", "ajouter"]) { formScreen(editing: nil, after: .hud) },
            Command.run("quicklinks.import", "Importer des liens rapides", subtitle: "Liens rapides", symbol: "square.and.arrow.down.fill", color: color,
                        keywords: ["import quicklinks", "json", "raycast"]) {
                DispatchQueue.main.async { SnippetsFeature.presentReport(importFromFile()) }
                return .close
            },
            Command.run("quicklinks.export", "Exporter des liens rapides", subtitle: "Liens rapides", symbol: "square.and.arrow.up.fill", color: color,
                        keywords: ["export quicklinks", "json", "sauvegarde"]) {
                DispatchQueue.main.async { SnippetsFeature.presentReport(exportToFile()) }
                return .close
            },
        ] + store.links.map { item(for: $0) }
    }

    static var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "quicklinks", title: "Liens rapides", symbol: symbol, color: color, order: 41) { AnyView(QuicklinkSettingsView()) }]
    }

    /// `prism://quicklinks/create?link=…&name=…`, `prism://quicklinks/search?q=…`.
    static func handle(url: URL) -> Bool {
        guard url.host == "quicklinks" else { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String { query.first { $0.name == name }?.value ?? "" }
        switch url.path {
        case "/create", "/new":
            CommandRunner.present(.push(formScreen(editing: nil, link: value("link"), name: value("name"), after: .hud)))
        case "/search", "", "/":
            CommandRunner.present(.push(searchScreen(), query: value("q")))
        default:
            return false
        }
        return true
    }

    // MARK: - Ouverture

    /// Ouvre un lien avec les valeurs de ses arguments. `selectionFallback` : lancé par un raccourci sans valeur,
    /// le texte sélectionné sert d'argument ; à défaut, le lanceur le demande.
    static func open(_ link: Quicklink, values: [String], app: String?, selectionFallback: Bool) -> ActionOutcome {
        let isEmpty = values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        if selectionFallback, isEmpty {
            if AppContext.launcher?.isVisible != true {
                let target = AppContext.previousApp
                Task { @MainActor in
                    let selection = await SelectedText.read(from: target)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !selection.isEmpty {
                        CommandRunner.present(open(link, values: [selection], app: app, selectionFallback: false))
                    } else if let form = ArgumentsForm.screen(for: argumentsItem(link, app: app)) {
                        CommandRunner.present(.push(form))
                    }
                }
                return .close
            }
            // Dans le lanceur, l'argument rendu facultatif reste obligatoire.
            if let argument = QuicklinkTemplate.arguments(link.link).first, !argument.isOptional {
                return .toast("« \(argument.name) » est requis")
            }
        }
        if Placeholders.needsSelection(QuicklinkTemplate.normalized(link.link)) {
            let target = AppContext.previousApp
            Task { @MainActor in
                let selection = await SelectedText.read(from: target)
                CommandRunner.present(openNow(link, values: values, app: app, selection: selection))
            }
            return .close
        }
        return openNow(link, values: values, app: app, selection: nil)
    }

    private static func openNow(_ link: Quicklink, values: [String], app: String?, selection: String?) -> ActionOutcome {
        var context = Placeholders.Context.live(usage: .quicklink)
        context.selection = selection
        let expanded = QuicklinkTemplate.expand(link.link, values: values, context: context)
        guard let url = QuicklinkTemplate.url(for: expanded) else { return .toast("Lien invalide : « \(expanded) »") }
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) {
            return .toast("Introuvable : \((url.path as NSString).abbreviatingWithTildeInPath)")
        }
        if QuicklinkSettings.shared.preferExistingTabs, app == nil, link.openWith == nil, BrowserTab.focusExisting(url) {
            return .close
        }
        if let appPath = app ?? link.openWith, FileManager.default.fileExists(atPath: appPath) {
            Actions.open(url, withApp: appPath)
        } else if !NSWorkspace.shared.open(url) {
            return .toast("Aucune application ne sait ouvrir « \(expanded) »")
        }
        return .close
    }

    /// L'élément qui demande les arguments (obligatoires) puis ouvre, avec une application choisie ou non.
    private static func argumentsItem(_ link: Quicklink, app: String?) -> ResultItem {
        var item = item(for: link)
        item.arguments = QuicklinkTemplate.arguments(link.link)
        item.runWithArguments = { values in open(link, values: values, app: app, selectionFallback: false) }
        return item
    }

    private static func openOutcome(_ link: Quicklink, app: String?) -> ActionOutcome {
        let item = argumentsItem(link, app: app)
        if !item.arguments.isEmpty, let form = ArgumentsForm.screen(for: item) { return .push(form) }
        return open(link, values: [], app: app, selectionFallback: false)
    }

    // MARK: - Éléments

    private static var iconCache: [String: ItemIcon] = [:]

    /// Symbole choisi, sinon favicon pour le web, icône du fichier, ou de l'application qui ouvre le lien profond.
    static func icon(for link: Quicklink) -> ItemIcon {
        if let name = link.iconName { return .symbol(name, symbolColor(for: link.name)) }
        if let cached = iconCache[link.link] { return cached }
        let icon: ItemIcon
        if QuicklinkTemplate.isFilePath(link.link) {
            let path = (QuicklinkTemplate.normalized(link.link).components(separatedBy: "{").first.map { ($0 as NSString).expandingTildeInPath }) ?? ""
            icon = FileManager.default.fileExists(atPath: path) ? .file(path) : .symbol("folder.fill", Palette.blue)
        } else if let url = QuicklinkTemplate.sampleURL(link.link) {
            if url.scheme == "http" || url.scheme == "https", url.host != nil {
                icon = .favicon(url)
            } else if let app = NSWorkspace.shared.urlForApplication(toOpen: url) {
                icon = .file(app.path)
            } else {
                icon = .symbol("link", Palette.gray)
            }
        } else {
            icon = .symbol("link", Palette.gray)
        }
        iconCache[link.link] = icon
        return icon
    }

    private static func symbolColor(for name: String) -> Color {
        let colors = [Palette.blue, Palette.violet, Palette.pink, Palette.orange, Palette.green, Palette.teal, Palette.indigo, Palette.red]
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return colors[sum % colors.count]
    }

    /// Une commande de la recherche principale : ↵ ouvre, ou demande d'abord les arguments.
    static func item(for link: Quicklink) -> ResultItem {
        var arguments = QuicklinkTemplate.arguments(link.link)
        let selectionFallback = settings.selectionAsArgument && arguments.count == 1 && arguments[0].options.isEmpty
        // Facultatif pour qu'un raccourci global lance le lien sans formulaire et lise la sélection.
        if selectionFallback { arguments[0].isOptional = true }
        let appName = link.openWith.map(AppName.of)
        let primaryTitle = appName.map { "Ouvrir dans \($0)" } ?? "Ouvrir le lien"
        var actions = [
            ItemAction(title: primaryTitle, symbol: "arrow.up.forward.app") { openOutcome(link, app: nil) },
            ItemAction(title: "Ouvrir avec…", symbol: "square.grid.2x2", shortcut: .openWith) { .push(openWithScreen(link)) },
            Actions.copy(link.link, title: "Copier le lien", symbol: "link", shortcut: .copyText, hud: "Lien copié"),
            Actions.copy(link.name, title: "Copier le nom", symbol: "textformat", shortcut: .copyName, hud: "Nom copié"),
        ]
        actions += [
            ItemAction(title: "Modifier le lien rapide", symbol: "pencil", shortcut: .edit, section: "Lien rapide") {
                .push(formScreen(editing: link, after: .pop))
            },
            ItemAction(title: "Dupliquer le lien rapide", symbol: "plus.square.on.square", shortcut: .duplicate, section: "Lien rapide") {
                var copy = link
                copy.name = link.name + " (copie)"
                return .push(formScreen(editing: nil, template: copy, after: .pop))
            },
            ItemAction(title: link.isPinned ? "Désépingler" : "Épingler", symbol: link.isPinned ? "pin.slash" : "pin", shortcut: .pin, section: "Lien rapide") {
                store.togglePin(link.id)
                return .refresh
            },
            ItemAction(title: "Créer un lien rapide", symbol: "plus", shortcut: .create, section: "Lien rapide") {
                .push(formScreen(editing: nil, after: .pop))
            },
            ItemAction(title: "Supprimer le lien rapide", symbol: "trash", shortcut: .removeEntry, isDestructive: true, section: "Lien rapide") {
                deleteOutcome(link)
            },
        ]
        let display = QuicklinkTemplate.display(link.link)
        return ResultItem(
            id: link.commandID,
            title: link.name,
            subtitle: display,
            icon: icon(for: link),
            accessory: "Lien rapide",
            keywords: link.tags + [display, "lien rapide", "quicklink"],
            actions: actions,
            arguments: arguments,
            runWithArguments: { values in open(link, values: values, app: nil, selectionFallback: selectionFallback) },
            isConfigurable: true
        )
    }

    private static func deleteOutcome(_ link: Quicklink) -> ActionOutcome {
        guard settings.confirmDelete else {
            store.delete(link.id)
            return .refresh
        }
        return .push(Confirmation.screen(
            title: "Supprimer le lien rapide",
            question: "Supprimer « \(link.name) » ?",
            confirmTitle: "Supprimer le lien rapide",
            icon: .symbol("trash.fill", Palette.red)
        ) {
            store.delete(link.id)
            return .pop
        })
    }

    /// « Ouvrir avec… » : les applications qui savent ouvrir ce lien, celle par défaut en tête.
    static func openWithScreen(_ link: Quicklink) -> LauncherScreen {
        ListScreen(id: "quicklinks.openwith", title: "Ouvrir « \(link.name) » avec…", placeholder: "Rechercher une application…", icon: icon(for: link)) { query in
            let paths = applications(for: link)
            let defaultApp = QuicklinkTemplate.sampleURL(link.link).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0)?.path }
            let normalized = query.normalizedForSearch
            let items = paths
                .filter { normalized.isEmpty || Fuzzy.score(normalized, AppName.of($0)) != nil }
                .map { path in
                    let name = AppName.of(path)
                    return ResultItem(
                        id: "openwith:" + path,
                        title: name,
                        icon: .file(path),
                        accessory: path == defaultApp ? "Par défaut" : (path == link.openWith ? "Choisie" : nil),
                        usageKey: "",
                        actions: [ItemAction(title: "Ouvrir avec \(name)", symbol: "arrow.up.forward.app") { openOutcome(link, app: path) }]
                    )
                }
            return [ResultSection(id: "apps", title: "Applications", items: items)]
        }
    }

    static func applications(for link: Quicklink) -> [String] {
        guard let url = QuicklinkTemplate.sampleURL(link.link) else { return [] }
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)?.path
        var paths: [String] = []
        for path in NSWorkspace.shared.urlsForApplications(toOpen: url).map(\.path) where !paths.contains(path) {
            paths.append(path)
        }
        return paths.sorted { lhs, rhs in
            if lhs == defaultApp { return true }
            if rhs == defaultApp { return false }
            return AppName.of(lhs).localizedCaseInsensitiveCompare(AppName.of(rhs)) == .orderedAscending
        }
    }

    // MARK: - Recherche

    private final class ScreenReference {
        weak var screen: LauncherScreen?
    }

    static func searchScreen() -> LauncherScreen {
        let reference = ScreenReference()
        let screen = ListScreen(
            id: "quicklinks",
            title: "Rechercher des liens rapides",
            placeholder: "Rechercher des liens rapides…",
            icon: icon,
            filter: tagFilter(selected: "all"),
            empty: { query in
                if !query.isEmpty { return ("magnifyingglass", "Aucun lien rapide pour « \(query) »") }
                return QuicklinkStore.shared.links.isEmpty
                    ? ("link", "Aucun lien rapide.\nLancez « Créer un lien rapide » pour commencer.")
                    : ("tag", "Aucun lien rapide avec cette étiquette")
            }
        ) { query in
            var selected = reference.screen?.filter?.selected ?? "all"
            if !tagFilter(selected: selected).options.contains(where: { $0.id == selected }) { selected = "all" }
            reference.screen?.filter = tagFilter(selected: selected)
            return sections(query: query, tag: selected.hasPrefix("tag:") ? String(selected.dropFirst(4)) : nil)
        }
        reference.screen = screen
        return screen
    }

    private static func tagFilter(selected: String) -> ScreenFilter {
        let options = [ScreenFilter.Option(id: "all", title: "Tous les liens")]
            + store.allTags.map { ScreenFilter.Option(id: "tag:" + $0, title: $0) }
        return ScreenFilter(options: options, selected: selected)
    }

    static func sections(query: String, tag: String?) -> [ResultSection] {
        var links = store.links
        if let tag {
            links = links.filter { $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
        }
        let config = CommandConfigStore.shared
        let normalized = query.normalizedForSearch
        let ordered: [Quicklink]
        if query.isEmpty {
            ordered = links
        } else {
            ordered = links.compactMap { link -> (Quicklink, Double)? in
                var best = Fuzzy.score(normalized, link.name)
                if let alias = config.alias(for: link.commandID), alias == normalized { best = 1_000 }
                if let value = Fuzzy.score(normalized, QuicklinkTemplate.display(link.link)).map({ $0 * 0.7 }), value > (best ?? 0) { best = value }
                for tag in link.tags {
                    if let value = Fuzzy.score(normalized, tag).map({ $0 * 0.6 }), value > (best ?? 0) { best = value }
                }
                if best == nil, link.link.normalizedForSearch.contains(normalized) { best = 30 }
                return best.map { (link, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        }
        func row(_ link: Quicklink) -> ResultItem {
            var item = item(for: link)
            item.accessory = link.openWith.map(AppName.of)
            if let alias = config.alias(for: link.commandID) { item.tags = [alias] }
            if config.isDisabled(link.commandID) { item.tags.append("masqué") }
            return item
        }
        return [
            ResultSection(id: "pinned", title: "Épinglés", items: ordered.filter(\.isPinned).map(row)),
            ResultSection(id: "quicklinks", title: query.isEmpty ? "Liens rapides" : "Résultats", items: ordered.filter { !$0.isPinned }.map(row)),
        ].filter { !$0.items.isEmpty }
    }

    // MARK: - Formulaire

    enum AfterSave {
        case pop
        case hud
    }

    static let iconChoices: [(value: String, title: String)] = [
        ("", "Automatique (favicon ou icône du fichier)"),
        ("globe", "Globe"), ("magnifyingglass", "Loupe"), ("link", "Lien"), ("star.fill", "Étoile"),
        ("bookmark.fill", "Signet"), ("folder.fill", "Dossier"), ("doc.text.fill", "Document"), ("book.fill", "Livre"),
        ("cart.fill", "Panier"), ("map.fill", "Carte"), ("play.rectangle.fill", "Vidéo"), ("music.note", "Musique"),
        ("envelope.fill", "Courrier"), ("calendar", "Calendrier"), ("bubble.left.fill", "Message"),
        ("chevron.left.forwardslash.chevron.right", "Code"), ("terminal.fill", "Terminal"), ("house.fill", "Maison"),
        ("bolt.fill", "Éclair"), ("briefcase.fill", "Travail"),
    ]

    /// Les navigateurs (et le Finder), plus l'application déjà choisie.
    static func appChoices(including current: String?) -> [(value: String, title: String)] {
        var paths: [String] = []
        if let sample = URL(string: "https://example.com") {
            paths = NSWorkspace.shared.urlsForApplications(toOpen: sample).map(\.path)
        }
        for extra in ["/System/Library/CoreServices/Finder.app", current].compactMap({ $0 }) where FileManager.default.fileExists(atPath: extra) {
            paths.append(extra)
        }
        var seen = Set<String>()
        let unique = paths.filter { seen.insert($0).inserted }
            .sorted { AppName.of($0).localizedCaseInsensitiveCompare(AppName.of($1)) == .orderedAscending }
        return [("", "Par défaut")] + unique.map { ($0, AppName.of($0)) }
    }

    static func formScreen(editing: Quicklink?, template: Quicklink? = nil, link: String = "", name: String = "", after: AfterSave) -> LauncherScreen {
        let source = editing ?? template
        var icons = iconChoices
        if let current = source?.iconName, !icons.contains(where: { $0.value == current }) { icons.append((current, current)) }
        let fields = [
            FormField(id: "name", label: "Nom", kind: .text, placeholder: "Par exemple : Recherche sur YouTube", value: source?.name ?? name),
            FormField(id: "link", label: "Lien", kind: .text, placeholder: "https://www.youtube.com/results?search_query={argument}", value: source?.link ?? link,
                      info: "Adresse, chemin de fichier ou de dossier, lien profond. {argument name=\"Recherche\"} demande une valeur, encodée pour l’adresse ; aussi {clipboard}, {selection}, {date}. ⌘⇧B remplit depuis l’onglet du navigateur."),
            FormField(id: "openWith", label: "Ouvrir avec", kind: .dropdown(appChoices(including: source?.openWith)), value: source?.openWith ?? ""),
            FormField(id: "icon", label: "Icône", kind: .dropdown(icons), value: source?.iconName ?? ""),
            FormField(id: "tags", label: "Étiquettes", kind: .text, placeholder: "Travail, Recherche web", value: source?.tags.joined(separator: ", ") ?? "",
                      info: "Séparées par des virgules ; ⌘P filtre la liste par étiquette."),
        ]
        let form = FormScreen(
            id: editing.map { "quicklinks.edit." + $0.id.uuidString } ?? "quicklinks.create",
            title: editing == nil ? "Créer un lien rapide" : "Modifier le lien rapide",
            icon: icon,
            submitTitle: editing == nil ? "Créer le lien rapide" : "Enregistrer",
            fields: fields
        ) { state in
            let linkValue = state.trimmed("link")
            guard !linkValue.isEmpty else {
                state.error = "Le lien est vide"
                return .stay
            }
            guard QuicklinkTemplate.sampleURL(linkValue) != nil else {
                state.error = "Ce lien n’est pas valable"
                return .stay
            }
            let nameValue = state.trimmed("name").nilIfEmpty ?? QuicklinkTemplate.display(linkValue)
            var quicklink = editing ?? Quicklink(name: nameValue, link: linkValue)
            quicklink.name = nameValue
            quicklink.link = linkValue
            quicklink.openWith = state["openWith"].nilIfEmpty
            quicklink.iconName = state["icon"].nilIfEmpty
            quicklink.tags = SnippetRules.parseTags(state["tags"])
            if let template, editing == nil { quicklink.isPinned = template.isPinned }
            QuicklinkStore.shared.save(quicklink)
            switch after {
            case .pop: return .pop
            case .hud: return .hud(editing == nil ? "Lien rapide « \(nameValue) » créé" : "Lien rapide enregistré")
            }
        }
        return QuicklinkFormScreen(form: form)
    }

    // MARK: - Import et export

    static func importFromFile() -> String? {
        guard let url = JSONFilePanel.open(title: "Importer des liens rapides") else { return nil }
        guard let data = try? Data(contentsOf: url), let incoming = try? QuicklinkTransfer.decode(data) else {
            return "⚠︎ Fichier illisible : un tableau JSON de liens rapides est attendu"
        }
        let report = QuicklinkTransfer.merge(incoming, into: store.links, resolveApp: QuicklinkTransfer.resolveApp)
        store.add(report.added)
        let added = report.added.count
        let addedText = "\(added) lien\(added > 1 ? "s" : "") ajouté\(added > 1 ? "s" : "")"
        return report.skipped > 0 ? addedText + ", \(report.skipped) ignoré\(report.skipped > 1 ? "s" : "") (doublons)" : addedText
    }

    static func exportToFile() -> String? {
        guard let url = JSONFilePanel.save(title: "Exporter des liens rapides", fileName: "Liens rapides.json") else { return nil }
        store.flush()
        do {
            try QuicklinkTransfer.export(store.links).write(to: url, options: .atomic)
            let count = store.links.count
            return "\(count) lien\(count > 1 ? "s" : "") exporté\(count > 1 ? "s" : "")"
        } catch {
            return "⚠︎ Écriture impossible : \(error.localizedDescription)"
        }
    }

    // MARK: - Autotests

    static func selfTest(_ check: (Bool, String) -> Void) {
        let google = "https://www.google.com/search?q={argument name=\"Recherche\"}"
        let arguments = QuicklinkTemplate.arguments(google)
        check(arguments.count == 1 && arguments.first?.name == "Recherche" && arguments.first?.isOptional == false, "argument nommé d’un lien")
        check(QuicklinkTemplate.arguments("https://x.fr/?a={argument name=\"a\"}&b={argument name=\"b\" default=\"1\"}").map(\.isOptional) == [false, true], "deux arguments, le second facultatif")
        check(QuicklinkTemplate.arguments("https://duckduckgo.com/?q={query}").first?.name == "Recherche", "{query} traité comme un argument")
        check(QuicklinkTemplate.arguments("https://news.ycombinator.com").isEmpty, "lien sans argument")

        var context = Placeholders.Context()
        context.clipboard = { _ in nil }
        let encoded = QuicklinkTemplate.expand(google, values: ["café crème"], context: context)
        check(encoded == "https://www.google.com/search?q=caf%C3%A9%20cr%C3%A8me", "encodage : « café crème » → café%20cr%C3%A8me")
        check(QuicklinkTemplate.expand("https://x.fr/?q={argument}", values: ["a&b=c"], context: context) == "https://x.fr/?q=a%26b%3Dc", "encodage des séparateurs d’adresse")
        check(QuicklinkTemplate.expand("https://x.fr/{argument | raw}", values: ["a/b"], context: context) == "https://x.fr/a/b", "modificateur raw")
        let path = QuicklinkTemplate.expand("~/Documents/{argument}", values: ["mes notes"], context: context)
        check(path == "~/Documents/mes notes" && QuicklinkTemplate.url(for: path)?.isFileURL == true, "chemin de fichier : pas d’encodage")
        check(QuicklinkTemplate.url(for: "github.com/apple")?.absoluteString == "https://github.com/apple", "domaine nu ouvert en https")
        check(QuicklinkTemplate.url(for: "mailto:contact@exemple.fr")?.scheme == "mailto", "lien profond gardé tel quel")
        check(QuicklinkTemplate.url(for: "localhost:3000")?.absoluteString == "https://localhost:3000", "port pas pris pour un schéma")
        check(QuicklinkTemplate.display("https://www.youtube.com/results?search_query={argument}") == "youtube.com", "domaine affiché")

        let existing = [Quicklink(name: "YouTube", link: "https://www.youtube.com/results?search_query={argument}")]
        let report = QuicklinkTransfer.merge([
            QuicklinkExchange(name: "YT", link: "https://www.youtube.com/results?search_query={argument}"),
            QuicklinkExchange(name: "HN", link: "https://news.ycombinator.com"),
            QuicklinkExchange(name: "HN bis", link: " https://news.ycombinator.com "),
            QuicklinkExchange(name: "Vide", link: "  "),
            QuicklinkExchange(name: nil, link: "https://www.lemonde.fr", openWith: "Safari"),
        ], into: existing) { $0 == "Safari" ? "/Applications/Safari.app" : nil }
        check(report.added.map(\.name) == ["HN", "lemonde.fr"] && report.skipped == 3, "import : doublons et liens vides ignorés, nom déduit du domaine")
        check(report.added.last?.openWith == "/Applications/Safari.app", "import : application d’ouverture retrouvée")
        let roundTrip = try? QuicklinkTransfer.decode(QuicklinkTransfer.export(existing))
        check(roundTrip?.first?.link == existing[0].link, "export relu à l’identique")

        let library = QuicklinkLibrary.links
        let aliases = QuicklinkLibrary.entries.map(\.alias)
        check(library.count == 10 && Set(aliases).count == 10, "bibliothèque par défaut : dix liens, alias distincts")
        check(QuicklinkLibrary.entries.allSatisfy { UUID(uuidString: $0.id) != nil }, "bibliothèque : identifiants stables valables")
        check(library.allSatisfy { QuicklinkTemplate.arguments($0.link).count == 1 }, "bibliothèque : un argument par lien")
        check(QuicklinkLibrary.entries.contains { $0.alias == "yt" && $0.name == "YouTube" }, "« yt » ouvre YouTube")
        let youtube = library.first { $0.name == "YouTube" }.map { item(for: $0) }
        check(youtube?.id.hasPrefix("quicklink:") == true && youtube?.isConfigurable == true && youtube?.runWithArguments != nil, "chaque lien est une commande configurable")
    }
}

/// Le formulaire d'un lien rapide, avec l'action « Remplir depuis l'onglet du navigateur » en plus.
@MainActor
final class QuicklinkFormScreen: LauncherScreen {
    let form: FormScreen

    init(form: FormScreen) {
        self.form = form
        super.init(id: form.id, title: form.title, icon: form.icon)
        layout = .custom
        hidesSearchField = true
    }

    override func customView() -> AnyView { form.customView() }

    override var screenActions: [ItemAction] {
        form.screenActions + [
            ItemAction(title: "Remplir depuis l’onglet du navigateur", symbol: "safari", shortcut: KeyShortcut(keyCode: 11, modifiers: [.command, .shift], label: "B")) { [weak self] in
                guard let self else { return .stay }
                guard let tab = BrowserTab.current() else { return .toast("Aucun onglet de navigateur trouvé") }
                self.form.state["link"] = tab.url
                if self.form.state.trimmed("name").isEmpty { self.form.state["name"] = tab.title }
                return .stay
            },
        ]
    }

    override func handleKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        if (event.keyCode == 36 || event.keyCode == 76), modifiers == .command {
            host?.apply(form.performSubmit())
            return true
        }
        return false
    }

    override var customViewHandlesNavigation: Bool { true }
}

/// Onglet « Liens rapides » des réglages.
struct QuicklinkSettingsView: View {
    @ObservedObject private var store = QuicklinkStore.shared
    @ObservedObject private var settings = QuicklinkSettings.shared
    @ObservedObject private var config = CommandConfigStore.shared
    @State private var restored: Int?

    var body: some View {
        Form {
            Section {
                if store.links.isEmpty {
                    Text("Aucun lien rapide").foregroundStyle(.secondary)
                }
                ForEach(store.links) { link in
                    HStack(spacing: 10) {
                        ItemIconView(icon: QuicklinksFeature.icon(for: link), size: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(link.name)
                            Text(link.link)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if let alias = config.alias(for: link.commandID) {
                            TagView(text: alias)
                        }
                        Toggle("", isOn: Binding(
                            get: { !config.isDisabled(link.commandID) },
                            set: { enabled in config.update(link.commandID) { $0.disabled = !enabled } }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    .contextMenu {
                        Button("Copier le lien") { Pasteboard.copy(link.link) }
                        Button("Supprimer", role: .destructive) { store.delete(link.id) }
                    }
                }
            } header: {
                Text("Liens rapides")
            } footer: {
                Text("Un lien désactivé disparaît de la recherche principale. L’alias se règle dans la recherche (⌘K, « Définir un alias ») ou dans l’onglet Commandes.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Options") {
                Toggle("Passer le texte sélectionné en argument (raccourci global, lien à un seul argument)", isOn: $settings.selectionAsArgument)
                Toggle("Demander confirmation avant de supprimer", isOn: $settings.confirmDelete)
                Toggle("Préférer les onglets déjà ouverts (le navigateur demandera l’autorisation d’être piloté)", isOn: $settings.preferExistingTabs)
            }

            Section {
                HStack {
                    Button("Importer…") { SnippetsFeature.presentReport(QuicklinksFeature.importFromFile()) }
                    Button("Exporter…") { SnippetsFeature.presentReport(QuicklinksFeature.exportToFile()) }
                    Spacer()
                    Button("Restaurer la bibliothèque par défaut") { restored = store.restoreLibrary() }
                }
                if let restored {
                    Text(restored == 0 ? "Tous les liens par défaut sont déjà là." : "\(restored) lien\(restored > 1 ? "s" : "") remis.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Données")
            } footer: {
                Text("Format JSON : un tableau d’objets « name », « link », « openWith » et « iconName » facultatifs.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
