import AppKit
import SwiftUI

/// Disposition du contenu d'un écran.
enum ScreenLayout: Equatable {
    /// Une liste (ou des grilles, selon `ResultSection.columns`).
    case list
    /// Liste à gauche, détail de l'élément sélectionné à droite (presse-papiers, fichiers).
    case split(listWidth: CGFloat)
    /// Une vue propre à l'écran (`customView`) : formulaire, réponse de l'IA, traduction.
    case custom
}

/// Filtre de la barre de recherche, comme le menu déroulant de Raycast (⌘P).
struct ScreenFilter {
    struct Option: Identifiable, Equatable {
        let id: String
        let title: String
    }

    var options: [Option]
    var selected: String
    /// Le titre quand la valeur choisie n'est pas parmi les options (menus d'extensions).
    var placeholder: String = ""

    var selectedTitle: String { options.first { $0.id == selected }?.title ?? placeholder }
}

/// Un écran du lanceur. La recherche principale en est un ; les commandes en empilent d'autres.
/// Les sous-classes redéfinissent `sections(query:)`, ou `customView()` avec `layout = .custom`.
@MainActor
class LauncherScreen: Identifiable {
    let id: String
    var title: String
    var placeholder: String
    var icon: ItemIcon
    var layout: ScreenLayout = .list
    var filter: ScreenFilter?
    /// Masque le champ de recherche (formulaires) ; le titre de l'écran le remplace.
    var hidesSearchField = false
    /// Indicateur d'activité à droite du champ de recherche.
    var isLoading = false {
        didSet { if isLoading != oldValue { host?.screenStateChanged() } }
    }

    /// Le modèle qui affiche l'écran, pour qu'il se recalcule (résultats asynchrones).
    weak var host: LauncherModel?

    init(id: String, title: String, placeholder: String = "Rechercher…", icon: ItemIcon) {
        self.id = id
        self.title = title
        self.placeholder = placeholder
        self.icon = icon
    }

    func sections(query: String) -> [ResultSection] { [] }

    /// Appelé à chaque frappe, avant `sections(query:)` : pour lancer une recherche asynchrone.
    func queryDidChange(_ query: String) {}

    func didAppear() {}
    func didDisappear() {}

    /// L'élément sélectionné a changé (extensions : `onSelectionChange`, pages suivantes).
    func selectionDidChange(_ itemID: String?) {}

    /// Message quand la liste est vide.
    func emptyState(query: String) -> (symbol: String, message: String) {
        if isLoading { return ("hourglass", "Recherche…") }
        return query.isEmpty ? ("tray", "Rien à afficher") : ("magnifyingglass", "Aucun résultat pour « \(query) »")
    }

    /// La vue affichée quand `layout == .custom`.
    func customView() -> AnyView { AnyView(EmptyView()) }

    /// Actions de l'écran quand aucun élément n'est sélectionné (vues personnalisées).
    var screenActions: [ItemAction] { [] }

    /// Le texte de gauche de la barre du bas ; le titre de l'écran par défaut.
    var footerTitle: String? { nil }

    /// Clavier, avant le traitement par défaut. `true` : la touche est consommée.
    func handleKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool { false }

    /// Les touches ↑ ↓ ↵ vont-elles à la vue personnalisée plutôt qu'à la liste ?
    var customViewHandlesNavigation: Bool { false }

    /// Recalcule l'écran (à appeler après un changement de données).
    func reload() { host?.refreshIfShowing(self) }
}

/// Un écran de liste défini par des fermetures : la forme la plus courante.
@MainActor
final class ListScreen: LauncherScreen {
    private let provider: @MainActor (String) -> [ResultSection]
    private let onQuery: (@MainActor (String) -> Void)?
    private let empty: (@MainActor (String) -> (symbol: String, message: String))?
    var onAppear: (@MainActor () -> Void)?
    var onDisappear: (@MainActor () -> Void)?

    init(
        id: String,
        title: String,
        placeholder: String = "Rechercher…",
        icon: ItemIcon,
        layout: ScreenLayout = .list,
        filter: ScreenFilter? = nil,
        empty: (@MainActor (String) -> (symbol: String, message: String))? = nil,
        onQuery: (@MainActor (String) -> Void)? = nil,
        sections: @escaping @MainActor (String) -> [ResultSection]
    ) {
        provider = sections
        self.onQuery = onQuery
        self.empty = empty
        super.init(id: id, title: title, placeholder: placeholder, icon: icon)
        self.layout = layout
        self.filter = filter
    }

    override func sections(query: String) -> [ResultSection] { provider(query) }
    override func queryDidChange(_ query: String) { onQuery?(query) }
    override func didAppear() { onAppear?() }
    override func didDisappear() { onDisappear?() }

    override func emptyState(query: String) -> (symbol: String, message: String) {
        empty?(query) ?? super.emptyState(query: query)
    }
}

// MARK: - Formulaires

/// Champ d'un formulaire.
struct FormField: Identifiable {
    enum Kind {
        case text
        case secure
        case textArea(lines: Int)
        case dropdown([(value: String, title: String)])
        case checkbox(label: String)
        case date(includesTime: Bool)
        /// Texte d'aide, sans saisie.
        case info
        /// Raccourci clavier enregistré par la saisie (`HotKeyRecorder`).
        case hotkey
        /// Couleur au format « #RRGGBB ».
        case color
    }

    let id: String
    var label: String
    var kind: Kind
    var placeholder: String = ""
    var value: String = ""
    var info: String? = nil
}

/// Les valeurs d'un formulaire, modifiées par la vue.
@MainActor
final class FormState: ObservableObject {
    @Published var values: [String: String]
    @Published var error: String?

    init(fields: [FormField]) {
        values = Dictionary(fields.map { ($0.id, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    subscript(_ id: String) -> String {
        get { values[id] ?? "" }
        set { values[id] = newValue }
    }

    func bool(_ id: String) -> Bool { values[id] == "true" }

    func trimmed(_ id: String) -> String { self[id].trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Un formulaire dans le lanceur (créer un snippet, un lien rapide, un évènement…). ⌘↵ valide.
@MainActor
final class FormScreen: LauncherScreen {
    let fields: [FormField]
    let state: FormState
    let submitTitle: String
    private let submit: @MainActor (FormState) -> ActionOutcome
    /// Champ qui reçoit le focus à l'ouverture.
    var initialFocus: String?

    init(
        id: String,
        title: String,
        icon: ItemIcon,
        submitTitle: String = "Enregistrer",
        fields: [FormField],
        submit: @escaping @MainActor (FormState) -> ActionOutcome
    ) {
        self.fields = fields
        self.submitTitle = submitTitle
        self.submit = submit
        state = FormState(fields: fields)
        super.init(id: id, title: title, icon: icon)
        layout = .custom
        hidesSearchField = true
        initialFocus = fields.first { field in
            switch field.kind {
            case .info, .checkbox, .dropdown, .date, .hotkey, .color: false
            default: true
            }
        }?.id
    }

    func performSubmit() -> ActionOutcome { submit(state) }

    override func customView() -> AnyView { AnyView(FormScreenView(screen: self)) }

    override var screenActions: [ItemAction] {
        [ItemAction(title: submitTitle, symbol: "checkmark.circle", shortcut: KeyShortcut(keyCode: 36, modifiers: [.command], label: "↵")) { [weak self] in
            self?.performSubmit() ?? .stay
        }]
    }

    override func handleKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        if (event.keyCode == 36 || event.keyCode == 76), modifiers == .command {
            host?.apply(performSubmit())
            return true
        }
        return false
    }

    override var customViewHandlesNavigation: Bool { true }
}

/// Les arguments d'une commande, demandés avant de l'exécuter.
@MainActor
enum ArgumentsForm {
    static func screen(for item: ResultItem, prefilled: [String] = []) -> FormScreen? {
        guard let run = item.runWithArguments, !item.arguments.isEmpty else { return nil }
        let fields = item.arguments.enumerated().map { index, argument -> FormField in
            let value = index < prefilled.count ? prefilled[index] : argument.defaultValue
            let kind: FormField.Kind
            if !argument.options.isEmpty {
                kind = .dropdown(argument.options.map { ($0, $0) })
            } else {
                kind = argument.isSecure ? .secure : .text
            }
            let label = argument.name.prefix(1).uppercased() + argument.name.dropFirst()
            return FormField(id: "arg\(index)", label: label + (argument.isOptional ? "" : " *"), kind: kind, placeholder: argument.placeholder, value: value.isEmpty && !argument.options.isEmpty ? argument.options[0] : value)
        }
        let form = FormScreen(id: "arguments." + item.id, title: item.title, icon: item.icon, submitTitle: "Lancer", fields: fields) { state in
            var values: [String] = []
            for (index, argument) in item.arguments.enumerated() {
                let value = state.trimmed("arg\(index)")
                if value.isEmpty, !argument.isOptional {
                    state.error = "« \(argument.name) » est requis"
                    return .stay
                }
                values.append(value)
            }
            return run(values)
        }
        return form
    }
}
