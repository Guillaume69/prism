import AppKit
import SwiftUI

/// Réglages de l'historique du presse-papiers. L'activation reste dans `Preferences.clipboardHistoryEnabled`.
@MainActor
final class ClipboardSettings: ObservableObject {
    static let shared = ClipboardSettings()

    enum PrimaryAction: String, CaseIterable {
        case paste, copy
    }

    /// Gestionnaires de mots de passe : leurs copies ne vont jamais dans l'historique.
    static let defaultDisabledApps = [
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
    ]

    /// Noms affichés quand l'application n'est pas installée.
    static let knownAppNames = [
        "com.apple.Passwords": "Mots de passe",
        "com.apple.keychainaccess": "Trousseau d’accès",
        "com.1password.1password": "1Password",
        "com.agilebits.onepassword7": "1Password 7",
        "com.bitwarden.desktop": "Bitwarden",
    ]

    private let defaults = UserDefaults.standard

    @Published var retention: ClipboardRetention {
        didSet { defaults.set(retention.rawValue, forKey: "clipboard.retention"); ClipboardMonitor.shared.prune() }
    }

    @Published var maxEntries: Int {
        didSet { defaults.set(maxEntries, forKey: "clipboard.maxEntries"); ClipboardMonitor.shared.prune() }
    }

    @Published var primaryAction: PrimaryAction {
        didSet { defaults.set(primaryAction.rawValue, forKey: "clipboard.primaryAction") }
    }

    @Published var preferPlainText: Bool {
        didSet { defaults.set(preferPlainText, forKey: "clipboard.preferPlainText") }
    }

    /// L'entrée collée ou copiée depuis l'historique remonte en tête.
    @Published var moveToTopOnUse: Bool {
        didSet { defaults.set(moveToTopOnUse, forKey: "clipboard.moveToTopOnUse") }
    }

    @Published var recognizeText: Bool {
        didSet {
            defaults.set(recognizeText, forKey: "clipboard.recognizeText")
            if recognizeText { ClipboardMonitor.shared.recognizeMissing() }
        }
    }

    @Published var accurateRecognition: Bool {
        didSet { defaults.set(accurateRecognition, forKey: "clipboard.accurateRecognition") }
    }

    /// Identifiants des applications dont les copies sont ignorées.
    @Published var disabledApps: [String] {
        didSet { defaults.set(disabledApps, forKey: "clipboard.disabledApps") }
    }

    /// Délai après lequel « Coller en séquence » repart de l'entrée la plus récente.
    @Published var sequenceTimeout: Double {
        didSet { defaults.set(sequenceTimeout, forKey: "clipboard.sequenceTimeout") }
    }

    @Published var sequenceAppendsNewline: Bool {
        didSet { defaults.set(sequenceAppendsNewline, forKey: "clipboard.sequenceAppendsNewline") }
    }

    private init() {
        retention = defaults.string(forKey: "clipboard.retention").flatMap(ClipboardRetention.init(rawValue:)) ?? .threeMonths
        maxEntries = defaults.object(forKey: "clipboard.maxEntries") as? Int ?? 1_000
        primaryAction = defaults.string(forKey: "clipboard.primaryAction").flatMap(PrimaryAction.init(rawValue:)) ?? .paste
        preferPlainText = defaults.bool(forKey: "clipboard.preferPlainText")
        moveToTopOnUse = defaults.object(forKey: "clipboard.moveToTopOnUse") as? Bool ?? true
        recognizeText = defaults.object(forKey: "clipboard.recognizeText") as? Bool ?? true
        accurateRecognition = defaults.bool(forKey: "clipboard.accurateRecognition")
        disabledApps = defaults.stringArray(forKey: "clipboard.disabledApps") ?? Self.defaultDisabledApps
        sequenceTimeout = defaults.object(forKey: "clipboard.sequenceTimeout") as? Double ?? 30
        sequenceAppendsNewline = defaults.bool(forKey: "clipboard.sequenceAppendsNewline")
    }

    static func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            return name
        }
        return knownAppNames[bundleID] ?? bundleID
    }

    static func appPath(_ bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
    }

    func disable(bundleID: String) {
        guard !disabledApps.contains(bundleID) else { return }
        disabledApps.append(bundleID)
    }
}

// MARK: - Onglet des réglages

struct ClipboardSettingsView: View {
    @ObservedObject private var preferences = Preferences.shared
    @ObservedObject private var settings = ClipboardSettings.shared
    @ObservedObject private var monitor = ClipboardMonitor.shared
    @State private var diskSize: Int?
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Toggle("Garder l’historique du presse-papiers", isOn: $preferences.clipboardHistoryEnabled)
                Picker("Conserver pendant", selection: $settings.retention) {
                    ForEach(ClipboardRetention.allCases) { Text($0.title).tag($0) }
                }
                Picker("Nombre maximal d’entrées", selection: $settings.maxEntries) {
                    ForEach([100, 300, 500, 1_000, 2_500, 5_000], id: \.self) { Text("\($0)").tag($0) }
                }
                LabeledContent("Historique") {
                    HStack(spacing: 10) {
                        Text(summary)
                            .foregroundStyle(.secondary)
                        Button("Effacer l’historique…", role: .destructive) { confirmClear = true }
                            .disabled(monitor.entries.isEmpty)
                    }
                }
            } header: {
                Text("Historique")
            } footer: {
                Text("Les entrées épinglées sont toujours gardées. Les copies des gestionnaires de mots de passe ne sont jamais enregistrées.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Utilisation") {
                Picker("Action principale (↵)", selection: $settings.primaryAction) {
                    Text("Coller dans l’application active").tag(ClipboardSettings.PrimaryAction.paste)
                    Text("Copier dans le presse-papiers").tag(ClipboardSettings.PrimaryAction.copy)
                }
                Toggle("Coller en texte brut par défaut", isOn: $settings.preferPlainText)
                Toggle("Remonter en tête l’entrée collée ou copiée", isOn: $settings.moveToTopOnUse)
            }

            Section {
                Toggle("Reconnaître le texte des images", isOn: $settings.recognizeText)
                Picker("Mode", selection: $settings.accurateRecognition) {
                    Text("Rapide").tag(false)
                    Text("Précis").tag(true)
                }
                .disabled(!settings.recognizeText)
            } header: {
                Text("Reconnaissance de texte")
            } footer: {
                Text("Le texte des images copiées est reconnu sur votre Mac, en arrière-plan, pour les retrouver par la recherche. Le mode précis est plus lent.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Repartir de la plus récente après", selection: $settings.sequenceTimeout) {
                    Text("10 secondes").tag(10.0)
                    Text("30 secondes").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                    Text("15 minutes").tag(900.0)
                }
                Toggle("Ajouter un retour à la ligne après le texte", isOn: $settings.sequenceAppendsNewline)
            } header: {
                Text("Coller en séquence")
            } footer: {
                Text("Chaque appel de « Coller en séquence » colle l’entrée suivante, de la plus récente à la plus ancienne. Une nouvelle copie fait aussi repartir du début.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(settings.disabledApps, id: \.self) { bundleID in
                    HStack(spacing: 9) {
                        if let path = ClipboardSettings.appPath(bundleID) {
                            Image(nsImage: IconCache.icon(for: path))
                                .resizable()
                                .frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "app.dashed")
                                .font(.system(size: 15))
                                .foregroundStyle(.tertiary)
                                .frame(width: 20, height: 20)
                        }
                        Text(ClipboardSettings.appName(bundleID))
                        if ClipboardSettings.appPath(bundleID) == nil {
                            Text("Non installée")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button {
                            settings.disabledApps.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Ne plus ignorer cette application")
                    }
                }
                HStack {
                    Menu("Ajouter une application") {
                        Button("Choisir une application…", action: chooseApp)
                        let running = runningApps
                        if !running.isEmpty {
                            Section("Applications ouvertes") {
                                ForEach(running, id: \.bundleID) { app in
                                    Button(app.name) { settings.disable(bundleID: app.bundleID) }
                                }
                            }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Button("Rétablir la liste par défaut") {
                        settings.disabledApps = ClipboardSettings.defaultDisabledApps
                    }
                    .buttonStyle(.borderless)
                    .disabled(settings.disabledApps == ClipboardSettings.defaultDisabledApps)
                }
            } header: {
                Text("Applications ignorées")
            } footer: {
                Text("Ce qui est copié dans ces applications n’entre pas dans l’historique.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: monitor.entries.count) {
            diskSize = await withCheckedContinuation { continuation in
                ClipboardStorage.queue.async { continuation.resume(returning: ClipboardStorage.diskSize()) }
            }
        }
        .alert("Effacer tout l’historique ?", isPresented: $confirmClear) {
            Button("Effacer", role: .destructive) { monitor.clear() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les \(monitor.entries.count) entrées, épinglées comprises, et leurs images seront supprimées définitivement.")
        }
    }

    private var summary: String {
        let count = monitor.entries.count
        var text = count == 0 ? "Vide" : count == 1 ? "1 entrée" : "\(count) entrées"
        if let diskSize, diskSize > 0 {
            text += " · " + ByteCountFormatter.string(fromByteCount: Int64(diskSize), countStyle: .file)
        }
        return text
    }

    private var runningApps: [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, !settings.disabledApps.contains(id) else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Ignorer les copies d’une application"
        panel.prompt = "Ignorer"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { settings.disable(bundleID: id) }
        }
    }
}
