import AppKit
import SwiftUI

/// Réglages des snippets, gardés dans les préférences (clés « snippets. »).
@MainActor
final class SnippetSettings: ObservableObject {
    static let shared = SnippetSettings()

    enum PrimaryAction: String {
        case paste, copy
    }

    /// Applications où les mots-clés ne se développent pas, par défaut les gestionnaires de mots de passe.
    static let defaultDisabledApps = ["com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7"]

    private let defaults = UserDefaults.standard

    @Published var expansionEnabled: Bool { didSet { store(expansionEnabled, "expansionEnabled"); SnippetExpander.shared.update() } }
    @Published var mode: ExpansionMode { didSet { store(mode.rawValue, "mode") } }
    @Published var keepDelimiter: Bool { didSet { store(keepDelimiter, "keepDelimiter") } }
    @Published var expandInsideWords: Bool { didSet { store(expandInsideWords, "expandInsideWords") } }
    /// Millisecondes entre l'effacement du mot-clé et le collage, pour les applications lentes.
    @Published var injectionDelay: Int { didSet { store(injectionDelay, "injectionDelay") } }
    @Published var playSound: Bool { didSet { store(playSound, "playSound") } }
    /// Identifiants de paquet.
    @Published var disabledApps: [String] { didSet { store(disabledApps, "disabledApps") } }
    @Published var confirmDelete: Bool { didSet { store(confirmDelete, "confirmDelete") } }
    @Published var primaryAction: PrimaryAction { didSet { store(primaryAction.rawValue, "primaryAction") } }

    private init() {
        let defaults = UserDefaults.standard
        func value<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: "snippets." + key) as? T ?? fallback }
        expansionEnabled = value("expansionEnabled", true)
        mode = ExpansionMode(rawValue: value("mode", "")) ?? .immediate
        keepDelimiter = value("keepDelimiter", true)
        expandInsideWords = value("expandInsideWords", false)
        injectionDelay = value("injectionDelay", 30)
        playSound = value("playSound", false)
        disabledApps = value("disabledApps", Self.defaultDisabledApps)
        confirmDelete = value("confirmDelete", true)
        primaryAction = PrimaryAction(rawValue: value("primaryAction", "")) ?? .paste
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: "snippets." + key)
    }
}

/// Onglet « Snippets » des réglages.
struct SnippetSettingsView: View {
    @ObservedObject private var settings = SnippetSettings.shared
    @ObservedObject private var expander = SnippetExpander.shared
    @ObservedObject private var store = SnippetStore.shared

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Développer les mots-clés en tapant", isOn: $settings.expansionEnabled)
                status
                Picker("Développer", selection: $settings.mode) {
                    Text("Dès que le mot-clé est tapé").tag(ExpansionMode.immediate)
                    Text("Après un délimiteur (espace, ponctuation, retour)").tag(ExpansionMode.delimiter)
                }
                .disabled(!settings.expansionEnabled)
                if settings.mode == .delimiter {
                    Toggle("Garder le délimiteur après le texte", isOn: $settings.keepDelimiter)
                        .disabled(!settings.expansionEnabled)
                }
                Toggle("Développer à l’intérieur des mots", isOn: $settings.expandInsideWords)
                    .disabled(!settings.expansionEnabled)
                Picker("Délai avant le collage", selection: $settings.injectionDelay) {
                    Text("Aucun").tag(0)
                    Text("30 ms").tag(30)
                    Text("100 ms").tag(100)
                    Text("250 ms").tag(250)
                    Text("500 ms").tag(500)
                }
                .disabled(!settings.expansionEnabled)
                Toggle("Jouer un son après le développement", isOn: $settings.playSound)
                    .disabled(!settings.expansionEnabled)
            } header: {
                Text("Développement des mots-clés")
            } footer: {
                Text("Tapez le mot-clé d’un snippet dans n’importe quelle application : il est remplacé par le texte. Un mot-clé qui commence par une lettre doit commencer un mot ; « ;sig » ou « !date » marchent partout. Les champs de mot de passe sont toujours ignorés.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                if settings.disabledApps.isEmpty {
                    Text("Aucune application").foregroundStyle(.secondary)
                }
                ForEach(settings.disabledApps, id: \.self) { bundleID in
                    HStack(spacing: 8) {
                        let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
                        if let path {
                            Image(nsImage: IconCache.icon(for: path)).resizable().frame(width: 18, height: 18)
                        } else {
                            Image(systemName: "app.dashed").frame(width: 18, height: 18).foregroundStyle(.secondary)
                        }
                        Text(path.map(AppName.of) ?? knownNames[bundleID] ?? bundleID)
                        if path == nil {
                            Text("non installée").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button {
                            settings.disabledApps.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Retirer")
                    }
                }
                HStack {
                    Menu("Ajouter une application ouverte") {
                        ForEach(runningApps, id: \.bundleID) { app in
                            Button(app.name) { settings.disabledApps.append(app.bundleID) }
                        }
                    }
                    .fixedSize()
                    Button("Choisir…", action: chooseApp)
                    Spacer()
                    Button("Valeurs par défaut") { settings.disabledApps = SnippetSettings.defaultDisabledApps }
                }
            } header: {
                Text("Applications désactivées")
            } footer: {
                Text("Les mots-clés ne se développent pas dans ces applications.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Liste des snippets") {
                Picker("Action principale", selection: $settings.primaryAction) {
                    Text("Coller dans l’application active").tag(SnippetSettings.PrimaryAction.paste)
                    Text("Copier dans le presse-papiers").tag(SnippetSettings.PrimaryAction.copy)
                }
                Toggle("Demander confirmation avant de supprimer", isOn: $settings.confirmDelete)
            }

            Section {
                LabeledContent("Snippets") {
                    Text("\(store.snippets.count)").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Importer…") { SnippetsFeature.presentReport(SnippetsFeature.importFromFile()) }
                    Button("Exporter…") { SnippetsFeature.presentReport(SnippetsFeature.exportToFile()) }
                    Spacer()
                    Button("Afficher le fichier") {
                        NSWorkspace.shared.activateFileViewerSelecting([StoreLocation.file("snippets.json")])
                    }
                }
            } header: {
                Text("Données")
            } footer: {
                Text("Format JSON de Raycast : un tableau d’objets « name », « text » et « keyword » facultatif.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { expander.update() }
        .onReceive(timer) { _ in expander.update() }
    }

    @ViewBuilder
    private var status: some View {
        switch expander.status {
        case .running:
            Label("Actif dans toutes les applications", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Palette.green)
                .font(.system(size: 12))
        case .needsAccessibility:
            HStack {
                Label("Prism a besoin de l’accessibilité pour lire et remplacer les mots-clés.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.orange)
                    .font(.system(size: 12))
                Spacer()
                Button("Autoriser…") {
                    Paster.requestTrust()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        case .failed:
            Label("Impossible d’écouter le clavier. Réessai automatique.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.orange)
                .font(.system(size: 12))
        case .off:
            EmptyView()
        }
    }

    /// Noms des applications par défaut, quand elles ne sont pas installées.
    private let knownNames = [
        "com.apple.Passwords": "Mots de passe",
        "com.apple.keychainaccess": "Trousseau d’accès",
        "com.1password.1password": "1Password",
        "com.agilebits.onepassword7": "1Password 7",
    ]

    private var runningApps: [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, !settings.disabledApps.contains(id) else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Désactiver les snippets dans une application"
        panel.prompt = "Ajouter"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier, !settings.disabledApps.contains(id) else { return }
        settings.disabledApps.append(id)
    }
}
