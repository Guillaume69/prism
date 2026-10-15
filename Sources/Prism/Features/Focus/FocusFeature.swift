import AppKit
import SwiftUI

/// Raycast Focus : des sessions de concentration qui masquent les apps et remplacent les sites qui distraient.
@MainActor
enum FocusFeature: PrismFeature {
    static func start() {
        FocusManager.shared.install()
    }

    private static let color = Palette.orange
    private static let noSession = ActionOutcome.toast("Aucune session de concentration en cours")

    // MARK: - Commandes

    static var commands: [ResultItem] {
        let manager = FocusManager.shared
        return [
            Command.screen(
                "focus.start", "Démarrer une session de concentration", subtitle: "Concentration",
                symbol: "scope", color: color,
                keywords: ["start focus session", "focus", "concentration", "pomodoro", "bloquer", "deep work", "travail"]
            ) { startForm(prefill: manager.lastConfiguration) },
            Command.run(
                "focus.toggle", "Basculer la session de concentration", subtitle: "Concentration",
                symbol: "power", color: color, keywords: ["toggle focus session", "focus", "concentration", "demarrer", "arreter"]
            ) {
                if manager.session == nil, manager.lastConfiguration == nil { return .push(startForm(prefill: nil)) }
                manager.toggle()
                return .close
            },
            Command.make(
                "focus.edit", "Modifier la session de concentration", subtitle: "Concentration",
                symbol: "slider.horizontal.3", color: color, keywords: ["edit focus session", "ajouter du temps", "objectif", "focus"],
                actions: [ItemAction(title: "Ouvrir la commande", symbol: "arrow.right.circle") {
                    manager.session == nil ? noSession : .push(editForm())
                }]
            ),
            Command.make(
                "focus.pause", "Faire une pause", subtitle: "Concentration",
                symbol: "pause.fill", color: color, keywords: ["pause focus session", "focus", "concentration", "break"],
                actions: [ItemAction(title: "Choisir la durée", symbol: "arrow.right.circle") {
                    guard let session = manager.session else { return noSession }
                    return session.isPaused ? .toast("La session est déjà en pause") : .push(pauseScreen())
                }]
            ),
            Command.run(
                "focus.resume", "Reprendre la concentration", subtitle: "Concentration",
                symbol: "play.fill", color: color, keywords: ["resume focus session", "focus", "reprendre"]
            ) {
                guard let session = manager.session else { return noSession }
                guard session.isPaused else { return .toast("La session n’est pas en pause") }
                manager.resume()
                return .close
            },
            Command.run(
                "focus.complete", "Terminer la session de concentration", subtitle: "Concentration",
                symbol: "checkmark.circle.fill", color: color, keywords: ["complete focus session", "finir", "arreter", "focus"]
            ) {
                guard manager.session != nil else { return noSession }
                manager.complete()
                return .close
            },
            Command.run(
                "focus.cancel", "Annuler la session de concentration", subtitle: "Concentration",
                symbol: "xmark.circle.fill", color: color, keywords: ["cancel focus session", "focus", "abandonner"]
            ) {
                guard manager.session != nil else { return noSession }
                manager.cancel()
                return .close
            },
            Command.run(
                "focus.snooze", "Reporter le blocage", subtitle: "Concentration",
                symbol: "clock.arrow.circlepath", color: color, keywords: ["snooze focus", "debloquer", "focus", "repit"]
            ) {
                guard manager.session != nil else { return noSession }
                guard FocusSettings.shared.snoozeMinutes > 0 else { return .toast("Le report est désactivé dans les réglages") }
                manager.snooze()
                return .close
            },
            Command.screen(
                "focus.categories", "Rechercher des catégories de concentration", subtitle: "Concentration",
                symbol: "square.grid.2x2.fill", color: color, keywords: ["search focus categories", "focus", "categories", "listes"]
            ) { categoriesScreen() },
            Command.screen(
                "focus.createCategory", "Créer une catégorie de concentration", subtitle: "Concentration",
                symbol: "plus.square.fill", color: color, keywords: ["create focus category", "focus", "nouvelle categorie"]
            ) { categoryForm(nil, done: .hud("Catégorie créée")) },
        ]
    }

    // MARK: - Recherche principale

    /// La session en cours, en tête de la recherche vide.
    static func topSections(query: String) -> [ResultSection] {
        let manager = FocusManager.shared
        guard query.isEmpty, let session = manager.session else { return [] }
        let now = manager.isSimulation ? manager.now : Date()
        let clock = session.isPaused ? "En pause" : FocusFormat.clock(session.remaining(at: now) ?? session.elapsed(at: now))
        let item = ResultItem(
            id: "focus.session",
            title: session.goal.isEmpty ? "Session de concentration" : session.goal,
            subtitle: manager.statusText(for: session, at: now) + " · " + manager.scopeDescription(for: session),
            icon: .symbol(session.isPaused ? "pause.fill" : "scope", session.isPaused ? Palette.yellow : color),
            accessory: clock,
            usageKey: "",
            actions: sessionActions(session)
        )
        return [ResultSection(id: "focus", title: "Concentration", items: [item])]
    }

    private static func sessionActions(_ session: FocusSession) -> [ItemAction] {
        let manager = FocusManager.shared
        var actions: [ItemAction] = [
            ItemAction(title: "Modifier la session", symbol: "slider.horizontal.3", shortcut: .edit) { .push(editForm()) },
        ]
        if session.isPaused {
            actions.append(ItemAction(title: "Reprendre", symbol: "play.fill") {
                manager.resume()
                return .close
            })
        } else {
            actions.append(ItemAction(title: "Faire une pause", symbol: "pause.fill") { .push(pauseScreen()) })
        }
        if !session.isUnlimited {
            for minutes in [5, 15, 30] {
                actions.append(ItemAction(title: "Ajouter \(minutes) minutes", symbol: "plus.circle", section: minutes == 5 ? "Durée" : nil) {
                    manager.extend(minutes: minutes)
                    return .refresh
                })
            }
        }
        if FocusSettings.shared.snoozeMinutes > 0, !session.isPaused {
            actions.append(ItemAction(title: "Reporter le blocage (\(FocusSettings.shared.snoozeMinutes) min)", symbol: "clock.arrow.circlepath", section: "Blocage") {
                manager.snooze()
                return .close
            })
        }
        actions.append(ItemAction(
            title: FocusSettings.shared.showInMenuBar ? "Afficher la barre de concentration" : "Déplacer dans la barre des menus",
            symbol: FocusSettings.shared.showInMenuBar ? "capsule" : "menubar.rectangle",
            section: "Affichage"
        ) {
            FocusSettings.shared.showInMenuBar.toggle()
            return .refresh
        })
        actions.append(ItemAction(title: "Terminer la session", symbol: "checkmark.circle", shortcut: KeyShortcut(keyCode: 14, modifiers: [.command, .shift], label: "E"), section: "Session") {
            manager.complete()
            return .close
        })
        actions.append(ItemAction(title: "Annuler la session", symbol: "xmark.circle", shortcut: .removeEntry, isDestructive: true) {
            manager.cancel()
            return .refresh
        })
        return actions
    }

    // MARK: - Formulaires de session

    /// Les champs communs au démarrage et à la modification : mode, catégories, ajouts.
    private static func scopeFields(_ configuration: FocusConfiguration) -> [FormField] {
        var fields = [FormField(
            id: "mode", label: "Mode",
            kind: .dropdown(FocusMode.allCases.map { ($0.rawValue, $0.title) }),
            value: configuration.mode.rawValue
        )]
        for (index, category) in FocusManager.shared.categories.enumerated() {
            fields.append(FormField(
                id: "cat." + category.id,
                label: index == 0 ? "Catégories" : "",
                kind: .checkbox(label: "\(category.name)  ·  \(category.summary)"),
                value: configuration.categoryIDs.contains(category.id) ? "true" : "false"
            ))
        }
        fields.append(FormField(
            id: "apps", label: "Autres apps", kind: .textArea(lines: 2),
            value: configuration.extraApps.joined(separator: "\n"),
            info: "Noms ou identifiants d’apps (Slack, com.spotify.client), un par ligne ou séparés par des virgules."
        ))
        fields.append(FormField(
            id: "websites", label: "Autres sites", kind: .textArea(lines: 2),
            value: configuration.extraWebsites.joined(separator: "\n"),
            info: "Domaines (youtube.com) ; les sous-domaines sont compris. Prism et le Finder ne sont jamais bloqués."
        ))
        return fields
    }

    /// Lit le mode, les catégories et les ajouts ; `nil` et un message d'erreur si la saisie ne va pas.
    private static func readScope(_ state: FormState) -> (mode: FocusMode, categories: [String], apps: [String], websites: [String])? {
        let mode = FocusMode(rawValue: state["mode"]) ?? .block
        let categories = FocusManager.shared.categories.map(\.id).filter { state.bool("cat." + $0) }
        let apps = FocusRules.parseList(state["apps"])
        let websites = FocusRules.parseWebsites(state["websites"])
        if let invalid = websites.invalid.first {
            state.error = "« \(invalid) » n’est pas un nom de domaine"
            return nil
        }
        if mode == .block, categories.isEmpty, apps.isEmpty, websites.valid.isEmpty {
            state.error = "Choisissez au moins une catégorie, une app ou un site à bloquer"
            return nil
        }
        return (mode, categories, apps, websites.valid)
    }

    static func startForm(prefill: FocusConfiguration?) -> FormScreen {
        let configuration = prefill ?? .standard
        var preset = "25"
        var custom = ""
        if let duration = configuration.duration {
            let minutes = Int((duration / 60).rounded())
            if FocusDuration.presets.contains(where: { $0.value == String(minutes) }) {
                preset = String(minutes)
            } else {
                custom = FocusFormat.duration(duration)
            }
        } else {
            preset = "unlimited"
        }
        let fields = [
            FormField(id: "goal", label: "Objectif", kind: .text, placeholder: "Sur quoi voulez-vous vous concentrer ?", value: configuration.goal),
            FormField(id: "duration", label: "Durée", kind: .dropdown(FocusDuration.presets), value: preset),
            FormField(
                id: "custom", label: "Ou durée libre", kind: .text, placeholder: "45 min, 1h30, jusqu’à 16h30…", value: custom,
                info: "Remplace la durée choisie, 24 h au maximum."
            ),
        ] + scopeFields(configuration)
        let form = FormScreen(
            id: "focus.start", title: "Démarrer une session de concentration", icon: .symbol("scope", color),
            submitTitle: "Démarrer la session", fields: fields
        ) { state in
            let now = Date()
            let duration: FocusDuration
            let text = state.trimmed("custom")
            if !text.isEmpty {
                guard let parsed = FocusDuration.parse(text, now: now) else {
                    state.error = "Durée non comprise : essayez « 45 min », « 1h30 » ou « jusqu’à 16h30 »"
                    return .stay
                }
                duration = parsed
            } else {
                duration = FocusDuration.preset(state["duration"], now: now) ?? .limited(25 * 60)
            }
            if let seconds = duration.seconds, seconds > FocusDuration.maximum {
                state.error = "Une session dure 24 h au maximum"
                return .stay
            }
            guard let scope = readScope(state) else { return .stay }
            FocusManager.shared.start(FocusConfiguration(
                goal: state.trimmed("goal"), duration: duration.seconds, mode: scope.mode,
                categoryIDs: scope.categories, extraApps: scope.apps, extraWebsites: scope.websites
            ))
            return .close
        }
        form.initialFocus = "goal"
        return form
    }

    /// Modifier la session : objectif, temps en plus, listes. Sans session, le formulaire de démarrage.
    static func editForm() -> FormScreen {
        guard let session = FocusManager.shared.session else { return startForm(prefill: FocusManager.shared.lastConfiguration) }
        let now = Date()
        var fields = [FormField(id: "goal", label: "Objectif", kind: .text, placeholder: "Sur quoi voulez-vous vous concentrer ?", value: session.goal)]
        if session.isUnlimited {
            fields.append(FormField(id: "info", label: "Durée", kind: .info, value: "Sans limite · \(FocusFormat.duration(session.elapsed(at: now))) écoulées"))
        } else {
            fields.append(FormField(
                id: "add", label: "Ajouter du temps",
                kind: .dropdown([("0", "Ne rien ajouter"), ("5", "+5 min"), ("15", "+15 min"), ("30", "+30 min"), ("60", "+1 h")]),
                value: "0",
                info: FocusManager.shared.statusText(for: session, at: now) + (session.endDate(at: now).map { ", fin à \(FocusFormat.time($0))" } ?? "")
            ))
        }
        fields += scopeFields(session.configuration)
        return FormScreen(
            id: "focus.edit", title: "Modifier la session de concentration", icon: .symbol("slider.horizontal.3", color),
            submitTitle: "Enregistrer", fields: fields
        ) { state in
            guard FocusManager.shared.session != nil else { return noSession }
            guard let scope = readScope(state) else { return .stay }
            FocusManager.shared.update(
                goal: state.trimmed("goal"), mode: scope.mode, categoryIDs: scope.categories,
                extraApps: scope.apps, extraWebsites: scope.websites, addMinutes: Int(state["add"]) ?? 0
            )
            return .hud("Session modifiée")
        }
    }

    static func pauseScreen() -> ListScreen {
        ListScreen(id: "focus.pause", title: "Faire une pause", placeholder: "Durée de la pause…", icon: .symbol("pause.fill", color)) { query in
            let options: [(minutes: Int?, title: String)] = [(5, "5 minutes"), (10, "10 minutes"), (15, "15 minutes"), (nil, "Jusqu’à la reprise")]
            let normalized = query.normalizedForSearch
            let items = options.filter { normalized.isEmpty || Fuzzy.score(normalized, $0.title) != nil }.map { option in
                ResultItem(
                    id: "focus.pause.\(option.minutes ?? 0)",
                    title: option.title,
                    subtitle: option.minutes.map { "Reprise à \(FocusFormat.time(Date().addingTimeInterval(TimeInterval($0 * 60)))), avec un rappel" } ?? "Le blocage est suspendu jusqu’à ce que vous repreniez",
                    icon: .symbol(option.minutes == nil ? "pause.circle.fill" : "cup.and.saucer.fill", Palette.yellow),
                    usageKey: "",
                    actions: [ItemAction(title: "Faire une pause", symbol: "pause.fill") {
                        FocusManager.shared.pause(minutes: option.minutes)
                        return .close
                    }]
                )
            }
            return [ResultSection(id: "pause", title: "Durée de la pause", items: items)]
        }
    }

    // MARK: - Catégories

    static func categoriesScreen() -> ListScreen {
        ListScreen(
            id: "focus.categories", title: "Catégories de concentration", placeholder: "Rechercher des catégories…",
            icon: .symbol("square.grid.2x2.fill", color), layout: .split(listWidth: 300)
        ) { query in
            let manager = FocusManager.shared
            let normalized = query.normalizedForSearch
            let matching = manager.categories.filter { category in
                normalized.isEmpty || Fuzzy.score(normalized, category.name) != nil
                    || category.websites.contains { $0.contains(normalized) }
                    || category.apps.contains { $0.normalizedForSearch.contains(normalized) }
            }
            @MainActor func item(_ category: FocusCategory) -> ResultItem {
                var actions: [ItemAction] = []
                if category.isBuiltIn {
                    actions.append(ItemAction(title: "Dupliquer et modifier", symbol: "plus.square.on.square", shortcut: .duplicate) {
                        .push(categoryForm(manager.draftCopy(of: category), done: .pop))
                    })
                } else {
                    actions.append(ItemAction(title: "Modifier la catégorie", symbol: "pencil", shortcut: .edit) {
                        .push(categoryForm(category, done: .pop))
                    })
                    actions.append(ItemAction(title: "Dupliquer", symbol: "plus.square.on.square", shortcut: .duplicate) {
                        _ = manager.duplicate(category)
                        return .refresh
                    })
                }
                actions.append(ItemAction(title: "Démarrer une session avec cette catégorie", symbol: "scope") {
                    var configuration = manager.lastConfiguration ?? .standard
                    configuration.mode = .block
                    configuration.categoryIDs = [category.id]
                    return .push(startForm(prefill: configuration))
                })
                actions.append(ItemAction(title: "Créer une catégorie", symbol: "plus", shortcut: .create) {
                    .push(categoryForm(nil, done: .pop))
                })
                if !category.isBuiltIn {
                    actions.append(ItemAction(title: "Supprimer la catégorie", symbol: "trash", shortcut: .removeEntry, isDestructive: true) {
                        manager.deleteCategory(category.id)
                        return .refresh
                    })
                }
                return ResultItem(
                    id: "focus.category." + category.id,
                    title: category.name,
                    subtitle: category.summary,
                    icon: .symbol(category.symbol, category.tint),
                    detail: ItemDetail(text: detail(category), metadata: [
                        ("Type", category.isBuiltIn ? "Intégrée, à dupliquer pour la modifier" : "Personnalisée"),
                        ("Apps", "\(category.apps.count)"),
                        ("Sites", "\(category.websites.count)"),
                    ], isMarkdown: true),
                    usageKey: "",
                    actions: actions
                )
            }
            return [
                ResultSection(id: "custom", title: "Personnalisées", items: matching.filter { !$0.isBuiltIn }.map(item)),
                ResultSection(id: "builtin", title: "Intégrées", items: matching.filter(\.isBuiltIn).map(item)),
            ].filter { !$0.items.isEmpty }
        }
    }

    private static func detail(_ category: FocusCategory) -> String {
        var text = "## \(category.name)\n\n"
        text += "**Apps**\n\n"
        text += category.apps.isEmpty ? "Aucune\n" : category.apps.map { "- \(appDisplayName($0))\n" }.joined()
        text += "\n**Sites**\n\n"
        text += category.websites.isEmpty ? "Aucun\n" : category.websites.map { "- \($0)\n" }.joined()
        return text
    }

    /// « Slack » pour `com.tinyspeck.slackmacgap` si l'app est installée, l'entrée telle quelle sinon.
    static func appDisplayName(_ entry: String) -> String {
        guard entry.contains("."), !entry.contains(" "),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry) else { return entry }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static let symbols: [(value: String, title: String)] = [
        ("folder.fill", "Dossier"), ("star.fill", "Étoile"), ("bolt.fill", "Éclair"), ("flame.fill", "Flamme"),
        ("globe", "Globe"), ("app.fill", "App"), ("bubble.left.fill", "Bulle"), ("music.note", "Musique"),
        ("film.fill", "Film"), ("book.fill", "Livre"), ("briefcase.fill", "Travail"), ("cart.fill", "Panier"),
        ("gamecontroller.fill", "Manette"), ("newspaper.fill", "Journal"), ("person.2.fill", "Personnes"), ("play.tv.fill", "Vidéo"),
    ]

    static func categoryForm(_ existing: FocusCategory?, done: ActionOutcome) -> FormScreen {
        let category = existing ?? FocusCategory(id: "custom-" + UUID().uuidString.prefix(8).lowercased(), name: "", symbol: "folder.fill", color: "violet", apps: [], websites: [])
        let fields = [
            FormField(id: "name", label: "Nom", kind: .text, placeholder: "Travail en équipe, Forums…", value: category.name),
            FormField(id: "symbol", label: "Icône", kind: .dropdown(symbols.contains { $0.value == category.symbol } ? symbols : [(category.symbol, category.symbol)] + symbols), value: category.symbol),
            FormField(id: "color", label: "Couleur", kind: .dropdown(FocusCategory.colors.map { ($0.id, $0.title) }), value: category.color),
            FormField(id: "apps", label: "Apps", kind: .textArea(lines: 4), value: category.apps.joined(separator: "\n"), info: "Noms ou identifiants d’apps, un par ligne ou séparés par des virgules."),
            FormField(id: "websites", label: "Sites", kind: .textArea(lines: 4), value: category.websites.joined(separator: "\n"), info: "Domaines ; les sous-domaines sont compris (reddit.com couvre old.reddit.com)."),
        ]
        return FormScreen(
            id: "focus.category", title: existing == nil ? "Créer une catégorie" : "Modifier « \(category.name) »",
            icon: .symbol(category.symbol, category.tint), submitTitle: "Enregistrer la catégorie", fields: fields
        ) { state in
            let name = state.trimmed("name")
            guard !name.isEmpty else {
                state.error = "Donnez un nom à la catégorie"
                return .stay
            }
            let websites = FocusRules.parseWebsites(state["websites"])
            if let invalid = websites.invalid.first {
                state.error = "« \(invalid) » n’est pas un nom de domaine"
                return .stay
            }
            var saved = category
            saved.name = name
            saved.symbol = state["symbol"]
            saved.color = state["color"]
            saved.apps = FocusRules.parseList(state["apps"])
            saved.websites = websites.valid
            saved.isBuiltIn = false
            FocusManager.shared.save(saved)
            return done
        }
    }

    // MARK: - Lanceur

    /// Ouvre le lanceur sur un écran (depuis la barre de concentration ou un lien profond).
    static func openInLauncher(_ screen: LauncherScreen) {
        guard let launcher = AppContext.launcher else { return }
        launcher.show(reset: true)
        launcher.model.push(screen)
    }

    // MARK: - Liens profonds

    /// `prism://focus/start?goal=…&duration=25&mode=block|allow&categories=social,news&apps=…&websites=…`,
    /// `prism://focus/toggle`, `complete`, `cancel`, `pause?minutes=5`, `resume`, `snooze`, `extend?minutes=5`, `edit`.
    static func handle(url: URL) -> Bool {
        guard url.host == "focus" else { return false }
        let manager = FocusManager.shared
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let minutes = value("minutes").flatMap(Int.init)
        switch url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
        case "start":
            switch configuration(from: query) {
            case .success(let configuration): manager.start(configuration)
            case .failure(let error): HUD.shared.show(error.message, symbol: "exclamationmark.triangle.fill")
            }
        case "toggle":
            manager.toggle()
        case "complete", "stop":
            manager.session == nil ? HUD.shared.show("Aucune session en cours", symbol: "scope") : manager.complete()
        case "cancel":
            manager.cancel()
        case "pause":
            manager.pause(minutes: minutes)
        case "resume":
            manager.resume()
        case "snooze":
            manager.snooze(minutes: minutes)
        case "extend":
            manager.extend(minutes: minutes ?? 5)
        case "edit":
            openInLauncher(editForm())
        case "", "new":
            openInLauncher(startForm(prefill: manager.lastConfiguration))
        default:
            HUD.shared.show("Lien de concentration inconnu : \(url.path)", symbol: "exclamationmark.triangle.fill")
        }
        return true
    }

    struct LinkError: Error {
        let message: String
    }

    /// La configuration d'un lien `start` : les paramètres absents reprennent la dernière configuration.
    static func configuration(from query: [URLQueryItem], now: Date = Date()) -> Result<FocusConfiguration, LinkError> {
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        var configuration = FocusManager.shared.lastConfiguration ?? .standard
        if let goal = value("goal") { configuration.goal = goal }
        if let text = value("duration"), !text.isEmpty {
            guard let duration = FocusDuration.preset(text, now: now) ?? FocusDuration.parse(text, now: now) else {
                return .failure(LinkError(message: "Durée non comprise : \(text)"))
            }
            if let seconds = duration.seconds, seconds > FocusDuration.maximum {
                return .failure(LinkError(message: "Une session dure 24 h au maximum"))
            }
            configuration.duration = duration.seconds
        }
        if let mode = value("mode") {
            guard let parsed = FocusMode(rawValue: mode) else { return .failure(LinkError(message: "Mode inconnu : \(mode)")) }
            configuration.mode = parsed
        }
        if let categories = value("categories") {
            let known = FocusManager.shared.categories
            configuration.categoryIDs = FocusRules.parseList(categories).compactMap { entry in
                known.first { $0.id == entry || $0.name.normalizedForSearch == entry.normalizedForSearch }?.id
            }
        }
        if let apps = value("apps") { configuration.extraApps = FocusRules.parseList(apps) }
        if let websites = value("websites") { configuration.extraWebsites = FocusRules.parseWebsites(websites).valid }
        return .success(configuration)
    }

    // MARK: - Réglages

    static var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "focus", title: "Concentration", symbol: "scope", color: color, order: 60) { AnyView(FocusSettingsView()) }]
    }

    // MARK: - Autotests

    static func selfTest(_ check: (Bool, String) -> Void) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 14, minute: 0)) ?? Date()
        func parse(_ text: String) -> FocusDuration? { FocusDuration.parse(text, now: now, calendar: calendar) }

        check(parse("25") == .limited(1500), "durée : un nombre seul en minutes")
        check(parse("45 min") == .limited(2700), "durée : « 45 min »")
        check(parse("1h30") == .limited(5400), "durée : « 1h30 »")
        check(parse("1 h 30") == .limited(5400), "durée : « 1 h 30 »")
        check(parse("1,5 h") == .limited(5400), "durée : « 1,5 h »")
        check(parse("2 heures") == .limited(7200), "durée : « 2 heures »")
        check(parse("90 minutes") == .limited(5400), "durée : « 90 minutes »")
        check(parse("1h et 15 min") == .limited(4500), "durée : « 1h et 15 min »")
        check(parse("jusqu’à 16h30") == .limited(9000), "durée : « jusqu’à 16h30 »")
        check(parse("jusqu'a 16:30") == .limited(9000), "durée : « jusqu'a 16:30 »")
        check(parse("à 9h") == .limited(19 * 3600), "durée : une heure passée vise le lendemain")
        check(parse("until 4pm") == .limited(7200), "durée : « until 4pm »")
        check(parse("journée") == .limited(10 * 3600), "durée : jusqu’à minuit")
        check(parse("Sans limite") == .unlimited, "durée : sans limite")
        check(parse("30h")?.seconds.map { $0 > FocusDuration.maximum } == true, "durée : plus de 24 h repérée")
        check(parse("abc") == nil && parse("25 pommes") == nil && parse("") == nil, "durée : texte non compris refusé")
        check(parse("jusqu'à 25h") == nil, "durée : heure impossible refusée")
        check(FocusDuration.preset("90", now: now, calendar: calendar) == .limited(5400), "durée : valeur de la liste")

        let slack = FocusAppIdentity(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        let finder = FocusAppIdentity(bundleID: "com.apple.finder", name: "Finder")
        let safari = FocusAppIdentity(bundleID: "com.apple.Safari", name: "Safari")
        let xcode = FocusAppIdentity(bundleID: "com.apple.dt.Xcode", name: "Xcode")
        check(FocusRules.app(slack, matches: "COM.tinyspeck.SLACKmacgap"), "app : identifiant sans casse")
        check(FocusRules.app(slack, matches: "slack.app") && FocusRules.app(slack, matches: " Slack "), "app : par son nom")
        check(!FocusRules.app(slack, matches: "Slac"), "app : pas de correspondance partielle")
        let block = FocusRules(mode: .block, apps: ["Slack", "com.apple.finder"], websites: ["reddit.com", "youtube.com/shorts"])
        check(block.blocks(app: slack) && !block.blocks(app: xcode), "blocage : seules les apps listées")
        check(!block.blocks(app: finder), "blocage : le Finder jamais bloqué")
        check(block.blocks(url: "https://www.Reddit.com/r/swift", browser: safari), "site : domaine et www")
        check(block.blocks(url: "https://old.reddit.com/", browser: safari), "site : sous-domaine")
        check(!block.blocks(url: "https://notreddit.com/", browser: safari), "site : domaine voisin non bloqué")
        check(block.blocks(url: "https://youtube.com/shorts/abc", browser: safari) && !block.blocks(url: "https://youtube.com/watch?v=1", browser: safari), "site : chemin")
        check(!block.blocks(url: "file:///tmp/blocked.html", browser: safari) && !block.blocks(url: "about:blank", browser: safari), "site : pages locales jamais bloquées")
        let allow = FocusRules(mode: .allow, apps: ["Xcode"], websites: ["github.com"])
        check(allow.blocks(app: slack) && !allow.blocks(app: xcode), "autoriser seulement : le reste est bloqué")
        check(!allow.blocks(app: finder), "autoriser seulement : le Finder reste permis")
        check(!allow.blocks(app: safari), "autoriser seulement : un site listé permet le navigateur")
        check(!allow.blocks(url: "https://api.github.com/x", browser: safari) && allow.blocks(url: "https://news.ycombinator.com", browser: safari), "autoriser seulement : sites")
        let browserOnly = FocusRules(mode: .allow, apps: ["Safari"], websites: [], allowAllSitesWithBrowser: true)
        check(!browserOnly.blocks(url: "https://example.com", browser: safari), "navigateur autorisé sans site : tout passe (réglage)")
        let strict = FocusRules(mode: .allow, apps: ["Safari"], websites: [], allowAllSitesWithBrowser: false)
        check(strict.blocks(url: "https://example.com", browser: safari), "navigateur autorisé sans site : tout bloqué sans le réglage")
        check(FocusRules.normalizeDomain("https://WWW.Example.com:8080/") == "example.com", "domaine normalisé")
        check(FocusRules.normalizeDomain("pas un site") == nil, "domaine invalide refusé")
        check(FocusRules.parseList("a, b\nc,,A") == ["a", "b", "c"], "liste : virgules, lignes, doublons")

        let sample = FocusConfiguration(goal: "Écrire", duration: 1500, mode: .block, categoryIDs: ["social"], extraApps: [], extraWebsites: ["example.org"])
        var session = FocusSession(configuration: sample, startedAt: now)
        let rules = FocusRules(session: session, categories: FocusCategory.builtIn, allowAllSitesWithBrowser: true)
        check(rules.blocks(url: "https://reddit.com", browser: safari) && rules.blocks(url: "https://example.org", browser: safari), "session : catégories et ajouts réunis")
        check(session.remaining(at: now.addingTimeInterval(600)) == 900, "minuterie : temps restant")
        session.pause(at: now.addingTimeInterval(600), for: 300)
        check(session.remaining(at: now.addingTimeInterval(800)) == 900, "pause : le temps est figé")
        check(session.pauseEndsAt == now.addingTimeInterval(900), "pause : fin prévue")
        session.resume(at: now.addingTimeInterval(900))
        check(session.pausedTotal == 300 && session.elapsed(at: now.addingTimeInterval(1000)) == 700, "reprise : la pause est déduite")
        session.extend(by: 300)
        check(session.remaining(at: now.addingTimeInterval(1000)) == 1100, "prolongation")
        check(!session.isOver(at: now.addingTimeInterval(2099)) && session.isOver(at: now.addingTimeInterval(2100)), "fin détectée à l’échéance")
        var unlimited = FocusSession(configuration: FocusConfiguration(goal: "", duration: nil, mode: .block, categoryIDs: [], extraApps: [], extraWebsites: []), startedAt: now)
        unlimited.extend(by: 300)
        check(unlimited.remaining(at: now) == nil && !unlimited.isOver(at: now.addingTimeInterval(90_000)), "sans limite : jamais terminée")
        var slept = FocusSession(configuration: sample, startedAt: now)
        slept.pause(at: now.addingTimeInterval(60), for: nil, bySleep: true)
        check(slept.pausedBySleep && slept.pauseEndsAt == nil, "veille : pause sans échéance")
        slept.resume(at: now.addingTimeInterval(3660))
        check(slept.remaining(at: now.addingTimeInterval(3660)) == 1440, "réveil : la veille ne compte pas")

        check(FocusFormat.clock(65) == "01:05" && FocusFormat.clock(3725) == "1:02:05", "minuteur affiché")
        check(FocusFormat.duration(5400) == "1 h 30" && FocusFormat.duration(1500) == "25 min" && FocusFormat.duration(7200) == "2 h", "durées affichées")
        let decoded = try? JSONDecoder.prism.decode(FocusData.self, from: Data("{}".utf8))
        check(decoded?.categories.isEmpty == true && decoded?.session == nil, "données : fichier vide accepté")
        let encoded = (try? JSONEncoder.prism.encode(session)).flatMap { try? JSONDecoder.prism.decode(FocusSession.self, from: $0) }
        check(encoded?.pausedTotal == 300 && encoded?.duration == 1800, "session : enregistrée puis relue")
        let link = configuration(from: [
            URLQueryItem(name: "goal", value: "Lire"), URLQueryItem(name: "duration", value: "1h"),
            URLQueryItem(name: "mode", value: "allow"), URLQueryItem(name: "categories", value: "social,news,inconnue"),
        ], now: now)
        if case .success(let parsed) = link {
            check(parsed.goal == "Lire" && parsed.duration == 3600 && parsed.mode == .allow && parsed.categoryIDs == ["social", "news"], "lien profond : paramètres lus")
        } else {
            check(false, "lien profond : paramètres lus")
        }
        if case .failure = configuration(from: [URLQueryItem(name: "duration", value: "beaucoup")], now: now) {
            check(true, "lien profond : durée invalide refusée")
        } else {
            check(false, "lien profond : durée invalide refusée")
        }
        check(Set(FocusCategory.builtIn.map(\.id)).count == 6, "six catégories intégrées")
        check(FocusCategory.builtIn.allSatisfy { $0.websites.allSatisfy { FocusRules.normalizeDomain($0) == $0 } }, "domaines intégrés déjà normalisés")
    }
}

// MARK: - Réglages

struct FocusSettingsView: View {
    @ObservedObject private var settings = FocusSettings.shared
    @ObservedObject private var manager = FocusManager.shared
    @State private var editing: FocusCategory?
    @State private var appsText = ""
    @State private var sitesText = ""
    @State private var error: String?
    @State private var showsAllHistory = false

    var body: some View {
        Form {
            Section {
                Picker("Report du blocage", selection: $settings.snoozeMinutes) {
                    ForEach(FocusSettings.snoozeOptions, id: \.minutes) { Text($0.title).tag($0.minutes) }
                }
                Picker("Affichage de la session", selection: $settings.showInMenuBar) {
                    Text("Barre de concentration flottante").tag(false)
                    Text("Barre des menus").tag(true)
                }
                Toggle("Jouer un son à la fin d’une session ou d’une pause", isOn: $settings.playSound)
                Toggle("Rouvrir à la fin les apps fermées pendant la session", isOn: $settings.reopenApps)
                Toggle("Autoriser tous les sites quand un navigateur est autorisé sans site listé", isOn: $settings.allowAllSitesWithBrowser)
            } header: {
                Text("Session")
            } footer: {
                Text("Une app bloquée est masquée, puis quittée si elle revient. Les sites sont surveillés dans Safari, Chrome, Arc, Brave, Edge et Vivaldi ; macOS demande une fois l’autorisation de piloter le navigateur.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                if manager.history.isEmpty {
                    Text("Aucune session pour l’instant.")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Aujourd’hui", value: FocusFormat.duration(todayTotal) + " de concentration")
                    ForEach(manager.history.prefix(showsAllHistory ? 100 : 6)) { entry in
                        historyRow(entry)
                    }
                    if manager.history.count > 6, !showsAllHistory {
                        Button("Afficher les \(manager.history.count) sessions") { showsAllHistory = true }
                            .buttonStyle(.link)
                    }
                }
            } header: {
                HStack {
                    Text("Sessions récentes")
                    Spacer()
                    if !manager.history.isEmpty {
                        Button("Effacer l’historique") { manager.clearHistory() }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
            }

            Section("Catégories") {
                ForEach(manager.categories) { category in
                    categoryRow(category)
                }
                if let editing {
                    editor(editing)
                } else {
                    Button("Nouvelle catégorie…") {
                        begin(FocusCategory(id: "custom-" + UUID().uuidString.prefix(8).lowercased(), name: "", symbol: "folder.fill", color: "violet", apps: [], websites: []))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var todayTotal: TimeInterval {
        let calendar = Calendar.current
        let reference = manager.isSimulation ? manager.now : Date()
        return manager.history.filter { calendar.isDate($0.endedAt, inSameDayAs: reference) }.reduce(0) { $0 + $1.focused }
    }

    private func categoryRow(_ category: FocusCategory) -> some View {
        HStack(spacing: 10) {
            ItemIconView(icon: .symbol(category.symbol, category.tint), size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(category.name).font(.system(size: 12.5, weight: .medium))
                Text(category.summary).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if category.isBuiltIn {
                TagView(text: "Intégrée")
            }
            Button("Dupliquer") { begin(FocusManager.shared.draftCopy(of: category)) }
                .buttonStyle(.borderless)
            if !category.isBuiltIn {
                Button("Modifier") { begin(category) }
                    .buttonStyle(.borderless)
                Button {
                    manager.deleteCategory(category.id)
                    if editing?.id == category.id { editing = nil }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Supprimer la catégorie")
            }
        }
    }

    private func begin(_ category: FocusCategory) {
        editing = category
        appsText = category.apps.joined(separator: "\n")
        sitesText = category.websites.joined(separator: "\n")
        error = nil
    }

    @ViewBuilder
    private func editor(_ category: FocusCategory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Nom", text: Binding(get: { editing?.name ?? "" }, set: { editing?.name = $0 }))
                Picker("", selection: Binding(get: { editing?.symbol ?? "folder.fill" }, set: { editing?.symbol = $0 })) {
                    ForEach(FocusFeature.symbols, id: \.value) { Label($0.title, systemImage: $0.value).tag($0.value) }
                }
                .labelsHidden()
                .fixedSize()
                Picker("", selection: Binding(get: { editing?.color ?? "violet" }, set: { editing?.color = $0 })) {
                    ForEach(FocusCategory.colors, id: \.id) { Text($0.title).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
            }
            HStack(alignment: .top, spacing: 12) {
                listEditor("Apps (noms ou identifiants)", text: $appsText)
                listEditor("Sites (domaines)", text: $sitesText)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.red)
            }
            HStack {
                Button("Annuler") { editing = nil }
                Spacer()
                Button("Enregistrer la catégorie") { saveEditing() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.vertical, 4)
    }

    private func listEditor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 90)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
        }
    }

    private func saveEditing() {
        guard var category = editing else { return }
        category.name = category.name.trimmingCharacters(in: .whitespaces)
        guard !category.name.isEmpty else {
            error = "Donnez un nom à la catégorie"
            return
        }
        let websites = FocusRules.parseWebsites(sitesText)
        if let invalid = websites.invalid.first {
            error = "« \(invalid) » n’est pas un nom de domaine"
            return
        }
        category.apps = FocusRules.parseList(appsText)
        category.websites = websites.valid
        category.isBuiltIn = false
        manager.save(category)
        editing = nil
    }

    private func historyRow(_ entry: FocusHistoryEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.planned.map { entry.focused >= $0 - 1 } == true ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(entry.planned.map { entry.focused >= $0 - 1 } == true ? Palette.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.goal.isEmpty ? "Session de concentration" : entry.goal)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(entry.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(FocusFormat.duration(entry.focused) + (entry.planned.map { " sur " + FocusFormat.duration($0) } ?? ""))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Rendu hors écran

/// `Prism --snapshot-focus sortie.png` : la barre de concentration, les notifications et le halo ;
/// `--launcher [--query …] [--mode …] [--actions]` : le lanceur avec une session fictive ;
/// `--settings` : l'onglet des réglages avec un historique fictif. Rien n'est bloqué ni écrit.
@MainActor
enum FocusSnapshot {
    static func run(arguments: [String]) -> Int32 {
        guard let index = arguments.firstIndex(of: "--snapshot-focus"), index + 1 < arguments.count else { return 1 }
        let output = arguments[index + 1]
        let now = Date()
        var configuration = FocusConfiguration(
            goal: "Rédiger le chapitre 3", duration: 25 * 60, mode: .block,
            categoryIDs: ["social", "news", "messaging"], extraApps: [], extraWebsites: ["lequipe.fr"]
        )
        let session = FocusSession(configuration: configuration, startedAt: now.addingTimeInterval(-7 * 60 - 18))
        let history = [
            FocusHistoryEntry(id: UUID(), goal: "Relire la maquette", startedAt: now.addingTimeInterval(-3 * 3600), endedAt: now.addingTimeInterval(-3 * 3600 + 1500), focused: 1500, planned: 1500),
            FocusHistoryEntry(id: UUID(), goal: "Courriels", startedAt: now.addingTimeInterval(-5 * 3600), endedAt: now.addingTimeInterval(-5 * 3600 + 720), focused: 720, planned: 1800),
            FocusHistoryEntry(id: UUID(), goal: "Préparer la réunion", startedAt: now.addingTimeInterval(-26 * 3600), endedAt: now.addingTimeInterval(-26 * 3600 + 3600), focused: 3600, planned: 3600),
        ]
        FocusManager.shared.simulate(session, history: history, now: now)

        var passthrough = Array(arguments.dropFirst())
        passthrough.removeSubrange((index - 1)...(index))
        if arguments.contains("--launcher") || arguments.contains("--settings") {
            passthrough.removeAll { $0 == "--launcher" }
            var forwarded = ["Prism", "--snapshot", output] + passthrough
            if arguments.contains("--settings"), !arguments.contains("--pane") { forwarded += ["--pane", "focus"] }
            return Snapshot.run(arguments: forwarded)
        }

        let dark = !arguments.contains("--light")
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        // `--form start|edit|category` : le formulaire seul, dans un cadre de la taille du lanceur.
        if let formIndex = arguments.firstIndex(of: "--form") {
            let kind = formIndex + 1 < arguments.count ? arguments[formIndex + 1] : "start"
            let form: FormScreen
            switch kind {
            case "edit": form = FocusFeature.editForm()
            case "category": form = FocusFeature.categoryForm(nil, done: .pop)
            default: form = FocusFeature.startForm(prefill: nil)
            }
            if arguments.contains("--error") { form.state.error = "Durée non comprise : essayez « 45 min », « 1h30 » ou « jusqu’à 16h30 »" }
            let frame = VStack(spacing: 0) {
                HStack(spacing: 9) {
                    ItemIconView(icon: form.icon, size: 20)
                    Text(form.title).font(.system(size: 17, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 18)
                .frame(height: LauncherLayout.searchHeight)
                Divider()
                form.customView()
                Divider()
                HStack {
                    Spacer()
                    Text(form.submitTitle).font(.system(size: 12.5, weight: .semibold))
                    KeycapRow(symbols: ["⌘", "↵"])
                }
                .padding(.horizontal, 14)
                .frame(height: LauncherLayout.footerHeight)
            }
            .frame(width: LauncherLayout.width, height: LauncherLayout.height)
            .background(dark ? Color(white: 0.12) : Color(white: 0.96))
            return write(NSHostingView(rootView: frame), size: NSSize(width: LauncherLayout.width, height: LauncherLayout.height), to: output)
        }

        var paused = session
        paused.pause(at: now.addingTimeInterval(-60), for: 600)
        configuration.duration = nil
        let unlimited = FocusSession(configuration: configuration, startedAt: now.addingTimeInterval(-42 * 60))

        let gallery = VStack(spacing: 18) {
            FocusBarView(session: session, now: now)
            FocusBarView(session: paused, now: now)
            FocusBarView(session: unlimited, now: now, isSnoozed: true)
            FocusToastView(title: "Slack est bloquée", message: "Pendant la concentration", symbol: "hand.raised.fill", tint: Palette.orange, buttons: [.init(title: "Reporter 3 min") {}])
            FocusToastView(title: "Session terminée", message: "Rédiger le chapitre 3 · 25 min", symbol: "checkmark.circle.fill", tint: Palette.green, buttons: [.init(title: "+5 min") {}, .init(title: "+15 min") {}])
        }
        .padding(28)
        .frame(width: 520, height: 470)
        .background(LinearGradient(colors: [Color(red: 0.16, green: 0.20, blue: 0.33), Color(red: 0.36, green: 0.18, blue: 0.30)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay(FocusHaloView(tint: Palette.orange, depth: 40))

        return write(NSHostingView(rootView: gallery), size: NSSize(width: 520, height: 470), to: output)
    }

    private static func write(_ hosting: NSView, size: NSSize, to output: String) -> Int32 {
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 1 }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        do {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        } catch {
            print("Écriture impossible : \(error)")
            return 1
        }
        print("✓ \(output)")
        return 0
    }
}
