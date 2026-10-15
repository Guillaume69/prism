import AppKit
import SwiftUI

@MainActor
final class LauncherModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    @Published private(set) var stack: [LauncherScreen]
    @Published private(set) var sections: [ResultSection] = []
    @Published private(set) var selectedID: String? {
        didSet {
            guard selectedID != oldValue else { return }
            resetInlineArguments()
            screen.selectionDidChange(selectedID)
        }
    }
    /// Arguments tapés dans la barre de recherche, à droite du texte, pour l'élément sélectionné (comme Raycast).
    @Published var inlineArguments: [String] = []
    /// L'argument qui a le focus (`nil` : le champ de recherche).
    @Published var argumentFocus: Int?
    @Published private(set) var isActionPanelOpen = false
    @Published private(set) var actionIndex = 0
    /// Filtre du panneau d'actions, tapé quand il est ouvert.
    @Published private(set) var actionFilter = ""
    @Published private(set) var toast: String?
    @Published private(set) var toastIsError = true
    /// Change à chaque nouvelle liste : la vue remonte alors en haut.
    @Published private(set) var resultsVersion = 0
    /// Change quand l'état d'un écran change sans nouvelle liste (chargement, vue personnalisée).
    @Published private(set) var screenVersion = 0

    var onClose: (() -> Void)?
    var focusSearch: (() -> Void)?
    var moveCaretToEnd: (() -> Void)?

    private var savedQueries: [String] = []
    private var toastWork: DispatchWorkItem?

    let root = RootScreen()

    init() {
        stack = [root]
        root.host = self
        let center = NotificationCenter.default
        for name in [Notification.Name.appCatalogDidChange, .clipboardDidChange, .prismDataDidChange] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
        }
    }

    // MARK: - Lecture

    var screen: LauncherScreen { stack.last ?? root }
    var isRoot: Bool { stack.count == 1 }
    var isSearching: Bool { screen.isLoading }

    /// Mode compact : seule la barre de recherche, tant que la recherche principale est vide.
    var isCompact: Bool {
        Preferences.shared.compactMode && isRoot && query.isEmpty && !isActionPanelOpen
    }

    /// Les favoris montrés en icônes dans le mode compact.
    var compactFavorites: [ResultItem] {
        guard isCompact, Preferences.shared.favoritesInCompactMode else { return [] }
        return sections.first { $0.id == "favorites" }?.items ?? []
    }

    var allItems: [ResultItem] { sections.flatMap(\.items) }

    var selectedItem: ResultItem? {
        guard let selectedID else { return nil }
        for section in sections {
            if let item = section.items.first(where: { $0.id == selectedID }) { return item }
        }
        return nil
    }

    /// Les actions de l'élément sélectionné, complétées de celles de configuration (favoris, alias, raccourci).
    var currentActions: [ItemAction] {
        guard let item = selectedItem else { return screen.screenActions }
        var actions = item.actions
        if item.isConfigurable { actions += CommandConfigStore.shared.actions(for: item) }
        return actions
    }

    var filteredActions: [ItemAction] {
        let filter = actionFilter.normalizedForSearch
        guard !filter.isEmpty else { return currentActions }
        return currentActions.filter { Fuzzy.score(filter, $0.title) != nil }
    }

    private var selectedPosition: (section: Int, item: Int)? {
        guard let selectedID else { return nil }
        for (sectionIndex, section) in sections.enumerated() {
            if let itemIndex = section.items.firstIndex(where: { $0.id == selectedID }) {
                return (sectionIndex, itemIndex)
            }
        }
        return nil
    }

    var isGridSelection: Bool {
        guard let position = selectedPosition else { return false }
        return sections[position.section].columns > 1
    }

    // MARK: - Cycle de vie

    func prepareForShow(reset: Bool) {
        isActionPanelOpen = false
        toast = nil
        AppCatalog.shared.reloadIfNeeded()
        if reset {
            popToRoot(clearQuery: true)
        } else {
            refresh(keepSelection: true)
        }
    }

    private func queryChanged() {
        if !Preferences.shared.searchHistory.contains(query) { historyIndex = -1 }
        actionFilter = ""
        screen.queryDidChange(trimmedQuery)
        refresh(keepSelection: false)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func refresh(keepSelection: Bool) {
        let current = screen
        sections = current.layout == .custom ? [] : current.sections(query: current is RootScreen ? query : trimmedQuery)
        screenVersion += 1
        if keepSelection, let selectedID, allItems.contains(where: { $0.id == selectedID }) { return }
        selectedID = sections.first?.items.first?.id
        actionIndex = 0
        isActionPanelOpen = false
        resultsVersion += 1
    }

    private var refreshScheduled = false

    /// Plusieurs changements de données d'affilée ne recalculent l'écran qu'une fois, au tour suivant :
    /// jamais pendant l'initialisation d'un magasin qui vient d'écrire.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh(keepSelection: true)
            }
        }
    }

    /// Un écran signale un changement : on ne recalcule que s'il est affiché.
    func refreshIfShowing(_ target: LauncherScreen) {
        guard target === screen else { return }
        refresh(keepSelection: true)
    }

    func screenStateChanged() {
        screenVersion += 1
    }

    // MARK: - Navigation entre écrans

    func push(_ newScreen: LauncherScreen, query newQuery: String = "") {
        savedQueries.append(query)
        screen.didDisappear()
        newScreen.host = self
        stack.append(newScreen)
        enter(newScreen, query: newQuery)
    }

    func replace(with newScreen: LauncherScreen, query newQuery: String = "") {
        guard !isRoot else { push(newScreen, query: newQuery); return }
        screen.didDisappear()
        newScreen.host = self
        stack[stack.count - 1] = newScreen
        enter(newScreen, query: newQuery)
    }

    private func enter(_ newScreen: LauncherScreen, query newQuery: String) {
        isActionPanelOpen = false
        actionFilter = ""
        newScreen.didAppear()
        if query == newQuery {
            newScreen.queryDidChange(trimmedQuery)
            refresh(keepSelection: false)
        } else {
            query = newQuery
        }
        focusSearch?()
    }

    func pop() {
        guard !isRoot else { return }
        screen.didDisappear()
        stack.removeLast()
        let previous = savedQueries.popLast() ?? ""
        isActionPanelOpen = false
        screen.didAppear()
        if query == previous { refresh(keepSelection: false) } else { query = previous }
        focusSearch?()
    }

    func popToRoot(clearQuery: Bool = false) {
        while !isRoot {
            screen.didDisappear()
            stack.removeLast()
        }
        savedQueries.removeAll()
        if clearQuery {
            if query.isEmpty { refresh(keepSelection: false) } else { query = "" }
        } else {
            refresh(keepSelection: false)
        }
    }

    // MARK: - Sélection

    /// Des champs d'arguments s'affichent dans la barre quand l'élément sélectionné en demande.
    var showsInlineArguments: Bool {
        guard isRoot, !query.isEmpty, let item = selectedItem else { return false }
        return !item.arguments.isEmpty && item.runWithArguments != nil
    }

    private func resetInlineArguments() {
        inlineArguments = selectedItem?.arguments.map(\.defaultValue) ?? []
        argumentFocus = nil
    }

    /// Tab : de champ en champ ; après le dernier, retour au champ de recherche.
    func focusNextArgument(backwards: Bool = false) {
        guard let item = selectedItem, !item.arguments.isEmpty else { return }
        if inlineArguments.count != item.arguments.count { inlineArguments = item.arguments.map(\.defaultValue) }
        let count = item.arguments.count
        switch (argumentFocus, backwards) {
        case (nil, false): argumentFocus = 0
        case (nil, true): argumentFocus = count - 1
        case (let index?, false): argumentFocus = index + 1 < count ? index + 1 : nil
        case (let index?, true): argumentFocus = index > 0 ? index - 1 : nil
        }
        if argumentFocus == nil { focusSearch?() }
    }

    func select(_ id: String) {
        selectedID = id
        isActionPanelOpen = false
    }

    func moveSelection(_ delta: Int) {
        if isActionPanelOpen {
            let count = filteredActions.count
            guard count > 0 else { return }
            actionIndex = (actionIndex + delta + count) % count
            return
        }
        if let position = selectedPosition, sections[position.section].columns > 1 {
            moveInGrid(position: position, rows: delta)
            return
        }
        step(delta)
    }

    func step(_ delta: Int) {
        let items = allItems
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == selectedID } ?? -1
        selectedID = items[max(0, min(items.count - 1, index + delta))].id
    }

    private func moveInGrid(position: (section: Int, item: Int), rows: Int) {
        let section = sections[position.section]
        let columns = section.columns
        let target = position.item + rows * columns
        if section.items.indices.contains(target) {
            selectedID = section.items[target].id
            return
        }
        if rows > 0 {
            let lastRowStart = (section.items.count - 1) / columns * columns
            if position.item < lastRowStart {
                selectedID = section.items.last?.id
            } else if position.section + 1 < sections.count {
                selectedID = sections[position.section + 1].items.first?.id
            }
        } else if position.section > 0 {
            let previous = sections[position.section - 1]
            let column = position.item % columns
            let lastRowStart = (previous.items.count - 1) / max(previous.columns, 1) * max(previous.columns, 1)
            let index = min(lastRowStart + column, previous.items.count - 1)
            selectedID = previous.items[previous.columns > 1 ? index : previous.items.count - 1].id
        }
    }

    // MARK: - Filtre de la barre de recherche

    func selectFilter(_ id: String) {
        guard var filter = screen.filter, filter.options.contains(where: { $0.id == id }) else { return }
        filter.selected = id
        screen.filter = filter
        refresh(keepSelection: false)
    }

    /// ⌘P : option suivante du filtre.
    func cycleFilter(_ delta: Int = 1) {
        guard let filter = screen.filter, !filter.options.isEmpty else { return }
        let index = filter.options.firstIndex { $0.id == filter.selected } ?? 0
        let next = filter.options[(index + delta + filter.options.count) % filter.options.count]
        selectFilter(next.id)
    }

    // MARK: - Actions

    func toggleActionPanel() {
        guard !currentActions.isEmpty else { return }
        isActionPanelOpen.toggle()
        actionIndex = 0
        actionFilter = ""
    }

    func closeActionPanel() {
        isActionPanelOpen = false
        actionFilter = ""
    }

    func typeInActionPanel(_ characters: String) {
        actionFilter += characters
        actionIndex = 0
    }

    func deleteInActionPanel() {
        guard !actionFilter.isEmpty else { return }
        actionFilter.removeLast()
        actionIndex = 0
    }

    func activate() {
        if isActionPanelOpen {
            let actions = filteredActions
            guard actions.indices.contains(actionIndex) else { return }
            perform(actions[actionIndex])
            return
        }
        if let item = selectedItem, !item.arguments.isEmpty {
            // Les arguments tapés dans la barre suffisent : on lance ; sinon le formulaire, prérempli.
            let values = item.arguments.indices.map { $0 < inlineArguments.count ? inlineArguments[$0].trimmingCharacters(in: .whitespaces) : "" }
            let complete = zip(item.arguments, values).allSatisfy { argument, value in argument.isOptional || !value.isEmpty }
            if showsInlineArguments, complete, let run = item.runWithArguments {
                record(item)
                argumentFocus = nil
                apply(run(values))
                return
            }
            if let form = ArgumentsForm.screen(for: item, prefilled: values) {
                record(item)
                push(form)
                return
            }
        }
        if let primary = currentActions.first {
            perform(primary)
        }
    }

    func activateTertiary() {
        let actions = currentActions
        guard actions.count > 2 else { return }
        perform(actions[2])
    }

    /// ⌘↑ ⌘↓ : au premier élément de la section précédente ou suivante.
    func jumpSection(_ delta: Int) {
        guard let position = selectedPosition else { return }
        let target = max(0, min(sections.count - 1, position.section + delta))
        if let first = sections[target].items.first { selectedID = first.id }
    }

    private var historyIndex = -1

    /// ↑ en haut d'une recherche vide : les recherches précédentes, de la plus récente à la plus ancienne.
    func recallSearchHistory() -> Bool {
        let history = Preferences.shared.searchHistory
        guard !history.isEmpty, query.isEmpty || history.contains(query) else { return false }
        historyIndex = min(historyIndex + 1, history.count - 1)
        query = history[historyIndex]
        moveCaretToEnd?()
        return true
    }

    func activateSecondary() {
        let actions = currentActions
        guard actions.count > 1 else { return }
        perform(actions[1])
    }

    func performShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let action = currentActions.first(where: { $0.shortcut?.matches(keyCode: keyCode, modifiers: modifiers) == true }) else {
            return false
        }
        perform(action)
        return true
    }

    /// La saisie de la recherche principale rejoint l'historique quand on lance quelque chose.
    private func rememberSearch() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard isRoot, !text.isEmpty else { return }
        var history = Preferences.shared.searchHistory
        history.removeAll { $0 == text }
        history.insert(text, at: 0)
        Preferences.shared.searchHistory = history
        historyIndex = -1
    }

    func perform(_ action: ItemAction) {
        rememberSearch()
        let item = selectedItem
        isActionPanelOpen = false
        actionFilter = ""
        let outcome = action.run()
        if let item { record(item) }
        apply(outcome)
    }

    private func record(_ item: ResultItem) {
        let key = item.usageKey ?? item.id
        if !key.isEmpty, !item.id.hasPrefix("fallback.") { UsageStore.shared.record(key) }
    }

    func apply(_ outcome: ActionOutcome) {
        switch outcome {
        case .close:
            close()
        case .stay:
            screenVersion += 1
        case .refresh:
            refresh(keepSelection: true)
        case .hud(let message):
            close()
            HUD.shared.show(message)
        case .toast(let message):
            showToast(message)
        case .push(let newScreen, let newQuery):
            push(newScreen, query: newQuery)
        case .replace(let newScreen, let newQuery):
            replace(with: newScreen, query: newQuery)
        case .pop:
            pop()
        case .popToRoot:
            popToRoot(clearQuery: true)
        case .setQuery(let newQuery):
            query = newQuery
            moveCaretToEnd?()
        case .then(let first, let second):
            apply(first)
            apply(second)
        }
    }

    func escape() {
        if argumentFocus != nil {
            argumentFocus = nil
            focusSearch?()
            return
        }
        if isActionPanelOpen {
            closeActionPanel()
        } else if !isRoot {
            if Preferences.shared.escapeClosesCompletely {
                close()
            } else {
                pop()
            }
        } else if !query.isEmpty {
            query = ""
        } else {
            close()
        }
    }

    func close() {
        onClose?()
    }

    func showToast(_ message: String, isError: Bool = true) {
        toast = message
        toastIsError = isError
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.toast = nil }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}
