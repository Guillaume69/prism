import AppKit
import SwiftUI

/// Mode jeu : les raccourcis de Prism se taisent pendant qu'un jeu est au premier plan.
@MainActor
enum GameMode {
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "gameMode") }
        set { UserDefaults.standard.set(newValue, forKey: "gameMode") }
    }

    static var isSuspended: Bool {
        guard isEnabled, let app = NSWorkspace.shared.frontmostApplication, let url = app.bundleURL else { return false }
        return GameCatalog.isGame(url)
    }
}

/// Ce qui est un jeu : les apps de la catégorie des jeux, et celles que l'utilisateur a marquées.
enum GameCatalog {
    /// Une app est un jeu si elle se déclare dans la catégorie des jeux, ou si l'utilisateur l'a marquée.
    static func isGame(_ url: URL) -> Bool {
        if markedApps.contains(key(bundleID: Bundle(url: url)?.bundleIdentifier, path: url.path)) { return true }
        return declaresGameCategory(url)
    }

    static func declaresGameCategory(_ url: URL) -> Bool {
        guard let category = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String else { return false }
        return category.hasPrefix("public.app-category.") && category.contains("games")
    }

    // MARK: - Apps marquées

    /// L'identifiant de paquet, sinon le chemin.
    static func key(bundleID: String?, path: String) -> String { bundleID ?? path }

    static var markedApps: [String] {
        UserDefaults.standard.stringArray(forKey: "games.markedApps") ?? []
    }

    static func setMarked(_ marked: Bool, key: String) {
        var apps = markedApps.filter { $0 != key }
        if marked { apps.append(key) }
        UserDefaults.standard.set(apps, forKey: "games.markedApps")
        NotificationCenter.default.post(name: .prismDataDidChange, object: nil)
    }
}

// MARK: - Steam

/// Un jeu installé par Steam.
struct SteamGame: Equatable {
    let appID: String
    let name: String
    let installDir: String
    /// Le dossier `steamapps` de la bibliothèque qui le contient.
    var library: String = ""

    var runURL: URL? { URL(string: "steam://run/\(appID)") }
}

/// Les jeux Steam installés, lus dans les manifestes `appmanifest_<id>.acf` de chaque bibliothèque.
enum SteamLibrary {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
    }

    /// Outils de Steam qui ne sont pas des jeux (redistribuables, environnements d'exécution).
    static let excludedAppIDs: Set<String> = ["228980", "1070560", "1391110", "1628350", "1493710"]

    /// Les paires « clé » « valeur » du format VDF de Steam, ligne à ligne.
    static func keyValues(_ text: String) -> [(String, String)] {
        var pairs: [(String, String)] = []
        for line in text.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "\"")
            // `"clé"\t\t"valeur"` se découpe en ["", clé, "\t\t", valeur, ""].
            if parts.count >= 5 { pairs.append((parts[1], parts[3])) }
        }
        return pairs
    }

    /// Un manifeste : la première occurrence de chaque clé (celles des blocs imbriqués viennent après).
    static func parseManifest(_ text: String) -> SteamGame? {
        var values: [String: String] = [:]
        for (key, value) in keyValues(text) where values[key.lowercased()] == nil {
            values[key.lowercased()] = value
        }
        guard let appID = values["appid"], let name = values["name"], !name.isEmpty else { return nil }
        return SteamGame(appID: appID, name: name, installDir: values["installdir"] ?? name)
    }

    /// Les bibliothèques déclarées dans `libraryfolders.vdf` (« path »).
    static func libraryPaths(fromFolders text: String) -> [String] {
        keyValues(text).filter { $0.0.lowercased() == "path" }.map(\.1)
    }

    /// Tous les jeux installés, triés par nom.
    static func installedGames(root: URL = SteamLibrary.root) -> [SteamGame] {
        let fileManager = FileManager.default
        var libraries = [root.appendingPathComponent("steamapps", isDirectory: true)]
        if let text = try? String(contentsOf: root.appendingPathComponent("steamapps/libraryfolders.vdf"), encoding: .utf8) {
            for path in libraryPaths(fromFolders: text) {
                let url = URL(fileURLWithPath: path).appendingPathComponent("steamapps", isDirectory: true)
                if !libraries.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) { libraries.append(url) }
            }
        }
        var games: [SteamGame] = []
        var seen = Set<String>()
        for library in libraries {
            guard let files = try? fileManager.contentsOfDirectory(atPath: library.path) else { continue }
            for file in files where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                guard let text = try? String(contentsOf: library.appendingPathComponent(file), encoding: .utf8),
                      var game = parseManifest(text),
                      !excludedAppIDs.contains(game.appID), !seen.contains(game.appID) else { continue }
                game.library = library.path
                seen.insert(game.appID)
                games.append(game)
            }
        }
        return games.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// L'icône du jeu dans le cache de Steam (ancien et nouveau rangement), sinon `nil`.
    static func iconPath(for appID: String, root: URL = SteamLibrary.root) -> String? {
        let cache = root.appendingPathComponent("appcache/librarycache", isDirectory: true)
        let fileManager = FileManager.default
        let flat = cache.appendingPathComponent("\(appID)_icon.jpg").path
        if fileManager.fileExists(atPath: flat) { return flat }
        let folder = cache.appendingPathComponent(appID, isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return nil }
        // L'icône porte un nom de 40 caractères hexadécimaux ; sinon le logo ou la jaquette.
        if let icon = files.first(where: { $0.hasSuffix(".jpg") && $0.count == 44 && $0.dropLast(4).allSatisfy(\.isHexDigit) }) {
            return folder.appendingPathComponent(icon).path
        }
        for name in ["logo.png", "library_600x900.jpg", "header.jpg"] where files.contains(name) {
            return folder.appendingPathComponent(name).path
        }
        return nil
    }
}

/// Les jeux Steam gardés en mémoire une minute : la recherche principale les lit à chaque frappe.
@MainActor
enum SteamCache {
    private static var games: [SteamGame] = []
    private static var icons: [String: NSImage] = [:]
    private static var loadedAt: Date?
    private static var isLoading = false

    static var current: [SteamGame] {
        if loadedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true { refresh() }
        return games
    }

    private static func refresh() {
        guard !isLoading else { return }
        isLoading = true
        DispatchQueue.global(qos: .utility).async {
            let found = SteamLibrary.installedGames()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let changed = found != games
                    games = found
                    loadedAt = Date()
                    isLoading = false
                    if changed { NotificationCenter.default.post(name: .prismDataDidChange, object: nil) }
                }
            }
        }
    }

    static func icon(for game: SteamGame) -> ItemIcon {
        if let image = icons[game.appID] { return .image(image) }
        if let path = SteamLibrary.iconPath(for: game.appID), let image = NSImage(contentsOfFile: path) {
            icons[game.appID] = image
            return .image(image)
        }
        return .symbol("gamecontroller.fill", Palette.indigo)
    }
}

// MARK: - Fonctionnalité

/// Le lanceur de jeux : apps de la catégorie des jeux, apps marquées et jeux Steam.
/// Les jeux Steam passent aussi par la recherche principale, comme des applications.
@MainActor
enum GamesFeature: PrismFeature {
    static var commands: [ResultItem] {
        [Command.screen("games", "Lanceur de jeux", subtitle: "Jeux", symbol: "gamecontroller.fill", color: Palette.indigo, keywords: ["game launcher", "jeux", "steam", "games", "jouer"]) {
            gamesScreen()
        }] + SteamCache.current.map(steamItem)
    }

    /// Un jeu Steam, rangé avec les applications (« app: ») pour être classé, mis en favori et doté d'un raccourci.
    static func steamItem(_ game: SteamGame) -> ResultItem {
        var actions: [ItemAction] = [
            ItemAction(title: "Lancer le jeu", symbol: "play.fill") {
                if let url = game.runURL { NSWorkspace.shared.open(url) }
                return .hud("Lancement de \(game.name)…")
            },
            ItemAction(title: "Afficher dans Steam", symbol: "list.bullet.rectangle") {
                if let url = URL(string: "steam://nav/games/details/\(game.appID)") { NSWorkspace.shared.open(url) }
                return .close
            },
        ]
        let folder = URL(fileURLWithPath: game.library).appendingPathComponent("common/\(game.installDir)").path
        if FileManager.default.fileExists(atPath: folder) {
            actions.append(ItemAction(title: "Ouvrir le dossier du jeu", symbol: "folder", shortcut: KeyShortcut(keyCode: 15, modifiers: [.command, .shift], label: "R")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: folder))
                return .close
            })
        }
        if let store = URL(string: "https://store.steampowered.com/app/\(game.appID)") {
            actions.append(Actions.openURL(store, title: "Ouvrir la page du magasin"))
        }
        actions.append(Actions.copy("steam://run/\(game.appID)", title: "Copier le lien de lancement", shortcut: .copyText, hud: "Lien copié"))
        return ResultItem(
            id: "app:steam:\(game.appID)",
            title: game.name,
            subtitle: "Steam",
            icon: SteamCache.icon(for: game),
            accessory: "Jeu",
            keywords: ["steam"],
            actions: actions,
            isConfigurable: true
        )
    }

    static func gamesScreen() -> ListScreen {
        ListScreen(
            id: "games",
            title: "Lanceur de jeux",
            placeholder: "Rechercher un jeu…",
            icon: .symbol("gamecontroller.fill", Palette.indigo),
            empty: { query in
                query.isEmpty
                    ? ("gamecontroller", "Aucun jeu : marquez une app avec « Traiter comme un jeu » (⌘K)")
                    : ("magnifyingglass", "Aucun jeu pour « \(query) »")
            }
        ) { query in
            let normalized = query.normalizedForSearch
            func matches(_ title: String) -> Bool { normalized.isEmpty || Fuzzy.score(normalized, title) != nil }
            let marked = Set(GameCatalog.markedApps)
            let gameIDs = Set(AppCatalog.shared.apps
                .filter { $0.declaresGame || marked.contains(GameCatalog.key(bundleID: $0.bundleID, path: $0.path)) }
                .map { "app:" + $0.path })
            let appItems = AppCatalog.shared.items().filter { gameIDs.contains($0.id) && matches($0.title) }
            let steam = SteamCache.current.filter { matches($0.name) }.map(steamItem)
            return [
                ResultSection(id: "apps", title: "Applications", items: appItems),
                ResultSection(id: "steam", title: "Steam", items: steam),
            ].filter { !$0.items.isEmpty }
        }
    }

    static func selfTest(_ check: (Bool, String) -> Void) {
        let manifest = """
        "AppState"
        {
        \t"appid"\t\t"620"
        \t"universe"\t\t"1"
        \t"name"\t\t"Portal 2"
        \t"StateFlags"\t\t"4"
        \t"installdir"\t\t"Portal 2"
        \t"UserConfig"
        \t{
        \t\t"name"\t\t"autre"
        \t}
        }
        """
        let game = SteamLibrary.parseManifest(manifest)
        check(game?.appID == "620" && game?.name == "Portal 2" && game?.installDir == "Portal 2", "Steam : manifeste lu (appid, nom, dossier)")
        check(game?.runURL?.absoluteString == "steam://run/620", "Steam : lien de lancement")
        check(SteamLibrary.parseManifest("\"AppState\"\n{\n}") == nil, "Steam : manifeste incomplet ignoré")
        let folders = "\"libraryfolders\"\n{\n\t\"0\"\n\t{\n\t\t\"path\"\t\t\"/Volumes/Jeux/SteamLibrary\"\n\t}\n}"
        check(SteamLibrary.libraryPaths(fromFolders: folders) == ["/Volumes/Jeux/SteamLibrary"], "Steam : bibliothèques supplémentaires")

        // Une bibliothèque factice : un jeu et un redistribuable à écarter.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prism-steam-\(UUID().uuidString)", isDirectory: true)
        let apps = root.appendingPathComponent("steamapps", isDirectory: true)
        try? FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try? manifest.write(to: apps.appendingPathComponent("appmanifest_620.acf"), atomically: true, encoding: .utf8)
        try? "\"AppState\"\n{\n\t\"appid\"\t\t\"228980\"\n\t\"name\"\t\t\"Steamworks Common Redistributables\"\n}"
            .write(to: apps.appendingPathComponent("appmanifest_228980.acf"), atomically: true, encoding: .utf8)
        check(SteamLibrary.installedGames(root: root).map(\.name) == ["Portal 2"], "Steam : jeux installés, sans les redistribuables")
        try? FileManager.default.removeItem(at: root)

        check(GameCatalog.key(bundleID: "com.example.jeu", path: "/Applications/Jeu.app") == "com.example.jeu", "jeux marqués : clé par identifiant de paquet")
    }
}
