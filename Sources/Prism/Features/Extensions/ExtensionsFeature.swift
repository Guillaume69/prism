import AppKit
import SwiftUI

/// Les extensions Raycast dans Prism : leurs commandes dans la recherche principale, le Store, les préférences.
@MainActor
enum ExtensionsFeature: PrismFeature {
    /// Les commandes sans vue en cours : gardées en vie jusqu'à leur fin.
    private static var headless: [ExtensionSession] = []

    static func start() {
        _ = ExtensionRegistry.shared
        ExtensionBackground.shared.restore()
        ExtensionDevelopment.shared.restore()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ExtensionSession.terminateAll() }
        }
    }

    static var commands: [ResultItem] {
        var items: [ResultItem] = [
            Command.screen("extensions.store", "Store d’extensions Raycast", subtitle: "Extensions", symbol: "bag.fill", color: Palette.violet,
                           keywords: ["store", "extensions", "raycast", "installer", "install"]) { ExtensionStoreScreen() },
            Command.screen("extensions.installed", "Extensions installées", subtitle: "Extensions", symbol: "puzzlepiece.extension.fill", color: Palette.violet,
                           keywords: ["extensions", "manage", "gérer", "désinstaller"]) { installedScreen() },
            Command.run("extensions.import", "Importer une extension", subtitle: "Extensions", symbol: "square.and.arrow.down.on.square", color: Palette.violet,
                        keywords: ["import extension", "develop", "développement", "local", "ray"]) { importWithPanel() },
        ]
        let missing = ExtensionRegistry.shared.missingFromSync
        if !missing.isEmpty {
            items.append(Command.run("extensions.install-synced", "Installer les extensions synchronisées (\(missing.count))", subtitle: missing.map(\.title).joined(separator: ", "),
                                     symbol: "arrow.triangle.2.circlepath.circle.fill", color: Palette.violet,
                                     keywords: ["extensions", "sync", "synchronisation", "installer"]) { installSynced(missing) })
        }
        for installed in ExtensionRegistry.shared.extensions {
            for command in installed.manifest.commands {
                items.append(item(installed, command: command))
            }
        }
        return items
    }

    static func item(_ installed: InstalledExtension, command: ExtensionManifest.Command) -> ResultItem {
        let arguments = command.arguments.map { argument in
            ItemArgument(name: argument.name, placeholder: argument.placeholder, isOptional: !argument.isRequired,
                         isSecure: argument.type == "password", options: argument.options.map(\.title))
        }
        let run: @MainActor ([String]) -> ActionOutcome = { values in
            var named: [String: String] = [:]
            for (index, argument) in command.arguments.enumerated() where index < values.count {
                let raw = values[index]
                named[argument.name] = argument.options.first { $0.title == raw }?.value ?? raw
            }
            return launch(installed, command: command, arguments: named)
        }
        let subtitle = subtitles[key(installed, command)] ?? (command.subtitle.isEmpty ? installed.title : command.subtitle)
        var actions: [ItemAction] = []
        let background = ExtensionBackground.shared
        if command.mode == "menu-bar" {
            let active = background.isActive(installed, command)
            actions.append(ItemAction(title: active ? "Retirer de la barre des menus" : "Ajouter à la barre des menus", symbol: "menubar.rectangle") {
                background.toggle(installed, command)
            })
            actions.append(ItemAction(title: "Afficher dans le lanceur", symbol: "list.bullet") { run([]) })
        } else {
            actions.append(ItemAction(title: "Ouvrir la commande", symbol: "arrow.right.circle") { run([]) })
            if command.mode == "no-view", command.interval != nil {
                let active = background.isActive(installed, command)
                actions.append(ItemAction(title: active ? "Désactiver l’arrière-plan" : "Activer en arrière-plan", symbol: "clock.arrow.2.circlepath") {
                    background.toggle(installed, command)
                })
            }
        }
        return ResultItem(
            id: "extension:\(installed.id)/\(command.name)",
            title: command.title,
            subtitle: subtitle,
            icon: installed.icon(for: command),
            accessory: command.mode == "menu-bar" ? "Barre des menus" : command.mode == "no-view" ? "Commande" : "Extension",
            tags: ExtensionBackground.shared.isActive(installed, command) ? ["Active"] : [],
            keywords: command.keywords + [installed.title, installed.manifest.name],
            actions: actions + [
                ItemAction(title: "Préférences de la commande", symbol: "gearshape", shortcut: KeyShortcut(keyCode: 43, modifiers: [.command, .shift], label: ",")) {
                    .push(preferencesForm(installed, command: command))
                },
                ItemAction(title: "Préférences de l’extension", symbol: "puzzlepiece.extension") { .push(preferencesForm(installed, command: nil)) },
                ItemAction(title: "Ouvrir le journal", symbol: "doc.text.magnifyingglass") {
                    NSWorkspace.shared.open(ExtensionSession.logFile(for: installed))
                    return .close
                },
            ],
            arguments: arguments,
            runWithArguments: arguments.isEmpty ? nil : run,
            isConfigurable: true
        )
    }

    // MARK: - Lancement

    /// Lance une commande : préférences obligatoires d'abord, puis l'écran (ou la commande sans vue).
    static func launch(_ installed: InstalledExtension, command: ExtensionManifest.Command, arguments: [String: String] = [:],
                       launchType: String = "userInitiated", launchContext: Any? = nil) -> ActionOutcome {
        if !ExtensionPreferences.shared.missing(for: installed, command: command).isEmpty {
            return .push(preferencesForm(installed, command: command, required: true) {
                launch(installed, command: command, arguments: arguments, launchType: launchType, launchContext: launchContext)
            })
        }
        do {
            if command.mode == "no-view" || launchType == "background" && command.mode != "view" {
                let session = ExtensionSession(installed: installed, command: command)
                session.onExit = { [weak session] _ in headless.removeAll { $0 === session } }
                session.onError = { message, _ in HUD.shared.show(message, symbol: "exclamationmark.triangle.fill") }
                headless.append(session)
                try session.start(arguments: arguments, launchType: launchType, launchContext: launchContext)
                return .close
            }
            return .push(try screen(for: installed, command: command, arguments: arguments, launchType: launchType, launchContext: launchContext))
        } catch {
            return .toast(error.localizedDescription)
        }
    }

    static func screen(for installed: InstalledExtension, command: ExtensionManifest.Command, arguments: [String: String] = [:],
                       launchType: String = "userInitiated", launchContext: Any? = nil) throws -> ExtensionScreen {
        let session = ExtensionSession(installed: installed, command: command)
        let screen = ExtensionScreen(session: session)
        try session.start(arguments: arguments, launchType: launchType, launchContext: launchContext)
        return screen
    }

    /// `launchCommand` de l'API : une commande de la même extension, ou d'une autre si elle est nommée.
    static func launch(from installed: InstalledExtension, options: [String: Any]) throws {
        let name = options["name"] as? String ?? ""
        var target = installed
        if let extensionName = options["extensionName"] as? String {
            let owner = options["ownerOrAuthorName"] as? String
            guard let other = ExtensionRegistry.shared.extensions.first(where: { $0.manifest.name == extensionName && (owner == nil || $0.origin.owner == owner) }) else {
                throw ExtensionSession.RequestError("L’extension « \(extensionName) » n’est pas installée")
            }
            target = other
        }
        guard let command = target.manifest.commands.first(where: { $0.name == name }) else {
            throw ExtensionSession.RequestError("La commande « \(name) » est introuvable")
        }
        let arguments = (options["arguments"] as? [String: Any] ?? [:]).compactMapValues { ExtensionValue.text($0) }
        let type = options["type"] as? String ?? "userInitiated"
        CommandRunner.present(launch(target, command: command, arguments: arguments, launchType: type, launchContext: options["context"]))
    }

    // MARK: - Sous-titres (`updateCommandMetadata`)

    private static let subtitlesKey = "extensions.subtitles"

    private static var subtitles: [String: String] { UserDefaults.standard.dictionary(forKey: subtitlesKey) as? [String: String] ?? [:] }

    private static func key(_ installed: InstalledExtension, _ command: ExtensionManifest.Command) -> String { "\(installed.id)/\(command.name)" }

    static func setSubtitle(_ subtitle: String?, for installed: InstalledExtension, command: ExtensionManifest.Command) {
        var all = subtitles
        all[key(installed, command)] = subtitle
        UserDefaults.standard.set(all, forKey: subtitlesKey)
        NotificationCenter.default.post(name: .prismDataDidChange, object: nil)
    }

    // MARK: - Préférences

    static func preferencesForm(_ installed: InstalledExtension, command: ExtensionManifest.Command?, required: Bool = false,
                                then: (@MainActor () -> ActionOutcome)? = nil) -> LauncherScreen {
        let preferences = ExtensionPreferences.shared
        var groups: [(ExtensionManifest.Preference, String)] = installed.manifest.preferences.map { ($0, ExtensionPreferences.scope(installed, command: nil)) }
        if let command { groups += command.preferences.map { ($0, ExtensionPreferences.scope(installed, command: command)) } }
        if required, let command {
            let missing = Set(preferences.missing(for: installed, command: command).map { "\($0.1)#\($0.0.name)" })
            groups = groups.filter { missing.contains("\($0.1)#\($0.0.name)") || !$0.0.isRequired }
        }
        var fields: [FormField] = []
        if required {
            fields.append(FormField(id: "_info", label: "", kind: .info, value: "« \(installed.title) » a besoin de ces réglages avant de démarrer."))
        }
        for (index, (preference, scope)) in groups.enumerated() {
            let current = preferences.value(preference, scope: scope) ?? ExtensionValue.text(preference.defaultValue) ?? ""
            let label = preference.title + (preference.isRequired ? " *" : "")
            let kind: FormField.Kind
            switch preference.type {
            case "password": kind = .secure
            case "checkbox": kind = .checkbox(label: preference.label)
            case "dropdown": kind = .dropdown(preference.options.map { ($0.value, $0.title) })
            default: kind = .text
            }
            var value = current
            if preference.type == "checkbox" { value = preferences.value(preference, scope: scope) ?? ((preference.defaultValue as? Bool) == true ? "true" : "false") }
            if preference.type == "dropdown", value.isEmpty { value = preference.options.first?.value ?? "" }
            fields.append(FormField(id: "p\(index)", label: label, kind: kind, placeholder: preference.placeholder, value: value,
                                    info: preference.description.isEmpty ? nil : preference.description))
        }
        if groups.isEmpty {
            fields.append(FormField(id: "_none", label: "", kind: .info, value: "Cette extension n’a pas de préférences."))
        }
        let title = command.map { "\($0.title) — préférences" } ?? "\(installed.title) — préférences"
        return FormScreen(id: "extensions.preferences.\(installed.id)", title: title, icon: installed.icon, submitTitle: then == nil ? "Enregistrer" : "Enregistrer et lancer", fields: fields) { state in
            for (index, (preference, scope)) in groups.enumerated() {
                let value = state.trimmed("p\(index)")
                if preference.isRequired, preference.type != "checkbox", value.isEmpty {
                    state.error = "« \(preference.title) » est requis"
                    return .stay
                }
                preferences.set(value, for: preference, scope: scope)
            }
            if let then { return .then(.pop, then()) }
            return .then(.pop, .toast("Préférences enregistrées"))
        }
    }

    // MARK: - Écrans de gestion

    static func installedScreen() -> LauncherScreen {
        ListScreen(id: "extensions.installed", title: "Extensions installées", placeholder: "Rechercher une extension…",
                   icon: .symbol("puzzlepiece.extension.fill", Palette.violet),
                   empty: { _ in ("puzzlepiece.extension", "Aucune extension. Le Store d’extensions Raycast en propose des milliers.") }) { query in
            let items = ExtensionRegistry.shared.extensions.compactMap { installed -> ResultItem? in
                guard query.isEmpty || Fuzzy.score(query.normalizedForSearch, installed.title) != nil else { return nil }
                return ResultItem(
                    id: "installed:" + installed.id,
                    title: installed.title,
                    subtitle: installed.manifest.description,
                    icon: installed.icon,
                    accessory: "\(installed.manifest.commands.count) commande(s)",
                    usageKey: "",
                    actions: [
                        ItemAction(title: "Ouvrir les commandes", symbol: "list.bullet") { .push(commandsScreen(installed)) },
                        ItemAction(title: "Préférences", symbol: "gearshape", shortcut: KeyShortcut(keyCode: 43, modifiers: [.command], label: ",")) {
                            .push(preferencesForm(installed, command: nil))
                        },
                        ItemAction(title: installed.origin.isDevelopment == true ? "Reconstruire (mode développement)" : "Réimporter depuis le dossier", symbol: "hammer") {
                            guard let source = installed.origin.sourcePath else { return .toast("Extension du Store : utilisez le Store pour la mettre à jour") }
                            ExtensionDevelopment.shared.rebuild(source)
                            return .hud("Reconstruction…")
                        },
                        ItemAction(title: "Afficher dans le Finder", symbol: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([installed.directory])
                            return .close
                        },
                        ItemAction(title: "Ouvrir le journal", symbol: "doc.text.magnifyingglass") {
                            NSWorkspace.shared.open(ExtensionSession.logFile(for: installed))
                            return .close
                        },
                        ItemAction(title: "Désinstaller", symbol: "trash", shortcut: KeyShortcut(keyCode: 51, modifiers: [.control], label: "⌫"), isDestructive: true) {
                            ExtensionRegistry.shared.uninstall(installed)
                            return .then(.refresh, .toast("« \(installed.title) » désinstallée"))
                        },
                    ]
                )
            }
            return [ResultSection(id: "installed", title: nil, items: items)]
        }
    }

    static func commandsScreen(_ installed: InstalledExtension) -> LauncherScreen {
        ListScreen(id: "extensions.commands.\(installed.id)", title: installed.title, placeholder: "Rechercher une commande…", icon: installed.icon) { query in
            let items = installed.manifest.commands.map { item(installed, command: $0) }
                .filter { query.isEmpty || Fuzzy.score(query.normalizedForSearch, $0.title) != nil }
            return [ResultSection(id: "commands", title: nil, items: items)]
        }
    }

    /// Installe, depuis le Store, les extensions venues d'un autre Mac par la synchronisation.
    static func installSynced(_ entries: [ExtensionRegistry.SyncedEntry]) -> ActionOutcome {
        Task { @MainActor in
            var installed = 0
            for entry in entries {
                guard let listing = try? await ExtensionStore.listings(query: entry.name).first(where: { $0.id == entry.storeID || ($0.publisher == entry.owner && $0.name == entry.name) }),
                      (try? await ExtensionStore.install(listing)) != nil else { continue }
                installed += 1
            }
            HUD.shared.show("\(installed) extension(s) sur \(entries.count) installée(s)", symbol: "puzzlepiece.extension.fill")
        }
        return .hud("Installation des extensions synchronisées…")
    }

    // MARK: - Import

    /// Choisit un dossier d'extension (construit ou source) et l'installe ; les sources passent en mode développement.
    static func importWithPanel() -> ActionOutcome {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Importer"
        panel.message = "Dossier d’une extension Raycast : construite, ou ses sources (après « npm install »)"
        AppContext.launcher?.keepOpenOnResign = true
        defer { AppContext.launcher?.keepOpenOnResign = false }
        guard panel.runModal() == .OK, let folder = panel.url else { return .stay }
        importFolder(folder)
        return .hud("Import de l’extension…")
    }

    static func importFolder(_ folder: URL, develop: Bool = true) {
        Task { @MainActor in
            do {
                let installed = try await ExtensionDevelopment.shared.importFolder(folder, develop: develop)
                let mode = installed.origin.isDevelopment == true ? " (mode développement : reconstruite à chaque modification)" : ""
                HUD.shared.show("« \(installed.title) » importée\(mode)", symbol: "puzzlepiece.extension.fill")
            } catch {
                HUD.shared.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    // MARK: - Réglages et liens

    static var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "extensions", title: "Extensions", symbol: "puzzlepiece.extension.fill", color: Palette.violet, order: 75) {
            AnyView(ExtensionsSettingsView())
        }]
    }

    /// `prism://oauth?…` (retour d'autorisation) et `prism://extensions/<auteur>/<extension>/<commande>`, comme les liens de Raycast.
    static func handle(url: URL) -> Bool {
        if ExtensionOAuth.handle(url) { return true }
        if url.host == "extensions-import" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let path = items.first(where: { $0.name == "path" })?.value else { return false }
            importFolder(URL(fileURLWithPath: ExtensionIcon.expand(path)), develop: items.first { $0.name == "develop" }?.value != "0")
            return true
        }
        guard url.host == "extensions" else { return false }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 3,
              let installed = ExtensionRegistry.shared.extensions.first(where: { $0.origin.owner == parts[0] && $0.manifest.name == parts[1] }),
              let command = installed.manifest.commands.first(where: { $0.name == parts[2] }) else { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var arguments: [String: String] = [:]
        if let raw = query.first(where: { $0.name == "arguments" })?.value, let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            arguments = object.compactMapValues { ExtensionValue.text($0) }
        }
        CommandRunner.present(launch(installed, command: command, arguments: arguments))
        return true
    }

    // MARK: - Autotests

    static func selfTest(_ check: (Bool, String) -> Void) {
        let manifest = ExtensionManifest(data: Data("""
        {"name":"demo","title":"Démo","icon":"icon.png","author":"prism","commands":[{"name":"list","title":"Liste","mode":"view",
        "arguments":[{"name":"who","type":"dropdown","placeholder":"Qui","required":true,"data":[{"title":"Léa","value":"lea"}]}]}],
        "preferences":[{"name":"token","type":"password","title":"Jeton","required":true},{"name":"dark","type":"checkbox","label":"Sombre","default":true}]}
        """.utf8))
        check(manifest?.commands.first?.arguments.first?.options.first?.value == "lea" && manifest?.preferences.first?.isSecret == true,
              "extensions : manifeste lu (commandes, arguments, préférences)")
        check(ExtensionIcon.symbol(forRaycastIcon: "star-16") == "star" && ExtensionIcon.symbol(forRaycastIcon: "star-filled-16") == "star.fill"
              && ExtensionIcon.symbol(forRaycastIcon: "magnifying-glass-16") == "magnifyingglass" && ExtensionIcon.symbol(forRaycastIcon: "icon.png") == nil,
              "extensions : icônes de Raycast en symboles SF")
        let shortcut = ExtensionShortcut.shortcut(["modifiers": ["cmd", "shift"], "key": "c"])
        check(shortcut?.keyCode == 8 && shortcut?.modifiers == [.command, .shift], "extensions : raccourcis des actions")
        let node = ExtensionNode(["type": "list", "props": ["isLoading": false], "children": [
            ["type": "list-item", "props": ["title": "A", "onAction": ["$fn": 3]], "children": [
                ["type": "slot", "props": ["name": "actions"], "children": [["type": "action-panel", "props": [:], "children": []]]],
            ]],
        ]])
        check(node?.all("list-item").first?.slot("actions")?.type == "action-panel" && node?.all("list-item").first?.handler("onAction") == "3",
              "extensions : arbre rendu par l’hôte")
        check(ExtensionColor.hex("FF0000")?.redComponent == 1 && ExtensionColor.nsColor("raycast-green") != nil, "extensions : couleurs")
        check(Fuzzy.score("store d'extensions".normalizedForSearch, "Store d’extensions Raycast") != nil, "recherche : apostrophe droite ou typographique")
        check(PrismArchive.excludedDirectories.contains("Extensions"), "extensions : paquets exclus de la synchronisation, seule leur liste voyage")
        check(NodeRuntime.hostScript != nil || CommandLine.arguments.contains("--no-host"), "extensions : hôte Node présent")
    }
}

/// Réglages : Node.js, extensions installées, Store.
struct ExtensionsSettingsView: View {
    @ObservedObject private var registry = ExtensionRegistry.shared
    @AppStorage(NodeRuntime.pathKey) private var nodePath = ""
    @State private var detected = NodeRuntime.path

    var body: some View {
        Form {
            Section("Node.js") {
                TextField("Chemin de node (vide : détection automatique)", text: $nodePath)
                    .onSubmit { NodeRuntime.reset(); detected = NodeRuntime.path }
                Text(detected.map { "Utilisé : \($0)" } ?? "Node.js 18 ou plus est introuvable : brew install node")
                    .font(.caption).foregroundStyle(detected == nil ? Palette.orange : .secondary)
                Text("Les extensions du Store de Raycast tournent dans Node.js, avec une réimplémentation de l’API de Raycast. La plupart fonctionnent ; celles qui demandent l’extension de navigateur de Raycast ou la gestion de fenêtres de Raycast non.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Extensions installées") {
                if registry.extensions.isEmpty {
                    Text("Aucune extension. Ouvrez « Store d’extensions Raycast » dans Prism.").foregroundStyle(.secondary)
                }
                ForEach(registry.extensions) { installed in
                    HStack {
                        ItemIconView(icon: installed.icon, size: 18)
                        VStack(alignment: .leading) {
                            Text(installed.title)
                            Text("\(installed.manifest.commands.count) commande(s) · \(installed.origin.owner)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Désinstaller", role: .destructive) { registry.uninstall(installed) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
