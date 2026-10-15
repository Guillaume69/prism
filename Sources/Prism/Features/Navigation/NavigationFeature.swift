import AppKit
import SwiftUI

/// Navigation : chercher dans les menus de l'app au premier plan, passer d'une fenêtre à l'autre.
@MainActor
enum NavigationFeature: PrismFeature {
    static let color = Palette.indigo

    static var commands: [ResultItem] {
        [
            Command.screen("navigation.menus", "Rechercher dans les menus", subtitle: "Navigation", symbol: "filemenu.and.selection", color: color,
                           keywords: ["search menu items", "menu bar", "barre des menus", "menus"]) { MenuSearchScreen() },
            Command.screen("navigation.windows", "Changer de fenêtre", subtitle: "Navigation", symbol: "macwindow.on.rectangle", color: color,
                           keywords: ["switch windows", "window switcher", "fenetres ouvertes", "basculer"]) { WindowSwitcherScreen() },
        ]
    }

    static func selfTest(_ check: (Bool, String) -> Void) {
        // Chemins de menus.
        check(MenuPath.parse("Fichier › Exporter › PDF") == ["Fichier", "Exporter", "PDF"], "chemin de menu analysé")
        check(MenuPath.parse("Édition > Rechercher >  Rechercher… ") == ["Édition", "Rechercher", "Rechercher…"], "chemin avec « > » et espaces")
        check(MenuPath.join(["Fichier", "Exporter", "PDF"]) == "Fichier › Exporter › PDF", "chemin de menu reconstitué")

        let bar = [
            MenuNode(title: "Apple", children: [MenuNode(title: "À propos de ce Mac")]),
            MenuNode(title: "Aperçu", children: [MenuNode(title: "Quitter Aperçu", shortcut: "⌘Q")]),
            MenuNode(title: "Fichier", children: [
                MenuNode(title: "Ouvrir…", shortcut: "⌘O"),
                MenuNode(title: ""),
                MenuNode(title: "Exporter", children: [
                    MenuNode(title: "PDF", shortcut: "⇧⌘E"),
                    MenuNode(title: "Image", isEnabled: false),
                ]),
            ]),
        ]
        let entries = MenuPath.flatten(bar)
        check(entries.map(\.fullPath) == ["Aperçu › Quitter Aperçu", "Fichier › Ouvrir…", "Fichier › Exporter › PDF", "Fichier › Exporter › Image"],
              "menus aplatis : menu Pomme et séparateurs ignorés")
        check(entries.first { $0.title == "PDF" }?.parentPath == "Fichier › Exporter", "chemin parent d’un sous-menu")
        check(entries.first { $0.title == "Image" }?.isEnabled == false, "élément désactivé repéré")

        // Libellés de raccourcis.
        check(MenuShortcut.label(character: "S", glyph: nil, modifiers: 0) == "⌘S", "raccourci ⌘S")
        check(MenuShortcut.label(character: "s", glyph: nil, modifiers: 1) == "⇧⌘S", "raccourci ⇧⌘S")
        check(MenuShortcut.label(character: "F", glyph: nil, modifiers: 4 | 1) == "⌃⇧⌘F", "ordre ⌃⌥⇧⌘")
        check(MenuShortcut.label(character: "T", glyph: nil, modifiers: 2 | 4 | 8) == "⌃⌥T", "sans ⌘ (bit 8)")
        check(MenuShortcut.label(character: nil, glyph: 0x17, modifiers: 0) == "⌘⌫", "glyphe ⌫")
        check(MenuShortcut.label(character: "\u{F702}", glyph: nil, modifiers: 2) == "⌥⌘←", "flèche gauche")
        check(MenuShortcut.label(character: "\u{F70F}", glyph: nil, modifiers: 8) == "F12", "touche de fonction seule")
        check(MenuShortcut.label(character: nil, glyph: nil, modifiers: 0) == nil, "aucun raccourci")

        // Sans accessibilité (toujours le cas ici) : état vide et action « Autoriser… », sans rien demander.
        let menus = MenuSearchScreen()
        check(menus.sections(query: "").isEmpty && menus.emptyState(query: "").symbol == "lock.shield", "menus : état vide sans accessibilité")
        check(menus.screenActions.first?.title.hasPrefix("Autoriser") == true, "menus : action « Autoriser… »")
        let switcher = WindowSwitcherScreen()
        check(switcher.sections(query: "").isEmpty && switcher.emptyState(query: "").symbol == "lock.shield", "fenêtres : état vide sans accessibilité")
        check(RootScreen().sections(query: "rechercher dans les menus").first { $0.id == "results" }?.items.first?.id == "command:navigation.menus", "commande « Rechercher dans les menus » trouvée")
        check(RootScreen().sections(query: "switch windows").first { $0.id == "results" }?.items.first?.id == "command:navigation.windows", "commande « Changer de fenêtre » trouvée en anglais")
    }
}
