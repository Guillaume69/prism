import AppKit
import SwiftUI

/// La recherche principale : favoris et suggestions quand elle est vide ; sinon sections des fonctionnalités,
/// apps et commandes classées (alias, recherche floue, fréquence), puis recherches de repli.
@MainActor
final class RootScreen: LauncherScreen {
    init() {
        super.init(id: "root", title: "Prism", placeholder: "Rechercher des apps et des commandes…", icon: .glyph("magnifyingglass"))
    }

    /// Tout ce que la recherche principale peut lancer, y compris les commandes masquées.
    static func candidates() -> [ResultItem] {
        Features.commands + AppCatalog.shared.items()
    }

    override func sections(query rawQuery: String) -> [ResultSection] {
        let config = CommandConfigStore.shared
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        let all = Self.candidates().map(Self.decorate)
        let visible = all.filter { !config.isDisabled($0.id) }

        if query.isEmpty {
            var sections: [ResultSection] = Features.all.flatMap { $0.topSections(query: "") }
            let byID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let favorites = config.data.favorites.compactMap { byID[$0] }
            if !favorites.isEmpty {
                sections.append(ResultSection(id: "favorites", title: "Favoris", items: favorites))
            }
            let shown = Set(favorites.map(\.id))
            let suggestions = UsageStore.shared.topKeys(limit: 20)
                .compactMap { byID[$0] }
                .filter { !shown.contains($0.id) }
                .prefix(6)
            if !suggestions.isEmpty {
                sections.append(ResultSection(id: "suggestions", title: "Suggestions", items: Array(suggestions)))
            }
            let listed = shown.union(suggestions.map(\.id))
            let commands = visible.filter { !$0.id.hasPrefix("app:") && !listed.contains($0.id) }
            sections.append(ResultSection(id: "commands", title: "Commandes", items: commands))
            return sections
        }

        var sections: [ResultSection] = Features.all.flatMap { $0.topSections(query: query) }
        var results: [ResultItem] = []

        // Un alias suivi d'une espace passe le reste de la saisie en argument : « yt lofi ».
        if let aliased = aliasInvocation(query: rawQuery, items: visible) {
            results.append(aliased)
        }

        let normalized = query.normalizedForSearch
        let scored: [(item: ResultItem, score: Double)] = visible.compactMap { item in
            var best = Fuzzy.score(normalized, item.title)
            for keyword in item.keywords {
                if let score = Fuzzy.score(normalized, keyword).map({ $0 * 0.85 }), score > (best ?? 0) { best = score }
            }
            if let subtitle = item.subtitle, let score = Fuzzy.score(normalized, subtitle).map({ $0 * 0.6 }), score > (best ?? 0) {
                best = score
            }
            if let alias = config.alias(for: item.id) {
                if alias == normalized { best = 1_000 } else if alias.hasPrefix(normalized) { best = max(best ?? 0, 200) }
            }
            guard let best else { return nil }
            return (item, best + UsageStore.shared.boost(item.usageKey ?? item.id))
        }
        let invoked = Set(results.map(\.id))
        results += scored
            .sorted { $0.score == $1.score ? $0.item.title < $1.item.title : $0.score > $1.score }
            .prefix(40)
            .map(\.item)
            .filter { !invoked.contains($0.id) }
        if !results.isEmpty {
            sections.append(ResultSection(id: "results", title: "Résultats", items: results))
        }

        sections += Features.all.flatMap { $0.extraSections(query: query) }

        let fallbacks = Self.orderedFallbacks(query: query)
        if !fallbacks.isEmpty {
            sections.append(ResultSection(id: "fallback", title: "Utiliser « \(query) » avec…", items: fallbacks))
        }
        return sections
    }

    override func emptyState(query: String) -> (symbol: String, message: String) {
        ("magnifyingglass", "Aucun résultat pour « \(query) »")
    }

    /// Tab avec une saisie : la question part à Quick AI, comme dans Raycast.
    override func handleKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard event.keyCode == 48, modifiers.isEmpty, let host, let quickAI = AppHooks.quickAI else { return false }
        // Une commande à arguments est sélectionnée : Tab va à ses champs, pas à Quick AI.
        if host.showsInlineArguments { return false }
        let query = host.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return false }
        host.push(quickAI(query))
        return true
    }

    /// Les recherches de repli, dans l'ordre choisi dans les réglages, sans celles désactivées.
    static func orderedFallbacks(query: String) -> [ResultItem] {
        let config = CommandConfigStore.shared.data
        let items = Features.all.flatMap { $0.fallbacks(query: query) }
            .filter { !config.disabledFallbacks.contains($0.id) }
        let order = config.fallbackOrder
        return items.enumerated().sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs.element.id) ?? (1_000 + lhs.offset)
            let right = order.firstIndex(of: rhs.element.id) ?? (1_000 + rhs.offset)
            return left < right
        }.map(\.element)
    }

    /// Les étiquettes d'alias et de raccourci, comme Raycast les affiche à droite.
    private static func decorate(_ item: ResultItem) -> ResultItem {
        guard item.isConfigurable else { return item }
        var item = item
        let config = CommandConfigStore.shared.config(for: item.id)
        if let alias = config.alias { item.tags.insert(alias, at: 0) }
        if let hotkey = config.hotkey { item.tags.append(hotkey.label) }
        return item
    }

    /// « alias texte » : l'élément dont l'alias ouvre la saisie, avec le texte en arguments.
    private func aliasInvocation(query: String, items: [ResultItem]) -> ResultItem? {
        guard let space = query.firstIndex(of: " ") else { return nil }
        let alias = query[..<space].lowercased()
        let rest = query[query.index(after: space)...].trimmingCharacters(in: .whitespaces)
        let config = CommandConfigStore.shared
        guard let item = items.first(where: { config.alias(for: $0.id) == alias }) else { return nil }
        guard let run = item.runWithArguments, !item.arguments.isEmpty, !rest.isEmpty else { return item }
        let values: [String]
        if item.arguments.count == 1 {
            values = [rest]
        } else {
            var parts = rest.split(separator: " ", maxSplits: item.arguments.count - 1).map(String.init)
            while parts.count < item.arguments.count { parts.append("") }
            values = parts
        }
        var invoked = item
        invoked.subtitle = values.filter { !$0.isEmpty }.joined(separator: " · ")
        invoked.arguments = []
        invoked.runWithArguments = nil
        invoked.actions = [ItemAction(title: "Lancer avec « \(rest) »", symbol: "play.fill") { run(values) }] + item.actions.dropFirst()
        return invoked
    }

    static func detectURL(_ query: String) -> URL? {
        guard !query.contains(" ") else { return nil }
        if query.hasPrefix("http://") || query.hasPrefix("https://") {
            return URL(string: query)
        }
        let pattern = #"^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(:\d+)?(/.*)?$"#
        guard query.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://" + query)
    }
}

/// Les commandes de Prism lui-même, la détection des liens et la recherche web de repli.
@MainActor
enum CoreFeature: PrismFeature {
    static var commands: [ResultItem] {
        [
            Command.make(
                "settings", "Réglages de Prism", subtitle: "Prism",
                symbol: "gearshape.fill", color: Palette.gray,
                keywords: ["preferences", "settings", "parametres", "raccourci", "configuration"],
                actions: [ItemAction(title: "Ouvrir les réglages", symbol: "gearshape") {
                    NotificationCenter.default.post(name: .prismOpenSettings, object: nil)
                    return .close
                }]
            ),
            Command.run("compact-mode", "Basculer le mode compact", subtitle: "Prism", symbol: "rectangle.compress.vertical", color: Palette.gray, keywords: ["compact mode", "fenetre"]) {
                Preferences.shared.compactMode.toggle()
                return .toast(Preferences.shared.compactMode ? "Mode compact activé" : "Mode compact désactivé")
            },
            Command.make(
                "quit", "Quitter Prism", subtitle: "Prism",
                symbol: "xmark", color: Palette.gray,
                keywords: ["quit", "fermer"],
                actions: [ItemAction(title: "Quitter Prism", symbol: "xmark.circle", isDestructive: true) {
                    NSApp.terminate(nil)
                    return .close
                }]
            ),
        ]
    }

    static func topSections(query: String) -> [ResultSection] {
        guard let url = RootScreen.detectURL(query) else { return [] }
        let item = ResultItem(
            id: "open-url",
            title: "Ouvrir \(url.absoluteString)",
            subtitle: url.host,
            icon: .favicon(url),
            accessory: "Lien",
            usageKey: "",
            actions: [
                Actions.openURL(url, title: "Ouvrir dans le navigateur"),
                Actions.copy(url.absoluteString, title: "Copier le lien"),
            ]
        )
        return [ResultSection(id: "url", title: "Lien", items: [item])]
    }

    static func fallbacks(query: String) -> [ResultItem] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let google = URL(string: "https://www.google.com/search?q=\(encoded)") else { return [] }
        return [ResultItem(
            id: "fallback.google",
            title: "Rechercher sur Google",
            subtitle: query,
            icon: .symbol("magnifyingglass", Palette.blue),
            accessory: "Web",
            actions: [Actions.openURL(google, title: "Rechercher sur Google")]
        )]
    }
}
