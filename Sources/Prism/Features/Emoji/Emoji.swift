import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Réglages et données

/// Réglages du sélecteur d'emojis, dans les préférences de l'app (`emoji.*`).
@MainActor
final class EmojiPreferences: ObservableObject {
    static let shared = EmojiPreferences()

    enum PrimaryAction: String, CaseIterable {
        case paste, copy

        var title: String { self == .paste ? "Coller dans l’application active" : "Copier dans le presse-papiers" }
    }

    static let columnRange = 6...10
    static let defaultColumns = 8

    private let defaults = UserDefaults.standard

    /// Nombre de colonnes de la grille (6 à 10), changé aussi par ⌘- ⌘+ ⌘0.
    @Published var columns: Int {
        didSet {
            let clamped = min(max(columns, Self.columnRange.lowerBound), Self.columnRange.upperBound)
            if clamped != columns { columns = clamped; return }
            defaults.set(columns, forKey: "emoji.columns")
            NotificationCenter.default.post(name: .prismDataDidChange, object: nil)
        }
    }

    @Published var primaryAction: PrimaryAction {
        didSet { defaults.set(primaryAction.rawValue, forKey: "emoji.primaryAction") }
    }

    /// Ton de peau appliqué aux emojis qui en acceptent un.
    @Published var skinTone: SkinTone {
        didSet {
            defaults.set(skinTone.rawValue, forKey: "emoji.skinTone")
            NotificationCenter.default.post(name: .prismDataDidChange, object: nil)
        }
    }

    private init() {
        let saved = defaults.integer(forKey: "emoji.columns")
        columns = Self.columnRange.contains(saved) ? saved : Self.defaultColumns
        primaryAction = PrimaryAction(rawValue: defaults.string(forKey: "emoji.primaryAction") ?? "") ?? .paste
        skinTone = SkinTone(rawValue: defaults.integer(forKey: "emoji.skinTone")) ?? .none
    }
}

/// Emojis épinglés et mots-clés personnalisés, dans `emoji.json`.
@MainActor
final class EmojiStore: ObservableObject {
    static let shared = EmojiStore()

    struct Content: Codable {
        /// Caractères de base (sans ton de peau), dans l'ordre choisi.
        var pinned: [String] = []
        /// Mots-clés ajoutés par l'utilisateur, par caractère de base.
        var keywords: [String: [String]] = [:]
    }

    let store = JSONStore("emoji.json", default: Content())

    private init() {}

    var data: Content {
        get { store.value }
        set { store.value = newValue; objectWillChange.send() }
    }

    func isPinned(_ character: String) -> Bool { data.pinned.contains(character) }

    func togglePin(_ character: String) {
        if let index = data.pinned.firstIndex(of: character) {
            data.pinned.remove(at: index)
        } else {
            data.pinned.append(character)
        }
    }

    func movePin(_ character: String, by delta: Int) {
        guard let index = data.pinned.firstIndex(of: character) else { return }
        let target = max(0, min(data.pinned.count - 1, index + delta))
        data.pinned.swapAt(index, target)
    }

    func keywords(for character: String) -> [String] { data.keywords[character] ?? [] }

    func setKeywords(_ keywords: [String], for character: String) {
        let cleaned = keywords.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        data.keywords[character] = cleaned.isEmpty ? nil : cleaned
    }

    /// « fête, joie ; youpi » → les mots-clés, séparés par des virgules ou des points-virgules, sans doublon.
    static func parseKeywords(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

// MARK: - Grille

@MainActor
enum EmojiProvider {
    /// Colonnes de la grille, selon le réglage.
    static var columns: Int { EmojiPreferences.shared.columns }

    /// Les cellules sont plus hautes quand il y a moins de colonnes.
    static var cellHeight: CGFloat { [6: 78, 7: 70, 8: 62, 9: 58, 10: 54][columns] ?? 62 }

    static func sections(query: String) -> [ResultSection] {
        sections(query: query, category: nil)
    }

    /// `category` nil : toutes les catégories ; sinon seulement celle-ci (filtre ⌘P).
    static func sections(query: String, category: EmojiCategory?) -> [ResultSection] {
        let store = EmojiStore.shared
        let entries = category.map { wanted in EmojiCatalog.all.filter { $0.category == wanted } } ?? EmojiCatalog.all
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            var sections: [ResultSection] = []
            if category == nil {
                let pinned = store.data.pinned.compactMap { EmojiCatalog.byCharacter[$0] }
                if !pinned.isEmpty {
                    sections.append(grid("emoji-pinned", "Épinglés", pinned.map { item($0, idPrefix: "emoji-pinned:") }))
                }
                let pinnedSet = Set(store.data.pinned)
                let frequent = UsageStore.shared.topKeys(prefix: "emoji:", limit: columns * 3)
                    .compactMap { EmojiCatalog.byCharacter[EmojiCatalog.base(of: String($0.dropFirst("emoji:".count)))] }
                    .filter { !pinnedSet.contains($0.character) }
                    .prefix(columns * 2)
                if !frequent.isEmpty {
                    sections.append(grid("emoji-frequent", "Utilisés fréquemment", frequent.map { item($0, idPrefix: "emoji-frequent:") }))
                }
            }
            // Une section par catégorie, et par famille pour les symboles Unicode.
            var groups: [(id: String, title: String, entries: [EmojiEntry])] = []
            for entry in entries {
                let title = entry.group ?? entry.category.title
                if groups.last?.title == title {
                    groups[groups.count - 1].entries.append(entry)
                } else {
                    groups.append((entry.category.rawValue + "-" + title, title, [entry]))
                }
            }
            sections += groups.map { group in grid("emoji-" + group.id, group.title, group.entries.map { item($0) }) }
            return sections
        }

        let keywords = store.data.keywords.mapValues { $0.map(EmojiCatalog.normalize) }
        let pinned = Set(store.data.pinned)
        func scored(fuzzy: Bool) -> [(entry: EmojiEntry, score: Double)] {
            entries.compactMap { entry in
                guard var score = EmojiCatalog.score(entry, query: trimmed, customKeywords: keywords[entry.character] ?? [], fuzzy: fuzzy) else { return nil }
                if pinned.contains(entry.character) { score += 15 }
                score += UsageStore.shared.boost("emoji:" + entry.character)
                return (entry, score)
            }
        }
        // La recherche floue (fautes, abréviations) seulement si rien ne correspond vraiment.
        var matches = scored(fuzzy: false)
        if matches.isEmpty { matches = scored(fuzzy: true) }
        // Le tri garde l'ordre du sélecteur entre emojis de même note.
        let sorted = matches.enumerated()
            .sorted { $0.element.score == $1.element.score ? $0.offset < $1.offset : $0.element.score > $1.element.score }
            .map { item($0.element.entry) }
        var sections = sorted.isEmpty ? [] : [grid("emoji-results", "Résultats", sorted)]
        // Peu ou pas de résultats : l'IA cherche par le sens (« fatigué », « bonne chance »).
        if category == nil, sorted.count < columns {
            let shown = Set(matches.map(\.entry.character))
            let suggested = EmojiAI.suggestions(for: trimmed).filter { !shown.contains($0.character) }
            if !suggested.isEmpty {
                sections.append(grid("emoji-ai", "Suggestions de l’IA", suggested.map { item($0, idPrefix: "emoji-ai:") }))
            }
        }
        return sections
    }

    private static func grid(_ id: String, _ title: String, _ items: [ResultItem]) -> ResultSection {
        ResultSection(id: id, title: title, items: items, columns: columns, cellHeight: cellHeight)
    }

    /// Le texte collé : avec le ton de peau par défaut si l'emoji en accepte un.
    static func output(for entry: EmojiEntry) -> String {
        entry.supportsSkinTone ? EmojiCatalog.applying(EmojiPreferences.shared.skinTone, to: entry.character) : entry.character
    }

    static func item(_ entry: EmojiEntry, idPrefix: String = "emoji:") -> ResultItem {
        let text = output(for: entry)
        return ResultItem(
            id: idPrefix + entry.character,
            title: entry.title,
            subtitle: entry.group ?? entry.category.title,
            icon: .emoji(entry.character == text ? entry.glyph : text),
            style: .emoji,
            keywords: [entry.name],
            usageKey: "emoji:" + entry.character,
            actions: actions(for: entry, text: text)
        )
    }

    // MARK: - Actions

    static func actions(for entry: EmojiEntry, text: String) -> [ItemAction] {
        let store = EmojiStore.shared
        let isSymbol = entry.category == .unicode
        let paste = ItemAction(title: Actions.pasteTitle, symbol: "doc.on.clipboard") { Paster.paste(text) }
        let copy = ItemAction(title: isSymbol ? "Copier le symbole" : "Copier l’emoji", symbol: "doc.on.doc") {
            Pasteboard.copy(text)
            return .hud("\(entry.glyph == entry.character ? text : entry.title) copié")
        }
        var actions = EmojiPreferences.shared.primaryAction == .paste ? [paste, copy] : [copy, paste]
        actions.append(ItemAction(
            title: "Coller et garder ouvert", symbol: "rectangle.and.pencil.and.ellipsis",
            shortcut: KeyShortcut(keyCode: 36, modifiers: [.command, .shift], label: "↵")
        ) {
            EmojiInserter.insertKeepingOpen(text)
        })
        if entry.supportsSkinTone {
            actions.append(ItemAction(title: "Coller avec un ton de peau…", symbol: "hand.raised", shortcut: KeyShortcut(keyCode: 17, modifiers: [.command], label: "T")) {
                .push(skinToneScreen(for: entry))
            })
        }
        let pinned = store.isPinned(entry.character)
        actions.append(ItemAction(title: pinned ? "Désépingler" : "Épingler", symbol: pinned ? "pin.slash" : "pin", shortcut: .pin, section: "Organiser") {
            store.togglePin(entry.character)
            return .refresh
        })
        if pinned {
            actions.append(ItemAction(title: "Avancer parmi les épinglés", symbol: "arrow.left", shortcut: .moveUp, section: "Organiser") {
                store.movePin(entry.character, by: -1)
                return .refresh
            })
            actions.append(ItemAction(title: "Reculer parmi les épinglés", symbol: "arrow.right", shortcut: .moveDown, section: "Organiser") {
                store.movePin(entry.character, by: 1)
                return .refresh
            })
        }
        actions.append(ItemAction(title: "Modifier les mots-clés…", symbol: "tag", shortcut: .edit, section: "Organiser") {
            .push(keywordsForm(for: entry))
        })
        actions.append(ItemAction(title: "Retirer des fréquents", symbol: "clock.arrow.circlepath", section: "Organiser") {
            UsageStore.shared.reset("emoji:" + entry.character)
            return .refresh
        })
        actions += [
            ItemAction(title: "Copier le code Unicode", symbol: "number", shortcut: KeyShortcut(keyCode: 8, modifiers: [.command, .option, .shift], label: "C"), section: "Copier") {
                let code = EmojiEntry.codePoints(of: text)
                Pasteboard.copy(code)
                return .hud("\(code) copié")
            },
            Actions.copy(entry.title, title: "Copier le nom", symbol: "textformat", shortcut: .copyText, hud: "Nom copié").inSection("Copier"),
            Actions.copy(entry.name, title: "Copier le nom anglais", symbol: "textformat", hud: "Nom anglais copié").inSection("Copier"),
            ItemAction(title: "Réglages des emojis", symbol: "gearshape", section: "Réglages") {
                NotificationCenter.default.post(name: .prismOpenSettings, object: "emoji")
                return .close
            },
        ]
        return actions
    }

    /// Les six versions d'un emoji, une par ton de peau.
    static func skinToneScreen(for entry: EmojiEntry) -> LauncherScreen {
        ListScreen(id: "emoji-tones." + entry.character, title: entry.title, placeholder: "Choisir un ton de peau…", icon: .emoji(entry.character)) { _ in
            let items = SkinTone.allCases.map { tone -> ResultItem in
                let text = EmojiCatalog.applying(tone, to: entry.character)
                let paste = ItemAction(title: Actions.pasteTitle, symbol: "doc.on.clipboard") { Paster.paste(text) }
                let copy = ItemAction(title: "Copier l’emoji", symbol: "doc.on.doc") {
                    Pasteboard.copy(text)
                    return .hud("\(text) copié")
                }
                var actions = EmojiPreferences.shared.primaryAction == .paste ? [paste, copy] : [copy, paste]
                actions.append(ItemAction(title: "Coller et garder ouvert", symbol: "rectangle.and.pencil.and.ellipsis",
                                          shortcut: KeyShortcut(keyCode: 36, modifiers: [.command, .shift], label: "↵")) {
                    EmojiInserter.insertKeepingOpen(text)
                })
                let isDefault = EmojiPreferences.shared.skinTone == tone
                actions.append(ItemAction(title: isDefault ? "Ton de peau par défaut" : "Utiliser ce ton par défaut", symbol: isDefault ? "checkmark.circle.fill" : "checkmark.circle", section: "Réglages") {
                    EmojiPreferences.shared.skinTone = tone
                    AppContext.launcher?.model.showToast("Ton par défaut : \(tone.title.lowercased())", isError: false)
                    return .refresh
                })
                return ResultItem(
                    id: "emoji-tone:\(tone.rawValue)",
                    title: tone.title,
                    icon: .emoji(text),
                    style: .emoji,
                    usageKey: "emoji:" + entry.character,
                    actions: actions
                )
            }
            return [ResultSection(id: "emoji-tones", title: "Tons de peau", items: items, columns: 6, cellHeight: 78)]
        }
    }

    static func keywordsForm(for entry: EmojiEntry) -> FormScreen {
        let current = EmojiStore.shared.keywords(for: entry.character)
        return FormScreen(
            id: "emoji-keywords." + entry.character,
            title: "Mots-clés de \(entry.glyph) \(entry.title)",
            icon: .emoji(entry.glyph),
            fields: [
                FormField(id: "keywords", label: "Mots-clés", kind: .text, placeholder: "Par exemple : bravo, youpi", value: current.joined(separator: ", "),
                          info: "Séparés par des virgules. La recherche les trouve en plus des noms et des mots-clés d’Unicode."),
                FormField(id: "names", label: "Noms", kind: .info, value: "\(entry.title)\n\(entry.name)"),
            ]
        ) { state in
            let keywords = EmojiStore.parseKeywords(state["keywords"])
            EmojiStore.shared.setKeywords(keywords, for: entry.character)
            return .then(.pop, .toast(keywords.isEmpty ? "Mots-clés retirés" : "Mots-clés enregistrés"))
        }
    }
}

/// Coller sans fermer le lanceur : le texte est inséré dans le champ actif de l'application de premier plan
/// par l'accessibilité ; à défaut, collage classique puis réouverture du lanceur.
@MainActor
enum EmojiInserter {
    static func insertKeepingOpen(_ text: String) -> ActionOutcome {
        if insertViaAccessibility(text) {
            AppContext.launcher?.model.showToast("\(text) inséré", isError: false)
            return .stay
        }
        let outcome = Paster.paste(text)
        if case .close = outcome {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { AppContext.launcher?.show() }
        }
        return outcome
    }

    private static func insertViaAccessibility(_ text: String) -> Bool {
        guard Paster.isTrusted, let app = AppContext.previousApp else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let field = unsafeBitCast(focused, to: AXUIElement.self)
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(field, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue else {
            return false
        }
        return AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }
}

// MARK: - Écran

/// La grille des emojis : filtre par catégorie (⌘P), colonnes réglables (⌘- ⌘+ ⌘0).
@MainActor
final class EmojiScreen: LauncherScreen {
    init() {
        super.init(id: "emoji", title: "Emojis et symboles", placeholder: "Rechercher un emoji ou un symbole…", icon: .symbol("face.smiling.inverse", Palette.yellow))
        filter = ScreenFilter(
            options: [ScreenFilter.Option(id: "all", title: "Tous")] + EmojiCategory.allCases.map { ScreenFilter.Option(id: $0.rawValue, title: $0.title) },
            selected: "all"
        )
    }

    var category: EmojiCategory? { filter.flatMap { EmojiCategory(rawValue: $0.selected) } }

    override func sections(query: String) -> [ResultSection] {
        EmojiProvider.sections(query: query, category: category)
    }

    override func emptyState(query: String) -> (symbol: String, message: String) {
        query.isEmpty ? ("face.smiling", "Aucun emoji") : ("magnifyingglass", "Aucun emoji ni symbole pour « \(query) »")
    }

    override func handleKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers == .command || modifiers == [.command, .shift] else { return false }
        let characters = event.charactersIgnoringModifiers ?? ""
        let preferences = EmojiPreferences.shared
        // Les caractères d'abord (claviers AZERTY), puis les touches physiques du QWERTY et du pavé numérique.
        if characters == "-" || event.keyCode == 27 || event.keyCode == 78 {
            preferences.columns -= 1
        } else if characters == "+" || characters == "=" || event.keyCode == 24 || event.keyCode == 69 {
            preferences.columns += 1
        } else if characters == "0" || characters == "à" || event.keyCode == 29 || event.keyCode == 82 {
            preferences.columns = EmojiPreferences.defaultColumns
        } else {
            return false
        }
        reload()
        return true
    }
}

// MARK: - Fonctionnalité

@MainActor
enum EmojiFeature: PrismFeature {
    static func screen() -> LauncherScreen { EmojiScreen() }

    static var commands: [ResultItem] {
        [Command.screen(
            "emoji", "Rechercher un emoji ou un symbole", subtitle: "Emojis et symboles",
            symbol: "face.smiling.inverse", color: Palette.yellow,
            keywords: ["emoji", "smiley", "symboles", "caracteres speciaux", "unicode", "fleche", "guillemets"],
            screen: screen
        )]
    }

    static func fallbacks(query: String) -> [ResultItem] {
        [ResultItem(
            id: "fallback.emoji",
            title: "Rechercher un emoji",
            subtitle: query,
            icon: .symbol("face.smiling.inverse", Palette.yellow),
            accessory: "Commande",
            actions: [ItemAction(title: "Rechercher un emoji", symbol: "face.smiling") { .push(screen(), query: query) }]
        )]
    }

    static var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "emoji", title: "Emojis", symbol: "face.smiling.inverse", color: Palette.yellow, order: 40) { AnyView(EmojiSettingsView()) }]
    }

    static func selfTest(_ check: (Bool, String) -> Void) {
        check(EmojiAI.parse("😴 🥱 Voici : 💤 😴 abc") == ["😴", "🥱", "💤"], "suggestions de l’IA : emojis gardés, texte et doublons écartés")

        let emojis = EmojiCatalog.emojis
        check(emojis.count > 1800, "\(emojis.count) emojis du système, \(EmojiCatalog.symbols.count) symboles Unicode")
        let categories = Set(EmojiCatalog.all.map(\.category))
        check(categories.count == EmojiCategory.allCases.count, "toutes les catégories sont remplies")
        check(EmojiCatalog.byCharacter["😀"]?.category == .smileys, "😀 dans Smileys et émotions")
        check(EmojiCatalog.byCharacter["👋"]?.category == .people, "👋 dans Personnes")
        check(EmojiCatalog.byCharacter["🇫🇷"]?.frenchName == "drapeau de la France", "drapeaux nommés en français")
        check(EmojiCatalog.byCharacter["👩‍💻"] != nil, "séquences ZWJ présentes")
        check(EmojiCatalog.byCharacter["«"]?.category == .unicode, "guillemets dans les symboles Unicode")
        check(EmojiCatalog.applying(.medium, to: "👋") == "👋🏽", "ton de peau simple")
        check(EmojiCatalog.applying(.dark, to: "☝️") == "☝🏿", "ton de peau : sélecteur de variante retiré")
        check(EmojiCatalog.applying(.light, to: "🧑‍🤝‍🧑") == "🧑🏻‍🤝‍🧑🏻", "ton de peau d'un couple, poignée de main intacte")
        check(EmojiCatalog.applying(.mediumDark, to: "👩‍💻") == "👩🏾‍💻", "ton de peau d'une séquence ZWJ")
        check(EmojiCatalog.base(of: "☝🏿") == "☝️", "retour au caractère de base")
        let smiling = EmojiCatalog.byCharacter["😀"]
        let thumbs = EmojiCatalog.byCharacter["👍"]
        check(smiling?.supportsSkinTone == false && thumbs?.supportsSkinTone == true, "tons de peau proposés à bon escient")
        check(EmojiEntry.codePoints(of: "👋🏽") == "U+1F44B U+1F3FD", "code Unicode")
        func first(_ query: String, _ category: EmojiCategory? = nil) -> String? {
            EmojiProvider.sections(query: query, category: category).first?.items.first.map { String($0.id.dropFirst("emoji:".count)) }
        }
        check(first("coeur") == "❤️", "« coeur » donne ❤️ en premier")
        check(first("heart") == "❤️", "« heart » donne ❤️ en premier")
        check(first("licorne") == "🦄", "recherche en français")
        check(first("unicorn") == "🦄", "recherche en anglais")
        check(first("pouce haut") == "👍", "plusieurs mots")
        check(first("mdr") == "😂", "mots familiers français")
        check(first("lcrne") == "🦄", "recherche floue en dernier recours")
        check(first("flèche droite", .unicode) == "→", "symboles : flèche")
        check(first("guillemet ouvrant") == "«", "symboles : guillemet")
        check(first("tiret cadratin") == "—", "symboles : tiret cadratin")
        check(first("commande") == "⌘", "symboles : touche Commande")
        check(first("france", .flags) == "🇫🇷", "filtre par catégorie")
        check(EmojiProvider.sections(query: "chat", category: .food).first?.items.contains { $0.id == "emoji:🐈" } != true, "le filtre écarte les autres catégories")
        if let wave = EmojiCatalog.byCharacter["👋"] {
            check(EmojiProvider.keywordsForm(for: wave).fields.first?.id == "keywords", "formulaire des mots-clés")
            let tones = EmojiProvider.skinToneScreen(for: wave).sections(query: "").first?.items.compactMap { item -> String? in
                if case .emoji(let text) = item.icon { return text } else { return nil }
            }
            check(tones == ["👋", "👋🏻", "👋🏼", "👋🏽", "👋🏾", "👋🏿"], "écran des six tons de peau")
            let actions = EmojiProvider.item(wave).actions.map(\.title)
            check(actions.contains("Coller avec un ton de peau…") && actions.contains("Copier le code Unicode") && actions.contains("Épingler"), "actions d'un emoji")
        }
        check(EmojiProvider.sections(query: "", category: .unicode).map(\.title) == UnicodeSymbols.groups.map(\.title), "symboles Unicode rangés par famille")
        check(EmojiStore.parseKeywords("fête, joie ; youpi,, Fête") == ["fête", "joie", "youpi"], "mots-clés personnalisés")
        if let slight = EmojiCatalog.byCharacter["🙂"] {
            check(EmojiCatalog.score(slight, query: "zorglub", customKeywords: ["zorglub"]) != nil, "un mot-clé personnalisé trouve l'emoji")
        }
    }
}

// MARK: - Réglages

struct EmojiSettingsView: View {
    @ObservedObject private var preferences = EmojiPreferences.shared
    @ObservedObject private var store = EmojiStore.shared
    @State private var newCharacter = ""
    @State private var newKeywords = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Picker("Colonnes", selection: $preferences.columns) {
                    ForEach(Array(EmojiPreferences.columnRange), id: \.self) { count in
                        Text("\(count) colonnes").tag(count)
                    }
                }
                Picker("Action principale (↵)", selection: $preferences.primaryAction) {
                    ForEach(EmojiPreferences.PrimaryAction.allCases, id: \.self) { action in
                        Text(action.title).tag(action)
                    }
                }
                Picker("Ton de peau par défaut", selection: $preferences.skinTone) {
                    ForEach(SkinTone.allCases, id: \.self) { tone in
                        Text("\(tone.sample)  \(tone.title)").tag(tone)
                    }
                }
            } header: {
                Text("Grille")
            } footer: {
                Text("Dans la grille : ⌘- et ⌘+ changent le nombre de colonnes, ⌘0 revient à \(EmojiPreferences.defaultColumns) ; ⌘P filtre par catégorie ; ⇧⌘↵ colle sans fermer la fenêtre ; ⌘K montre toutes les actions.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(store.data.keywords.keys.sorted(), id: \.self) { character in
                    KeywordRow(character: character)
                }
                HStack(spacing: 8) {
                    TextField("", text: $newCharacter, prompt: Text("Emoji"))
                        .labelsHidden()
                        .frame(width: 70)
                    TextField("", text: $newKeywords, prompt: Text("Mots-clés, séparés par des virgules"))
                        .labelsHidden()
                        .onSubmit(add)
                    Button("Ajouter", action: add)
                        .disabled(newCharacter.isEmpty || newKeywords.isEmpty)
                }
                .textFieldStyle(.roundedBorder)
                if let error {
                    Text(error).font(.system(size: 11.5)).foregroundStyle(Palette.red)
                }
            } header: {
                Text("Mots-clés personnalisés")
            } footer: {
                Text("Aussi depuis la grille : ⌘E sur un emoji. La recherche les trouve en plus des noms français et anglais.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Épinglés et fréquents") {
                LabeledContent("Épinglés") {
                    HStack {
                        Text(store.data.pinned.isEmpty ? "Aucun (⌘. dans la grille)" : store.data.pinned.joined(separator: " "))
                            .lineLimit(1)
                        Button("Tout désépingler") { store.data.pinned = [] }
                            .disabled(store.data.pinned.isEmpty)
                    }
                }
                LabeledContent("Utilisés fréquemment") {
                    Button("Oublier") {
                        for key in UsageStore.shared.topKeys(prefix: "emoji:", limit: 10_000) { UsageStore.shared.reset(key) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        let character = newCharacter.trimmingCharacters(in: .whitespaces)
        let base = EmojiCatalog.base(of: character)
        guard EmojiCatalog.byCharacter[base] != nil else {
            error = "« \(character) » n’est pas dans le catalogue"
            return
        }
        let keywords = EmojiStore.parseKeywords(newKeywords)
        store.setKeywords(store.keywords(for: base) + keywords, for: base)
        newCharacter = ""
        newKeywords = ""
        error = nil
    }
}

private struct KeywordRow: View {
    let character: String
    @ObservedObject private var store = EmojiStore.shared
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            Text(character).font(.system(size: 18)).frame(width: 28)
            Text(EmojiCatalog.byCharacter[character]?.title ?? "")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            TextField("", text: $text, prompt: Text("Mots-clés"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit { store.setKeywords(EmojiStore.parseKeywords(text), for: character) }
            Button {
                store.setKeywords([], for: character)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Retirer ces mots-clés")
        }
        .onAppear { text = store.keywords(for: character).joined(separator: ", ") }
    }
}


/// Emojis trouvés par le sens, grâce à l'IA (Apple Intelligence par défaut, sur l'appareil),
/// quand les noms et les mots-clés ne suffisent pas. Les réponses sont gardées pour la session.
@MainActor
enum EmojiAI {
    private static var cache: [String: [String]] = [:]
    private static var pending: String?
    private static var generation = 0

    static func suggestions(for query: String) -> [EmojiEntry] {
        let key = query.normalizedForSearch
        guard key.count >= 3 else { return [] }
        if let cached = cache[key] {
            return cached.compactMap { EmojiCatalog.byCharacter[EmojiCatalog.base(of: $0)] ?? EmojiCatalog.byCharacter[$0] }
        }
        request(key, original: query)
        return []
    }

    private static func request(_ key: String, original: String) {
        guard let complete = AppHooks.aiComplete, pending != key, !CommandLine.arguments.contains("--snapshot"), !CommandLine.arguments.contains("--selftest") else { return }
        generation += 1
        let current = generation
        pending = key
        Task { @MainActor in
            // Attendre la fin de la frappe.
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard current == generation else { return }
            let prompt = "Propose jusqu’à 12 emojis qui correspondent au sens de « \(original) ». Réponds uniquement avec les emojis, séparés par des espaces, sans texte."
            let answer = (try? await complete(prompt, "Tu choisis des emojis pertinents. Tu réponds seulement par des emojis.")) ?? ""
            cache[key] = parse(answer)
            if pending == key { pending = nil }
            NotificationCenter.default.post(name: .prismDataDidChange, object: nil)
        }
    }

    /// Les emojis connus du catalogue, dans l'ordre de la réponse, sans doublon.
    static func parse(_ answer: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for character in answer {
            let text = String(character)
            guard character.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0xFF }) else { continue }
            let known = EmojiCatalog.byCharacter[EmojiCatalog.base(of: text)] ?? EmojiCatalog.byCharacter[text]
            guard let entry = known, !seen.contains(entry.character) else { continue }
            seen.insert(entry.character)
            result.append(entry.character)
        }
        return Array(result.prefix(12))
    }
}
