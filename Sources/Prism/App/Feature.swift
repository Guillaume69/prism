import AppKit
import SwiftUI

/// Un onglet des réglages, fourni par une fonctionnalité.
struct SettingsPane: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let color: Color
    /// Ordre dans la barre latérale des réglages.
    var order: Int = 100
    let view: @MainActor () -> AnyView
}

/// Une fonctionnalité de Prism (presse-papiers, snippets, fenêtres…), branchée sur le lanceur
/// sans toucher à son cœur. Toutes les méthodes ont une implémentation vide par défaut.
@MainActor
protocol PrismFeature {
    /// Au lancement de l'application : moniteurs, raccourcis, fenêtres.
    static func start()
    /// Les commandes proposées par la recherche principale.
    static var commands: [ResultItem] { get }
    /// Sections en tête de la recherche principale (calculatrice, traduction, prochaine réunion…),
    /// appelées aussi quand la saisie est vide.
    static func topSections(query: String) -> [ResultSection]
    /// Sections placées après les résultats (fichiers, contacts, évènements…), saisie non vide.
    static func extraSections(query: String) -> [ResultSection]
    /// Recherches de repli, proposées sous les résultats (« Rechercher sur Google »).
    static func fallbacks(query: String) -> [ResultItem]
    /// Les onglets des réglages.
    static var settingsPanes: [SettingsPane] { get }
    /// Liens profonds `prism://…` : `true` si le lien a été pris en charge.
    static func handle(url: URL) -> Bool
    /// Vérifications sans interface, lancées par `Prism --selftest`. Ne demande aucune autorisation.
    static func selfTest(_ check: (Bool, String) -> Void)
}

extension PrismFeature {
    static func start() {}
    static var commands: [ResultItem] { [] }
    static func topSections(query: String) -> [ResultSection] { [] }
    static func extraSections(query: String) -> [ResultSection] { [] }
    static func fallbacks(query: String) -> [ResultItem] { [] }
    static var settingsPanes: [SettingsPane] { [] }
    static func handle(url: URL) -> Bool { false }
    static func selfTest(_ check: (Bool, String) -> Void) {}
}

/// Fabrique des commandes, pour qu'elles se ressemblent toutes.
@MainActor
enum Command {
    /// Une commande de la recherche principale. L'identifiant devient « command:<id> ».
    static func make(
        _ id: String,
        _ title: String,
        subtitle: String,
        symbol: String,
        color: Color,
        keywords: [String] = [],
        accessory: String = "Commande",
        arguments: [ItemArgument] = [],
        runWithArguments: (@MainActor ([String]) -> ActionOutcome)? = nil,
        actions: [ItemAction]
    ) -> ResultItem {
        ResultItem(
            id: "command:" + id,
            title: title,
            subtitle: subtitle,
            icon: .symbol(symbol, color),
            accessory: accessory,
            keywords: keywords,
            actions: actions,
            arguments: arguments,
            runWithArguments: runWithArguments,
            isConfigurable: true
        )
    }

    /// Une commande qui ouvre un écran du lanceur.
    static func screen(
        _ id: String,
        _ title: String,
        subtitle: String,
        symbol: String,
        color: Color,
        keywords: [String] = [],
        screen: @escaping @MainActor () -> LauncherScreen
    ) -> ResultItem {
        make(id, title, subtitle: subtitle, symbol: symbol, color: color, keywords: keywords, actions: [
            ItemAction(title: "Ouvrir la commande", symbol: "arrow.right.circle") { .push(screen()) },
        ])
    }

    /// Une commande qui agit aussitôt (« Lancer la commande »).
    static func run(
        _ id: String,
        _ title: String,
        subtitle: String,
        symbol: String,
        color: Color,
        keywords: [String] = [],
        perform: @escaping @MainActor () -> ActionOutcome
    ) -> ResultItem {
        make(id, title, subtitle: subtitle, symbol: symbol, color: color, keywords: keywords, actions: [
            ItemAction(title: "Lancer la commande", symbol: "play.fill", run: perform),
        ])
    }
}

/// Toutes les fonctionnalités, dans l'ordre où leurs sections apparaissent.
@MainActor
enum Features {
    static let all: [any PrismFeature.Type] = [
        CoreFeature.self,
        CalculatorFeature.self,
        CalendarFeature.self,
        QuicklinksFeature.self,
        ClipboardFeature.self,
        SnippetsFeature.self,
        EmojiFeature.self,
        FilesFeature.self,
        ContactsFeature.self,
        ScreenshotsFeature.self,
        WindowsFeature.self,
        NavigationFeature.self,
        SystemFeature.self,
        SystemSettingsFeature.self,
        ApplicationsFeature.self,
        GamesFeature.self,
        FunFeature.self,
        ThemesFeature.self,
        StoreFeature.self,
        StatsFeature.self,
        FocusFeature.self,
        TranslateFeature.self,
        DictationFeature.self,
        AIFeature.self,
        RunFeature.self,
        NotesFeature.self,
        ScriptsFeature.self,
        HyperKeyFeature.self,
        SyncFeature.self,
        ExtensionsFeature.self,
        TeamFeature.self,
    ]

    static func startAll() {
        for feature in all { feature.start() }
    }

    static var commands: [ResultItem] { all.flatMap { $0.commands } }

    static var settingsPanes: [SettingsPane] {
        all.flatMap { $0.settingsPanes }.sorted { $0.order < $1.order }
    }

    static func handle(url: URL) -> Bool {
        all.contains { $0.handle(url: url) }
    }
}
