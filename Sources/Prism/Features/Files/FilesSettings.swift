import AppKit
import SwiftUI

/// Réglages de la recherche de fichiers : portées, motifs ignorés, fichiers cachés, terminal.
@MainActor
final class FilesSettings: ObservableObject {
    static let shared = FilesSettings()

    private let defaults = UserDefaults.standard

    static let defaultIgnoredPatterns = ["Library", "node_modules", ".build", "DerivedData", "Pods", "vendor", ".git"]

    /// Dossiers où chercher en plus du dossier personnel (chemins absolus).
    @Published var extraScopes: [String] {
        didSet { defaults.set(extraScopes, forKey: "files.extraScopes") }
    }

    /// Cherche dans tout le dossier personnel (sinon seulement dans les dossiers ajoutés).
    @Published var searchHome: Bool {
        didSet { defaults.set(searchHome, forKey: "files.searchHome") }
    }

    /// Noms de dossiers (ou motifs `*`) dont le contenu est écarté des résultats.
    @Published var ignoredPatterns: [String] {
        didSet { defaults.set(ignoredPatterns, forKey: "files.ignoredPatterns") }
    }

    @Published var showHidden: Bool {
        didSet { defaults.set(showHidden, forKey: "files.showHidden") }
    }

    /// Identifiant de l'application de terminal.
    @Published var terminal: String {
        didSet { defaults.set(terminal, forKey: "files.terminal") }
    }

    /// Tri du contenu d'un dossier parcouru : « modified », « created » ou « name ».
    /// Cherche aussi dans le contenu des fichiers (index Spotlight), pas seulement dans leur nom.
    @Published var contentSearch: Bool {
        didSet { defaults.set(contentSearch, forKey: "files.contentSearch") }
    }

    @Published var folderSort: String {
        didSet { defaults.set(folderSort, forKey: "files.folderSort") }
    }

    private init() {
        extraScopes = defaults.stringArray(forKey: "files.extraScopes") ?? []
        searchHome = defaults.object(forKey: "files.searchHome") as? Bool ?? true
        ignoredPatterns = defaults.stringArray(forKey: "files.ignoredPatterns") ?? Self.defaultIgnoredPatterns
        showHidden = defaults.bool(forKey: "files.showHidden")
        terminal = defaults.string(forKey: "files.terminal") ?? TerminalApp.terminal.rawValue
        folderSort = defaults.string(forKey: "files.folderSort") ?? "modified"
        contentSearch = defaults.bool(forKey: "files.contentSearch")
    }

    /// Les portées de Spotlight.
    var searchScopes: [Any] {
        var scopes: [Any] = searchHome ? [NSMetadataQueryUserHomeScope] : []
        scopes += extraScopes.map { URL(fileURLWithPath: $0) }
        return scopes.isEmpty ? [NSMetadataQueryUserHomeScope] : scopes
    }

    /// Faut-il écarter ce chemin des résultats ?
    func isExcluded(_ path: String) -> Bool {
        FileFilter.isExcluded(path, patterns: ignoredPatterns, showHidden: showHidden)
    }
}

/// Le filtrage des chemins, sans état : testé par `--selftest`.
enum FileFilter {
    static func isExcluded(_ path: String, patterns: [String], showHidden: Bool) -> Bool {
        // Le contenu des paquets (apps, bibliothèques Photos) n'est jamais montré.
        if path.contains(".app/") || path.contains(".photoslibrary/") { return true }
        let components = path.split(separator: "/").map(String.init)
        // Le dernier composant est le fichier lui-même : seuls ses dossiers parents sont comparés aux motifs.
        let folders = components.dropLast()
        if !showHidden, components.contains(where: { $0.hasPrefix(".") }) { return true }
        for pattern in patterns where !pattern.isEmpty {
            if folders.contains(where: { fnmatch(pattern, $0, 0) == 0 }) { return true }
        }
        return false
    }
}

/// L'onglet « Fichiers » des réglages.
struct FilesSettingsView: View {
    @ObservedObject private var settings = FilesSettings.shared
    @ObservedObject private var preferences = Preferences.shared
    @State private var newPattern = ""

    var body: some View {
        Form {
            Section {
                Toggle("Chercher dans le dossier personnel", isOn: $settings.searchHome)
                ForEach(settings.extraScopes, id: \.self) { path in
                    HStack {
                        Image(nsImage: IconCache.icon(for: path)).resizable().frame(width: 18, height: 18)
                        Text(FileOps.abbreviated(path)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            settings.extraScopes.removeAll { $0 == path }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Retirer ce dossier")
                    }
                }
                Button("Ajouter un dossier…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = true
                    panel.prompt = "Ajouter"
                    guard panel.runModal() == .OK else { return }
                    for url in panel.urls where !settings.extraScopes.contains(url.path) {
                        settings.extraScopes.append(url.path)
                    }
                }
            } header: {
                Text("Où chercher")
            } footer: {
                Text("Spotlight cherche dans ces dossiers, par nom de fichier. Ajoutez un disque externe ou un dossier hors de votre dossier personnel.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section {
                ForEach(settings.ignoredPatterns, id: \.self) { pattern in
                    HStack {
                        Text(pattern).font(.system(size: 12.5, design: .monospaced))
                        Spacer()
                        Button {
                            settings.ignoredPatterns.removeAll { $0 == pattern }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Motif", text: $newPattern, prompt: Text("Nom de dossier ou motif (build, *.xcarchive…)"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addPattern)
                    Button("Ajouter", action: addPattern)
                        .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Rétablir les motifs par défaut") {
                    settings.ignoredPatterns = FilesSettings.defaultIgnoredPatterns
                }
                .disabled(settings.ignoredPatterns == FilesSettings.defaultIgnoredPatterns)
            } header: {
                Text("Dossiers ignorés")
            } footer: {
                Text("Les fichiers rangés dans un dossier de ce nom n’apparaissent pas dans les résultats.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("Affichage") {
                Toggle("Afficher les fichiers cachés", isOn: $settings.showHidden)
                Toggle("Chercher aussi dans le contenu des fichiers", isOn: $settings.contentSearch)
                Toggle("Inclure les fichiers dans la recherche principale", isOn: $preferences.filesInRootSearch)
                Picker("Ouvrir les dossiers dans", selection: $settings.terminal) {
                    ForEach(TerminalApp.installed) { app in
                        Text(app.title).tag(app.rawValue)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addPattern() {
        let pattern = newPattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty, !settings.ignoredPatterns.contains(pattern) else { return }
        settings.ignoredPatterns.append(pattern)
        newPattern = ""
    }
}
