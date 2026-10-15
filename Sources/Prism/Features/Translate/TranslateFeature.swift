import AppKit
import SwiftUI

/// Une commande de traduction personnalisée : une paire fixe (« Français → Anglais »), lancée comme une commande.
struct TranslationCommand: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// `nil` : détection automatique.
    var source: String?
    var target: String

    var sourceLanguage: TranslationLanguage? { Languages.language(code: source) }
    var targetLanguage: TranslationLanguage { Languages.language(code: target) ?? Languages.system }

    var commandID: String { "translate.custom.\(id.uuidString)" }

    static func defaultName(source: TranslationLanguage?, target: TranslationLanguage) -> String {
        guard let source else { return "Traduire en \(target.french)" }
        return "\(source.title) → \(target.title)"
    }
}

@MainActor
final class TranslationCommandStore: ObservableObject {
    static let shared = TranslationCommandStore()
    let store = JSONStore("translate-commands.json", default: [TranslationCommand]())

    private init() {}

    var commands: [TranslationCommand] {
        get { store.value }
        set { store.value = newValue; objectWillChange.send() }
    }

    func save(_ command: TranslationCommand) {
        if let index = commands.firstIndex(where: { $0.id == command.id }) {
            commands[index] = command
        } else {
            commands.append(command)
        }
    }

    func remove(_ id: UUID) {
        commands.removeAll { $0.id == id }
    }
}

/// Les formulaires de création et de modification d'une commande de traduction.
@MainActor
enum TranslationCommandForms {
    static func form(for command: TranslationCommand) -> FormScreen {
        let isNew = !TranslationCommandStore.shared.commands.contains { $0.id == command.id }
        let languages = Languages.all.map { (value: $0.code, title: $0.title) }
        return FormScreen(
            id: "translate.command." + command.id.uuidString,
            title: isNew ? "Nouvelle commande de traduction" : "Modifier « \(command.name) »",
            icon: .symbol("character.bubble.fill", Palette.blue),
            submitTitle: isNew ? "Créer la commande" : "Enregistrer",
            fields: [
                FormField(id: "name", label: "Nom", kind: .text, placeholder: "Français → Anglais", value: command.name),
                FormField(id: "source", label: "Langue source", kind: .dropdown([(value: "auto", title: "Détecter la langue")] + languages), value: command.source ?? "auto"),
                FormField(id: "target", label: "Langue cible", kind: .dropdown(languages), value: command.target,
                          info: "La commande apparaît dans la recherche principale ; donnez-lui un alias ou un raccourci global (⌘K)."),
            ]
        ) { state in
            let source = state["source"] == "auto" ? nil : state["source"]
            let target = state["target"]
            guard Languages.language(code: target) != nil else {
                state.error = "Choisissez la langue cible"
                return .stay
            }
            if source == target {
                state.error = "Les deux langues sont identiques"
                return .stay
            }
            var updated = command
            updated.source = source
            updated.target = target
            let name = state.trimmed("name")
            updated.name = name.isEmpty ? TranslationCommand.defaultName(source: updated.sourceLanguage, target: updated.targetLanguage) : name
            TranslationCommandStore.shared.save(updated)
            return .then(.pop, .toast(isNew ? "Commande « \(updated.name) » créée" : "Commande enregistrée"))
        }
    }
}

/// Traduction : écran « Traduire », traduction en ligne dans la recherche principale, commandes personnalisées.
@MainActor
enum TranslateFeature: PrismFeature {
    static func start() {
        AppHooks.translate = { text in
            TranslateScreen(prefill: text.isEmpty ? nil : text)
        }
        // Les statuts des langues, prêts quand on ouvre un menu de langue.
        TranslationStatusCache.shared.refresh()
    }

    /// Ouvre l'écran ; lancé par un raccourci global, il part du texte sélectionné dans l'app au premier plan.
    static func open(source: TranslationLanguage?, target: TranslationLanguage, title: String = "Traduire") -> ActionOutcome {
        let screen = TranslateScreen(source: source, target: target, title: title)
        if let launcher = AppContext.launcher, !launcher.isVisible {
            screen.closesOnEscape = true
            if TranslatePreferences.shared.useSelection {
                // La sélection est lue avant d'ouvrir le lanceur, quand l'app visée est encore devant.
                Task { @MainActor in
                    let selection = await SelectedText.read()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    CommandRunner.present(.push(screen, query: selection))
                }
                return .close
            }
        }
        return .push(screen)
    }

    static var commands: [ResultItem] {
        let preferences = TranslatePreferences.shared
        var items = [
            Command.make(
                "translate", "Traduire", subtitle: "Traduction",
                symbol: "character.bubble.fill", color: Palette.blue,
                keywords: ["translate", "traduction", "traducteur", "langue", "language"],
                actions: [ItemAction(title: "Ouvrir la commande", symbol: "arrow.right.circle") {
                    open(source: preferences.initialSource, target: preferences.initialTarget)
                }]
            ),
        ]
        for command in TranslationCommandStore.shared.commands {
            let source = command.sourceLanguage
            let target = command.targetLanguage
            items.append(Command.make(
                command.commandID, command.name, subtitle: "Traduction",
                symbol: "character.bubble.fill", color: Palette.teal,
                keywords: ["translate", "traduire", target.french, target.english] + (source.map { [$0.french, $0.english] } ?? []),
                actions: [
                    ItemAction(title: "Ouvrir la commande", symbol: "arrow.right.circle") {
                        open(source: source, target: target, title: command.name)
                    },
                    ItemAction(title: "Modifier la commande", symbol: "pencil", shortcut: .edit) {
                        .push(TranslationCommandForms.form(for: command))
                    },
                    ItemAction(title: "Supprimer la commande", symbol: "trash", shortcut: .removeEntry, isDestructive: true) {
                        TranslationCommandStore.shared.remove(command.id)
                        return .then(.refresh, .toast("Commande supprimée"))
                    },
                ]
            ))
        }
        items.append(Command.make(
            "translate.new-command", "Créer une commande de traduction", subtitle: "Traduction",
            symbol: "plus", color: Palette.blue,
            keywords: ["translate", "traduction", "paire", "langues"],
            actions: [ItemAction(title: "Créer la commande", symbol: "plus") {
                .push(TranslationCommandForms.form(for: TranslationCommand(
                    name: "",
                    source: preferences.initialSource?.code,
                    target: preferences.initialTarget.code
                )))
            }]
        ))
        return items
    }

    // MARK: - Traduction en ligne

    private static var inlineTask: Task<Void, Never>?
    private static var inlineKey: String?
    /// Échecs récents (aucun moteur pour la paire) : une simple ligne vers l'écran, sans réessayer à chaque frappe.
    private static var inlineFailures: [String: Date] = [:]

    static func topSections(query: String) -> [ResultSection] {
        guard TranslatePreferences.shared.inlineTranslation, let (text, target) = Languages.parseInline(query) else { return [] }
        let detected = Languages.detect(text)
        let key = "\(target.code)|\(text)"
        let open = ItemAction(title: "Ouvrir dans Traduire", symbol: "character.bubble", shortcut: KeyShortcut(keyCode: 31, modifiers: [.command], label: "O")) {
            .push(TranslateScreen(source: nil, target: target), query: text)
        }

        // Déjà dans la langue demandée, ou aucun moteur : une simple ligne vers l'écran.
        let failedRecently = inlineFailures[key].map { Date().timeIntervalSince($0) < 30 } ?? false
        if detected == target || failedRecently {
            let row = ResultItem(
                id: "translate.inline",
                title: "Traduire « \(text) » en \(target.french)",
                icon: .symbol("character.bubble.fill", Palette.blue),
                accessory: "Traduction",
                usageKey: "",
                actions: [open]
            )
            return [ResultSection(id: "translate", title: "Traduction", items: [row])]
        }

        let sourceCaption = detected?.title ?? "Texte"
        if let output = Translator.cached(text, from: nil, to: target) {
            let copy = ItemAction(title: "Copier la traduction", symbol: "doc.on.doc") {
                Pasteboard.copy(output.text)
                return .hud("Traduction copiée")
            }
            let paste = Actions.paste(output.text)
            let primary = TranslatePreferences.shared.primaryAction == .paste ? [paste, copy] : [copy, paste]
            let card = ResultItem(
                id: "translate.inline",
                title: output.text,
                subtitle: text,
                icon: .symbol("character.bubble.fill", Palette.blue),
                style: .card(source: text, sourceCaption: output.source?.title ?? sourceCaption, result: output.text, resultCaption: target.title),
                usageKey: "",
                actions: primary + [
                    open,
                    ItemAction(title: "Copier le texte source", symbol: "text.quote", shortcut: TranslateScreen.copySourceShortcut) {
                        Pasteboard.copy(text)
                        return .hud("Texte source copié")
                    },
                    ItemAction(title: "Prononcer la traduction", symbol: "speaker.wave.2", shortcut: TranslateScreen.speakShortcut) {
                        TranslateSpeaker.toggle(output.text, language: target)
                        return .stay
                    },
                ]
            )
            return [ResultSection(id: "translate", title: "Traduction", items: [card])]
        }

        startInlineTranslation(text: text, target: target, key: key)
        let pending = ResultItem(
            id: "translate.inline",
            title: "Traduction en \(target.french)…",
            icon: .symbol("character.bubble.fill", Palette.blue),
            style: .card(source: text, sourceCaption: sourceCaption, result: "…", resultCaption: target.title),
            usageKey: "",
            actions: [open]
        )
        return [ResultSection(id: "translate", title: "Traduction", items: [pending])]
    }

    /// Traduit en tâche de fond, puis la recherche principale se recalcule (`prismDataDidChange`).
    private static func startInlineTranslation(text: String, target: TranslationLanguage, key: String) {
        guard inlineKey != key else { return }
        inlineTask?.cancel()
        inlineKey = key
        inlineTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            do {
                _ = try await Translator.translate(text, from: nil, to: target)
            } catch {
                guard !Task.isCancelled else { return }
                inlineFailures[key] = Date()
            }
            if inlineKey == key { inlineKey = nil }
            NotificationCenter.default.post(name: .prismDataDidChange, object: nil)
        }
    }

    // MARK: - Liens profonds

    /// `prism://translate?text=…&to=de&from=en`.
    static func handle(url: URL) -> Bool {
        guard url.host == "translate" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let preferences = TranslatePreferences.shared
        let target = Languages.language(code: value("to")) ?? value("to").flatMap(Languages.named) ?? preferences.initialTarget
        let source = Languages.language(code: value("from")) ?? preferences.initialSource
        let screen = TranslateScreen(source: source, target: target)
        screen.closesOnEscape = true
        CommandRunner.present(.push(screen, query: value("text") ?? ""))
        return true
    }

    // MARK: - Réglages

    static var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "translate", title: "Traduction", symbol: "character.bubble.fill", color: Palette.blue, order: 60) {
            AnyView(TranslateSettingsView())
        }]
    }

    // MARK: - Autotests

    static func selfTest(_ check: (Bool, String) -> Void) {
        check(Languages.named("german")?.code == "de", "« german » → allemand")
        check(Languages.named("allemand")?.code == "de", "« allemand » → allemand")
        check(Languages.named("jap")?.code == "ja", "« jap » → japonais")
        check(Languages.named("Japonais")?.code == "ja", "majuscules ignorées")
        check(Languages.named("chinois")?.code == "zh-Hans", "« chinois » → chinois simplifié")
        check(Languages.named("francais")?.code == "fr", "accents facultatifs")
        check(Languages.named("de") == nil, "un code de langue n'est pas un nom")
        check(Languages.named("ja") == nil, "moins de trois caractères refusés")
        check(Languages.named("china") == nil, "« china » n'est pas une langue")
        check(Languages.search("jap").first?.code == "ja", "recherche floue : « jap » d'abord japonais")
        check(Languages.search("allem").first?.code == "de", "recherche floue : « allem »")
        check(Languages.language(code: "zh-TW")?.code == "zh-Hant", "zh-TW → chinois traditionnel")
        check(Languages.language(code: "pt-PT")?.code == "pt-BR", "pt-PT → portugais")
        check(Languages.language(code: "fr-CA")?.code == "fr", "fr-CA → français")

        let hello = Languages.parseInline("hello in german")
        check(hello?.text == "hello" && hello?.target.code == "de", "« hello in german »")
        let bonjour = Languages.parseInline("bonjour en anglais")
        check(bonjour?.text == "bonjour" && bonjour?.target.code == "en", "« bonjour en anglais »")
        let hola = Languages.parseInline("hola into french")
        check(hola?.text == "hola" && hola?.target.code == "fr", "« hola into french »")
        let merci = Languages.parseInline("merci en japonais")
        check(merci?.text == "merci" && merci?.target.code == "ja", "« merci en japonais »")
        let partial = Languages.parseInline("good morning in ital")
        check(partial?.text == "good morning" && partial?.target.code == "it", "nom de langue partiel « ital »")
        let nested = Languages.parseInline("je suis en retard en anglais")
        check(nested?.text == "je suis en retard" && nested?.target.code == "en", "dernière occurrence du séparateur")
        let quoted = Languages.parseInline("« au revoir » en espagnol")
        check(quoted?.text == "au revoir", "guillemets retirés")
        check(Languages.parseInline("made in china") == nil, "« made in china » n'est pas une traduction")
        check(Languages.parseInline("in german") == nil, "texte vide refusé")
        check(Languages.parseInline("hello en de") == nil, "code de langue refusé")
        check(Languages.parseInline("safari") == nil, "simple recherche ignorée")

        check(Languages.detect("Bonjour, je voudrais réserver une table pour ce soir.")?.code == "fr", "détection du français")
        check(Languages.detect("The quick brown fox jumps over the lazy dog.")?.code == "en", "détection de l'anglais")
        check(Languages.detect("Wie geht es dir heute?")?.code == "de", "détection de l'allemand")
        let english = Languages.all[0]
        check(Languages.alternate(for: english) != english, "langue de repli différente de la cible")
        check(TextStats.summary("Bonjour le monde") == "3 mots · 16 caractères", "mots et caractères")
        check(TextStats.words("l’arbre, c’est-à-dire") >= 2, "mots avec apostrophes")
        check(TranslationCommand.defaultName(source: Languages.language(code: "fr"), target: english) == "Français → Anglais", "nom d'une commande personnalisée")
        check(TranslationCommand.defaultName(source: nil, target: english) == "Traduire en anglais", "nom avec détection")
        check(Translator.aiPrompt(from: nil, to: english).contains("into English"), "prompt de traduction stricte")
    }
}

// MARK: - Réglages

struct TranslateSettingsView: View {
    @ObservedObject private var preferences = TranslatePreferences.shared
    @ObservedObject private var commands = TranslationCommandStore.shared
    @ObservedObject private var statuses = TranslationStatusCache.shared

    var body: some View {
        Form {
            Section("Traduire") {
                Picker("Action principale (↵)", selection: $preferences.primaryAction) {
                    Text("Copier la traduction").tag(TranslatePreferences.PrimaryAction.copy)
                    Text("Coller dans l’app active").tag(TranslatePreferences.PrimaryAction.paste)
                }
                Picker("Moteur", selection: $preferences.engine) {
                    ForEach(TranslatePreferences.Engine.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Langue source par défaut", selection: Binding(
                    get: { preferences.defaultSource ?? "auto" },
                    set: { preferences.defaultSource = $0 == "auto" ? nil : $0 }
                )) {
                    Text("Détecter la langue").tag("auto")
                    Divider()
                    ForEach(Languages.all) { Text($0.title).tag($0.code) }
                }
                Picker("Langue cible par défaut", selection: $preferences.defaultTarget) {
                    ForEach(Languages.all) { Text($0.title).tag($0.code) }
                }
                Toggle("Reprendre la dernière langue cible utilisée", isOn: $preferences.rememberLastTarget)
                Toggle("Partir du texte sélectionné quand la commande est lancée par un raccourci", isOn: $preferences.useSelection)
                Toggle("Traduire dans la recherche principale (« hello in german », « merci en japonais »)", isOn: $preferences.inlineTranslation)
            }
            if !Translator.isAIAvailable, preferences.engine != .apple {
                Text("L’IA n’est pas configurée : seules les paires installées d’Apple Translation sont traduites.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Section {
                if commands.commands.isEmpty {
                    Text("Aucune commande. Une commande traduit toujours vers la même langue : « Français → Anglais », « Traduire en japonais »…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                ForEach(commands.commands) { command in
                    TranslationCommandRow(command: command)
                }
                Button {
                    let target = preferences.initialTarget
                    commands.save(TranslationCommand(name: TranslationCommand.defaultName(source: nil, target: target), source: nil, target: target.code))
                } label: {
                    Label("Ajouter une commande", systemImage: "plus")
                }
            } header: {
                Text("Commandes personnalisées")
            } footer: {
                Text("Chacune apparaît dans la recherche principale : donnez-lui un alias ou un raccourci global dans l’onglet Commandes.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                if !Translator.isAppleAvailable {
                    Text("Apple Translation sur l’appareil demande macOS 26.")
                        .foregroundStyle(.secondary)
                } else if statuses.statuses.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Lecture des langues installées…").foregroundStyle(.secondary)
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                        ForEach(Languages.all) { language in
                            LanguageStatusCell(language: language, status: statuses.statuses[language.code])
                        }
                    }
                }
                HStack {
                    Button("Gérer les langues de traduction…") { Translator.openLanguageSettings() }
                    Button("Actualiser") { statuses.refresh(force: true) }
                }
            } header: {
                Text("Langues d’Apple Translation")
            } footer: {
                Text("Les langues installées traduisent hors ligne, sur l’appareil. Les autres se téléchargent dans Réglages Système › Général › Langue et région › Langues de traduction.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { statuses.refresh() }
    }
}

private struct TranslationCommandRow: View {
    let command: TranslationCommand
    @ObservedObject private var store = TranslationCommandStore.shared
    @State private var name = ""

    var body: some View {
        HStack(spacing: 8) {
            ItemIconView(icon: .symbol("character.bubble.fill", Palette.teal), size: 18)
            TextField("Nom", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140)
                .onSubmit(saveName)
                .onChange(of: name) { _, _ in saveName() }
            Picker("", selection: Binding(
                get: { command.source ?? "auto" },
                set: { value in update { $0.source = value == "auto" ? nil : value } }
            )) {
                Text("Détecter").tag("auto")
                ForEach(Languages.all) { Text($0.title).tag($0.code) }
            }
            .labelsHidden()
            .frame(width: 130)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            Picker("", selection: Binding(
                get: { command.target },
                set: { value in update { $0.target = value } }
            )) {
                ForEach(Languages.all) { Text($0.title).tag($0.code) }
            }
            .labelsHidden()
            .frame(width: 130)
            Button(role: .destructive) {
                store.remove(command.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Supprimer la commande")
        }
        .onAppear { name = command.name }
    }

    private func update(_ change: (inout TranslationCommand) -> Void) {
        var updated = store.commands.first { $0.id == command.id } ?? command
        let previousDefault = TranslationCommand.defaultName(source: updated.sourceLanguage, target: updated.targetLanguage)
        change(&updated)
        // Le nom suit les langues tant qu'on ne l'a pas personnalisé.
        if updated.name == previousDefault {
            updated.name = TranslationCommand.defaultName(source: updated.sourceLanguage, target: updated.targetLanguage)
            name = updated.name
        }
        store.save(updated)
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != command.name else { return }
        update { $0.name = trimmed }
    }
}

private struct LanguageStatusCell: View {
    let language: TranslationLanguage
    let status: Translator.PairStatus?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 14)
            Text(language.title)
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .help(help)
    }

    private var symbol: String {
        switch status {
        case .installed: "checkmark.circle.fill"
        case .downloadable: "arrow.down.circle"
        default: "minus.circle"
        }
    }

    private var color: Color {
        switch status {
        case .installed: Palette.green
        case .downloadable: Palette.blue
        default: Palette.gray
        }
    }

    private var help: String {
        switch status {
        case .installed: "Installée"
        case .downloadable: "À télécharger"
        case .unsupported: "Non prise en charge par Apple Translation"
        default: "Indisponible"
        }
    }
}
