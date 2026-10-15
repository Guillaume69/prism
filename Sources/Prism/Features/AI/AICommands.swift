import AppKit
import SwiftUI

/// Ce que fait une commande d'IA de sa réponse.
enum AICommandOutput: String, Codable, CaseIterable, Identifiable {
    /// Afficher dans le lanceur, avec les actions (coller, copier, continuer…).
    case show
    /// Remplacer la sélection (coller par-dessus).
    case replace
    /// Coller dans l'application de premier plan.
    case paste
    /// Copier dans le presse-papiers.
    case copy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .show: "Afficher dans Prism"
        case .replace: "Remplacer la sélection"
        case .paste: "Coller dans l’application"
        case .copy: "Copier dans le presse-papiers"
        }
    }
}

/// Une commande d'IA : un prompt à placeholders, un modèle, une créativité, une sortie.
struct AICommandDefinition: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var symbol: String
    /// Nom d'une couleur de la palette (`AICommandColors`).
    var color: String
    var prompt: String
    /// `nil` : le modèle par défaut des commandes.
    var model: String?
    /// `nil` : la créativité générale.
    var creativity: Double?
    var output: AICommandOutput = .show
    var isBuiltIn = false

    var commandID: String { "command:ai.cmd." + id }
    var tint: Color { AICommandColors.color(color) }
    var icon: ItemIcon { .symbol(symbol, tint) }
    var needsSelection: Bool { Placeholders.needsSelection(prompt) }
    var usesBrowserTab: Bool { Placeholders.tokens(in: prompt).contains { $0.name == "browser-tab" } }
}

enum AICommandColors {
    static let names = ["violet", "indigo", "blue", "teal", "green", "yellow", "orange", "red", "pink", "gray"]

    static func color(_ name: String) -> Color {
        switch name {
        case "indigo": Palette.indigo
        case "blue": Palette.blue
        case "teal": Palette.teal
        case "green": Palette.green
        case "yellow": Palette.yellow
        case "orange": Palette.orange
        case "red": Palette.red
        case "pink": Palette.pink
        case "gray": Palette.gray
        default: Palette.violet
        }
    }

    static func title(_ name: String) -> String {
        switch name {
        case "indigo": "Indigo"
        case "blue": "Bleu"
        case "teal": "Bleu-vert"
        case "green": "Vert"
        case "yellow": "Jaune"
        case "orange": "Orange"
        case "red": "Rouge"
        case "pink": "Rose"
        case "gray": "Gris"
        default: "Violet"
        }
    }
}

/// Les symboles proposés pour une commande personnalisée.
enum AICommandSymbols {
    static let all: [(symbol: String, title: String)] = [
        ("sparkles", "Étincelles"), ("wand.and.stars", "Baguette"), ("text.badge.checkmark", "Texte vérifié"),
        ("pencil.line", "Crayon"), ("text.quote", "Citation"), ("list.bullet.rectangle", "Liste"),
        ("doc.text.magnifyingglass", "Loupe sur document"), ("character.bubble", "Traduction"), ("lightbulb", "Ampoule"),
        ("ladybug", "Bogue"), ("chevron.left.forwardslash.chevron.right", "Code"), ("envelope", "Courriel"),
        ("bubble.left.and.bubble.right", "Discussion"), ("briefcase", "Mallette"), ("face.smiling", "Sourire"),
        ("globe", "Globe"), ("questionmark.bubble", "Question"), ("checklist", "Liste de tâches"),
        ("number", "Nombres"), ("calendar", "Calendrier"),
    ]
}

// MARK: - Les commandes intégrées

enum AIBuiltInCommands {
    static let all: [AICommandDefinition] = [
        AICommandDefinition(
            id: "improve-writing", name: "Améliorer l’écriture", symbol: "wand.and.stars", color: "violet",
            prompt: "Améliore l’écriture du texte suivant : rends-le plus clair, plus fluide et plus précis, corrige les fautes, et garde son sens, sa langue et son ton. Réponds uniquement avec le texte amélioré, sans commentaire ni guillemets.\n\nTexte :\n{selection}",
            isBuiltIn: true
        ),
        AICommandDefinition(
            id: "fix-spelling", name: "Corriger l’orthographe et la grammaire", symbol: "text.badge.checkmark", color: "green",
            prompt: "Corrige l’orthographe, la grammaire et la ponctuation du texte suivant, sans changer ni son style, ni son sens, ni sa langue. S’il n’y a rien à corriger, renvoie-le tel quel. Réponds uniquement avec le texte corrigé, sans commentaire ni guillemets.\n\nTexte :\n{selection}",
            isBuiltIn: true
        ),
        AICommandDefinition(
            id: "explain", name: "Expliquer simplement", symbol: "lightbulb", color: "yellow",
            prompt: "Explique simplement le texte suivant, comme à quelqu’un qui découvre le sujet : d’abord l’idée principale, puis les notions utiles, avec un exemple concret si possible. Réponds dans la langue du texte.\n\nTexte :\n{selection}",
            isBuiltIn: true
        ),
        AICommandDefinition(
            id: "professional-tone", name: "Ton professionnel", symbol: "briefcase", color: "blue",
            prompt: "Réécris le texte suivant sur un ton professionnel, courtois et assuré, sans en changer le sens ni la langue. Réponds uniquement avec le texte réécrit, sans commentaire ni guillemets.\n\nTexte :\n{selection}",
            isBuiltIn: true
        ),
        AICommandDefinition(
            id: "friendly-tone", name: "Ton amical", symbol: "face.smiling", color: "orange",
            prompt: "Réécris le texte suivant sur un ton amical, chaleureux et naturel, sans en changer le sens ni la langue. Réponds uniquement avec le texte réécrit, sans commentaire ni guillemets.\n\nTexte :\n{selection}",
            isBuiltIn: true
        ),
        AICommandDefinition(
            id: "find-bugs", name: "Trouver les bogues dans le code", symbol: "ladybug", color: "red",
            prompt: "Analyse le code suivant et trouve ses bogues : erreurs de logique, cas limites oubliés, problèmes de sécurité ou de performance. Pour chaque problème, dis où il se trouve, pourquoi c’en est un et comment le corriger, avec le code corrigé. S’il n’y a pas de bogue, dis-le simplement.\n\nCode :\n{selection}",
            isBuiltIn: true
        ),
        AICommandDefinition(
            id: "summarize-page", name: "Résumer la page web", symbol: "doc.text.magnifyingglass", color: "teal",
            prompt: "Résume la page web suivante : une phrase d’ensemble, puis les points clés en liste. Ignore la navigation, les publicités et les mentions légales. Réponds en français.\n\nPage :\n{browser-tab}",
            isBuiltIn: true
        ),
        AICommandDefinition(
            id: "ask-page", name: "Poser une question sur la page web", symbol: "questionmark.bubble", color: "teal",
            prompt: "Réponds à la question à partir de la page web suivante. Si la page ne contient pas la réponse, dis-le.\n\nQuestion :\n{argument name=\"question\"}\n\nPage :\n{browser-tab}",
            isBuiltIn: true
        ),
        AICommandDefinition(
            id: "translate-english", name: "Traduire en anglais", symbol: "character.bubble", color: "indigo",
            prompt: "Translate the following text into natural, idiomatic English, keeping its tone and formatting. Reply with the translation only, without comments or quotation marks.\n\nText:\n{selection}",
            isBuiltIn: true
        ),
        AICommandDefinition(
            id: "summarize-text", name: "Résumer le texte", symbol: "list.bullet.rectangle", color: "pink",
            prompt: "Résume le texte suivant : une phrase d’ensemble, puis les points clés en liste. Réponds dans la langue du texte.\n\nTexte :\n{selection}",
            isBuiltIn: true
        ),
    ]
}

// MARK: - Stockage

@MainActor
final class AICommandStore: ObservableObject {
    static let shared = AICommandStore()

    struct Content: Codable {
        var custom: [AICommandDefinition] = []
        /// Commandes intégrées modifiées, par identifiant.
        var overrides: [String: AICommandDefinition] = [:]
    }

    private let persisted = AIPersisted("ai-commands.json", default: Content())

    @Published var content: Content {
        didSet { persisted.value = content }
    }

    private init() {
        content = Content()
        content = persisted.value
    }

    /// Les intégrées (modifiées le cas échéant), puis les personnalisées.
    var all: [AICommandDefinition] {
        AIBuiltInCommands.all.map { content.overrides[$0.id] ?? $0 } + content.custom
    }

    func command(_ id: String) -> AICommandDefinition? {
        all.first { $0.id == id }
    }

    func isModified(_ id: String) -> Bool { content.overrides[id] != nil }

    func save(_ command: AICommandDefinition) {
        if command.isBuiltIn {
            let original = AIBuiltInCommands.all.first { $0.id == command.id }
            content.overrides[command.id] = command == original ? nil : command
        } else if let index = content.custom.firstIndex(where: { $0.id == command.id }) {
            content.custom[index] = command
        } else {
            content.custom.append(command)
        }
    }

    func delete(_ id: String) {
        content.custom.removeAll { $0.id == id }
    }

    func reset(_ id: String) {
        content.overrides[id] = nil
    }

    func duplicate(_ command: AICommandDefinition) -> AICommandDefinition {
        var copy = command
        copy.id = UUID().uuidString.lowercased()
        copy.name = "\(command.name) (copie)"
        copy.isBuiltIn = false
        content.custom.append(copy)
        return copy
    }

    // MARK: Export et import

    /// Toutes les commandes personnalisées (et les intégrées modifiées) en JSON lisible.
    func exportJSON() -> String {
        let exported = content.custom + Array(content.overrides.values)
        guard let data = try? JSONEncoder.prism.encode(exported) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Ajoute les commandes d'un JSON (un tableau, ou une seule commande) ; renvoie leur nombre.
    func importJSON(_ text: String) -> Int? {
        guard let commands = Self.decode(text) else { return nil }
        for var command in commands {
            if command.isBuiltIn, AIBuiltInCommands.all.contains(where: { $0.id == command.id }) {
                content.overrides[command.id] = command
                continue
            }
            command.isBuiltIn = false
            if content.custom.contains(where: { $0.id == command.id }) || AIBuiltInCommands.all.contains(where: { $0.id == command.id }) {
                command.id = UUID().uuidString.lowercased()
            }
            content.custom.append(command)
        }
        return commands.count
    }

    static func decode(_ text: String) -> [AICommandDefinition]? {
        let data = Data(text.utf8)
        if let list = try? JSONDecoder.prism.decode([AICommandDefinition].self, from: data) { return list }
        if let single = try? JSONDecoder.prism.decode(AICommandDefinition.self, from: data) { return [single] }
        return nil
    }
}

// MARK: - Exécution

@MainActor
enum AICommandRunner {
    /// Le prompt final : placeholders remplacés, valeurs entourées de `"""`.
    static func expand(_ command: AICommandDefinition, selection: String?, arguments: [String]) -> String {
        var context = Placeholders.Context(usage: .aiCommand)
        context.selection = selection
        context.arguments = Placeholders.argumentValues(arguments, for: command.prompt)
        return Placeholders.expand(command.prompt, context: context).text
    }

    /// Lance une commande : la sélection est lue d'abord si le prompt la demande (depuis l'application d'avant).
    static func run(_ command: AICommandDefinition, arguments: [String] = []) -> ActionOutcome {
        if AIRuntime.isDemo { return .push(AIAnswerScreen.demoCommand(command)) }
        guard command.needsSelection else { return start(command, selection: nil, arguments: arguments) }
        if let text = SelectedText.viaAccessibility(AppContext.previousApp), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return start(command, selection: text, arguments: arguments)
        }
        guard Paster.isTrusted else {
            Paster.requestTrust()
            return .hud("Autorisez Prism dans Accessibilité pour lire la sélection")
        }
        // Le lanceur prendrait le ⌘C simulé : il se ferme, la sélection est copiée, puis il revient sur le résultat.
        Task { @MainActor in
            if AppContext.launcher?.isVisible == true { try? await Task.sleep(nanoseconds: 180_000_000) }
            guard let text = await SelectedText.read(from: AppContext.previousApp),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                HUD.shared.show("Aucun texte sélectionné", symbol: "text.cursor")
                return
            }
            CommandRunner.present(start(command, selection: text, arguments: arguments))
        }
        return .close
    }

    private static func start(_ command: AICommandDefinition, selection: String?, arguments: [String]) -> ActionOutcome {
        let prompt = expand(command, selection: selection, arguments: arguments)
        var conversation = AIConversation()
        conversation.origin = "command"
        conversation.title = command.name
        conversation.isTitleManual = true
        conversation.model = command.model
        let session = AIChatSession(conversation: conversation, usage: .commands)
        session.temperatureOverride = command.creativity
        let display = displayText(for: command, arguments: arguments)

        switch command.output {
        case .show:
            let screen = AIAnswerScreen(session: session, mode: .command(command, hadSelection: selection != nil))
            screen.pendingPrompt = (prompt, display)
            return .push(screen)
        case .replace, .paste, .copy:
            session.onFinish = { text in
                if command.output == .copy {
                    Pasteboard.copy(text)
                    HUD.shared.show("Réponse copiée")
                } else {
                    _ = Paster.paste(text)
                }
            }
            session.onStateChange = { [weak session] in
                if let error = session?.error { HUD.shared.show(error, symbol: "exclamationmark.triangle.fill") }
            }
            session.send(prompt, displayText: display)
            HUD.shared.show("\(command.name)…", symbol: "sparkles")
            AIBackgroundRuns.keep(session)
            return .close
        }
    }

    /// « Poser une question sur la page web : Quel est le prix ? »
    static func displayText(for command: AICommandDefinition, arguments: [String]) -> String {
        let values = arguments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return values.isEmpty ? command.name : "\(command.name) : \(values.joined(separator: " · "))"
    }

    /// La commande de la recherche principale (alias, raccourci global, favoris).
    static func item(_ command: AICommandDefinition) -> ResultItem {
        let arguments = Placeholders.arguments(in: command.prompt)
        var keywords = ["ia", "ai", "intelligence artificielle"]
        if command.needsSelection { keywords.append("selection") }
        if command.usesBrowserTab { keywords += ["page", "web", "navigateur"] }
        var runWithArguments: (@MainActor ([String]) -> ActionOutcome)?
        if !arguments.isEmpty {
            runWithArguments = { (values: [String]) -> ActionOutcome in AICommandRunner.run(command, arguments: values) }
        }
        return Command.make(
            "ai.cmd." + command.id, command.name,
            subtitle: "Commande d’IA",
            symbol: command.symbol, color: command.tint,
            keywords: keywords,
            accessory: "IA",
            arguments: arguments,
            runWithArguments: runWithArguments,
            actions: [
                ItemAction(title: "Lancer la commande", symbol: "sparkles") { run(command) },
                ItemAction(title: "Modifier la commande", symbol: "pencil", shortcut: .edit) { .push(AICommandForm.screen(editing: command)) },
                ItemAction(title: "Dupliquer la commande", symbol: "plus.square.on.square", shortcut: .duplicate) {
                    .push(AICommandForm.screen(editing: AICommandStore.shared.duplicate(command)))
                },
            ]
        )
    }
}

/// Les commandes lancées sans affichage (coller, copier) vivent jusqu'à leur réponse.
@MainActor
enum AIBackgroundRuns {
    private static var running: [ObjectIdentifier: AIChatSession] = [:]

    static func keep(_ session: AIChatSession) {
        let key = ObjectIdentifier(session)
        running[key] = session
        let previous = session.onStateChange
        session.onStateChange = { [weak session] in
            previous?()
            if session?.isGenerating == false { running[key] = nil }
        }
    }
}

// MARK: - Formulaire

@MainActor
enum AICommandForm {
    /// « Créer une commande d’IA », ou la modifier.
    static func screen(editing existing: AICommandDefinition? = nil) -> FormScreen {
        let command = existing ?? AICommandDefinition(
            id: UUID().uuidString.lowercased(), name: "", symbol: "sparkles", color: "violet",
            prompt: "Reformule le texte suivant en trois versions plus courtes :\n\n{selection}"
        )
        let models = [(value: "default", title: "Modèle par défaut des commandes")] + AIModelCatalog.shared.options.map { ($0.rawValue, $0.label) }
        let creativities = [(value: "default", title: "Créativité générale")] + AICreativity.allCases.map { (String($0.rawValue), $0.title) }
        let fields: [FormField] = [
            FormField(id: "name", label: "Nom", kind: .text, placeholder: "Par exemple : Résumer en trois points", value: command.name),
            FormField(id: "symbol", label: "Icône", kind: .dropdown(AICommandSymbols.all.map { ($0.symbol, $0.title) }), value: command.symbol),
            FormField(id: "color", label: "Couleur", kind: .dropdown(AICommandColors.names.map { ($0, AICommandColors.title($0)) }), value: command.color),
            FormField(id: "prompt", label: "Prompt", kind: .textArea(lines: 7), value: command.prompt,
                      info: "Placeholders : {selection} le texte sélectionné, {argument name=\"…\"} une saisie demandée au lancement, {clipboard} le presse-papiers, {browser-tab} la page du navigateur, {date} la date du jour."),
            FormField(id: "model", label: "Modèle", kind: .dropdown(models), value: command.model ?? "default"),
            FormField(id: "creativity", label: "Créativité", kind: .dropdown(creativities), value: command.creativity.map { String($0) } ?? "default"),
            FormField(id: "output", label: "Résultat", kind: .dropdown(AICommandOutput.allCases.map { ($0.rawValue, $0.title) }), value: command.output.rawValue),
        ]
        let title = existing == nil ? "Créer une commande d’IA" : "Modifier « \(command.name) »"
        return FormScreen(id: "ai.command-form." + command.id, title: title, icon: .symbol("sparkles", Palette.violet), submitTitle: existing == nil ? "Créer la commande" : "Enregistrer", fields: fields) { state in
            let name = state.trimmed("name")
            let prompt = state.trimmed("prompt")
            guard !name.isEmpty else { state.error = "Donnez un nom à la commande"; return .stay }
            guard !prompt.isEmpty else { state.error = "Écrivez le prompt de la commande"; return .stay }
            var saved = command
            saved.name = name
            saved.prompt = prompt
            saved.symbol = state["symbol"]
            saved.color = state["color"]
            saved.model = state["model"] == "default" ? nil : state["model"]
            saved.creativity = state["creativity"] == "default" ? nil : Double(state["creativity"])
            saved.output = AICommandOutput(rawValue: state["output"]) ?? .show
            AICommandStore.shared.save(saved)
            return .then(.pop, .toast(existing == nil ? "Commande « \(name) » créée" : "Commande enregistrée"))
        }
    }
}

// MARK: - « Rechercher les commandes d’IA »

@MainActor
enum AICommandsScreen {
    static func make() -> LauncherScreen {
        ListScreen(
            id: "ai.commands",
            title: "Commandes d’IA",
            placeholder: "Rechercher une commande d’IA…",
            icon: .symbol("sparkles", Palette.violet),
            layout: .split(listWidth: 300)
        ) { query in
            sections(query: query)
        }
    }

    static func sections(query: String) -> [ResultSection] {
        let store = AICommandStore.shared
        let normalized = query.normalizedForSearch
        let matching = store.all.filter { normalized.isEmpty || Fuzzy.score(normalized, $0.name) != nil || $0.prompt.normalizedForSearch.contains(normalized) }
        let builtIn = matching.filter(\.isBuiltIn).map(row)
        let custom = matching.filter { !$0.isBuiltIn }.map(row)
        var sections: [ResultSection] = []
        if !custom.isEmpty { sections.append(ResultSection(id: "custom", title: "Mes commandes", items: custom)) }
        if !builtIn.isEmpty { sections.append(ResultSection(id: "builtin", title: "Intégrées", items: builtIn)) }
        sections.append(ResultSection(id: "manage", title: nil, items: [createItem]))
        return sections
    }

    private static var createItem: ResultItem {
        ResultItem(
            id: "ai.commands.create", title: "Créer une commande d’IA", subtitle: "Prompt, modèle, sortie",
            icon: .symbol("plus", Palette.gray), usageKey: "",
            actions: [ItemAction(title: "Créer une commande d’IA", symbol: "plus") { .push(AICommandForm.screen()) }] + manageActions
        )
    }

    private static var manageActions: [ItemAction] {
        [
            ItemAction(title: "Exporter les commandes…", symbol: "square.and.arrow.up", section: "Toutes les commandes") { export() },
            ItemAction(title: "Copier l’export JSON", symbol: "doc.on.doc", section: "Toutes les commandes") {
                Pasteboard.copy(AICommandStore.shared.exportJSON())
                return .toast("Export JSON copié")
            },
            ItemAction(title: "Importer depuis le presse-papiers", symbol: "square.and.arrow.down.on.square", section: "Toutes les commandes") {
                guard let text = NSPasteboard.general.string(forType: .string), let count = AICommandStore.shared.importJSON(text) else {
                    return .toast("Le presse-papiers ne contient pas de commandes d’IA en JSON")
                }
                return .toast("\(count) commande\(count > 1 ? "s" : "") importée\(count > 1 ? "s" : "")")
            },
            ItemAction(title: "Importer un fichier…", symbol: "folder", section: "Toutes les commandes") { importFile() },
        ]
    }

    private static func row(_ command: AICommandDefinition) -> ResultItem {
        let store = AICommandStore.shared
        var tags: [String] = []
        if store.isModified(command.id) { tags.append("Modifiée") }
        if command.output != .show { tags.append(command.output == .copy ? "Copie" : "Colle") }
        var actions: [ItemAction] = [
            ItemAction(title: "Lancer la commande", symbol: "sparkles") { AICommandRunner.run(command) },
            ItemAction(title: "Modifier", symbol: "pencil", shortcut: .edit) { .push(AICommandForm.screen(editing: command)) },
            ItemAction(title: "Dupliquer", symbol: "plus.square.on.square", shortcut: .duplicate) {
                .push(AICommandForm.screen(editing: AICommandStore.shared.duplicate(command)))
            },
            ItemAction(title: "Copier le prompt", symbol: "doc.on.doc", shortcut: .copyText) {
                Pasteboard.copy(command.prompt)
                return .toast("Prompt copié")
            },
        ]
        if command.isBuiltIn, store.isModified(command.id) {
            actions.append(ItemAction(title: "Rétablir la version d’origine", symbol: "arrow.counterclockwise") {
                AICommandStore.shared.reset(command.id)
                return .refresh
            })
        }
        if !command.isBuiltIn {
            actions.append(ItemAction(title: "Supprimer", symbol: "trash", shortcut: .removeEntry, isDestructive: true) {
                AICommandStore.shared.delete(command.id)
                return .refresh
            })
        }
        actions.append(ItemAction(title: "Créer une commande d’IA", symbol: "plus", shortcut: .create, section: "Toutes les commandes") { .push(AICommandForm.screen()) })
        actions += manageActions
        let model = command.model.map { AIModelChoice(rawValue: $0).label } ?? "Par défaut (\(AISettings.shared.choice(for: .commands).label))"
        return ResultItem(
            id: "ai.command." + command.id,
            title: command.name,
            icon: command.icon,
            tags: tags,
            keywords: [command.prompt],
            detail: ItemDetail(
                text: command.prompt,
                metadata: [
                    ("Modèle", model),
                    ("Créativité", command.creativity.map(AICreativity.title(for:)) ?? "Générale"),
                    ("Résultat", command.output.title),
                    ("Type", command.isBuiltIn ? "Intégrée" : "Personnalisée"),
                ]
            ),
            usageKey: command.commandID,
            actions: actions
        )
    }

    /// Écrit l'export dans Téléchargements et le montre dans le Finder.
    private static func export() -> ActionOutcome {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let url = folder.appendingPathComponent("Commandes d’IA Prism.json")
        do {
            try AICommandStore.shared.exportJSON().write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return .hud("Commandes exportées dans Téléchargements")
        } catch {
            return .toast("Export impossible : \(error.localizedDescription)")
        }
    }

    /// Choisit un fichier JSON ; le lanceur s'efface pendant le panneau d'ouverture.
    private static func importFile() -> ActionOutcome {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json]
            panel.allowsMultipleSelection = false
            panel.message = "Choisissez un export de commandes d’IA"
            panel.begin { response in
                MainActor.assumeIsolated {
                    guard response == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
                    if let count = AICommandStore.shared.importJSON(text) {
                        HUD.shared.show("\(count) commande\(count > 1 ? "s" : "") importée\(count > 1 ? "s" : "")")
                    } else {
                        HUD.shared.show("Ce fichier ne contient pas de commandes d’IA", symbol: "exclamationmark.triangle.fill")
                    }
                }
            }
        }
        return .close
    }
}
