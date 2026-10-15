import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Réglages généraux du lanceur. Chaque fonctionnalité garde les siens dans son propre fichier.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    static let defaultLauncherHotkey = Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))

    /// Le raccourci qui ouvre Prism (⌥ Espace par défaut).
    @Published var launcherHotkey: Hotkey {
        didSet {
            defaults.set(HotkeyCoding.encode(launcherHotkey), forKey: "launcherHotkey")
            NotificationCenter.default.post(name: .prismHotKeyChanged, object: nil)
        }
    }

    @Published var clipboardHistoryEnabled: Bool {
        didSet { defaults.set(clipboardHistoryEnabled, forKey: "clipboardHistoryEnabled") }
    }

    /// Mode compact : la fenêtre n'est qu'une barre de recherche tant qu'on n'a rien tapé.
    @Published var compactMode: Bool {
        didSet { defaults.set(compactMode, forKey: "compactMode") }
    }

    /// Échap ferme tout de suite le lanceur, au lieu de revenir à l'écran précédent.
    @Published var escapeClosesCompletely: Bool {
        didSet { defaults.set(escapeClosesCompletely, forKey: "escapeClosesCompletely") }
    }

    @Published var showMenuBarIcon: Bool {
        didSet {
            defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon")
            NotificationCenter.default.post(name: .prismMenuBarChanged, object: nil)
        }
    }

    /// Délai (secondes) après lequel le lanceur rouvert revient à la recherche vide.
    @Published var resetDelay: Double {
        didSet { defaults.set(resetDelay, forKey: "resetDelay") }
    }

    /// Montre les fichiers dans la recherche principale.
    @Published var filesInRootSearch: Bool {
        didSet { defaults.set(filesInRootSearch, forKey: "filesInRootSearch") }
    }

    /// Sensibilité de la recherche floue : 0 faible, 1 moyenne, 2 élevée.
    @Published var searchSensitivity: Int {
        didSet {
            defaults.set(searchSensitivity, forKey: "searchSensitivity")
            Fuzzy.sensitivity = searchSensitivity
        }
    }

    /// L'écran où s'ouvre le lanceur : « mouse » (celui de la souris), « window » (celui de la fenêtre active), « main ».
    @Published var showOnScreen: String { didSet { defaults.set(showOnScreen, forKey: "showOnScreen") } }
    /// Raccourcis de navigation : « emacs » (⌃N ⌃P) ou « vim » (⌃J ⌃K).
    @Published var navigationBindings: String { didSet { defaults.set(navigationBindings, forKey: "navigationBindings") } }
    /// Favoris en icônes dans le mode compact.
    @Published var favoritesInCompactMode: Bool { didSet { defaults.set(favoritesInCompactMode, forKey: "favoritesInCompactMode") } }
    /// Source de saisie à activer à l'ouverture (identifiant TIS ; vide : aucune).
    @Published var inputSource: String { didSet { defaults.set(inputSource, forKey: "inputSource") } }
    /// Favicons : « site » (le site lui-même), « duckduckgo », « google », « none ».
    @Published var faviconProvider: String { didSet { defaults.set(faviconProvider, forKey: "faviconProvider") } }
    /// Historique des recherches (↑ sur une recherche vide), le plus récent d'abord.
    var searchHistory: [String] {
        get { defaults.stringArray(forKey: "searchHistory") ?? [] }
        set { defaults.set(Array(newValue.prefix(30)), forKey: "searchHistory") }
    }

    /// Taille de l'interface du lanceur : 1 (par défaut), 1,12 (grande), 1,25 (plus grande).
    @Published var interfaceScale: Double {
        didSet {
            defaults.set(interfaceScale, forKey: "interfaceScale")
            NotificationCenter.default.post(name: .prismThemeDidChange, object: nil)
        }
    }

    var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: "hasLaunchedBefore") }
        set { defaults.set(newValue, forKey: "hasLaunchedBefore") }
    }

    private init() {
        if let saved = defaults.string(forKey: "launcherHotkey").flatMap(HotkeyCoding.decode) {
            launcherHotkey = saved
        } else {
            launcherHotkey = Preferences.migratedHotkey(defaults.string(forKey: "hotKey"))
        }
        clipboardHistoryEnabled = defaults.object(forKey: "clipboardHistoryEnabled") as? Bool ?? true
        compactMode = defaults.bool(forKey: "compactMode")
        escapeClosesCompletely = defaults.bool(forKey: "escapeClosesCompletely")
        showMenuBarIcon = defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true
        resetDelay = defaults.object(forKey: "resetDelay") as? Double ?? 90
        filesInRootSearch = defaults.bool(forKey: "filesInRootSearch")
        searchSensitivity = defaults.object(forKey: "searchSensitivity") as? Int ?? 1
        showOnScreen = defaults.string(forKey: "showOnScreen") ?? "mouse"
        interfaceScale = min(1.3, max(1, defaults.object(forKey: "interfaceScale") as? Double ?? 1))
        navigationBindings = defaults.string(forKey: "navigationBindings") ?? "emacs"
        favoritesInCompactMode = defaults.bool(forKey: "favoritesInCompactMode")
        inputSource = defaults.string(forKey: "inputSource") ?? ""
        faviconProvider = defaults.string(forKey: "faviconProvider") ?? "site"
        Fuzzy.sensitivity = searchSensitivity
    }

    /// Les anciens réglages proposaient cinq raccourcis fixes.
    private static func migratedHotkey(_ preset: String?) -> Hotkey {
        let space = UInt32(kVK_Space)
        switch preset {
        case "controlSpace": return Hotkey(keyCode: space, modifiers: UInt32(controlKey))
        case "commandSpace": return Hotkey(keyCode: space, modifiers: UInt32(cmdKey))
        case "optionCommandSpace": return Hotkey(keyCode: space, modifiers: UInt32(optionKey | cmdKey))
        case "shiftCommandSpace": return Hotkey(keyCode: space, modifiers: UInt32(shiftKey | cmdKey))
        default: return defaultLauncherHotkey
        }
    }
}

extension Notification.Name {
    static let prismMenuBarChanged = Notification.Name("PrismMenuBarChanged")
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("Prism : ouverture au démarrage impossible : \(error.localizedDescription)")
            return false
        }
    }
}
