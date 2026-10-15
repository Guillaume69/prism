import CommonCrypto
import CryptoKit
import Foundation

/// Les familles de données qu'on exporte, importe ou synchronise.
enum SyncCategory: String, CaseIterable, Codable, Sendable {
    case commands, snippets, quicklinks, notes, themes, ai, clipboard, other, preferences

    var title: String {
        switch self {
        case .commands: "Commandes, alias et raccourcis"
        case .snippets: "Snippets"
        case .quicklinks: "Liens rapides"
        case .notes: "Notes"
        case .themes: "Thèmes"
        case .ai: "IA (conversations, commandes, réglages)"
        case .clipboard: "Historique du presse-papiers"
        case .other: "Autres données (emojis, scripts…)"
        case .preferences: "Préférences"
        }
    }

    var symbol: String {
        switch self {
        case .commands: "command"
        case .snippets: "text.badge.plus"
        case .quicklinks: "link"
        case .notes: "note.text"
        case .themes: "paintpalette"
        case .ai: "sparkles"
        case .clipboard: "doc.on.clipboard"
        case .other: "square.stack.3d.up"
        case .preferences: "gearshape"
        }
    }

    /// La famille d'un fichier de données, d'après son nom (ou celui de son sous-dossier).
    static func category(forFile relativePath: String) -> SyncCategory {
        let name = relativePath.lowercased()
        func starts(_ prefixes: String...) -> Bool { prefixes.contains { name.hasPrefix($0) } }
        if starts("command", "alias", "hotkey") { return .commands }
        if starts("snippet") { return .snippets }
        if starts("quicklink", "quick-link", "links") { return .quicklinks }
        if starts("note") { return .notes }
        if starts("theme") { return .themes }
        if starts("ai.", "ai-", "ai_", "ai/", "chat", "prompt", "presets") { return .ai }
        if starts("clipboard") { return .clipboard }
        return .other
    }
}

enum ArchiveError: LocalizedError, Equatable {
    case invalidFormat
    case unsupportedVersion(Int)
    case passphraseRequired
    case wrongPassphrase
    case passphraseTooShort

    var errorDescription: String? {
        switch self {
        case .invalidFormat: "Ce fichier n’est pas une exportation de Prism."
        case .unsupportedVersion(let version): "Format \(version) inconnu : mettez Prism à jour."
        case .passphraseRequired: "Ce fichier est chiffré : saisissez sa phrase de passe."
        case .wrongPassphrase: "Phrase de passe incorrecte."
        case .passphraseTooShort: "La phrase de passe doit compter au moins 8 caractères."
        }
    }
}

/// Une exportation `.prismconfig` : les fichiers JSON d'Application Support/Prism et les préférences de l'app.
struct PrismArchive: Codable, Equatable {
    struct File: Codable, Equatable {
        var modified: Date
        var data: Data

        /// Les dates passent par un nombre de secondes : à la milliseconde près.
        static func == (lhs: File, rhs: File) -> Bool {
            lhs.data == rhs.data && abs(lhs.modified.timeIntervalSince(rhs.modified)) < 0.001
        }
    }

    static let formatName = "prism-config"
    static let fileExtension = "prismconfig"
    static let iterations = 200_000

    var format = PrismArchive.formatName
    var version = 1
    var created: Date
    var device: String
    var categories: [SyncCategory]
    /// Chemin relatif au dossier des données → contenu.
    var files: [String: File]
    /// Les préférences, en plist binaire.
    var preferences: Data?
    var preferencesModified: Date?

    /// Le dictionnaire des préférences contenues.
    var preferencesDictionary: [String: Any] {
        guard let preferences,
              let object = try? PropertyListSerialization.propertyList(from: preferences, format: nil) as? [String: Any] else { return [:] }
        return object
    }

    // MARK: - Collecte

    /// Dossiers d'Application Support/Prism qui ne sont pas des données à exporter.
    /// Les extensions installées sont du code : seule leur liste (`extensions-installed.json`) se synchronise.
    static let excludedDirectories: Set<String> = ["Backups", "Scripts", "Sync", "Extensions"]

    /// Les fichiers `*.json` du dossier (sous-dossiers compris), par chemin relatif.
    static func dataFiles(in directory: URL) -> [String: URL] {
        var result: [String: URL] = [:]
        let base = directory.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [:] }
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                if excludedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard url.pathExtension.lowercased() == "json" else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            result[String(path.dropFirst(base.count + 1))] = url
        }
        return result
    }

    /// Préférences propres à la machine ou au système : jamais exportées.
    static func isPortablePreference(_ key: String) -> Bool {
        let excludedPrefixes = ["NS", "Apple", "com.apple.", "WebKit", "SU", "sync.", "backup.", "hyper.applied", "hyper.replaced"]
        let excludedKeys: Set<String> = ["hasLaunchedBefore"]
        return !excludedKeys.contains(key) && !excludedPrefixes.contains { key.hasPrefix($0) }
    }

    static func collect(from directory: URL, categories: Set<SyncCategory>, preferences: [String: Any], preferencesModified: Date? = nil,
                        device: String = Host.current().localizedName ?? "Mac") -> PrismArchive {
        var files: [String: File] = [:]
        for (path, url) in dataFiles(in: directory) where categories.contains(SyncCategory.category(forFile: path)) {
            guard let data = try? Data(contentsOf: url) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            files[path] = File(modified: modified, data: data)
        }
        var archive = PrismArchive(created: Date(), device: device, categories: SyncCategory.allCases.filter { categories.contains($0) }, files: files)
        if categories.contains(.preferences) {
            let portable = preferences.filter { isPortablePreference($0.key) }
            archive.preferences = try? PropertyListSerialization.data(fromPropertyList: portable, format: .binary, options: 0)
            archive.preferencesModified = preferencesModified
        }
        return archive
    }

    static func == (lhs: PrismArchive, rhs: PrismArchive) -> Bool {
        lhs.files == rhs.files && lhs.categories == rhs.categories
            && NSDictionary(dictionary: lhs.preferencesDictionary).isEqual(to: rhs.preferencesDictionary)
    }

    // MARK: - Lecture et écriture, chiffrement

    private struct Probe: Codable {
        var format: String?
        var version: Int?
        var encrypted: Bool?
    }

    private struct Envelope: Codable {
        var format = PrismArchive.formatName
        var version = 1
        var encrypted = true
        var kdf = "PBKDF2-HMAC-SHA256"
        var iterations: Int
        var salt: Data
        /// Nonce, texte chiffré et étiquette d'AES-GCM, à la suite.
        var payload: Data
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    /// Le fichier `.prismconfig` : en clair, ou chiffré par AES-GCM avec une clé tirée de la phrase de passe.
    func encoded(passphrase: String?) throws -> Data {
        let plain = try Self.encoder.encode(self)
        guard let passphrase, !passphrase.isEmpty else { return plain }
        guard passphrase.count >= 8 else { throw ArchiveError.passphraseTooShort }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw ArchiveError.invalidFormat }
        let key = try Self.deriveKey(passphrase: passphrase, salt: salt, iterations: Self.iterations)
        let sealed = try AES.GCM.seal(plain, using: key)
        guard let combined = sealed.combined else { throw ArchiveError.invalidFormat }
        return try Self.encoder.encode(Envelope(iterations: Self.iterations, salt: salt, payload: combined))
    }

    static func isEncrypted(_ data: Data) -> Bool {
        (try? decoder.decode(Probe.self, from: data))?.encrypted == true
    }

    static func decode(_ data: Data, passphrase: String?) throws -> PrismArchive {
        guard let probe = try? decoder.decode(Probe.self, from: data), probe.format == formatName else { throw ArchiveError.invalidFormat }
        if let version = probe.version, version > 1 { throw ArchiveError.unsupportedVersion(version) }
        var plain = data
        if probe.encrypted == true {
            guard let passphrase, !passphrase.isEmpty else { throw ArchiveError.passphraseRequired }
            guard let envelope = try? decoder.decode(Envelope.self, from: data) else { throw ArchiveError.invalidFormat }
            let key = try deriveKey(passphrase: passphrase, salt: envelope.salt, iterations: envelope.iterations)
            do {
                plain = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.payload), using: key)
            } catch {
                throw ArchiveError.wrongPassphrase
            }
        }
        guard let archive = try? decoder.decode(PrismArchive.self, from: plain) else { throw ArchiveError.invalidFormat }
        return archive
    }

    /// PBKDF2-HMAC-SHA256 (CommonCrypto) → clé AES de 256 bits.
    static func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let length = passphrase.utf8.count
        let status = salt.withUnsafeBytes { saltBuffer in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), passphrase, length,
                saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                &derived, derived.count
            )
        }
        guard status == kCCSuccess else { throw ArchiveError.invalidFormat }
        return SymmetricKey(data: derived)
    }

    // MARK: - Import

    enum ImportMode: String, CaseIterable {
        /// Ajoute les éléments absents (par identifiant) aux listes connues ; remplace le reste.
        case merge
        /// Remplace les fichiers par ceux de l'exportation.
        case replace

        var title: String { self == .merge ? "Fusionner avec les données actuelles" : "Remplacer les données actuelles" }
    }

    struct ImportReport: Equatable {
        var written: [String] = []
        var merged: [String] = []
        var unchanged: [String] = []
        var preferenceCount = 0

        var changedFiles: [String] { written + merged }
    }

    /// Écrit les fichiers de l'exportation dans le dossier ; les préférences sont rendues à part (`preferencesDictionary`).
    func apply(to directory: URL, categories: Set<SyncCategory>, mode: ImportMode) throws -> ImportReport {
        var report = ImportReport()
        for (path, file) in files.sorted(by: { $0.key < $1.key }) where categories.contains(SyncCategory.category(forFile: path)) {
            // Un chemin qui sortirait du dossier des données est ignoré.
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { continue }
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let local = try? Data(contentsOf: url)
            var output = file.data
            if mode == .merge, let local {
                output = Self.merge(local: local, incoming: file.data) ?? file.data
            }
            if output == local {
                report.unchanged.append(path)
                continue
            }
            try output.write(to: url, options: .atomic)
            if local == nil || mode == .replace { report.written.append(path) } else { report.merged.append(path) }
        }
        if categories.contains(.preferences) { report.preferenceCount = preferencesDictionary.count }
        return report
    }

    /// Fusion de deux JSON : les listes d'objets à `id` (et les tableaux de chaînes) gagnent les éléments absents,
    /// les dictionnaires d'objets par identifiant gagnent les clés absentes, les autres valeurs sont remplacées.
    static func merge(local: Data, incoming: Data) -> Data? {
        guard let left = try? JSONSerialization.jsonObject(with: local, options: [.fragmentsAllowed]),
              let right = try? JSONSerialization.jsonObject(with: incoming, options: [.fragmentsAllowed]) else { return nil }
        let merged = mergeValue(left, right, depth: 0)
        return try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    }

    private static func mergeValue(_ local: Any, _ incoming: Any, depth: Int) -> Any {
        if let left = local as? [Any], let right = incoming as? [Any] {
            return mergeLists(left, right) ?? incoming
        }
        if let left = local as? [String: Any], let right = incoming as? [String: Any] {
            if depth == 0 {
                var result = left
                for (key, value) in right {
                    result[key] = left[key].map { mergeValue($0, value, depth: 1) } ?? value
                }
                return result
            }
            let values = Array(left.values) + Array(right.values)
            if !values.isEmpty, values.allSatisfy({ $0 is [String: Any] }) {
                var result = left
                for (key, value) in right where left[key] == nil { result[key] = value }
                return result
            }
        }
        return incoming
    }

    private static func mergeLists(_ left: [Any], _ right: [Any]) -> [Any]? {
        func identifier(_ value: Any) -> String? {
            guard let object = value as? [String: Any], let id = object["id"] else { return nil }
            return "\(id)"
        }
        if left.allSatisfy({ identifier($0) != nil }), right.allSatisfy({ identifier($0) != nil }) {
            var seen = Set(left.compactMap(identifier))
            return left + right.filter { identifier($0).map { seen.insert($0).inserted } ?? false }
        }
        if (left + right).allSatisfy({ $0 is String || $0 is NSNumber }) {
            var seen = Set(left.map { "\($0)" })
            return left + right.filter { seen.insert("\($0)").inserted }
        }
        return nil
    }
}

// MARK: - Synchronisation par un dossier partagé

/// Synchronise le dossier des données avec un fichier `.prismconfig` partagé (iCloud Drive, Dropbox…) :
/// pour chaque fichier dont le contenu diffère, le plus récent l'emporte. Rien n'est supprimé.
struct SyncEngine {
    var dataDirectory: URL
    var syncFile: URL
    var categories: Set<SyncCategory>
    var passphrase: String?
    var preferences: [String: Any]
    var preferencesModified: Date?
    var device: String = Host.current().localizedName ?? "Mac"

    struct Result {
        /// Fichiers repris de la copie partagée.
        var imported: [String] = []
        /// Fichiers envoyés vers la copie partagée.
        var exported: [String] = []
        /// Préférences à appliquer (plus récentes ailleurs).
        var importedPreferences: [String: Any]?
        var remoteDevice: String?

        var didChangeLocalData: Bool { !imported.isEmpty || importedPreferences != nil }
    }

    func run() throws -> Result {
        var result = Result()
        let manager = FileManager.default
        var remote: PrismArchive?
        if manager.fileExists(atPath: syncFile.path) {
            remote = try PrismArchive.decode(Data(contentsOf: syncFile), passphrase: passphrase)
            result.remoteDevice = remote?.device
        }
        let local = PrismArchive.collect(from: dataDirectory, categories: categories, preferences: preferences,
                                         preferencesModified: preferencesModified, device: device)
        // Le fichier partagé garde aussi ce que les autres Mac synchronisent et pas celui-ci.
        var shared = remote ?? PrismArchive(created: Date(), device: device, categories: [], files: [:])
        let paths = Set(local.files.keys).union(remote.map { Array($0.files.keys) } ?? [])
        for path in paths.sorted() where categories.contains(SyncCategory.category(forFile: path)) {
            let mine = local.files[path]
            let theirs = remote?.files[path]
            switch (mine, theirs) {
            case let (mine?, theirs?) where mine.data != theirs.data:
                if theirs.modified.timeIntervalSince(mine.modified) > 1 {
                    try write(theirs, to: path)
                    result.imported.append(path)
                } else {
                    shared.files[path] = mine
                    result.exported.append(path)
                }
            case let (nil, theirs?):
                try write(theirs, to: path)
                result.imported.append(path)
            case let (mine?, nil):
                shared.files[path] = mine
                result.exported.append(path)
            default:
                break
            }
        }
        if categories.contains(.preferences) {
            let mine = local.preferencesDictionary
            let theirs = remote?.preferencesDictionary ?? [:]
            if !NSDictionary(dictionary: mine).isEqual(to: theirs) {
                let remoteDate = remote?.preferencesModified ?? .distantPast
                let localDate = preferencesModified ?? .distantPast
                if remote?.preferences != nil, remoteDate > localDate {
                    result.importedPreferences = theirs
                } else {
                    shared.preferences = local.preferences
                    shared.preferencesModified = preferencesModified ?? Date()
                    result.exported.append("préférences")
                }
            }
        }
        if !result.exported.isEmpty || remote == nil {
            shared.created = Date()
            shared.device = device
            shared.categories = SyncCategory.allCases.filter { Set(shared.categories).union(categories).contains($0) }
            try manager.createDirectory(at: syncFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try shared.encoded(passphrase: passphrase).write(to: syncFile, options: .atomic)
        }
        result.imported.sort()
        result.exported.sort()
        return result
    }

    /// Écrit un fichier repris et lui donne la date de la copie partagée : les deux côtés sont alors à égalité.
    private func write(_ file: PrismArchive.File, to path: String) throws {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return }
        let url = dataDirectory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.modificationDate: file.modified], ofItemAtPath: url.path)
    }
}
