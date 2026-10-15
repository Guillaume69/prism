import AppKit
import SwiftUI

/// Raccourci clavier d'une action, affiché dans le panneau d'actions.
struct KeyShortcut: Equatable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let label: String

    var symbols: [String] {
        var result: [String] = []
        if modifiers.contains(.control) { result.append("⌃") }
        if modifiers.contains(.option) { result.append("⌥") }
        if modifiers.contains(.shift) { result.append("⇧") }
        if modifiers.contains(.command) { result.append("⌘") }
        result.append(label)
        return result
    }

    func matches(keyCode code: UInt16, modifiers flags: NSEvent.ModifierFlags) -> Bool {
        code == keyCode && flags == modifiers
    }

    static func == (lhs: KeyShortcut, rhs: KeyShortcut) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    static let copyPath = KeyShortcut(keyCode: 8, modifiers: [.command, .shift], label: "C")
    static let copyText = KeyShortcut(keyCode: 8, modifiers: [.command, .shift], label: "C")
    static let copyName = KeyShortcut(keyCode: 8, modifiers: [.command, .option], label: "C")
    static let removeEntry = KeyShortcut(keyCode: 7, modifiers: [.control], label: "X")
    static let removeAll = KeyShortcut(keyCode: 7, modifiers: [.control, .shift], label: "X")
    static let quitApp = KeyShortcut(keyCode: 12, modifiers: [.control], label: "Q")
    static let forceQuit = KeyShortcut(keyCode: 12, modifiers: [.control, .option], label: "Q")
    static let openWith = KeyShortcut(keyCode: 31, modifiers: [.command, .shift], label: "O")
    static let pin = KeyShortcut(keyCode: 47, modifiers: [.command], label: ".")
    static let edit = KeyShortcut(keyCode: 14, modifiers: [.command], label: "E")
    static let create = KeyShortcut(keyCode: 45, modifiers: [.command], label: "N")
    static let duplicate = KeyShortcut(keyCode: 2, modifiers: [.command], label: "D")
    static let quickLook = KeyShortcut(keyCode: 16, modifiers: [.command], label: "Y")
    static let favorite = KeyShortcut(keyCode: 3, modifiers: [.command, .shift], label: "F")
    static let refresh = KeyShortcut(keyCode: 15, modifiers: [.command], label: "R")
    static let pastePlain = KeyShortcut(keyCode: 9, modifiers: [.command, .shift], label: "V")
    static let deeplink = KeyShortcut(keyCode: 37, modifiers: [.command, .shift], label: "L")
    static let alias = KeyShortcut(keyCode: 0, modifiers: [.command, .option], label: "A")
    static let hotkey = KeyShortcut(keyCode: 4, modifiers: [.command, .option], label: "H")
    static let moveUp = KeyShortcut(keyCode: 126, modifiers: [.command, .option], label: "↑")
    static let moveDown = KeyShortcut(keyCode: 125, modifiers: [.command, .option], label: "↓")
    static let openTerminal = KeyShortcut(keyCode: 17, modifiers: [.command, .shift], label: "T")
    static let share = KeyShortcut(keyCode: 1, modifiers: [.command, .shift], label: "S")
    static let toAI = KeyShortcut(keyCode: 38, modifiers: [.command], label: "J")
}

/// Ce que le lanceur fait une fois l'action exécutée.
enum ActionOutcome {
    case close
    case stay
    case refresh
    case hud(String)
    case toast(String)
    /// Ouvre un écran par-dessus l'écran courant (liste, formulaire, vue).
    case push(LauncherScreen, query: String = "")
    /// Remplace l'écran courant.
    case replace(LauncherScreen, query: String = "")
    case pop
    case popToRoot
    /// Remplace la saisie, curseur à la fin (les liens rapides : « yt »).
    case setQuery(String)
    /// Deux effets à la suite : enregistrer puis revenir, par exemple.
    indirect case then(ActionOutcome, ActionOutcome)
}

struct ItemAction: Identifiable {
    let id = UUID()
    var title: String
    var symbol: String
    var shortcut: KeyShortcut? = nil
    var isDestructive = false
    /// Groupe affiché au-dessus de l'action dans le panneau d'actions.
    var section: String? = nil
    var run: @MainActor () -> ActionOutcome
}

extension ItemAction {
    /// La même action, rangée dans un groupe du panneau d'actions.
    func inSection(_ name: String) -> ItemAction {
        var copy = self
        copy.section = name
        return copy
    }
}

enum ItemIcon {
    /// Icône Finder d'un fichier ou d'une application.
    case file(String)
    /// Symbole SF sur un carré coloré, comme les commandes de Raycast.
    case symbol(String, Color)
    /// Symbole SF seul, sans fond.
    case glyph(String)
    /// Symbole SF seul, teinté.
    case tinted(String, Color)
    case emoji(String)
    case image(NSImage)
    /// Pastille de couleur (presse-papiers, calculatrice).
    case color(NSColor)
    /// Favicon d'un site, chargée en arrière-plan.
    case favicon(URL)
    /// Image distante (icônes du Store), chargée en arrière-plan, avec un symbole en attendant.
    case remote(URL, fallback: String)
    /// Pas d'icône (éléments d'extension qui n'en donnent pas) : la place reste vide.
    case none
}

enum ItemStyle {
    case row
    case calculator(expression: String, result: String)
    /// Carte à deux colonnes légendées, comme la calculatrice : traduction (« Français » → « Anglais »).
    case card(source: String, sourceCaption: String, result: String, resultCaption: String)
    case emoji
    /// Vignette d'image dans une grille (captures d'écran).
    case thumbnail
}

struct ItemDetail {
    var text: String
    var metadata: [(label: String, value: String)]
    var image: NSImage? = nil
    /// Texte rendu en Markdown plutôt qu'en police à chasse fixe.
    var isMarkdown = false
}

/// Un argument saisi avant d'exécuter une commande (lien rapide, script, commande d'IA).
struct ItemArgument {
    var name: String
    var placeholder: String
    var isOptional = false
    var isSecure = false
    /// Valeurs proposées : l'argument devient une liste déroulante.
    var options: [String] = []
    var defaultValue: String = ""
}

struct ResultItem: Identifiable {
    let id: String
    var title: String
    var subtitle: String? = nil
    var icon: ItemIcon
    var accessory: String? = nil
    /// Étiquettes affichées à droite (alias, mot-clé, statut).
    var tags: [String] = []
    var style: ItemStyle = .row
    var keywords: [String] = []
    var detail: ItemDetail? = nil
    /// Clé de fréquence d'utilisation, l'identifiant par défaut. Vide : non comptée.
    var usageKey: String? = nil
    var actions: [ItemAction]
    /// Arguments demandés avant l'action principale.
    var arguments: [ItemArgument] = []
    /// Exécution avec les arguments saisis, dans l'ordre de `arguments`.
    var runWithArguments: (@MainActor ([String]) -> ActionOutcome)? = nil
    /// Peut recevoir un alias, un raccourci global, aller dans les favoris : commandes, apps, liens, scripts.
    var isConfigurable = false
    /// Affiché grisé (élément de menu désactivé).
    var isDimmed = false
}

struct ResultSection: Identifiable {
    let id: String
    var title: String?
    var items: [ResultItem]
    var columns: Int = 1
    /// Hauteur des cellules d'une grille.
    var cellHeight: CGFloat = 62
}

enum Palette {
    static let red = Color(red: 1.00, green: 0.38, blue: 0.38)
    static let orange = Color(red: 1.00, green: 0.58, blue: 0.25)
    static let yellow = Color(red: 0.98, green: 0.76, blue: 0.20)
    static let green = Color(red: 0.25, green: 0.78, blue: 0.45)
    static let teal = Color(red: 0.20, green: 0.74, blue: 0.78)
    static let blue = Color(red: 0.24, green: 0.55, blue: 1.00)
    static let indigo = Color(red: 0.40, green: 0.42, blue: 0.95)
    static let violet = Color(red: 0.62, green: 0.40, blue: 0.95)
    static let pink = Color(red: 0.96, green: 0.36, blue: 0.62)
    static let gray = Color(red: 0.52, green: 0.53, blue: 0.57)
    static let brown = Color(red: 0.65, green: 0.48, blue: 0.35)
}

extension Notification.Name {
    static let appCatalogDidChange = Notification.Name("PrismAppCatalogDidChange")
    static let clipboardDidChange = Notification.Name("PrismClipboardDidChange")
    static let prismOpenSettings = Notification.Name("PrismOpenSettings")
    static let prismHotKeyChanged = Notification.Name("PrismHotKeyChanged")
    /// Une donnée affichée par le lanceur a changé : il recalcule l'écran courant.
    static let prismDataDidChange = Notification.Name("PrismDataDidChange")
    static let prismThemeDidChange = Notification.Name("PrismThemeDidChange")
    /// Double-clic sur la barre du lanceur : il revient à sa place habituelle.
    static let prismLauncherResetPosition = Notification.Name("PrismLauncherResetPosition")
}

/// L'application qui était au premier plan quand le lanceur s'est ouvert : c'est là qu'on colle et qu'on range les fenêtres.
@MainActor
enum AppContext {
    static var previousApp: NSRunningApplication?
    static var hotKeyRegistered = false
    static var simulateHotKey: (() -> Int32)?
    /// Le lanceur, pour les fonctionnalités qui l'ouvrent sur un écran (raccourcis, liens profonds, barre des menus).
    static weak var launcher: LauncherPanelController?
}
