import AppKit
import SwiftUI

/// La sélection de l'onglet des réglages, partagée avec les commandes qui ouvrent un onglet précis.
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var selection = "general"
}

struct SettingsView: View {
    @ObservedObject private var navigation = SettingsNavigation.shared
    @State private var search = ""
    let hotKeyRegistered: () -> Bool

    private var panes: [SettingsPane] {
        [
            SettingsPane(id: "general", title: "Général", symbol: "gearshape.fill", color: Palette.gray, order: 0) {
                AnyView(GeneralSettingsView(hotKeyRegistered: hotKeyRegistered))
            },
            SettingsPane(id: "commands", title: "Commandes", symbol: "command", color: Palette.indigo, order: 10) {
                AnyView(CommandsSettingsView())
            },
        ] + Features.settingsPanes
    }

    /// Un onglet correspond s'il porte le mot, ou si une commande de sa fonctionnalité le porte.
    private func matches(_ pane: SettingsPane) -> Bool {
        let query = search.normalizedForSearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        if pane.title.normalizedForSearch.contains(query) || pane.id.contains(query) { return true }
        let keywords = SettingsSearch.keywords[pane.id] ?? []
        return keywords.contains { $0.normalizedForSearch.contains(query) }
    }

    var body: some View {
        let panes = panes.sorted { $0.order < $1.order }
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    Image(nsImage: IconRenderer.image(size: 64))
                        .resizable()
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Prism").font(.system(size: 14, weight: .semibold))
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0")")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 34)
                .padding(.bottom, 12)
                TextField("Rechercher dans les réglages", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(panes.filter { matches($0) }) { pane in
                            Button {
                                navigation.selection = pane.id
                            } label: {
                                HStack(spacing: 9) {
                                    ItemIconView(icon: .symbol(pane.symbol, pane.color), size: 18)
                                    Text(pane.title).font(.system(size: 13))
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 28)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(navigation.selection == pane.id ? Color.accentColor.opacity(0.18) : .clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            .padding(.horizontal, 8)
            .frame(width: 210)
            .background(VisualEffectBackground(material: .sidebar, blending: .behindWindow))

            Divider()

            Group {
                if let pane = panes.first(where: { $0.id == navigation.selection }) ?? panes.first {
                    pane.view()
                        .id(pane.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Les mots qui mènent à chaque onglet depuis la recherche des réglages.
enum SettingsSearch {
    static let keywords: [String: [String]] = [
        "general": ["taille", "interface", "raccourci", "hotkey", "compact", "échap", "connexion", "barre des menus", "accessibilité", "sensibilité", "écran", "vim", "emacs", "source de saisie", "favicon", "historique", "jeu"],
        "commands": ["alias", "raccourci", "favoris", "repli", "fallback", "désactiver"],
        "themes": ["couleur", "apparence", "sombre", "clair"],
        "clipboard": ["historique", "copier", "coller", "conservation", "ocr", "séquence"],
        "ai": ["modèle", "clé", "api", "anthropic", "openai", "ollama", "apple intelligence", "mcp", "mémoire", "automatisation", "skills", "agents", "projets", "outils", "fournisseur"],
        "calculator": ["devise", "taux", "rem", "couleur"],
        "snippets": ["mot-clé", "développement", "texte"],
        "emoji": ["ton de peau", "colonnes"],
        "files": ["spotlight", "contenu", "dossier", "terminal", "cachés"],
        "windows": ["écart", "gaps", "moitié", "disposition", "stage manager"],
        "quicklinks": ["lien", "onglet", "url"],
        "calendar": ["agenda", "réunion", "visio", "barre des menus"],
        "notes": ["markdown", "zoom"],
        "scripts": ["script", "dossier"],
        "contacts": ["contact"],
        "screenshots": ["capture", "ocr"],
        "applications": ["fermeture automatique", "auto quit", "désinstaller"],
        "hyper": ["verr. maj", "caps lock", "hyper"],
        "system": ["corbeille", "quitter", "confirmation"],
        "sync": ["icloud", "sauvegarde", "export", "import"],
        "translate": ["langue", "traduction"],
        "dictation": ["micro", "voix", "dictée"],
        "focus": ["blocage", "concentration", "sites"],
    ]
}

// MARK: - Général

struct GeneralSettingsView: View {
    @ObservedObject private var preferences = Preferences.shared
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var accessibilityGranted = Paster.isTrusted
    @State private var gameMode = GameMode.isEnabled
    let hotKeyRegistered: () -> Bool

    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Lanceur") {
                LabeledContent("Raccourci d’ouverture") {
                    HotkeyRecorder(value: Binding(
                        get: { HotkeyCoding.encode(preferences.launcherHotkey) },
                        set: { value in
                            if let hotkey = HotkeyCoding.decode(value), hotkey.isValid {
                                preferences.launcherHotkey = hotkey
                            }
                        }
                    ))
                    .frame(width: 200, height: 26)
                }
                if !hotKeyRegistered() {
                    Label("Ce raccourci est déjà pris par une autre application.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.orange)
                }
                Toggle("Ouvrir Prism à l’ouverture de session", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        if !LoginItem.set(enabled) { launchAtLogin = LoginItem.isEnabled }
                    }
                Toggle("Mode compact (seulement la barre de recherche tant qu’on n’a rien tapé)", isOn: $preferences.compactMode)
                Picker("Touche Échap", selection: $preferences.escapeClosesCompletely) {
                    Text("Revenir à l’écran précédent").tag(false)
                    Text("Fermer la fenêtre").tag(true)
                }
                Picker("Revenir à la recherche vide après", selection: $preferences.resetDelay) {
                    Text("Tout de suite").tag(0.0)
                    Text("30 secondes").tag(30.0)
                    Text("90 secondes").tag(90.0)
                    Text("5 minutes").tag(300.0)
                    Text("Jamais").tag(Double.greatestFiniteMagnitude)
                }
                Picker("Sensibilité de la recherche", selection: $preferences.searchSensitivity) {
                    Text("Faible : début des mots, initiales").tag(0)
                    Text("Moyenne").tag(1)
                    Text("Élevée : lettres éparses acceptées").tag(2)
                }
                Toggle("Favoris en icônes dans le mode compact", isOn: $preferences.favoritesInCompactMode)
                    .disabled(!preferences.compactMode)
                Picker("Taille de l’interface", selection: $preferences.interfaceScale) {
                    Text("Par défaut").tag(1.0)
                    Text("Grande").tag(1.12)
                    Text("Plus grande").tag(1.25)
                }
                Picker("Ouvrir Prism sur", selection: $preferences.showOnScreen) {
                    Text("L’écran de la souris").tag("mouse")
                    Text("L’écran de la fenêtre active").tag("window")
                    Text("L’écran principal").tag("main")
                }
                Picker("Raccourcis de navigation", selection: $preferences.navigationBindings) {
                    Text("Emacs (⌃N, ⌃P)").tag("emacs")
                    Text("Vim (⌃J, ⌃K)").tag("vim")
                }
                Picker("Source de saisie à l’ouverture", selection: $preferences.inputSource) {
                    Text("Ne pas changer").tag("")
                    ForEach(InputSourceSwitcher.available, id: \.id) { source in
                        Text(source.name).tag(source.id)
                    }
                }
                Picker("Icônes des sites", selection: $preferences.faviconProvider) {
                    Text("Demandées au site lui-même").tag("site")
                    Text("DuckDuckGo").tag("duckduckgo")
                    Text("Google").tag("google")
                    Text("Aucune").tag("none")
                }
                LabeledContent("Historique des recherches") {
                    Button("Effacer (\(preferences.searchHistory.count))") { preferences.searchHistory = []; preferences.objectWillChange.send() }
                }
                Toggle("Afficher l’icône dans la barre des menus", isOn: $preferences.showMenuBarIcon)
                Toggle("Inclure les fichiers dans la recherche principale", isOn: $preferences.filesInRootSearch)
                Toggle("Mode jeu : couper les raccourcis de Prism quand un jeu est au premier plan", isOn: $gameMode)
                    .onChange(of: gameMode) { _, enabled in GameMode.isEnabled = enabled }
            }
            Section {
                LabeledContent("Accessibilité") {
                    if accessibilityGranted {
                        Label("Autorisée", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Palette.green)
                    } else {
                        Button("Autoriser…") {
                            Paster.requestTrust()
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            } header: {
                Text("Autorisations")
            } footer: {
                Text("Nécessaire pour coller dans l’application active, ranger les fenêtres, développer les snippets, lire la sélection et chercher dans les menus.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in accessibilityGranted = Paster.isTrusted }
    }
}

// MARK: - Commandes

/// Toutes les commandes : alias, raccourci, activation ; puis les recherches de repli.
struct CommandsSettingsView: View {
    @ObservedObject private var config = CommandConfigStore.shared
    @State private var search = ""
    @State private var filter = "all"

    var body: some View {
        let items = RootScreen.candidates()
            .filter { item in
                let normalized = search.normalizedForSearch
                guard normalized.isEmpty || Fuzzy.score(normalized, item.title) != nil || Fuzzy.score(normalized, item.subtitle ?? "") != nil else { return false }
                let entry = config.config(for: item.id)
                switch filter {
                case "commands": return !item.id.hasPrefix("app:")
                case "apps": return item.id.hasPrefix("app:")
                case "alias": return entry.alias != nil
                case "hotkey": return entry.hotkey != nil
                case "disabled": return entry.disabled
                default: return true
                }
            }
        VStack(spacing: 0) {
            HStack {
                TextField("Rechercher une commande", text: $search)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $filter) {
                    Text("Tout").tag("all")
                    Text("Commandes").tag("commands")
                    Text("Applications").tag("apps")
                    Text("Avec alias").tag("alias")
                    Text("Avec raccourci").tag("hotkey")
                    Text("Désactivées").tag("disabled")
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(14)
            HStack {
                Text("Nom").frame(maxWidth: .infinity, alignment: .leading)
                Text("Alias").frame(width: 110, alignment: .leading)
                Text("Raccourci").frame(width: 150, alignment: .leading)
                Text("Activée").frame(width: 50)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.bottom, 4)
            Divider()
            List {
                ForEach(items) { item in
                    CommandSettingsRow(item: item)
                }
                Section("Recherches de repli") {
                    FallbackSettingsList()
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct CommandSettingsRow: View {
    let item: ResultItem
    @ObservedObject private var config = CommandConfigStore.shared
    @State private var alias = ""

    var body: some View {
        let entry = config.config(for: item.id)
        HStack {
            HStack(spacing: 8) {
                ItemIconView(icon: item.icon, size: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title).font(.system(size: 12.5)).lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TextField("Alias", text: $alias)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 110)
                .onSubmit(saveAlias)
                .onChange(of: alias) { _, _ in saveAlias() }
            HotkeyRecorder(value: Binding(
                get: { entry.hotkey.map(HotkeyCoding.encode) ?? "" },
                set: { value in
                    let hotkey = HotkeyCoding.decode(value)
                    if let hotkey, let owner = config.owner(of: hotkey), owner != item.id {
                        config.update(owner) { $0.hotkey = nil }
                    }
                    config.update(item.id) { $0.hotkey = hotkey?.isValid == true ? hotkey : nil }
                }
            ))
            .frame(width: 150, height: 24)
            Toggle("", isOn: Binding(
                get: { !entry.disabled },
                set: { enabled in config.update(item.id) { $0.disabled = !enabled } }
            ))
            .labelsHidden()
            .frame(width: 50)
        }
        .onAppear { alias = entry.alias ?? "" }
    }

    private func saveAlias() {
        let cleaned = alias.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.trimmingCharacters(in: .whitespaces)
        config.update(item.id) { $0.alias = cleaned.isEmpty ? nil : cleaned }
    }
}

/// Les recherches de repli : activer, désactiver, réordonner.
private struct FallbackSettingsList: View {
    @ObservedObject private var config = CommandConfigStore.shared

    var body: some View {
        let all = Features.all.flatMap { $0.fallbacks(query: "…") }
        let order = config.data.fallbackOrder
        let sorted = all.enumerated().sorted { lhs, rhs in
            (order.firstIndex(of: lhs.element.id) ?? 1_000 + lhs.offset) < (order.firstIndex(of: rhs.element.id) ?? 1_000 + rhs.offset)
        }.map(\.element)
        ForEach(Array(sorted.enumerated()), id: \.element.id) { index, item in
            HStack(spacing: 8) {
                ItemIconView(icon: item.icon, size: 18)
                Text(item.title).font(.system(size: 12.5))
                Spacer()
                Button {
                    move(sorted.map(\.id), index, -1)
                } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                Button {
                    move(sorted.map(\.id), index, 1)
                } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(.borderless)
                    .disabled(index == sorted.count - 1)
                Toggle("", isOn: Binding(
                    get: { !config.data.disabledFallbacks.contains(item.id) },
                    set: { enabled in
                        if enabled {
                            config.data.disabledFallbacks.removeAll { $0 == item.id }
                        } else {
                            config.data.disabledFallbacks.append(item.id)
                        }
                    }
                ))
                .labelsHidden()
            }
        }
    }

    private func move(_ ids: [String], _ index: Int, _ delta: Int) {
        var ids = ids
        let target = index + delta
        guard ids.indices.contains(target) else { return }
        ids.swapAt(index, target)
        config.data.fallbackOrder = ids
    }
}
