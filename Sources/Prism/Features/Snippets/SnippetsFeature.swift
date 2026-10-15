import AppKit
import SwiftUI

/// Snippets, comme ceux de Raycast : recherche avec aperçu, création, import et export, placeholders dynamiques,
/// et développement des mots-clés dans toutes les applications (`SnippetExpander`).
@MainActor
enum SnippetsFeature: PrismFeature {
    static let symbol = "text.quote"
    static let color = Palette.orange
    static var icon: ItemIcon { .symbol(symbol, color) }

    private static var store: SnippetStore { SnippetStore.shared }
    private static var settings: SnippetSettings { SnippetSettings.shared }

    static func start() {
        AppHooks.createSnippet = { text in .push(form(editing: nil, text: text, after: .pop)) }
        SnippetExpander.shared.update()
    }

    static var commands: [ResultItem] {
        [
            Command.screen("snippets.search", "Rechercher des snippets", subtitle: "Snippets", symbol: symbol, color: color,
                           keywords: ["search snippets", "snippet", "texte", "modele", "abreviation"]) { searchScreen() },
            Command.screen("snippets.create", "Créer un snippet", subtitle: "Snippets", symbol: "plus.square.fill", color: color,
                           keywords: ["create snippet", "nouveau snippet", "ajouter"]) { form(editing: nil, after: .hud) },
            Command.run("snippets.import", "Importer des snippets", subtitle: "Snippets", symbol: "square.and.arrow.down.fill", color: color,
                        keywords: ["import snippets", "json", "raycast"]) {
                DispatchQueue.main.async { presentReport(importFromFile()) }
                return .close
            },
            Command.run("snippets.export", "Exporter des snippets", subtitle: "Snippets", symbol: "square.and.arrow.up.fill", color: color,
                        keywords: ["export snippets", "json", "sauvegarde"]) {
                DispatchQueue.main.async { presentReport(exportToFile()) }
                return .close
            },
        ]
    }

    static var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "snippets", title: "Snippets", symbol: symbol, color: color, order: 40) { AnyView(SnippetSettingsView()) }]
    }

    /// `prism://snippets/create?text=…&name=…`, `prism://snippets/search?q=…`.
    static func handle(url: URL) -> Bool {
        guard url.host == "snippets" else { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String { query.first { $0.name == name }?.value ?? "" }
        switch url.path {
        case "/create", "/new":
            CommandRunner.present(.push(form(editing: nil, text: value("text"), name: value("name"), after: .hud)))
        case "/search", "", "/":
            CommandRunner.present(.push(searchScreen(), query: value("q")))
        default:
            return false
        }
        return true
    }

    // MARK: - Développement des placeholders

    enum Delivery {
        case paste, copy
    }

    /// Le texte final et la position du curseur, avec le contexte réel (presse-papiers, autres snippets).
    static func expand(_ text: String, arguments: [String: String], selection: String?) -> (text: String, cursorFromEnd: Int?) {
        var context = Placeholders.Context.live(usage: .snippet)
        context.arguments = arguments
        context.selection = selection
        return Placeholders.expand(text, context: context)
    }

    /// Colle ou copie un snippet, avec les valeurs de ses arguments.
    static func deliver(_ snippet: Snippet, _ delivery: Delivery, values: [String], countsUse: Bool = true) -> ActionOutcome {
        if countsUse { store.recordUse(snippet.id) }
        let arguments = Placeholders.argumentValues(values, for: snippet.text)
        guard Placeholders.needsSelection(snippet.text) else {
            return finish(snippet, delivery, arguments: arguments, selection: nil)
        }
        // `{selection}` : la sélection de l'application d'avant se lit une fois le lanceur fermé.
        let target = AppContext.previousApp
        Task { @MainActor in
            let selection = await SelectedText.read(from: target)
            CommandRunner.present(finish(snippet, delivery, arguments: arguments, selection: selection))
        }
        return .close
    }

    private static func finish(_ snippet: Snippet, _ delivery: Delivery, arguments: [String: String], selection: String?) -> ActionOutcome {
        let result = expand(snippet.text, arguments: arguments, selection: selection)
        switch delivery {
        case .paste:
            ClipboardMonitor.shared.ignoreNextChange()
            return Paster.paste(result.text, cursorFromEnd: result.cursorFromEnd, restoreClipboard: true)
        case .copy:
            Pasteboard.copy(result.text)
            return .hud("Snippet copié dans le presse-papiers")
        }
    }

    /// Une action qui demande d'abord les arguments du snippet s'il en a.
    private static func run(_ snippet: Snippet, _ delivery: Delivery) -> ActionOutcome {
        let variant = item(for: snippet, delivery: delivery)
        if !variant.arguments.isEmpty, let form = ArgumentsForm.screen(for: variant) { return .push(form) }
        return deliver(snippet, delivery, values: [])
    }

    // MARK: - Éléments

    /// L'élément d'un snippet ; ↵ fait l'action principale (coller ou copier selon les réglages).
    static func item(for snippet: Snippet, delivery: Delivery? = nil, countsUse: Bool = true) -> ResultItem {
        let primary = delivery ?? (settings.primaryAction == .paste ? .paste : .copy)
        let pasteAction = ItemAction(title: Actions.pasteTitle, symbol: "doc.on.clipboard") { run(snippet, .paste) }
        let copyAction = ItemAction(title: "Copier dans le presse-papiers", symbol: "doc.on.doc") { run(snippet, .copy) }
        var actions = primary == .paste ? [pasteAction, copyAction] : [copyAction, pasteAction]
        actions += [
            ItemAction(title: "Modifier le snippet", symbol: "pencil", shortcut: .edit, section: "Snippet") {
                .push(form(editing: snippet, after: .pop))
            },
            ItemAction(title: "Dupliquer le snippet", symbol: "plus.square.on.square", shortcut: .duplicate, section: "Snippet") {
                var copy = snippet
                copy.name = snippet.name + " (copie)"
                copy.keyword = nil
                return .push(form(editing: nil, template: copy, after: .pop))
            },
            ItemAction(title: snippet.isPinned ? "Désépingler" : "Épingler", symbol: snippet.isPinned ? "pin.slash" : "pin", shortcut: .pin, section: "Snippet") {
                store.togglePin(snippet.id)
                return .refresh
            },
        ]
        if let keyword = snippet.keyword {
            var copyKeyword = Actions.copy(keyword, title: "Copier le mot-clé", symbol: "textformat.abc",
                                           shortcut: KeyShortcut(keyCode: 40, modifiers: [.command, .shift], label: "K"), hud: "Mot-clé copié")
            copyKeyword.section = "Snippet"
            actions.append(copyKeyword)
        }
        actions.append(ItemAction(title: "Créer un snippet", symbol: "plus", shortcut: .create, section: "Snippet") {
            .push(form(editing: nil, after: .pop))
        })
        actions.append(ItemAction(title: "Supprimer le snippet", symbol: "trash", shortcut: .removeEntry, isDestructive: true, section: "Snippet") {
            deleteOutcome(snippet)
        })
        return ResultItem(
            id: "snippet:" + snippet.id.uuidString,
            title: snippet.name,
            icon: .glyph(snippet.isPinned ? "pin.fill" : "doc.text"),
            accessory: snippet.keyword,
            keywords: snippet.tags,
            detail: detail(for: snippet),
            usageKey: "",
            actions: actions,
            arguments: Placeholders.arguments(in: snippet.text),
            runWithArguments: { values in deliver(snippet, primary, values: values, countsUse: countsUse) }
        )
    }

    private static func deleteOutcome(_ snippet: Snippet) -> ActionOutcome {
        guard settings.confirmDelete else {
            store.delete(snippet.id)
            return .refresh
        }
        return .push(Confirmation.screen(
            title: "Supprimer le snippet",
            question: "Supprimer « \(snippet.name) » ?",
            confirmTitle: "Supprimer le snippet",
            icon: .symbol("trash.fill", Palette.red)
        ) {
            store.delete(snippet.id)
            return .pop
        })
    }

    private static func detail(for snippet: Snippet) -> ItemDetail {
        let full = DateFormatter()
        full.dateStyle = .medium
        full.timeStyle = .short
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        return ItemDetail(
            text: previewMarkdown(snippet.text),
            metadata: [
                ("Mot-clé", snippet.keyword ?? "—"),
                ("Étiquettes", snippet.tags.isEmpty ? "—" : snippet.tags.joined(separator: ", ")),
                ("Utilisations", "\(snippet.useCount)"),
                ("Dernière utilisation", snippet.lastUsedAt.map { relative.localizedString(for: $0, relativeTo: Date()) } ?? "Jamais"),
                ("Modifié", full.string(from: snippet.updatedAt)),
            ],
            isMarkdown: true
        )
    }

    /// Le texte tel quel pour l'aperçu Markdown : chaque ligne est protégée (espace sans chasse en tête,
    /// ponctuation échappée) et les placeholders ressortent en gras à chasse fixe.
    static func previewMarkdown(_ text: String) -> String {
        func escape(_ plain: Substring) -> String {
            var result = ""
            for character in plain {
                if character == "\n" {
                    result += "\n\u{200B}"
                } else if character.isASCII, character.isPunctuation || character.isSymbol {
                    result += "\\" + String(character)
                } else {
                    result.append(character)
                }
            }
            return result
        }
        var output = "\u{200B}"
        var index = text.startIndex
        for token in Placeholders.tokens(in: text) {
            output += escape(text[index..<token.range.lowerBound])
            let raw = text[token.range].replacingOccurrences(of: "\n", with: " ")
            // Le gras encadre des gluons invisibles : sans eux, « ** » en début de ligne ne serait pas reconnu.
            let code = raw.contains("`") ? escape(Substring(raw)) : "`" + raw + "`"
            output += "**\u{2060}" + code + "\u{2060}**"
            index = token.range.upperBound
        }
        output += escape(text[index...])
        return output
    }

    // MARK: - Recherche

    /// Garde une référence à l'écran pour lire son filtre (⌘P) depuis le calcul des sections.
    private final class ScreenReference {
        weak var screen: LauncherScreen?
    }

    static func searchScreen() -> LauncherScreen {
        let reference = ScreenReference()
        let screen = ListScreen(
            id: "snippets",
            title: "Rechercher des snippets",
            placeholder: "Rechercher par nom, mot-clé ou contenu…",
            icon: icon,
            layout: .split(listWidth: 300),
            filter: tagFilter(selected: "all"),
            empty: { query in
                if !query.isEmpty { return ("magnifyingglass", "Aucun snippet pour « \(query) »") }
                return SnippetStore.shared.snippets.isEmpty
                    ? ("text.quote", "Aucun snippet pour l’instant.\nLancez « Créer un snippet » pour commencer.")
                    : ("tag", "Aucun snippet avec cette étiquette")
            }
        ) { query in
            var selected = reference.screen?.filter?.selected ?? "all"
            // Les étiquettes changent quand on modifie un snippet : le menu suit.
            let filter = tagFilter(selected: selected)
            if !filter.options.contains(where: { $0.id == selected }) { selected = "all" }
            reference.screen?.filter = tagFilter(selected: selected)
            return sections(query: query, tag: selected.hasPrefix("tag:") ? String(selected.dropFirst(4)) : nil)
        }
        reference.screen = screen
        return screen
    }

    private static func tagFilter(selected: String) -> ScreenFilter {
        let tags = store.allTags
        let options = [ScreenFilter.Option(id: "all", title: "Tous les snippets")]
            + tags.map { ScreenFilter.Option(id: "tag:" + $0, title: $0) }
        return ScreenFilter(options: options, selected: selected)
    }

    static func sections(query: String, tag: String?) -> [ResultSection] {
        var snippets = store.snippets
        if let tag {
            snippets = snippets.filter { $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
        }
        let ordered: [Snippet]
        if query.isEmpty {
            ordered = snippets.sorted { lhs, rhs in
                let left = lhs.lastUsedAt ?? lhs.updatedAt
                let right = rhs.lastUsedAt ?? rhs.updatedAt
                return left == right ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending : left > right
            }
        } else {
            let normalized = query.normalizedForSearch
            ordered = snippets.compactMap { snippet -> (Snippet, Double)? in
                score(snippet, query: query, normalized: normalized).map { (snippet, $0) }
            }
            .sorted { $0.1 == $1.1 ? $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending : $0.1 > $1.1 }
            .map(\.0)
        }
        let pinned = ordered.filter(\.isPinned).map { item(for: $0) }
        let others = ordered.filter { !$0.isPinned }.map { item(for: $0) }
        return [
            ResultSection(id: "pinned", title: "Épinglés", items: pinned),
            ResultSection(id: "snippets", title: query.isEmpty ? "Snippets" : "Résultats", items: others),
        ].filter { !$0.items.isEmpty }
    }

    /// Mot-clé exact d'abord, puis le nom, le mot-clé et enfin le contenu.
    static func score(_ snippet: Snippet, query: String, normalized: String) -> Double? {
        if snippet.keyword == query { return 1_000 }
        var best = Fuzzy.score(normalized, snippet.name)
        if let keyword = snippet.keyword, let value = Fuzzy.score(normalized, keyword).map({ $0 * 0.95 }), value > (best ?? 0) { best = value }
        for tag in snippet.tags {
            if let value = Fuzzy.score(normalized, tag).map({ $0 * 0.7 }), value > (best ?? 0) { best = value }
        }
        if best == nil, snippet.text.normalizedForSearch.contains(normalized) { best = 40 }
        return best
    }

    // MARK: - Formulaire

    enum AfterSave {
        /// Revenir à l'écran d'avant (liste, presse-papiers).
        case pop
        /// Fermer le lanceur avec une confirmation.
        case hud
    }

    /// Crée (`editing == nil`) ou modifie un snippet. `template` préremplit une création (duplication).
    static func form(editing: Snippet?, template: Snippet? = nil, text: String = "", name: String = "", after: AfterSave) -> FormScreen {
        let source = editing ?? template
        let fields = [
            FormField(id: "name", label: "Nom", kind: .text, placeholder: "Par exemple : Signature", value: source?.name ?? name,
                      info: "Facultatif : la première ligne du texte sinon."),
            FormField(id: "text", label: "Texte", kind: .textArea(lines: 7), value: source?.text ?? text,
                      info: "Placeholders : {cursor} place le curseur, {clipboard} insère le presse-papiers, {selection} le texte sélectionné, {date}, {time}, {datetime}, {day}, {uuid}, {argument name=\"prénom\"} demande une valeur, {snippet name=\"Signature\"} insère un autre snippet. Modificateurs : {clipboard | trim | uppercase}."),
            FormField(id: "keyword", label: "Mot-clé", kind: .text, placeholder: "Par exemple : ;sig", value: source?.keyword ?? "",
                      info: "Tapé dans n’importe quelle application, il est remplacé par le texte. Sans espace, guillemet, apostrophe ni accent grave."),
            FormField(id: "tags", label: "Étiquettes", kind: .text, placeholder: "Travail, Perso", value: source?.tags.joined(separator: ", ") ?? "",
                      info: "Séparées par des virgules ; ⌘P filtre la recherche par étiquette."),
        ]
        let form = FormScreen(
            id: editing.map { "snippets.edit." + $0.id.uuidString } ?? "snippets.create",
            title: editing == nil ? "Créer un snippet" : "Modifier le snippet",
            icon: icon,
            submitTitle: editing == nil ? "Créer le snippet" : "Enregistrer",
            fields: fields
        ) { state in
            let text = state["text"]
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                state.error = "Le texte est vide"
                return .stay
            }
            guard text.count <= SnippetRules.maxLength else {
                state.error = "Le texte dépasse 65 000 caractères (\(text.count))"
                return .stay
            }
            let keyword = state.trimmed("keyword")
            if let error = SnippetRules.keywordError(keyword) {
                state.error = error
                return .stay
            }
            if !keyword.isEmpty, let owner = SnippetStore.shared.snippet(keyword: keyword), owner.id != editing?.id {
                state.error = "Le mot-clé « \(keyword) » est déjà pris par « \(owner.name) »"
                return .stay
            }
            let name = state.trimmed("name").nilIfEmpty ?? SnippetRules.defaultName(for: text)
            var snippet = editing ?? Snippet(name: name, text: text, isPinned: template?.isPinned ?? false)
            snippet.name = name
            snippet.text = text
            snippet.keyword = keyword.nilIfEmpty
            snippet.tags = SnippetRules.parseTags(state["tags"])
            SnippetStore.shared.save(snippet)
            switch after {
            case .pop: return .pop
            case .hud: return .hud(editing == nil ? "Snippet « \(name) » créé" : "Snippet enregistré")
            }
        }
        return form
    }

    // MARK: - Import et export

    /// Le compte rendu d'un import ou d'un export, `nil` si l'utilisateur a annulé.
    static func importFromFile() -> String? {
        guard let url = JSONFilePanel.open(title: "Importer des snippets") else { return nil }
        guard let data = try? Data(contentsOf: url), let incoming = try? SnippetTransfer.decode(data) else {
            return "⚠︎ Fichier illisible : un tableau JSON de snippets est attendu"
        }
        let report = SnippetTransfer.merge(incoming, into: store.snippets)
        store.add(report.added)
        return importSummary(added: report.added.count, skipped: report.skipped, noun: "snippet")
    }

    static func exportToFile() -> String? {
        guard let url = JSONFilePanel.save(title: "Exporter des snippets", fileName: "Snippets.json") else { return nil }
        store.flush()
        do {
            try SnippetTransfer.export(store.snippets).write(to: url, options: .atomic)
            let count = store.snippets.count
            return "\(count) snippet\(count > 1 ? "s" : "") exporté\(count > 1 ? "s" : "")"
        } catch {
            return "⚠︎ Écriture impossible : \(error.localizedDescription)"
        }
    }

    static func importSummary(added: Int, skipped: Int, noun: String) -> String {
        let addedText = "\(added) \(noun)\(added > 1 ? "s" : "") ajouté\(added > 1 ? "s" : "")"
        guard skipped > 0 else { return addedText }
        return addedText + ", \(skipped) ignoré\(skipped > 1 ? "s" : "") (doublons ou mots-clés déjà pris)"
    }

    /// Montre un compte rendu : une erreur commence par « ⚠︎ ».
    static func presentReport(_ message: String?) {
        guard let message else { return }
        if message.hasPrefix("⚠︎ ") {
            HUD.shared.show(String(message.dropFirst(3)), symbol: "exclamationmark.triangle.fill")
        } else {
            HUD.shared.show(message)
        }
    }

    // MARK: - Autotests

    static func selfTest(_ check: (Bool, String) -> Void) {
        check(SnippetRules.keywordError(";sig") == nil, "mot-clé valable")
        check(SnippetRules.keywordError("deux mots") != nil, "mot-clé avec une espace refusé")
        check(SnippetRules.keywordError("l'adr") != nil && SnippetRules.keywordError("l’adr") != nil, "apostrophes refusées")
        check(SnippetRules.keywordError("\"x") != nil && SnippetRules.keywordError("`x") != nil, "guillemets et accents graves refusés")
        check(SnippetRules.parseTags(" Travail, perso,, travail ") == ["Travail", "perso"], "étiquettes séparées par des virgules, sans doublon")

        let keywords = [";sig", "sig", "signature", "adr"]
        let immediate = KeywordMatcher.match(buffer: "Merci ;si", typed: "g", keywords: keywords, mode: .immediate, insideWords: false)
        check(immediate == KeywordMatch(keyword: ";sig", charactersToDelete: 3, delimiter: nil), "immédiat : « ;sig » trouvé dès le g, 3 caractères à effacer")
        check(KeywordMatcher.match(buffer: "", typed: "s", keywords: keywords, mode: .immediate, insideWords: false) == nil, "immédiat : rien avant la fin du mot-clé")
        let delimited = KeywordMatcher.match(buffer: "voici adr", typed: " ", keywords: keywords, mode: .delimiter, insideWords: false)
        check(delimited == KeywordMatch(keyword: "adr", charactersToDelete: 3, delimiter: " "), "délimiteur : « adr » suivi d’une espace")
        check(KeywordMatcher.match(buffer: "voici adr", typed: "e", keywords: keywords, mode: .delimiter, insideWords: false) == nil, "délimiteur : une lettre ne déclenche pas")
        check(KeywordMatcher.match(buffer: "padr", typed: ".", keywords: keywords, mode: .delimiter, insideWords: false) == nil, "dans un mot : ignoré par défaut")
        check(KeywordMatcher.match(buffer: "padr", typed: ".", keywords: keywords, mode: .delimiter, insideWords: true)?.keyword == "adr", "dans un mot : développé si le réglage le permet")
        check(KeywordMatcher.match(buffer: "abc;si", typed: "g", keywords: keywords, mode: .immediate, insideWords: false)?.keyword == ";sig", "un mot-clé qui commence par une ponctuation se développe partout")
        check(KeywordMatcher.match(buffer: "x signatur", typed: "e", keywords: keywords, mode: .immediate, insideWords: false)?.keyword == "signature", "le mot-clé le plus long l’emporte")
        check(KeywordMatcher.match(buffer: "x sig", typed: "\n", keywords: keywords, mode: .delimiter, insideWords: false)?.delimiter == "\n", "le retour est un délimiteur")

        let existing = [Snippet(name: "Signature", text: "Cordialement", keyword: ";sig")]
        let incoming = [
            SnippetExchange(name: "Signature", text: "Cordialement", keyword: ";sig"),
            SnippetExchange(name: "Autre", text: "Bonjour", keyword: ";sig"),
            SnippetExchange(name: "Salut", text: "Salut !", keyword: nil),
            SnippetExchange(name: "Salut", text: "Salut !", keyword: nil),
            SnippetExchange(name: "Adresse", text: "12 rue des Lilas", keyword: ";adr"),
            SnippetExchange(name: "Mauvais", text: "x", keyword: "a b"),
        ]
        let report = SnippetTransfer.merge(incoming, into: existing)
        check(report.added.map(\.name) == ["Salut", "Adresse"] && report.skipped == 4, "import : doublons, collisions de mots-clés et mots-clés invalides ignorés")
        let roundTrip = try? SnippetTransfer.decode(SnippetTransfer.export(existing))
        check(roundTrip?.first?.keyword == ";sig" && roundTrip?.first?.text == "Cordialement", "export relu à l’identique")
        check((try? SnippetTransfer.decode(Data(#"[{"name":"A","text":"B"}]"#.utf8)))?.first?.keyword == nil, "import au format de Raycast, mot-clé facultatif")

        var context = Placeholders.Context(usage: .snippet)
        context.clipboard = { $0 == 0 ? "presse" : nil }
        let expanded = Placeholders.expand("Bonjour {cursor}, {clipboard} !", context: context)
        check(expanded.text == "Bonjour , presse !" && expanded.cursorFromEnd == 10, "développement : curseur compté depuis la fin")
        context.snippet = { $0 == "Signature" ? "Camille" : nil }
        context.arguments = ["prénom": "Léa"]
        check(Placeholders.expand("{argument name=\"prénom\"} — {snippet name=\"Signature\"}", context: context).text == "Léa — Camille", "arguments et snippet imbriqué")
        let preview = previewMarkdown("# Titre *gras*\n- {cursor}")
        check(preview.contains("\\#") && preview.contains("\\*") && preview.contains("`{cursor}`\u{2060}**"), "aperçu : Markdown neutralisé, placeholders mis en évidence")
    }
}
