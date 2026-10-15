import AppKit
import SwiftUI

/// Les applications : désinstallation, fermeture automatique et leurs réglages.
/// Les apps elles-mêmes restent fournies à la recherche principale par `AppCatalog`.
@MainActor
enum ApplicationsFeature: PrismFeature {
    static func start() {
        AutoQuit.shared.start()
    }

    static var commands: [ResultItem] {
        [
            Command.screen("applications.uninstall", "Désinstaller des applications", subtitle: "Applications", symbol: "trash.fill", color: Palette.red, keywords: ["uninstall application", "desinstaller", "supprimer une app", "remove app"]) {
                AppUninstaller.listScreen()
            },
            Command.screen("applications.auto-quit", "Gérer la fermeture automatique", subtitle: "Applications", symbol: "timer", color: Palette.orange, keywords: ["auto quit", "fermeture automatique", "quitter automatiquement", "inactives"]) {
                autoQuitScreen()
            },
        ]
    }

    // MARK: - Fermeture automatique

    /// Les apps concernées (avec leur délai), puis les apps ouvertes à ajouter d'un ↵.
    static func autoQuitScreen() -> ListScreen {
        ListScreen(id: "applications.auto-quit", title: "Fermeture automatique", placeholder: "Rechercher une application…", icon: .symbol("timer", Palette.orange)) { query in
            let normalized = query.normalizedForSearch
            func matches(_ title: String) -> Bool { normalized.isEmpty || Fuzzy.score(normalized, title) != nil }
            let apps = ApplicationsPreferences.autoQuitApps
            let defaultDelay = ApplicationsPreferences.autoQuitDelay
            let enabled = apps.keys
                .compactMap { bundleID -> (String, URL?, String)? in
                    let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                    let name = url.map(AppBundleList.name(of:)) ?? bundleID
                    return matches(name) ? (bundleID, url, name) : nil
                }
                .sorted { $0.2.localizedStandardCompare($1.2) == .orderedAscending }
                .map { bundleID, url, name in
                    autoQuitItem(bundleID: bundleID, url: url, name: name, own: apps[bundleID] ?? 0, defaultDelay: defaultDelay)
                }
            let candidates = SystemActions.regularApps()
                .filter { app in
                    guard let id = app.bundleIdentifier else { return false }
                    return apps[id] == nil && !SystemActions.protectedBundleIDs.contains(id) && matches(app.localizedName ?? id)
                }
                .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
                .map { app -> ResultItem in
                    let id = app.bundleIdentifier ?? ""
                    let name = app.localizedName ?? id
                    return ResultItem(
                        id: "auto-quit.add." + id,
                        title: name,
                        subtitle: "Ouverte",
                        icon: app.bundleURL.map { .file($0.path) } ?? .symbol("app", Palette.gray),
                        usageKey: "",
                        actions: [ItemAction(title: "Activer la fermeture automatique", symbol: "timer") {
                            AutoQuit.setEnabled(true, for: id)
                            return .toast("\(name) se fermera après \(defaultDelay) min d’inactivité")
                        }]
                    )
                }
            return [
                ResultSection(id: "enabled", title: "Fermeture automatique activée", items: enabled),
                ResultSection(id: "running", title: "Applications ouvertes", items: candidates),
            ].filter { !$0.items.isEmpty }
        }
    }

    private static func autoQuitItem(bundleID: String, url: URL?, name: String, own: Int, defaultDelay: Int) -> ResultItem {
        var actions: [ItemAction] = [
            ItemAction(title: "Désactiver la fermeture automatique", symbol: "timer", isDestructive: true) {
                AutoQuit.setEnabled(false, for: bundleID)
                return .toast("Fermeture automatique désactivée pour \(name)")
            },
            ItemAction(title: "Délai par défaut (\(defaultDelay) min)", symbol: own == 0 ? "checkmark" : "clock", section: "Délai") {
                AutoQuit.setDelay(0, for: bundleID)
                return .refresh
            },
        ]
        for minutes in ApplicationsPreferences.autoQuitDelays {
            actions.append(ItemAction(title: "Après \(minutes) min", symbol: own == minutes ? "checkmark" : "clock", section: "Délai") {
                AutoQuit.setDelay(minutes, for: bundleID)
                return .refresh
            })
        }
        return ResultItem(
            id: "auto-quit.app." + bundleID,
            title: name,
            subtitle: AutoQuit.describe(own, defaultDelay: defaultDelay),
            icon: url.map { .file($0.path) } ?? .symbol("app.dashed", Palette.gray),
            accessory: NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty ? nil : "Ouverte",
            usageKey: "",
            actions: actions
        )
    }

    // MARK: - Réglages et autotests

    static var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "applications", title: "Applications", symbol: "square.grid.2x2.fill", color: Palette.blue, order: 50) { AnyView(ApplicationsSettingsView()) }]
    }

    static func selfTest(_ check: (Bool, String) -> Void) {
        let textEditTypes = RecentDocuments.contentTypes(ofAppAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"))
        check(textEditTypes.contains("public.rtf") && !textEditTypes.contains("public.item"), "fichiers récents : types de documents de TextEdit")

        // Une bibliothèque factice : ce qui appartient à l'app, et des voisins qui lui ressemblent.
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("prism-uninstall-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        let owned = [
            "Application Support/com.exemple.app",
            "Application Support/Exemple",
            "Caches/com.exemple.app",
            "Containers/com.exemple.app",
            "Group Containers/ABCDE12345.com.exemple.app",
            "Saved Application State/com.exemple.app.savedState",
            "HTTPStorages/com.exemple.app",
        ]
        let foreign = [
            "Application Support/com.exemple.application",
            "Caches/com.autre.app",
            "Logs/Exemple Pro",
        ]
        for path in owned + foreign {
            try? fileManager.createDirectory(at: library.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try? fileManager.createDirectory(at: library.appendingPathComponent("Preferences"), withIntermediateDirectories: true)
        try? Data().write(to: library.appendingPathComponent("Preferences/com.exemple.app.plist"))
        try? Data().write(to: library.appendingPathComponent("Preferences/com.exemple.application.plist"))
        let found = Set(AppUninstaller.supportFiles(bundleID: "com.exemple.app", appName: "Exemple", library: library)
            .map { $0.path.replacingOccurrences(of: library.path + "/", with: "") })
        check(found == Set(owned + ["Preferences/com.exemple.app.plist"]), "désinstallation : \(found.count) fichiers d'assistance trouvés, aucun voisin")
        check(AppUninstaller.supportFiles(bundleID: nil, appName: "Ex", library: library).isEmpty, "désinstallation : pas de correspondance sur un nom trop court")
        try? fileManager.removeItem(at: library)

        let apps = ["com.exemple.app": 0, "com.exemple.lent": 15]
        check(AutoQuit.delay(for: "com.exemple.app", apps: apps, defaultDelay: 5) == 5, "fermeture automatique : délai par défaut")
        check(AutoQuit.delay(for: "com.exemple.lent", apps: apps, defaultDelay: 5) == 15, "fermeture automatique : délai propre à l'app")
        check(AutoQuit.delay(for: "com.autre", apps: apps, defaultDelay: 5) == nil, "fermeture automatique : app non concernée")
        let now = Date()
        check(AutoQuit.isDue(lastActive: now.addingTimeInterval(-301), now: now, delayMinutes: 5)
              && !AutoQuit.isDue(lastActive: now.addingTimeInterval(-120), now: now, delayMinutes: 5), "fermeture automatique : échéance")

        let safari = AppCatalog.scan().first { $0.fileName == "Safari" }
        check(safari?.isSystem == true, "Safari est une app du système : jamais désinstallée")
        if let safari {
            let titles = AppActions.actions(for: safari, running: nil, context: .current()).map(\.title)
            check(titles.contains("Lire les informations") && !titles.contains("Désinstaller…"), "actions d'une app : informations, pas de désinstallation pour le système")
        }
    }
}

/// L'onglet « Applications » des réglages.
struct ApplicationsSettingsView: View {
    @State private var defaultDelay = ApplicationsPreferences.autoQuitDelay
    @State private var autoQuit = ApplicationsPreferences.autoQuitApps
    @State private var folders = ApplicationsPreferences.extraFolders
    @State private var hotkeyAction = ApplicationsPreferences.hotkeyAction

    var body: some View {
        Form {
            Section {
                Picker("Délai par défaut", selection: $defaultDelay) {
                    ForEach(ApplicationsPreferences.autoQuitDelays.filter { $0 <= 15 }, id: \.self) { Text("\($0) min").tag($0) }
                }
                .onChange(of: defaultDelay) { _, value in ApplicationsPreferences.autoQuitDelay = value }
                AppBundleList(
                    bundleIDs: Binding(
                        get: { autoQuit.keys.sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending } },
                        set: { ids in
                            autoQuit = Dictionary(uniqueKeysWithValues: ids.map { ($0, autoQuit[$0] ?? 0) })
                            ApplicationsPreferences.autoQuitApps = autoQuit
                        }
                    ),
                    emptyText: "Aucune application ne se ferme automatiquement",
                    trailing: { bundleID in
                        AnyView(Picker("", selection: Binding(
                            get: { autoQuit[bundleID] ?? 0 },
                            set: { value in
                                autoQuit[bundleID] = value
                                ApplicationsPreferences.autoQuitApps = autoQuit
                            }
                        )) {
                            Text("Par défaut").tag(0)
                            ForEach(ApplicationsPreferences.autoQuitDelays, id: \.self) { Text("\($0) min").tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize())
                    }
                )
            } header: {
                Text("Fermeture automatique")
            } footer: {
                Text("Une app de la liste est quittée quand elle n’a pas été au premier plan pendant ce délai. Jamais l’app de devant, ni pendant un appel ou un enregistrement (micro ou caméra allumés), ni Spotify ou Musique en lecture.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Si l’app est déjà au premier plan", selection: $hotkeyAction) {
                    Text("La masquer (basculer)").tag("toggle")
                    Text("La laisser au premier plan").tag("show")
                }
                .onChange(of: hotkeyAction) { _, value in ApplicationsPreferences.hotkeyAction = value }
            } header: {
                Text("Raccourci d’une application")
            }
            Section {
                if folders.isEmpty {
                    Text("/Applications, ~/Applications et les apps du système").foregroundStyle(.secondary)
                }
                ForEach(folders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(Palette.blue)
                        Text((folder as NSString).abbreviatingWithTildeInPath)
                        Spacer()
                        Button {
                            folders.removeAll { $0 == folder }
                            save()
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Retirer")
                    }
                }
                Button("Ajouter un dossier…") { chooseFolder() }
            } header: {
                Text("Dossiers de recherche")
            } footer: {
                Text("Prism cherche les apps jusqu’à trois niveaux de sous-dossiers.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func name(of bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map(AppBundleList.name(of:)) ?? bundleID
    }

    private func save() {
        ApplicationsPreferences.extraFolders = folders
        AppCatalog.shared.reload()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !folders.contains(url.path) { folders.append(url.path) }
        save()
    }
}
