import AppKit

struct AppEntry: Sendable {
    let path: String
    let name: String
    let fileName: String
    let bundleID: String?
    /// App du système (sous /System, Safari compris) : jamais désinstallée.
    var isSystem = false
    /// Se déclare dans la catégorie des jeux (`LSApplicationCategoryType`).
    var declaresGame = false
}

/// Les applications installées, relues en arrière-plan au plus toutes les 30 secondes.
@MainActor
final class AppCatalog {
    static let shared = AppCatalog()

    private(set) var apps: [AppEntry] = []
    private var lastScan: Date?
    private var isScanning = false

    func reloadIfNeeded() {
        if let lastScan, Date().timeIntervalSince(lastScan) < 30 { return }
        reload()
    }

    func loadSynchronously() {
        apps = AppCatalog.scan()
        lastScan = Date()
    }

    func reload() {
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = AppCatalog.scan()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.apps = found
                    self.lastScan = Date()
                    self.isScanning = false
                    NotificationCenter.default.post(name: .appCatalogDidChange, object: nil)
                }
            }
        }
    }

    nonisolated static func scan() -> [AppEntry] {
        let fileManager = FileManager.default
        let roots = [
            "/Applications",
            "/System/Applications",
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
            "/System/Library/CoreServices/Applications",
        ] + ApplicationsPreferences.extraFolders
        var seen = Set<String>()
        var result: [AppEntry] = []

        func add(_ url: URL) {
            let bundleID = Bundle(url: url)?.bundleIdentifier
            let key = bundleID ?? url.path
            guard !seen.contains(key) else { return }
            seen.insert(key)
            var name = fileManager.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            result.append(AppEntry(
                path: url.path,
                name: name,
                fileName: url.deletingPathExtension().lastPathComponent,
                bundleID: bundleID,
                isSystem: url.path.hasPrefix("/System/") || url.resolvingSymlinksInPath().path.hasPrefix("/System/"),
                declaresGame: GameCatalog.declaresGameCategory(url)
            ))
        }

        // Parcours à la main : l'énumérateur de FileManager ignore les liens symboliques,
        // or Safari n'est plus qu'un lien vers un « cryptex » depuis macOS 13.
        func visit(_ directory: URL, depth: Int) {
            guard let children = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { return }
            // Pas `.skipsHiddenFiles` : le lien de Safari porte le drapeau « hidden ».
            for url in children where !url.lastPathComponent.hasPrefix(".") {
                if url.pathExtension == "app" {
                    add(url)
                } else if depth < 3, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    visit(url, depth: depth + 1)
                }
            }
        }
        for root in roots {
            visit(URL(fileURLWithPath: root), depth: 1)
        }
        add(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Le raccourci d'une app la masque-t-il quand elle est déjà au premier plan ? (Réglages › Applications.)
    static var hotkeyTogglesVisibility: Bool {
        ApplicationsPreferences.hotkeyAction != "show"
    }

    func items() -> [ResultItem] {
        let running = Dictionary(
            NSWorkspace.shared.runningApplications.compactMap { app in app.bundleURL.map { ($0.path, app) } },
            uniquingKeysWith: { first, _ in first }
        )
        let context = AppActions.Context.current()
        return apps.map { entry in
            var keywords: [String] = []
            if entry.fileName != entry.name { keywords.append(entry.fileName) }
            return ResultItem(
                id: "app:" + entry.path,
                title: entry.name,
                icon: .file(entry.path),
                accessory: running[entry.path] != nil ? "Ouverte" : "Application",
                keywords: keywords,
                actions: AppActions.actions(for: entry, running: running[entry.path], context: context),
                isConfigurable: true
            )
        }
    }
}
