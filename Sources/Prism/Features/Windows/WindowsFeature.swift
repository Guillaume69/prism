import AppKit
import SwiftUI

/// Une commande de fenêtre qui n'est pas un simple cadre : plein écran, bureaux, réduction…
@MainActor
struct WindowAction {
    let id: String
    let title: String
    var subtitle = WindowsFeature.subtitle
    let symbol: String
    let keywords: [String]
    let group: String
    let perform: @MainActor () -> ActionOutcome
}

/// Gestion des fenêtres, comme celle de Raycast : rangements, écrans, bureaux, commandes personnalisées, dispositions.
@MainActor
enum WindowsFeature: PrismFeature {
    static let subtitle = "Gestion des fenêtres"
    static let color = Palette.teal

    // MARK: - Commandes

    static var actions: [WindowAction] {
        var list: [WindowAction] = [
            WindowAction(id: "toggleFullscreen", title: "Basculer le plein écran", symbol: "arrow.up.left.and.arrow.down.right",
                         keywords: ["toggle fullscreen", "full screen", "plein ecran"], group: "Taille", perform: WindowManager.toggleFullScreen),
            WindowAction(id: "restore", title: "Restaurer", symbol: "arrow.uturn.backward",
                         keywords: ["restore", "annuler", "taille precedente", "undo"], group: "Taille", perform: WindowManager.restore),
            WindowAction(id: "minimize", title: "Réduire la fenêtre", symbol: "minus.rectangle",
                         keywords: ["minimize", "dock", "reduire"], group: "Fenêtres", perform: WindowManager.minimize),
            WindowAction(id: "minimizeAll", title: "Réduire les fenêtres de cet écran", symbol: "dock.arrow.down.rectangle",
                         keywords: ["minimize all", "tout reduire", "dock", "bureau propre"], group: "Fenêtres", perform: WindowManager.minimizeAllOnScreen),
            WindowAction(id: "nextWindow", title: "Fenêtre suivante de l’app", symbol: "macwindow.stack",
                         keywords: ["next window", "fenetre suivante", "cycle"], group: "Fenêtres") { WindowManager.focusSibling(1) },
            WindowAction(id: "previousWindow", title: "Fenêtre précédente de l’app", symbol: "macwindow.stack",
                         keywords: ["previous window", "fenetre precedente", "cycle"], group: "Fenêtres") { WindowManager.focusSibling(-1) },
            WindowAction(id: "nextSpace", title: "Bureau suivant", subtitle: subtitle + " · simule ⌃→", symbol: "arrow.right.square",
                         keywords: ["next space", "next desktop", "space suivant", "bureau suivant"], group: "Bureaux") { Spaces.switchSpace(next: true) },
            WindowAction(id: "previousSpace", title: "Bureau précédent", subtitle: subtitle + " · simule ⌃←", symbol: "arrow.left.square",
                         keywords: ["previous space", "previous desktop", "space precedent", "bureau precedent"], group: "Bureaux") { Spaces.switchSpace(next: false) },
            WindowAction(id: "moveToNextSpace", title: "Envoyer la fenêtre au bureau suivant", subtitle: subtitle + " · au mieux", symbol: "arrow.forward.square",
                         keywords: ["move to next space", "move window next desktop", "deplacer space suivant"], group: "Bureaux") { Spaces.moveWindow(next: true) },
            WindowAction(id: "moveToPreviousSpace", title: "Envoyer la fenêtre au bureau précédent", subtitle: subtitle + " · au mieux", symbol: "arrow.backward.square",
                         keywords: ["move to previous space", "move window previous desktop", "deplacer space precedent"], group: "Bureaux") { Spaces.moveWindow(next: false) },
        ]
        for number in 1...9 {
            list.append(WindowAction(
                id: "desktop\(number)", title: "Aller au bureau \(number)", subtitle: subtitle + " · simule ⌃\(number) (Mission Control)",
                symbol: "\(number).square.fill", keywords: ["desktop \(number)", "space \(number)", "bureau \(number)", "switch desktop"], group: "Bureaux"
            ) { Spaces.goToDesktop(number) })
        }
        return list
    }

    static func item(_ layout: WindowLayout) -> ResultItem {
        Command.run("window." + layout.rawValue, layout.title, subtitle: subtitle, symbol: layout.symbol, color: color,
                    keywords: layout.keywords + ["window", "fenetre"]) {
            WindowManager.apply(layout)
        }
    }

    static func item(_ action: WindowAction) -> ResultItem {
        Command.run("window." + action.id, action.title, subtitle: action.subtitle, symbol: action.symbol, color: color,
                    keywords: action.keywords + ["window", "fenetre"], perform: action.perform)
    }

    static func item(_ command: CustomWindowCommand) -> ResultItem {
        Command.make(
            "window.custom." + command.id, command.name, subtitle: subtitle,
            symbol: command.spec.anchor.symbol, color: color,
            keywords: ["custom window command", "commande de fenetre", "fenetre", command.spec.summary],
            accessory: "Personnalisée",
            actions: CustomCommandScreens.actions(for: command)
        )
    }

    static func item(_ layout: SavedWindowLayout) -> ResultItem {
        Command.make(
            "window.layout." + layout.id, layout.name, subtitle: subtitle,
            symbol: "rectangle.3.group", color: color,
            keywords: ["window layout", "disposition", "fenetres", layout.summary],
            accessory: "Disposition",
            actions: LayoutScreens.actions(for: layout)
        )
    }

    /// Les commandes fixes de la gestion des fenêtres (rangements, actions, formulaires).
    static var builtInItems: [ResultItem] {
        WindowLayout.allCases.map(item) + actions.map(item) + [
            Command.screen("window.resize", "Redimensionner la fenêtre", subtitle: subtitle, symbol: "square.resize", color: color,
                           keywords: ["resize window", "redimensionner", "taille", "largeur", "hauteur", "window", "fenetre"], screen: WindowForms.resize),
            Command.screen("window.move", "Déplacer la fenêtre", subtitle: subtitle, symbol: "arrow.up.and.down.and.arrow.left.and.right", color: color,
                           keywords: ["move window", "deplacer", "position", "coordonnees", "window", "fenetre"], screen: WindowForms.move),
        ]
    }

    static var commands: [ResultItem] {
        let store = WindowStore.shared.data
        return builtInItems + [
            Command.screen("window.createCommand", "Créer une commande de fenêtre", subtitle: subtitle, symbol: "macwindow.badge.plus", color: color,
                           keywords: ["create custom window management command", "nouvelle commande", "fenetre personnalisee"]) {
                CustomCommandScreens.form(editing: nil)
            },
            Command.screen("window.searchCommands", "Rechercher les commandes de fenêtre", subtitle: subtitle, symbol: "macwindow.on.rectangle", color: color,
                           keywords: ["search window management commands", "commandes personnalisees", "fenetre"], screen: CustomCommandScreens.list),
            Command.screen("window.saveLayout", "Enregistrer la disposition actuelle", subtitle: subtitle, symbol: "square.and.arrow.down.on.square", color: color,
                           keywords: ["save window layout", "disposition", "sauvegarder fenetres"]) {
                LayoutScreens.saveForm(replacing: nil)
            },
            Command.screen("window.applyLayout", "Appliquer une disposition", subtitle: subtitle, symbol: "rectangle.3.group", color: color,
                           keywords: ["apply window layout", "restore layout", "disposition", "gerer les dispositions"], screen: LayoutScreens.list),
        ] + store.commands.map(item) + store.layouts.map(item)
    }

    static var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "windows", title: "Fenêtres", symbol: "macwindow", color: color, order: 40) { AnyView(WindowSettingsView()) }]
    }

    // MARK: - Liens profonds

    /// `prism://windows/<rangement>`, `prism://windows/custom?name=…` ou `?position=top-left&width=50%&height=100%&x=0&y=0`,
    /// `prism://windows/layout?name=…`.
    static func handle(url: URL) -> Bool {
        guard url.host == "windows" else { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier { AppContext.previousApp = frontmost }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let outcome: ActionOutcome
        switch path {
        case "custom":
            if let name = query.first(where: { $0.name == "name" })?.value {
                guard let command = WindowStore.shared.command(named: name) else {
                    outcome = .hud("Commande de fenêtre « \(name) » introuvable")
                    break
                }
                outcome = WindowManager.apply(command.spec)
            } else if let spec = DeeplinkSpec.parse(query) {
                outcome = WindowManager.apply(spec)
            } else {
                outcome = .hud("Paramètres de fenêtre invalides")
            }
        case "layout":
            guard let name = query.first(where: { $0.name == "name" })?.value, let layout = WindowStore.shared.layout(named: name) else {
                outcome = .hud("Disposition introuvable")
                break
            }
            outcome = LayoutEngine.apply(layout)
        default:
            if let layout = WindowLayout(rawValue: path) {
                outcome = WindowManager.apply(layout)
            } else if let action = actions.first(where: { $0.id == path }) {
                outcome = action.perform()
            } else {
                return false
            }
        }
        CommandRunner.present(outcome)
        return true
    }

    // MARK: - Autotests

    static func selfTest(_ check: (Bool, String) -> Void) {
        WindowSelfTest.run(check)
    }
}

/// Les paramètres d'une commande temporaire passée par lien profond.
enum DeeplinkSpec {
    static func parse(_ query: [URLQueryItem]) -> CustomWindowSpec? {
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        guard value("position") != nil || value("width") != nil || value("height") != nil else { return nil }
        let anchor = value("position").map(WindowAnchor.parse) ?? .center
        guard let anchor,
              let width = WindowDimension.parse(value("width") ?? "100%"),
              let height = WindowDimension.parse(value("height") ?? "100%"),
              let offsetX = value("x").map({ WindowDimension.parse($0) }) ?? .percent(0),
              let offsetY = value("y").map({ WindowDimension.parse($0) }) ?? .percent(0),
              width.value > 0, height.value > 0 else { return nil }
        return CustomWindowSpec(width: width, height: height, anchor: anchor, offsetX: offsetX, offsetY: offsetY)
    }
}

// MARK: - Formulaires de taille et de position

@MainActor
enum WindowForms {
    private static var currentFrame: CGRect? {
        guard AccessibilityGate.isGranted, case .success(let target) = WindowManager.target() else { return nil }
        return target.frame
    }

    static func resize() -> LauncherScreen {
        let frame = currentFrame
        return FormScreen(
            id: "window.resize", title: "Redimensionner la fenêtre", icon: .symbol("square.resize", WindowsFeature.color), submitTitle: "Redimensionner",
            fields: [
                FormField(id: "width", label: "Largeur", kind: .text, placeholder: "1200 ou 60 %", value: frame.map { String(Int($0.width)) } ?? ""),
                FormField(id: "height", label: "Hauteur", kind: .text, placeholder: "800 ou 80 %", value: frame.map { String(Int($0.height)) } ?? "",
                          info: "En points, ou en pourcentage de l’écran (« 50 % »). La position ne change pas."),
            ]
        ) { state in
            guard let width = WindowDimension.parse(state.trimmed("width")), width.value > 0,
                  let height = WindowDimension.parse(state.trimmed("height")), height.value > 0 else {
                state.error = "Indiquez une largeur et une hauteur positives"
                return .stay
            }
            return WindowManager.resize(width: width, height: height)
        }
    }

    static func move() -> LauncherScreen {
        let frame = currentFrame
        let area = frame.map(WindowManager.visibleArea(containing:))
        return FormScreen(
            id: "window.move", title: "Déplacer la fenêtre", icon: .symbol("arrow.up.and.down.and.arrow.left.and.right", WindowsFeature.color), submitTitle: "Déplacer",
            fields: [
                FormField(id: "x", label: "x", kind: .text, placeholder: "0 ou 10 %", value: frame.flatMap { f in area.map { String(Int(f.minX - $0.minX)) } } ?? ""),
                FormField(id: "y", label: "y", kind: .text, placeholder: "0 ou 10 %", value: frame.flatMap { f in area.map { String(Int(f.minY - $0.minY)) } } ?? "",
                          info: "Le coin haut gauche de la fenêtre, compté depuis le coin haut gauche de l’écran (sous la barre des menus), en points ou en %."),
            ]
        ) { state in
            guard let x = WindowDimension.parse(state.trimmed("x")), let y = WindowDimension.parse(state.trimmed("y")) else {
                state.error = "Indiquez deux nombres"
                return .stay
            }
            return WindowManager.move(x: x, y: y)
        }
    }
}

// MARK: - Commandes personnalisées

@MainActor
enum CustomCommandScreens {
    static let unitOptions: [(value: String, title: String)] = [("percent", "%"), ("points", "points")]

    /// Lit les valeurs du formulaire ; un message si quelque chose ne va pas. Pure, pour les autotests.
    static func spec(from values: [String: String]) -> Result<CustomWindowSpec, FormError> {
        func dimension(_ id: String, _ label: String, allowNegative: Bool) -> Result<WindowDimension, FormError> {
            let unit = WindowDimension.Unit(rawValue: values[id + "Unit"] ?? "percent") ?? .percent
            let text = (values[id] ?? "").trimmingCharacters(in: .whitespaces)
            guard let parsed = WindowDimension.parse(text.isEmpty && allowNegative ? "0" : text, defaultUnit: unit) else {
                return .failure(FormError("« \(label) » doit être un nombre"))
            }
            if allowNegative {
                if parsed.unit == .percent, abs(parsed.value) > 100 { return .failure(FormError("« \(label) » va de −100 % à +100 %")) }
            } else {
                if parsed.value <= 0 { return .failure(FormError("« \(label) » doit être positive")) }
                if parsed.unit == .percent, parsed.value > 100 { return .failure(FormError("« \(label) » ne dépasse pas 100 %")) }
            }
            return .success(parsed)
        }
        let anchor = WindowAnchor(rawValue: values["anchor"] ?? "") ?? .center
        switch (dimension("width", "Largeur", allowNegative: false), dimension("height", "Hauteur", allowNegative: false),
                dimension("offsetX", "Décalage horizontal", allowNegative: true), dimension("offsetY", "Décalage vertical", allowNegative: true)) {
        case (.success(let width), .success(let height), .success(let offsetX), .success(let offsetY)):
            return .success(CustomWindowSpec(width: width, height: height, anchor: anchor, offsetX: offsetX, offsetY: offsetY))
        case (.failure(let error), _, _, _), (_, .failure(let error), _, _), (_, _, .failure(let error), _), (_, _, _, .failure(let error)):
            return .failure(error)
        }
    }

    struct FormError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private static func number(_ dimension: WindowDimension) -> String {
        dimension.value == dimension.value.rounded() ? String(Int(dimension.value)) : String(dimension.value)
    }

    /// Créer (ou modifier, ou dupliquer avec `duplicate`) une commande de fenêtre.
    static func form(editing command: CustomWindowCommand?, duplicate: Bool = false) -> LauncherScreen {
        let initial = command?.spec ?? CustomWindowSpec(width: .percent(50), height: .percent(100), anchor: .left)
        let name = command.map { duplicate ? $0.name + " (copie)" : $0.name } ?? ""
        let isEditing = command != nil && !duplicate
        return FormScreen(
            id: "window.customForm",
            title: isEditing ? "Modifier « \(command?.name ?? "") »" : "Créer une commande de fenêtre",
            icon: .symbol("macwindow.badge.plus", WindowsFeature.color),
            submitTitle: isEditing ? "Enregistrer" : "Créer la commande",
            fields: [
                FormField(id: "name", label: "Nom", kind: .text, placeholder: "Par exemple : Lecture à droite", value: name),
                FormField(id: "anchor", label: "Position", kind: .dropdown(WindowAnchor.allCases.map { ($0.rawValue, $0.title) }), value: initial.anchor.rawValue,
                          info: "Le point de l’écran où la fenêtre s’épingle."),
                FormField(id: "width", label: "Largeur", kind: .text, placeholder: "50", value: number(initial.width)),
                FormField(id: "widthUnit", label: "Unité de la largeur", kind: .dropdown(unitOptions), value: initial.width.unit.rawValue),
                FormField(id: "height", label: "Hauteur", kind: .text, placeholder: "100", value: number(initial.height)),
                FormField(id: "heightUnit", label: "Unité de la hauteur", kind: .dropdown(unitOptions), value: initial.height.unit.rawValue),
                FormField(id: "offsetX", label: "Décalage horizontal", kind: .text, placeholder: "0", value: number(initial.offsetX)),
                FormField(id: "offsetXUnit", label: "Unité", kind: .dropdown(unitOptions), value: initial.offsetX.unit.rawValue),
                FormField(id: "offsetY", label: "Décalage vertical", kind: .text, placeholder: "0", value: number(initial.offsetY)),
                FormField(id: "offsetYUnit", label: "Unité", kind: .dropdown(unitOptions), value: initial.offsetY.unit.rawValue,
                          info: "De −100 % à +100 % de l’écran, ou en points ; positif vers la droite et vers le bas."),
            ]
        ) { state in
            let name = state.trimmed("name")
            guard !name.isEmpty else {
                state.error = "Donnez un nom à la commande"
                return .stay
            }
            switch spec(from: state.values) {
            case .failure(let error):
                state.error = error.message
                return .stay
            case .success(let spec):
                let id = isEditing ? (command?.id ?? WindowStore.newID()) : WindowStore.newID()
                WindowStore.shared.save(CustomWindowCommand(id: id, name: name, spec: spec))
                return .then(.pop, .toast(isEditing ? "Commande « \(name) » enregistrée" : "Commande « \(name) » créée"))
            }
        }
    }

    static func actions(for command: CustomWindowCommand) -> [ItemAction] {
        [
            ItemAction(title: "Lancer la commande", symbol: "play.fill") { WindowManager.apply(command.spec) },
            ItemAction(title: "Modifier la commande", symbol: "pencil", shortcut: .edit) { .push(form(editing: command)) },
            ItemAction(title: "Dupliquer la commande", symbol: "plus.square.on.square", shortcut: .duplicate) { .push(form(editing: command, duplicate: true)) },
            ItemAction(title: "Créer une commande de fenêtre", symbol: "plus", shortcut: .create) { .push(form(editing: nil)) },
            ItemAction(title: "Copier le lien profond", symbol: "link", shortcut: KeyShortcut(keyCode: 8, modifiers: [.command, .shift], label: "C")) {
                var components = URLComponents()
                components.scheme = Deeplinks.scheme
                components.host = "windows"
                components.path = "/custom"
                components.queryItems = [URLQueryItem(name: "name", value: command.name)]
                Pasteboard.copy(components.url?.absoluteString ?? "")
                return .toast("Lien copié")
            },
            ItemAction(title: "Supprimer la commande", symbol: "trash", shortcut: .removeEntry, isDestructive: true) {
                WindowStore.shared.deleteCommand(command.id)
                return .then(.refresh, .toast("Commande « \(command.name) » supprimée"))
            },
        ]
    }

    /// Les commandes personnalisées, puis toutes les commandes intégrées par groupe.
    static func list() -> LauncherScreen {
        ListScreen(id: "window.searchCommands", title: "Commandes de fenêtre", placeholder: "Rechercher une commande de fenêtre…",
                   icon: .symbol("macwindow.on.rectangle", WindowsFeature.color)) { query in
            let normalized = query.normalizedForSearch
            func keep(_ item: ResultItem) -> Bool {
                normalized.isEmpty || Fuzzy.score(normalized, item.title) != nil || item.keywords.contains { Fuzzy.score(normalized, $0) != nil }
            }
            var custom = WindowStore.shared.data.commands.map { command -> ResultItem in
                var item = WindowsFeature.item(command)
                item.subtitle = command.spec.summary
                return item
            }.filter(keep)
            if normalized.isEmpty || Fuzzy.score(normalized, "Créer une commande") != nil {
                custom.append(ResultItem(
                    id: "window.custom.new", title: "Créer une commande de fenêtre", subtitle: "Taille, position épinglée et décalage",
                    icon: .symbol("plus", Palette.gray), usageKey: "",
                    actions: [ItemAction(title: "Créer une commande", symbol: "plus") { .push(form(editing: nil)) }]
                ))
            }
            var sections = [ResultSection(id: "custom", title: "Personnalisées", items: custom)]
            let builtIn = WindowsFeature.builtInItems
            let groups = Dictionary(grouping: WindowLayout.allCases.map { ($0.group, "command:window." + $0.rawValue) }
                + WindowsFeature.actions.map { ($0.group, "command:window." + $0.id) }, by: \.0)
            for group in ["Moitiés", "Tiers", "Quarts", "Sixièmes", "Taille", "Déplacement", "Écrans", "Fenêtres", "Bureaux"] {
                let ids = Set(groups[group]?.map(\.1) ?? [])
                var items = builtIn.filter { ids.contains($0.id) && keep($0) }
                if group == "Taille" { items += builtIn.filter { ["command:window.resize", "command:window.move"].contains($0.id) && keep($0) } }
                sections.append(ResultSection(id: "group." + group, title: group, items: items.map { var item = $0; item.usageKey = ""; return item }))
            }
            return sections.filter { !$0.items.isEmpty }
        }
    }
}

// MARK: - Dispositions

@MainActor
enum LayoutScreens {
    static func saveForm(replacing layout: SavedWindowLayout?) -> LauncherScreen {
        let count = AccessibilityGate.isGranted ? LayoutEngine.captureWindows().count : 0
        let info = AccessibilityGate.isGranted
            ? "\(count) fenêtre\(count > 1 ? "s" : "") visible\(count > 1 ? "s" : "") seront retenues (huit au plus par écran) : application, titre, place sur l’écran."
            : "Autorisez d’abord Prism dans Réglages Système › Accessibilité."
        return FormScreen(
            id: "window.saveLayout", title: layout == nil ? "Enregistrer la disposition actuelle" : "Remplacer « \(layout?.name ?? "") »",
            icon: .symbol("square.and.arrow.down.on.square", WindowsFeature.color), submitTitle: "Enregistrer",
            fields: [
                FormField(id: "name", label: "Nom", kind: .text, placeholder: "Par exemple : Écriture", value: layout?.name ?? "", info: info),
                FormField(id: "others", label: "Autres fenêtres", kind: .dropdown(OtherWindowsBehavior.allCases.map { ($0.rawValue, $0.title) }),
                          value: (layout?.otherWindows ?? .keep).rawValue, info: "Ce que deviennent, à l’application, les fenêtres absentes de la disposition."),
            ]
        ) { state in
            let name = state.trimmed("name")
            guard !name.isEmpty else {
                state.error = "Donnez un nom à la disposition"
                return .stay
            }
            if layout == nil, WindowStore.shared.layout(named: name) != nil {
                state.error = "Une disposition porte déjà ce nom"
                return .stay
            }
            return LayoutEngine.saveCurrent(name: name, otherWindows: OtherWindowsBehavior(rawValue: state["others"]) ?? .keep, replacing: layout?.id)
        }
    }

    static func editForm(_ layout: SavedWindowLayout) -> LauncherScreen {
        FormScreen(
            id: "window.editLayout", title: "Modifier « \(layout.name) »", icon: .symbol("rectangle.3.group", WindowsFeature.color),
            fields: [
                FormField(id: "name", label: "Nom", kind: .text, value: layout.name),
                FormField(id: "others", label: "Autres fenêtres", kind: .dropdown(OtherWindowsBehavior.allCases.map { ($0.rawValue, $0.title) }),
                          value: layout.otherWindows.rawValue),
            ]
        ) { state in
            let name = state.trimmed("name")
            guard !name.isEmpty else {
                state.error = "Donnez un nom à la disposition"
                return .stay
            }
            var updated = layout
            updated.name = name
            updated.otherWindows = OtherWindowsBehavior(rawValue: state["others"]) ?? .keep
            WindowStore.shared.save(updated)
            return .then(.pop, .toast("Disposition « \(name) » enregistrée"))
        }
    }

    static func actions(for layout: SavedWindowLayout) -> [ItemAction] {
        [
            ItemAction(title: "Appliquer la disposition", symbol: "rectangle.3.group") { LayoutEngine.apply(layout) },
            ItemAction(title: "Renommer…", symbol: "pencil", shortcut: .edit) { .push(editForm(layout)) },
            ItemAction(title: "Remplacer par les fenêtres actuelles", symbol: "arrow.triangle.2.circlepath") { .push(saveForm(replacing: layout)) },
            ItemAction(title: "Enregistrer la disposition actuelle", symbol: "plus", shortcut: .create) { .push(saveForm(replacing: nil)) },
            ItemAction(title: "Supprimer la disposition", symbol: "trash", shortcut: .removeEntry, isDestructive: true) {
                WindowStore.shared.deleteLayout(layout.id)
                return .then(.refresh, .toast("Disposition « \(layout.name) » supprimée"))
            },
        ]
    }

    static func list() -> LauncherScreen {
        ListScreen(id: "window.layouts", title: "Dispositions", placeholder: "Rechercher une disposition…",
                   icon: .symbol("rectangle.3.group", WindowsFeature.color)) { query in
            let normalized = query.normalizedForSearch
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "fr_FR")
            formatter.dateStyle = .medium
            let layouts = WindowStore.shared.data.layouts
                .filter { normalized.isEmpty || Fuzzy.score(normalized, $0.name) != nil }
                .map { layout in
                    ResultItem(id: "layout:" + layout.id, title: layout.name, subtitle: layout.summary, icon: .symbol("rectangle.3.group", WindowsFeature.color),
                               accessory: formatter.string(from: layout.created), usageKey: "", actions: actions(for: layout))
                }
            let create = ResultItem(
                id: "layout:new", title: "Enregistrer la disposition actuelle", subtitle: "Les fenêtres visibles, écran par écran",
                icon: .symbol("plus", Palette.gray), usageKey: "",
                actions: [ItemAction(title: "Enregistrer la disposition actuelle", symbol: "plus") { .push(saveForm(replacing: nil)) }]
            )
            return [
                ResultSection(id: "layouts", title: "Dispositions", items: layouts),
                ResultSection(id: "new", title: nil, items: [create]),
            ].filter { !$0.items.isEmpty }
        }
    }
}
