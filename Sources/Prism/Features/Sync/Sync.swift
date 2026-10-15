import AppKit
import IOKit.ps
import Security
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Des fichiers de données ont été remplacés par un import ou une synchronisation (`object` : leurs chemins relatifs).
    /// Une fonctionnalité qui garde ses données en mémoire peut l'écouter pour relire son `JSONStore`.
    static let prismDataImported = Notification.Name("PrismDataImported")
}

// MARK: - Réglages

@MainActor
final class SyncSettings: ObservableObject {
    static let shared = SyncSettings()
    private let defaults = UserDefaults.standard

    enum BackupFrequency: String, CaseIterable {
        case off, daily, weekly, monthly

        var title: String {
            switch self {
            case .off: "Jamais"
            case .daily: "Chaque jour"
            case .weekly: "Chaque semaine"
            case .monthly: "Chaque mois"
            }
        }

        var interval: TimeInterval? {
            switch self {
            case .off: nil
            case .daily: 86_400
            case .weekly: 7 * 86_400
            case .monthly: 30 * 86_400
            }
        }
    }

    /// iCloud Drive/Prism si iCloud Drive est là, sinon Documents/Prism.
    static var defaultSyncFolder: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if FileManager.default.fileExists(atPath: iCloud.path) { return iCloud.appendingPathComponent("Prism").path }
        return home.appendingPathComponent("Documents/Prism").path
    }

    /// « iCloud Drive/Prism » plutôt que le chemin réel de iCloud Drive.
    static func displayName(_ path: String) -> String {
        let iCloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path
        if path == iCloud { return "iCloud Drive" }
        if path.hasPrefix(iCloud + "/") { return "iCloud Drive/" + path.dropFirst(iCloud.count + 1) }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    static var defaultBackupFolder: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Sauvegardes Prism").path
    }

    @Published var syncEnabled: Bool { didSet { defaults.set(syncEnabled, forKey: "sync.enabled"); SyncService.shared.settingsChanged() } }
    @Published var syncFolder: String { didSet { defaults.set(syncFolder, forKey: "sync.folder"); SyncService.shared.settingsChanged() } }
    @Published var syncCategories: Set<SyncCategory> {
        didSet { defaults.set(syncCategories.map(\.rawValue).sorted(), forKey: "sync.categories") }
    }
    /// Chiffre la copie partagée avec la phrase de passe (gardée dans le trousseau).
    @Published var encrypt: Bool { didSet { defaults.set(encrypt, forKey: "sync.encrypt") } }
    @Published var hasPassphrase: Bool { didSet { defaults.set(hasPassphrase, forKey: "sync.hasPassphrase") } }

    @Published var lastSync: Date? { didSet { defaults.set(lastSync, forKey: "sync.lastSync") } }
    @Published var lastSyncDevice: String? { didSet { defaults.set(lastSyncDevice, forKey: "sync.lastDevice") } }
    @Published var lastError: String? { didSet { defaults.set(lastError, forKey: "sync.lastError") } }
    @Published var isSyncing = false

    @Published var backupFrequency: BackupFrequency { didSet { defaults.set(backupFrequency.rawValue, forKey: "backup.frequency") } }
    @Published var backupFolder: String { didSet { defaults.set(backupFolder, forKey: "backup.folder") } }
    @Published var backupKeep: Int { didSet { defaults.set(backupKeep, forKey: "backup.keep") } }
    @Published var backupOnBattery: Bool { didSet { defaults.set(backupOnBattery, forKey: "backup.onBattery") } }
    @Published var backupEncrypt: Bool { didSet { defaults.set(backupEncrypt, forKey: "backup.encrypt") } }
    @Published var lastBackup: Date? { didSet { defaults.set(lastBackup, forKey: "backup.last") } }

    static let defaultSyncCategories: Set<SyncCategory> = Set(SyncCategory.allCases).subtracting([.clipboard])

    private init() {
        syncEnabled = defaults.bool(forKey: "sync.enabled")
        syncFolder = defaults.string(forKey: "sync.folder") ?? Self.defaultSyncFolder
        syncCategories = (defaults.stringArray(forKey: "sync.categories")).map { Set($0.compactMap(SyncCategory.init(rawValue:))) } ?? Self.defaultSyncCategories
        encrypt = defaults.bool(forKey: "sync.encrypt")
        hasPassphrase = defaults.bool(forKey: "sync.hasPassphrase")
        lastSync = defaults.object(forKey: "sync.lastSync") as? Date
        lastSyncDevice = defaults.string(forKey: "sync.lastDevice")
        lastError = defaults.string(forKey: "sync.lastError")
        backupFrequency = BackupFrequency(rawValue: defaults.string(forKey: "backup.frequency") ?? "") ?? .off
        backupFolder = defaults.string(forKey: "backup.folder") ?? Self.defaultBackupFolder
        let keep = defaults.integer(forKey: "backup.keep")
        backupKeep = keep > 0 ? keep : 10
        backupOnBattery = defaults.bool(forKey: "backup.onBattery")
        backupEncrypt = defaults.bool(forKey: "backup.encrypt")
        lastBackup = defaults.object(forKey: "backup.last") as? Date
    }

    var syncFile: URL { URL(fileURLWithPath: syncFolder, isDirectory: true).appendingPathComponent("Prism.\(PrismArchive.fileExtension)") }
}

/// La phrase de passe de la synchronisation, dans le trousseau de session.
enum SyncKeychain {
    private static let service = "Prism — synchronisation"
    private static let account = "passphrase"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ passphrase: String?) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard let passphrase, !passphrase.isEmpty else { return true }
        var attributes = query
        attributes[kSecValueData as String] = Data(passphrase.utf8)
        attributes[kSecAttrLabel as String] = service
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}

// MARK: - Données locales

@MainActor
enum PrismData {
    /// Le domaine des préférences de l'app.
    static var preferencesDomain: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }

    /// Les préférences exportables de l'app.
    static func preferences() -> [String: Any] {
        (UserDefaults.standard.persistentDomain(forName: preferencesDomain) ?? [:]).filter { PrismArchive.isPortablePreference($0.key) }
    }

    static func applyPreferences(_ values: [String: Any]) {
        for (key, value) in values where PrismArchive.isPortablePreference(key) {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    // Pas d'écriture forcée des magasins avant une copie : elle changerait la date des fichiers, et la synchronisation
    // croirait la copie locale plus récente. Les magasins écrivent d'eux-mêmes 0,2 s après chaque modification.

    /// Fichiers que Prism sait relire sans redémarrer.
    static let reloadableFiles: Set<String> = ["commands.json", "themes.json", "emoji.json", "scripts.json"]

    /// Relit les magasins connus et prévient les autres. Rend `true` s'il faut redémarrer pour tout prendre en compte.
    @discardableResult
    static func reload(after paths: [String], preferencesChanged: Bool) -> Bool {
        CommandConfigStore.shared.store.reload()
        CommandConfigStore.shared.objectWillChange.send()
        CommandConfigStore.shared.registerHotkeys()
        ThemeStore.shared.store.reload()
        ThemeStore.shared.objectWillChange.send()
        NotificationCenter.default.post(name: .prismThemeDidChange, object: nil)
        EmojiStore.shared.store.reload()
        EmojiStore.shared.objectWillChange.send()
        ScriptsStore.shared.store.reload()
        ScriptCatalog.shared.reload()
        NotificationCenter.default.post(name: .prismDataImported, object: paths)
        NotificationCenter.default.post(name: .prismDataDidChange, object: nil)
        return preferencesChanged || paths.contains { !reloadableFiles.contains($0) }
    }

    /// Relance Prism : la nouvelle instance attend que celle-ci ait quitté.
    static func restart() {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else {
            HUD.shared.show("Relancez Prism à la main", symbol: "exclamationmark.triangle.fill")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", path, "\(ProcessInfo.processInfo.processIdentifier)"]
        try? process.run()
        NSApp.terminate(nil)
    }

    static var restartAction: ItemAction {
        ItemAction(title: "Redémarrer Prism", symbol: "arrow.triangle.2.circlepath") {
            restart()
            return .close
        }
    }
}

// MARK: - Synchronisation

@MainActor
final class SyncService {
    static let shared = SyncService()

    private var pending: DispatchWorkItem?
    private var timer: Timer?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFolder: String?
    private var ignoreChangesUntil = Date.distantPast
    private var cachedPassphrase: String?
    private var started = false

    func start() {
        started = true
        NotificationCenter.default.addObserver(forName: .prismDataDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SyncService.shared.dataDidChange() }
        }
        let timer = Timer(timeInterval: 300, repeats: true) { _ in
            MainActor.assumeIsolated {
                SyncService.shared.syncNow(manual: false)
                BackupService.runIfDue()
            }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        settingsChanged()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            SyncService.shared.syncNow(manual: false)
            BackupService.runIfDue()
        }
    }

    func settingsChanged() {
        guard started else { return }
        watchFolder()
    }

    /// Une donnée a changé : synchronisation quelques secondes plus tard, en une fois.
    private func dataDidChange() {
        guard SyncSettings.shared.syncEnabled, Date() > ignoreChangesUntil else { return }
        pending?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { SyncService.shared.syncNow(manual: false) } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Le dossier partagé change (une autre machine a écrit) : on relit.
    private func watchFolder() {
        let settings = SyncSettings.shared
        let folder = settings.syncEnabled ? settings.syncFolder : nil
        guard folder != watchedFolder else { return }
        watcher?.cancel()
        watcher = nil
        watchedFolder = folder
        guard let folder else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let descriptor = open(folder, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .attrib], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { SyncService.shared.dataDidChange() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private var passphrase: String? {
        guard SyncSettings.shared.encrypt else { return nil }
        if cachedPassphrase == nil { cachedPassphrase = SyncKeychain.read() }
        return cachedPassphrase
    }

    func setPassphrase(_ value: String?) -> Bool {
        cachedPassphrase = value
        let saved = SyncKeychain.write(value)
        SyncSettings.shared.hasPassphrase = saved && !(value ?? "").isEmpty
        return saved
    }

    /// La phrase de passe en mémoire (sauvegardes chiffrées).
    var currentPassphrase: String? {
        if cachedPassphrase == nil, SyncSettings.shared.hasPassphrase { cachedPassphrase = SyncKeychain.read() }
        return cachedPassphrase
    }

    /// La date de dernière modification des préférences, suivie par un instantané (UserDefaults n'en a pas).
    private func preferencesModified() -> Date {
        let defaults = UserDefaults.standard
        let current = PrismData.preferences()
        let snapshot = defaults.data(forKey: "sync.preferencesSnapshot")
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        if !NSDictionary(dictionary: current).isEqual(to: snapshot) {
            defaults.set(try? PropertyListSerialization.data(fromPropertyList: current, format: .binary, options: 0), forKey: "sync.preferencesSnapshot")
            defaults.set(Date(), forKey: "sync.preferencesModified")
        }
        return defaults.object(forKey: "sync.preferencesModified") as? Date ?? .distantPast
    }

    func syncNow(manual: Bool) {
        let settings = SyncSettings.shared
        guard settings.syncEnabled else {
            if manual { AppContext.launcher?.model.showToast("Activez d’abord la synchronisation dans les réglages") }
            return
        }
        guard !settings.isSyncing else { return }
        if settings.encrypt, passphrase == nil {
            settings.lastError = "Phrase de passe manquante"
            if manual { HUD.shared.show("Synchronisation : phrase de passe manquante", symbol: "exclamationmark.triangle.fill") }
            return
        }
        // iCloud Drive peut n'avoir qu'un fichier fantôme : on demande le vrai.
        try? FileManager.default.startDownloadingUbiquitousItem(at: settings.syncFile)
        let engine = SyncEngine(
            dataDirectory: StoreLocation.directory, syncFile: settings.syncFile, categories: settings.syncCategories,
            passphrase: passphrase, preferences: PrismData.preferences(), preferencesModified: preferencesModified()
        )
        settings.isSyncing = true
        DispatchQueue.global(qos: .utility).async {
            let outcome = Swift.Result { try engine.run() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { SyncService.shared.finish(outcome, manual: manual) }
            }
        }
    }

    private func finish(_ outcome: Swift.Result<SyncEngine.Result, Error>, manual: Bool) {
        let settings = SyncSettings.shared
        settings.isSyncing = false
        switch outcome {
        case .failure(let error):
            settings.lastError = error.localizedDescription
            if manual { HUD.shared.show("Synchronisation impossible : \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill") }
        case .success(let result):
            settings.lastError = nil
            settings.lastSync = Date()
            settings.lastSyncDevice = result.remoteDevice
            var needsRestart = false
            if result.didChangeLocalData {
                ignoreChangesUntil = Date().addingTimeInterval(3)
                if let preferences = result.importedPreferences {
                    PrismData.applyPreferences(preferences)
                    // Les préférences reprises ne repartent pas comme une modification locale.
                    UserDefaults.standard.set(try? PropertyListSerialization.data(fromPropertyList: PrismData.preferences(), format: .binary, options: 0),
                                              forKey: "sync.preferencesSnapshot")
                }
                needsRestart = PrismData.reload(after: result.imported, preferencesChanged: result.importedPreferences != nil)
            }
            if manual {
                let summary = result.didChangeLocalData || !result.exported.isEmpty
                    ? "Synchronisé : \(result.imported.count + (result.importedPreferences == nil ? 0 : 1)) reçu(s), \(result.exported.count) envoyé(s)"
                    : "Déjà à jour"
                HUD.shared.show(needsRestart ? summary + " — redémarrez Prism" : summary, symbol: "arrow.triangle.2.circlepath")
            } else if needsRestart {
                HUD.shared.show("Données synchronisées — redémarrez Prism pour tout prendre en compte", symbol: "arrow.triangle.2.circlepath")
            }
        }
    }
}

// MARK: - Sauvegardes programmées

@MainActor
enum BackupService {
    /// Sur batterie ? (sauvegardes reportées si le réglage le demande)
    static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    static func runIfDue() {
        let settings = SyncSettings.shared
        guard let interval = settings.backupFrequency.interval else { return }
        if let last = settings.lastBackup, Date().timeIntervalSince(last) < interval { return }
        if isOnBattery, !settings.backupOnBattery { return }
        _ = backupNow()
    }

    /// Écrit une sauvegarde complète et ne garde que les plus récentes. Rend le fichier écrit.
    @discardableResult
    static func backupNow() -> Result<URL, Error> {
        let settings = SyncSettings.shared
        let archive = PrismArchive.collect(from: StoreLocation.directory, categories: Set(SyncCategory.allCases), preferences: PrismData.preferences())
        let result = Result {
            try write(archive, to: URL(fileURLWithPath: settings.backupFolder, isDirectory: true), keep: settings.backupKeep,
                      passphrase: settings.backupEncrypt ? SyncService.shared.currentPassphrase : nil)
        }
        if case .success = result { settings.lastBackup = Date() }
        return result
    }

    static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Prism \(formatter.string(from: date)).\(PrismArchive.fileExtension)"
    }

    static func write(_ archive: PrismArchive, to folder: URL, keep: Int, passphrase: String?, date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName(for: date))
        try archive.encoded(passphrase: passphrase).write(to: url, options: .atomic)
        prune(folder, keep: keep)
        return url
    }

    /// Supprime les sauvegardes de Prism les plus anciennes au-delà de `keep` (les autres fichiers ne sont pas touchés).
    static func prune(_ folder: URL, keep: Int) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let backups = names.filter { $0.hasPrefix("Prism ") && $0.hasSuffix("." + PrismArchive.fileExtension) }.sorted(by: >)
        for name in backups.dropFirst(max(keep, 1)) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}

// MARK: - Exporter et importer depuis le lanceur

@MainActor
enum ImportExport {
    static func exportForm() -> FormScreen {
        var fields = [FormField(id: "intro", label: "Contenu", kind: .info, value: "Les données choisies et les préférences, dans un fichier .prismconfig à importer sur un autre Mac.")]
        for category in SyncCategory.allCases {
            fields.append(FormField(id: "category." + category.rawValue, label: "", kind: .checkbox(label: category.title), value: category == .clipboard ? "false" : "true"))
        }
        fields += [
            FormField(id: "passphrase", label: "Phrase de passe", kind: .secure, placeholder: "8 caractères au moins",
                      info: "Chiffre le fichier (AES-GCM). Laissez vide pour un fichier en clair : il contient vos données telles quelles."),
            FormField(id: "confirmation", label: "Confirmation", kind: .secure, placeholder: "La même phrase de passe"),
        ]
        let form = FormScreen(id: "sync.export", title: "Exporter les réglages et données", icon: .symbol("square.and.arrow.up.fill", Palette.teal), submitTitle: "Exporter…", fields: fields) { state in
            let categories = Set(SyncCategory.allCases.filter { state.bool("category." + $0.rawValue) })
            guard !categories.isEmpty else {
                state.error = "Choisissez au moins une catégorie"
                return .stay
            }
            let passphrase = state["passphrase"]
            if !passphrase.isEmpty {
                guard passphrase.count >= 8 else {
                    state.error = ArchiveError.passphraseTooShort.errorDescription
                    return .stay
                }
                guard passphrase == state["confirmation"] else {
                    state.error = "Les deux phrases de passe diffèrent"
                    return .stay
                }
            }
            let archive = PrismArchive.collect(from: StoreLocation.directory, categories: categories, preferences: PrismData.preferences())
            DispatchQueue.main.async { save(archive, passphrase: passphrase.isEmpty ? nil : passphrase) }
            return .close
        }
        form.initialFocus = "passphrase"
        return form
    }

    private static func save(_ archive: PrismArchive, passphrase: String?) {
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "Prism \(formatter.string(from: Date())).\(PrismArchive.fileExtension)"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.title = "Exporter les réglages et données"
        panel.prompt = "Exporter"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try archive.encoded(passphrase: passphrase).write(to: url, options: .atomic)
            HUD.shared.show("Exporté : \(archive.files.count) fichier(s)" + (passphrase == nil ? "" : ", chiffré"))
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            HUD.shared.show("Exportation impossible : \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
        }
    }

    /// Choisit un fichier puis ouvre le formulaire d'import dans le lanceur.
    static func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Importer les réglages et données"
        panel.prompt = "Importer"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let type = UTType(filenameExtension: PrismArchive.fileExtension) { panel.allowedContentTypes = [type, .json] }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    static func open(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            HUD.shared.show("Lecture impossible", symbol: "exclamationmark.triangle.fill")
            return
        }
        if PrismArchive.isEncrypted(data) {
            CommandRunner.present(.push(unlockForm(data: data, name: url.lastPathComponent)))
            return
        }
        do {
            CommandRunner.present(.push(importForm(try PrismArchive.decode(data, passphrase: nil), name: url.lastPathComponent)))
        } catch {
            HUD.shared.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
        }
    }

    static func unlockForm(data: Data, name: String) -> FormScreen {
        FormScreen(id: "sync.unlock", title: "Importer « \(name) »", icon: .symbol("lock.fill", Palette.teal), submitTitle: "Déverrouiller", fields: [
            FormField(id: "passphrase", label: "Phrase de passe", kind: .secure, placeholder: "Celle choisie à l’exportation", info: "Ce fichier est chiffré."),
        ]) { state in
            do {
                return .replace(importForm(try PrismArchive.decode(data, passphrase: state["passphrase"]), name: name))
            } catch {
                state.error = error.localizedDescription
                return .stay
            }
        }
    }

    static func importForm(_ archive: PrismArchive, name: String) -> FormScreen {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        let present = SyncCategory.allCases.filter { category in
            category == .preferences ? archive.preferences != nil : archive.files.keys.contains { SyncCategory.category(forFile: $0) == category }
        }
        var fields = [FormField(id: "intro", label: "Fichier", kind: .info, value: "\(name)\nExporté de « \(archive.device) » le \(formatter.string(from: archive.created)).")]
        for category in present {
            let count = archive.files.keys.filter { SyncCategory.category(forFile: $0) == category }.count
            let detail = category == .preferences ? "\(archive.preferencesDictionary.count) réglages" : "\(count) fichier\(count > 1 ? "s" : "")"
            fields.append(FormField(id: "category." + category.rawValue, label: "", kind: .checkbox(label: "\(category.title) (\(detail))"), value: "true"))
        }
        fields.append(FormField(id: "mode", label: "Import", kind: .dropdown(PrismArchive.ImportMode.allCases.map { ($0.rawValue, $0.title) }), value: PrismArchive.ImportMode.merge.rawValue,
                                info: "Fusionner ajoute ce qui manque (snippets, notes, liens… par identifiant) et remplace le reste."))
        return FormScreen(id: "sync.import", title: "Importer les réglages et données", icon: .symbol("square.and.arrow.down.fill", Palette.teal), submitTitle: "Importer", fields: fields) { state in
            let categories = Set(present.filter { state.bool("category." + $0.rawValue) })
            guard !categories.isEmpty else {
                state.error = "Choisissez au moins une catégorie"
                return .stay
            }
            let mode = PrismArchive.ImportMode(rawValue: state["mode"]) ?? .merge
            do {
                let report = try archive.apply(to: StoreLocation.directory, categories: categories, mode: mode)
                if categories.contains(.preferences) { PrismData.applyPreferences(archive.preferencesDictionary) }
                let restart = PrismData.reload(after: report.changedFiles, preferencesChanged: report.preferenceCount > 0)
                return .replace(resultScreen(report, needsRestart: restart))
            } catch {
                state.error = "Import impossible : \(error.localizedDescription)"
                return .stay
            }
        }
    }

    static func resultScreen(_ report: PrismArchive.ImportReport, needsRestart: Bool) -> LauncherScreen {
        ListScreen(id: "sync.import-result", title: "Import terminé", icon: .symbol("checkmark.circle.fill", Palette.green)) { _ in
            var items: [ResultItem] = []
            let done = ItemAction(title: "Terminé", symbol: "checkmark") { .popToRoot }
            let actions = needsRestart ? [PrismData.restartAction, done] : [done, PrismData.restartAction]
            if needsRestart {
                items.append(ResultItem(id: "restart", title: "Redémarrer Prism pour tout prendre en compte", subtitle: "Recommandé",
                                        icon: .symbol("arrow.triangle.2.circlepath", Palette.orange), usageKey: "", actions: actions))
            }
            func row(_ id: String, _ title: String, _ paths: [String], _ symbol: String, _ color: Color) {
                guard !paths.isEmpty else { return }
                items.append(ResultItem(id: id, title: title, subtitle: paths.joined(separator: ", "), icon: .symbol(symbol, color),
                                        accessory: "\(paths.count)", usageKey: "", actions: actions))
            }
            row("written", "Ajoutés ou remplacés", report.written, "doc.badge.plus", Palette.blue)
            row("merged", "Fusionnés", report.merged, "arrow.triangle.merge", Palette.teal)
            row("unchanged", "Déjà à jour", report.unchanged, "equal.circle", Palette.gray)
            if report.preferenceCount > 0 {
                items.append(ResultItem(id: "preferences", title: "Préférences reprises", icon: .symbol("gearshape.fill", Palette.gray),
                                        accessory: "\(report.preferenceCount)", usageKey: "", actions: actions))
            }
            return [ResultSection(id: "result", title: nil, items: items)]
        }
    }
}

// MARK: - Fonctionnalité

@MainActor
enum SyncFeature: PrismFeature {
    static func start() {
        SyncService.shared.start()
    }

    static var commands: [ResultItem] {
        [
            Command.make("sync.export", "Exporter les réglages et données", subtitle: "Synchronisation", symbol: "square.and.arrow.up.fill", color: Palette.teal,
                         keywords: ["export settings", "sauvegarde", "migrer"], actions: [ItemAction(title: "Exporter…", symbol: "square.and.arrow.up") { .push(ImportExport.exportForm()) }]),
            Command.run("sync.import", "Importer les réglages et données", subtitle: "Synchronisation", symbol: "square.and.arrow.down.fill", color: Palette.teal,
                        keywords: ["import settings", "restaurer", "migrer"]) {
                DispatchQueue.main.async { ImportExport.chooseFile() }
                return .close
            },
            Command.run("sync.now", "Synchroniser maintenant", subtitle: "Synchronisation", symbol: "arrow.triangle.2.circlepath", color: Palette.teal,
                        keywords: ["cloud sync", "icloud", "synchronisation"]) {
                SyncService.shared.syncNow(manual: true)
                return SyncSettings.shared.syncEnabled ? .close : .stay
            },
            Command.run("sync.backup", "Sauvegarder maintenant", subtitle: "Synchronisation", symbol: "externaldrive.fill.badge.timemachine", color: Palette.teal,
                        keywords: ["backup", "sauvegarde"]) {
                switch BackupService.backupNow() {
                case .success(let url): return .hud("Sauvegardé : \(url.lastPathComponent)")
                case .failure(let error): return .toast("Sauvegarde impossible : \(error.localizedDescription)")
                }
            },
            Command.run("restart", "Redémarrer Prism", subtitle: "Prism", symbol: "arrow.clockwise", color: Palette.gray, keywords: ["restart", "relancer"]) {
                PrismData.restart()
                return .close
            },
        ]
    }

    static var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "sync", title: "Synchronisation", symbol: "arrow.triangle.2.circlepath", color: Palette.teal, order: 90) { AnyView(SyncSettingsView()) }]
    }

    /// `prism://sync/now`, `prism://sync/export`, `prism://sync/import`, `prism://sync/backup`.
    static func handle(url: URL) -> Bool {
        guard url.host == "sync" else { return false }
        switch url.path {
        case "/now": SyncService.shared.syncNow(manual: true)
        case "/export": CommandRunner.present(.push(ImportExport.exportForm()))
        case "/import": ImportExport.chooseFile()
        case "/backup": _ = BackupService.backupNow()
        default: NotificationCenter.default.post(name: .prismOpenSettings, object: "sync")
        }
        return true
    }

    static func selfTest(_ check: (Bool, String) -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prism-sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("A", isDirectory: true)
        let target = root.appendingPathComponent("B", isDirectory: true)
        func write(_ text: String, _ path: String, in folder: URL, modified: Date? = nil) {
            let url = folder.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
            if let modified { try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        }
        func json(_ path: String, in folder: URL) -> Any? {
            (try? Data(contentsOf: folder.appendingPathComponent(path))).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        }
        write(#"{"commands":{"command:a":{"alias":"a"}},"favorites":["app:Safari"],"fallbackOrder":["x"]}"#, "commands.json", in: source)
        write(#"[{"id":"1","text":"un"}]"#, "notes.json", in: source)
        write(#"[{"id":"c1","text":"secret"}]"#, "clipboard.json", in: source)
        write(#"{"pinned":["😀"]}"#, "emoji.json", in: source)
        write(#"{"ignoré":true}"#, "Backups/vieux.json", in: source)

        check(SyncCategory.category(forFile: "snippets.json") == .snippets && SyncCategory.category(forFile: "notes/abc.json") == .notes
              && SyncCategory.category(forFile: "ai-chats.json") == .ai && SyncCategory.category(forFile: "emoji.json") == .other, "catégories des fichiers")
        let preferences: [String: Any] = ["emoji.columns": 9, "hyper.key": "capsLock", "sync.enabled": true, "NSWindow Frame Réglages": "0 0 10 10", "hasLaunchedBefore": true]
        let archive = PrismArchive.collect(from: source, categories: [.commands, .notes, .other, .preferences], preferences: preferences, device: "Essai")
        check(Set(archive.files.keys) == ["commands.json", "notes.json", "emoji.json"], "export : catégories choisies seulement, sauvegardes exclues")
        check(Set(archive.preferencesDictionary.keys) == ["emoji.columns", "hyper.key"], "export : préférences propres à la machine exclues")

        check((try? archive.encoded(passphrase: "court")) == nil, "phrase de passe de moins de 8 caractères refusée")
        guard let encrypted = try? archive.encoded(passphrase: "phrase de passe sûre") else {
            check(false, "chiffrement")
            return
        }
        check(PrismArchive.isEncrypted(encrypted) && !String(decoding: encrypted, as: UTF8.self).contains("secret") && !String(decoding: encrypted, as: UTF8.self).contains("alias"), "fichier chiffré illisible en clair")
        var refusal: ArchiveError?
        do { _ = try PrismArchive.decode(encrypted, passphrase: "mauvaise phrase") } catch { refusal = error as? ArchiveError }
        check(refusal == .wrongPassphrase, "mauvaise phrase de passe refusée")
        do { _ = try PrismArchive.decode(encrypted, passphrase: nil) } catch { refusal = error as? ArchiveError }
        check(refusal == .passphraseRequired, "phrase de passe demandée")
        let decoded = try? PrismArchive.decode(encrypted, passphrase: "phrase de passe sûre")
        check(decoded == archive && decoded?.device == "Essai", "aller-retour chiffré")
        let plain = try? archive.encoded(passphrase: nil)
        check(plain.flatMap { try? PrismArchive.decode($0, passphrase: nil) } == archive, "aller-retour en clair")
        check((try? PrismArchive.decode(Data("{}".utf8), passphrase: nil)) == nil, "fichier étranger refusé")

        write(#"{"commands":{"command:b":{"alias":"b"}},"favorites":["app:Mail"],"fallbackOrder":["y"]}"#, "commands.json", in: target)
        write(#"[{"id":"2","text":"deux"},{"id":"1","text":"un, version locale"}]"#, "notes.json", in: target)
        if let decoded, let report = try? decoded.apply(to: target, categories: [.commands, .notes], mode: .merge) {
            let notes = json("notes.json", in: target) as? [[String: String]]
            check(notes?.map { $0["id"] ?? "" } == ["2", "1"] && notes?.last?["text"] == "un, version locale", "import : notes fusionnées par identifiant, version locale gardée")
            let commands = json("commands.json", in: target) as? [String: Any]
            check((commands?["commands"] as? [String: Any]).map { Set($0.keys) } == ["command:a", "command:b"]
                  && commands?["favorites"] as? [String] == ["app:Mail", "app:Safari"], "import : alias et favoris fusionnés")
            check(commands?["fallbackOrder"] as? [String] == ["y", "x"], "import : listes de chaînes réunies")
            check(report.merged.sorted() == ["commands.json", "notes.json"] && !FileManager.default.fileExists(atPath: target.appendingPathComponent("emoji.json").path),
                  "import : catégories non cochées ignorées")
            _ = try? decoded.apply(to: target, categories: [.notes], mode: .replace)
            check((json("notes.json", in: target) as? [Any])?.count == 1, "import : remplacement")
        } else {
            check(false, "import")
        }

        // Synchronisation entre deux « Mac » par un dossier partagé.
        let macA = root.appendingPathComponent("MacA", isDirectory: true)
        let macB = root.appendingPathComponent("MacB", isDirectory: true)
        let shared = root.appendingPathComponent("Partagé/Prism.prismconfig")
        let past = Date().addingTimeInterval(-3_600)
        write(#"[{"id":"1"}]"#, "snippets.json", in: macA, modified: past)
        write(#"{"custom":[]}"#, "themes.json", in: macB, modified: past)
        func engine(_ folder: URL, passphrase: String? = "phrase de passe sûre", preferences: [String: Any] = [:], modified: Date? = nil) -> SyncEngine {
            SyncEngine(dataDirectory: folder, syncFile: shared, categories: SyncSettings.defaultSyncCategories, passphrase: passphrase,
                       preferences: preferences, preferencesModified: modified, device: folder.lastPathComponent)
        }
        let first = try? engine(macA, preferences: ["emoji.columns": 7], modified: past).run()
        check(first?.exported.contains("snippets.json") == true && FileManager.default.fileExists(atPath: shared.path), "synchro : la première machine envoie ses fichiers")
        let second = try? engine(macB).run()
        check(second?.imported == ["snippets.json"] && second?.exported.contains("themes.json") == true
              && second?.importedPreferences?["emoji.columns"] as? Int == 7, "synchro : la seconde reçoit et envoie")
        write(#"[{"id":"1"},{"id":"2"}]"#, "snippets.json", in: macB, modified: Date().addingTimeInterval(10))
        _ = try? engine(macB).run()
        let third = try? engine(macA, preferences: ["emoji.columns": 7], modified: past).run()
        check(third?.imported.sorted() == ["snippets.json", "themes.json"] && (json("snippets.json", in: macA) as? [Any])?.count == 2,
              "synchro : le fichier le plus récent l'emporte")
        let idle = try? engine(macA, preferences: ["emoji.columns": 7], modified: past).run()
        check(idle?.imported.isEmpty == true && idle?.exported.isEmpty == true, "synchro : rien à faire quand tout est à jour")
        var syncRefusal: ArchiveError?
        do { _ = try engine(macB, passphrase: "pas la bonne phrase").run() } catch { syncRefusal = error as? ArchiveError }
        check(syncRefusal == .wrongPassphrase, "synchro : mauvaise phrase de passe refusée")

        let exportForm = ImportExport.exportForm()
        check(exportForm.fields.filter { if case .checkbox = $0.kind { return true } else { return false } }.count == SyncCategory.allCases.count
              && exportForm.state["category.clipboard"] == "false", "formulaire d'exportation : une case par catégorie, presse-papiers décoché")
        if let decoded {
            let importForm = ImportExport.importForm(decoded, name: "essai.prismconfig")
            check(importForm.fields.contains { $0.id == "category.notes" } && !importForm.fields.contains { $0.id == "category.clipboard" },
                  "formulaire d'import : seulement les catégories présentes")
        }

        let backups = root.appendingPathComponent("Sauvegardes", isDirectory: true)
        for day in 0..<4 {
            _ = try? BackupService.write(archive, to: backups, keep: 2, passphrase: nil, date: Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400))
        }
        write("à garder", "notes perso.txt", in: backups)
        let remaining = ((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []).sorted()
        check(remaining.count == 3 && remaining.contains("notes perso.txt") && remaining.first?.hasPrefix("Prism 2027-01-") == true, "sauvegardes : seules les plus récentes restent")
    }
}

// MARK: - Réglages

struct SyncSettingsView: View {
    @ObservedObject private var settings = SyncSettings.shared
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    Button("Exporter…") { CommandRunner.present(.push(ImportExport.exportForm())) }
                    Button("Importer…") { ImportExport.chooseFile() }
                }
            } header: {
                Text("Exporter et importer")
            } footer: {
                Text("Un fichier .prismconfig, chiffré si vous donnez une phrase de passe, pour passer vos commandes, alias, snippets, notes, thèmes et préférences d’un Mac à l’autre.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Synchroniser par un dossier partagé", isOn: $settings.syncEnabled)
                LabeledContent("Dossier") {
                    HStack {
                        Text(SyncSettings.displayName(settings.syncFolder))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choisir…") { if let folder = chooseFolder() { settings.syncFolder = folder } }
                    }
                }
                DisclosureGroup("Données synchronisées") {
                    ForEach(SyncCategory.allCases, id: \.self) { category in
                        Toggle(category.title, isOn: Binding(
                            get: { settings.syncCategories.contains(category) },
                            set: { enabled in
                                if enabled { settings.syncCategories.insert(category) } else { settings.syncCategories.remove(category) }
                            }
                        ))
                    }
                }
                Toggle("Chiffrer la copie partagée", isOn: $settings.encrypt)
                if settings.encrypt {
                    HStack {
                        SecureField("", text: $passphrase, prompt: Text(settings.hasPassphrase ? "Nouvelle phrase de passe" : "Phrase de passe"))
                            .labelsHidden()
                        SecureField("", text: $confirmation, prompt: Text("Confirmation"))
                            .labelsHidden()
                        Button("Enregistrer", action: savePassphrase)
                            .disabled(passphrase.isEmpty)
                    }
                    .textFieldStyle(.roundedBorder)
                }
                if let message {
                    Text(message).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                LabeledContent("État") {
                    HStack {
                        status
                        Button("Synchroniser maintenant") { SyncService.shared.syncNow(manual: true) }
                            .disabled(!settings.syncEnabled || settings.isSyncing)
                    }
                }
            } header: {
                Text("Synchronisation")
            } footer: {
                Text("Chaque modification est copiée dans « Prism.prismconfig » de ce dossier (iCloud Drive par défaut) ; ce que les autres Mac y écrivent est repris, fichier par fichier, au plus récent. Rien n’est supprimé. La phrase de passe reste dans le trousseau.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Sauvegarde automatique", selection: $settings.backupFrequency) {
                    ForEach(SyncSettings.BackupFrequency.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent("Dossier") {
                    HStack {
                        Text(SyncSettings.displayName(settings.backupFolder))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choisir…") { if let folder = chooseFolder() { settings.backupFolder = folder } }
                        Button("Ouvrir") {
                            try? FileManager.default.createDirectory(atPath: settings.backupFolder, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(URL(fileURLWithPath: settings.backupFolder, isDirectory: true))
                        }
                    }
                }
                Stepper("Garder les \(settings.backupKeep) dernières", value: $settings.backupKeep, in: 1...100)
                Toggle("Sauvegarder aussi sur batterie", isOn: $settings.backupOnBattery)
                Toggle("Chiffrer avec la phrase de passe de la synchronisation", isOn: $settings.backupEncrypt)
                    .disabled(!settings.hasPassphrase)
                LabeledContent("Dernière sauvegarde") {
                    HStack {
                        Text(settings.lastBackup.map(relative) ?? "Aucune").foregroundStyle(.secondary)
                        Button("Sauvegarder maintenant") {
                            switch BackupService.backupNow() {
                            case .success(let url): message = "Sauvegardé : \(url.lastPathComponent)"
                            case .failure(let error): message = "Sauvegarde impossible : \(error.localizedDescription)"
                            }
                        }
                    }
                }
            } header: {
                Text("Sauvegardes")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var status: some View {
        if !settings.syncEnabled {
            Text("Désactivée").foregroundStyle(.secondary)
        } else if settings.isSyncing {
            ProgressView().controlSize(.small)
        } else if let error = settings.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.orange).lineLimit(2)
        } else if let date = settings.lastSync {
            Label("Synchronisé \(relative(date))" + (settings.lastSyncDevice.map { " (dernier envoi : \($0))" } ?? ""), systemImage: "checkmark.circle.fill")
                .foregroundStyle(Palette.green)
                .lineLimit(1)
        } else {
            Text("Jamais synchronisé").foregroundStyle(.secondary)
        }
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func savePassphrase() {
        guard passphrase.count >= 8 else {
            message = ArchiveError.passphraseTooShort.errorDescription
            return
        }
        guard passphrase == confirmation else {
            message = "Les deux phrases de passe diffèrent"
            return
        }
        message = SyncService.shared.setPassphrase(passphrase) ? "Phrase de passe enregistrée dans le trousseau. Utilisez la même sur vos autres Mac." : "Le trousseau a refusé la phrase de passe."
        passphrase = ""
        confirmation = ""
    }

    private func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choisir"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
