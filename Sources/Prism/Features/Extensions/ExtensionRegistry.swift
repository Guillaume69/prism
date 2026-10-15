import AppKit
import Security

/// Le manifeste d'une extension Raycast construite (`package.json`) : ses commandes, arguments et préférences.
struct ExtensionManifest {
    struct Option {
        let title: String
        let value: String
    }

    struct Preference {
        let name: String
        let type: String
        let title: String
        let description: String
        let isRequired: Bool
        let defaultValue: Any?
        let placeholder: String
        let label: String
        let options: [Option]

        init(_ json: [String: Any]) {
            name = json["name"] as? String ?? ""
            type = json["type"] as? String ?? "textfield"
            title = json["title"] as? String ?? (json["label"] as? String ?? name)
            description = json["description"] as? String ?? ""
            isRequired = json["required"] as? Bool ?? false
            defaultValue = json["default"]
            placeholder = json["placeholder"] as? String ?? ""
            label = json["label"] as? String ?? title
            options = (json["data"] as? [[String: Any]] ?? []).map {
                Option(title: $0["title"] as? String ?? "", value: ExtensionValue.text($0["value"]) ?? "")
            }
        }

        var isSecret: Bool { type == "password" }
    }

    struct Argument {
        let name: String
        let type: String
        let placeholder: String
        let isRequired: Bool
        let options: [Option]

        init(_ json: [String: Any]) {
            name = json["name"] as? String ?? ""
            type = json["type"] as? String ?? "text"
            placeholder = json["placeholder"] as? String ?? name
            isRequired = json["required"] as? Bool ?? false
            options = (json["data"] as? [[String: Any]] ?? []).map {
                Option(title: $0["title"] as? String ?? "", value: ExtensionValue.text($0["value"]) ?? "")
            }
        }
    }

    struct Command {
        let name: String
        let title: String
        let subtitle: String
        let description: String
        let mode: String
        let icon: String?
        let keywords: [String]
        let arguments: [Argument]
        let preferences: [Preference]
        let isDisabledByDefault: Bool
        /// L'intervalle de rafraîchissement en arrière-plan (« 10m », « 1h »…), pour les menus et les commandes sans vue.
        let interval: TimeInterval?

        init(_ json: [String: Any]) {
            name = json["name"] as? String ?? ""
            title = json["title"] as? String ?? name
            subtitle = json["subtitle"] as? String ?? ""
            description = json["description"] as? String ?? ""
            mode = json["mode"] as? String ?? "view"
            icon = json["icon"] as? String
            keywords = json["keywords"] as? [String] ?? []
            arguments = (json["arguments"] as? [[String: Any]] ?? []).map(Argument.init)
            preferences = (json["preferences"] as? [[String: Any]] ?? []).map(Preference.init)
            isDisabledByDefault = json["disabledByDefault"] as? Bool ?? false
            interval = (json["interval"] as? String).flatMap(Self.parseInterval)
        }

        /// « 30s », « 10m », « 2h », « 1d » en secondes (Raycast refuse moins de 10 s).
        static func parseInterval(_ raw: String) -> TimeInterval? {
            guard let unit = raw.last, let value = Double(raw.dropLast()) else { return nil }
            let seconds: Double
            switch unit {
            case "s": seconds = value
            case "m": seconds = value * 60
            case "h": seconds = value * 3600
            case "d": seconds = value * 86_400
            default: return nil
            }
            return max(seconds, 10)
        }
    }

    let name: String
    let title: String
    let description: String
    let icon: String?
    let author: String
    let commands: [Command]
    let preferences: [Preference]

    init?(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let name = json["name"] as? String else { return nil }
        self.name = name
        title = json["title"] as? String ?? name
        description = json["description"] as? String ?? ""
        icon = json["icon"] as? String
        author = json["owner"] as? String ?? (json["author"] as? String ?? "")
        commands = (json["commands"] as? [[String: Any]] ?? []).map(Command.init).filter { !$0.name.isEmpty }
        preferences = (json["preferences"] as? [[String: Any]] ?? []).map(Preference.init)
    }
}

/// Une extension installée : son dossier (le paquet construit tel que le Store le livre) et sa provenance.
struct InstalledExtension: Identifiable {
    struct Origin: Codable {
        var storeID: String?
        var owner: String
        var name: String
        var commitSHA: String?
        var installedAt = Date()
        /// Extension importée d'un dossier : ses sources, reconstruites à chaque modification en mode développement.
        var sourcePath: String?
        var isDevelopment: Bool?
    }

    let directory: URL
    let manifest: ExtensionManifest
    let origin: Origin

    /// « auteur.nom » : stable d'une mise à jour à l'autre.
    var id: String { "\(origin.owner).\(origin.name)" }
    var title: String { manifest.title }
    var assets: URL { directory.appendingPathComponent("assets", isDirectory: true) }

    @MainActor var icon: ItemIcon { ExtensionIcon.icon(manifest.icon, assets: assets, fallback: .symbol("puzzlepiece.extension.fill", Palette.violet)) }

    @MainActor func icon(for command: ExtensionManifest.Command) -> ItemIcon {
        command.icon.map { ExtensionIcon.icon($0, assets: assets, fallback: icon) } ?? icon
    }

    /// Le dossier de données de l'extension (`environment.supportPath`).
    var supportPath: URL {
        StoreLocation.subdirectory("Extensions/Support").appendingPathComponent(id, isDirectory: true)
    }
}

/// Les extensions installées dans `Application Support/Prism/Extensions`.
@MainActor
final class ExtensionRegistry: ObservableObject {
    static let shared = ExtensionRegistry()

    @Published private(set) var extensions: [InstalledExtension] = []

    static var directory: URL { StoreLocation.subdirectory("Extensions/Installed") }

    private init() { reload() }

    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        extensions = folders.compactMap(Self.load).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        writeSyncedList()
        NotificationCenter.default.post(name: .prismDataDidChange, object: nil)
    }

    // MARK: - Liste synchronisée

    /// Une extension du Store, telle que la synchronisation la transmet aux autres Mac.
    struct SyncedEntry: Codable, Equatable {
        var storeID: String?
        var owner: String
        var name: String
        var title: String
    }

    static var syncedListFile: URL { StoreLocation.file("extensions-installed.json") }

    /// La liste des extensions du Store installées ici, réunie avec celle venue des autres Mac.
    private func writeSyncedList() {
        guard !SnippetStore.isHeadless else { return }
        let here = extensions.filter { $0.origin.storeID != nil }.map { SyncedEntry(storeID: $0.origin.storeID, owner: $0.origin.owner, name: $0.origin.name, title: $0.title) }
        let known = Self.syncedList()
        var merged = known.filter { entry in !here.contains { $0.owner == entry.owner && $0.name == entry.name } && !removed.contains("\(entry.owner).\(entry.name)") }
        merged += here
        merged.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        guard merged != known, let data = try? JSONEncoder.prism.encode(merged) else { return }
        try? data.write(to: Self.syncedListFile, options: .atomic)
    }

    static func syncedList() -> [SyncedEntry] {
        (try? Data(contentsOf: syncedListFile)).flatMap { try? JSONDecoder.prism.decode([SyncedEntry].self, from: $0) } ?? []
    }

    /// Les extensions installées sur un autre Mac et absentes ici.
    var missingFromSync: [SyncedEntry] {
        Self.syncedList().filter { entry in installed(owner: entry.owner, name: entry.name) == nil }
    }

    /// Désinstallées ici pendant cette session : retirées de la liste synchronisée.
    private var removed: Set<String> = []

    static func load(_ folder: URL) -> InstalledExtension? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("package.json")),
              let manifest = ExtensionManifest(data: data) else { return nil }
        let originURL = folder.appendingPathComponent(".prism.json")
        let origin = (try? Data(contentsOf: originURL)).flatMap { try? JSONDecoder.prism.decode(InstalledExtension.Origin.self, from: $0) }
            ?? InstalledExtension.Origin(owner: manifest.author.isEmpty ? "local" : manifest.author, name: manifest.name)
        return InstalledExtension(directory: folder, manifest: manifest, origin: origin)
    }

    func installed(owner: String, name: String) -> InstalledExtension? {
        extensions.first { $0.origin.owner == owner && $0.origin.name == name }
    }

    func find(_ id: String) -> InstalledExtension? { extensions.first { $0.id == id } }

    /// Installe un paquet décompressé : son dossier remplace l'ancien, avec sa provenance.
    func install(from folder: URL, origin: InstalledExtension.Origin) throws -> InstalledExtension {
        let destination = Self.directory.appendingPathComponent("\(origin.owner).\(origin.name)", isDirectory: true)
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        try manager.moveItem(at: folder, to: destination)
        try JSONEncoder.prism.encode(origin).write(to: destination.appendingPathComponent(".prism.json"))
        reload()
        guard let installed = find("\(origin.owner).\(origin.name)") else {
            throw NSError(domain: "Prism", code: 1, userInfo: [NSLocalizedDescriptionKey: "Le paquet de l’extension est illisible"])
        }
        return installed
    }

    /// Désinstalle : le paquet part à la corbeille, les données et les préférences sont effacées.
    func uninstall(_ installed: InstalledExtension) {
        ExtensionBackground.shared.removeAll(for: installed)
        if let source = installed.origin.sourcePath { ExtensionDevelopment.shared.stopWatching(source) }
        NSWorkspace.shared.recycle([installed.directory]) { _, _ in }
        try? FileManager.default.removeItem(at: installed.supportPath)
        ExtensionPreferences.shared.removeAll(for: installed)
        extensions.removeAll { $0.id == installed.id }
        removed.insert(installed.id)
        let remaining = Self.syncedList().filter { "\($0.owner).\($0.name)" != installed.id }
        if let data = try? JSONEncoder.prism.encode(remaining) { try? data.write(to: Self.syncedListFile, options: .atomic) }
        NotificationCenter.default.post(name: .prismDataDidChange, object: nil)
    }
}

/// Les préférences des extensions (et de leurs commandes). Les mots de passe vont dans le trousseau.
@MainActor
final class ExtensionPreferences {
    static let shared = ExtensionPreferences()

    private let store = JSONStore("extension-preferences.json", default: [String: [String: String]]())
    private static let keychainService = "app.prism.extensions"

    static func scope(_ installed: InstalledExtension, command: ExtensionManifest.Command?) -> String {
        command.map { "\(installed.id)/\($0.name)" } ?? installed.id
    }

    func value(_ preference: ExtensionManifest.Preference, scope: String) -> String? {
        if preference.isSecret { return Self.readSecret(account: scope + "#" + preference.name) }
        return store.value[scope]?[preference.name]
    }

    func set(_ value: String, for preference: ExtensionManifest.Preference, scope: String) {
        if preference.isSecret {
            Self.writeSecret(value, account: scope + "#" + preference.name)
            return
        }
        store.value[scope, default: [:]][preference.name] = value
    }

    /// Les valeurs transmises à `getPreferenceValues()` : celles de l'extension puis celles de la commande, avec les défauts.
    func values(for installed: InstalledExtension, command: ExtensionManifest.Command) -> [String: Any] {
        var result: [String: Any] = [:]
        let groups: [(ExtensionManifest.Preference, String)] =
            installed.manifest.preferences.map { ($0, Self.scope(installed, command: nil)) } +
            command.preferences.map { ($0, Self.scope(installed, command: command)) }
        for (preference, scope) in groups {
            let stored = value(preference, scope: scope)
            switch preference.type {
            case "checkbox":
                result[preference.name] = stored.map { $0 == "true" } ?? (preference.defaultValue as? Bool ?? false)
            default:
                result[preference.name] = stored ?? ExtensionValue.text(preference.defaultValue) ?? (preference.type == "dropdown" ? preference.options.first?.value ?? "" : "")
            }
        }
        return result
    }

    /// Les préférences obligatoires encore vides : demandées avant le premier lancement.
    func missing(for installed: InstalledExtension, command: ExtensionManifest.Command) -> [(ExtensionManifest.Preference, String)] {
        let groups: [(ExtensionManifest.Preference, String)] =
            installed.manifest.preferences.map { ($0, Self.scope(installed, command: nil)) } +
            command.preferences.map { ($0, Self.scope(installed, command: command)) }
        return groups.filter { preference, scope in
            guard preference.isRequired, preference.type != "checkbox" else { return false }
            let current = value(preference, scope: scope) ?? ExtensionValue.text(preference.defaultValue) ?? ""
            return current.isEmpty
        }
    }

    func removeAll(for installed: InstalledExtension) {
        for key in store.value.keys where key == installed.id || key.hasPrefix(installed.id + "/") {
            store.value[key] = nil
        }
        let groups = [installed.manifest.preferences.map { (installed.id, $0) }] +
            installed.manifest.commands.map { command in command.preferences.map { ("\(installed.id)/\(command.name)", $0) } }
        for (scope, preference) in groups.flatMap({ $0 }) where preference.isSecret {
            Self.deleteSecret(account: scope + "#" + preference.name)
        }
    }

    // MARK: Trousseau

    private static func readSecret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeSecret(_ value: String, account: String) {
        deleteSecret(account: account)
        guard !value.isEmpty else { return }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
            kSecAttrLabel as String: "Prism — préférence d’extension",
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func deleteSecret(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
