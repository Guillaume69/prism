import AppKit
import Quartz
import SwiftUI

/// Arrête le processus d'une commande quand son écran disparaît pour de bon (libéré par le lanceur).
final class ExtensionReaper: @unchecked Sendable {
    weak var process: Process?

    func kill() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }
}

/// L'écran d'une commande d'extension : il affiche ce que l'extension rend (liste, grille, détail, formulaire, menu)
/// et lui renvoie la saisie, la sélection, les actions et le retour en arrière.
@MainActor
final class ExtensionScreen: LauncherScreen {
    let session: ExtensionSession
    private nonisolated let reaper: ExtensionReaper
    private(set) var view: ExtensionNode?
    var toast: ExtensionToast?
    private var failure: (message: String, stack: String)?
    let form = ExtensionFormModel()

    /// Les recherches envoyées à l'extension et pas encore revenues dans `searchText`.
    private var sentQueries: [String] = []
    private var lastDropdownValue: String?
    private var nodesByItemID: [String: ExtensionNode] = [:]
    private var orderedItemIDs: [String] = []
    private var currentQuery = ""
    private var requestedPage = -1

    init(session: ExtensionSession) {
        self.session = session
        reaper = session.reaper
        super.init(id: "extension.\(session.installed.id).\(session.command.name)", title: session.command.title,
                   placeholder: "Rechercher…", icon: session.installed.icon(for: session.command))
        isLoading = true
        session.screen = self
        session.onRender = { [weak self] view, depth in self?.render(view, depth: depth) }
        session.onError = { [weak self] message, stack in
            self?.failure = (message, stack)
            self?.layout = .custom
            self?.hidesSearchField = true
            self?.isLoading = false
            self?.host?.screenStateChanged()
        }
        session.onExit = { [weak self] status in
            guard let self, self.view == nil, self.failure == nil else { return }
            if status != 0 { self.failure = ("La commande s’est arrêtée (code \(status)).", "") }
            self.isLoading = false
            self.layout = .custom
            self.hidesSearchField = true
            self.host?.screenStateChanged()
        }
    }

    deinit { reaper.kill() }

    var installed: InstalledExtension { session.installed }

    // MARK: - Rendu

    private func render(_ newView: ExtensionNode?, depth: Int) {
        view = newView
        failure = nil
        guard let view = newView else {
            host?.screenStateChanged()
            return
        }
        title = view.string("navigationTitle") ?? session.command.title
        isLoading = view.bool("isLoading") ?? false
        switch view.type {
        case "list", "grid", "menubar":
            hidesSearchField = false
            layout = view.bool("isShowingDetail") == true ? .split(listWidth: 300) : .list
            placeholder = view.string("searchBarPlaceholder") ?? "Rechercher…"
            updateFilter(view.slot("searchBarAccessory"))
            // `searchText` contrôlé : les valeurs qui reviennent de la frappe sont des échos, en retard sur la saisie ;
            // seules celles que l'extension impose (effacement, texte sélectionné…) remplacent la recherche.
            if let controlled = view.string("searchText") {
                if let echo = sentQueries.lastIndex(of: controlled) {
                    sentQueries.removeFirst(echo + 1)
                } else if controlled != currentQuery {
                    session.log("recherche imposée par l’extension : « \(controlled) » (saisie : « \(currentQuery) »)")
                    currentQuery = controlled
                    host?.apply(.setQuery(controlled))
                }
            }
        case "form":
            layout = .custom
            hidesSearchField = true
            form.sync(with: view)
        default:
            layout = .custom
            hidesSearchField = true
        }
        if let host, host.screen === self {
            host.refreshIfShowing(self)
            host.screenStateChanged()
        }
        if depth > 1 { requestedPage = -1 }
    }

    private func updateFilter(_ dropdown: ExtensionNode?) {
        guard let dropdown, dropdown.type == "dropdown" else {
            filter = nil
            return
        }
        let options = Self.dropdownItems(dropdown).map { ScreenFilter.Option(id: $0.value, title: $0.title) }
        guard !options.isEmpty else { filter = nil; return }
        let controlled = dropdown.string("value")
        let current = filter?.selected
        let selected = controlled ?? current.flatMap { id in options.contains { $0.id == id } ? id : nil }
            ?? dropdown.string("defaultValue") ?? options[0].id
        filter = ScreenFilter(options: options, selected: selected, placeholder: dropdown.string("tooltip") ?? dropdown.string("placeholder") ?? "")
        if lastDropdownValue == nil {
            lastDropdownValue = selected
            if controlled == nil, let onChange = dropdown.handler("onChange") { session.call(onChange, [selected]) }
        }
    }

    static func dropdownItems(_ node: ExtensionNode) -> [(title: String, value: String)] {
        node.children.flatMap { child -> [(title: String, value: String)] in
            switch child.type {
            case "dropdown-item", "tagpicker-item": return [(child.string("title") ?? "", child.string("value") ?? "")]
            case "dropdown-section": return dropdownItems(child)
            default: return []
            }
        }
    }

    // MARK: - Listes, grilles, menus

    override func queryDidChange(_ query: String) {
        guard query != currentQuery || sentQueries.isEmpty else { return }
        currentQuery = query
        guard let view, ["list", "grid"].contains(view.type) else { return }
        if let handler = view.handler("onSearchTextChange") {
            session.log("recherche envoyée : « \(query) »")
            sentQueries.append(query)
            if sentQueries.count > 100 { sentQueries.removeFirst(sentQueries.count - 100) }
            session.call(handler, [query])
        }
    }

    override func sections(query: String) -> [ResultSection] {
        guard let view else { return [] }
        if let selected = filter?.selected, selected != lastDropdownValue {
            lastDropdownValue = selected
            if let dropdown = view.slot("searchBarAccessory"), let onChange = dropdown.handler("onChange") { session.call(onChange, [selected]) }
        }
        nodesByItemID = [:]
        orderedItemIDs = []
        let listActions = view.slot("actions")
        switch view.type {
        case "list":
            return listSections(view, query: query, listActions: listActions, grid: false)
        case "grid":
            return listSections(view, query: query, listActions: listActions, grid: true)
        case "menubar":
            return menuSections(view, query: query)
        default:
            return []
        }
    }

    /// Filtrage par Prism, sauf si l'extension filtre elle-même (`onSearchTextChange` sans `filtering`).
    private func filters(_ view: ExtensionNode) -> Bool {
        if let filtering = view["filtering"] as? Bool { return filtering }
        if view["filtering"] is [String: Any] { return true }
        return view.handler("onSearchTextChange") == nil
    }

    private func listSections(_ view: ExtensionNode, query: String, listActions: ExtensionNode?, grid: Bool) -> [ResultSection] {
        let filtering = filters(view) && !query.isEmpty
        let columns = grid ? Self.columns(view) : 1
        var sections: [ResultSection] = []
        var loose: [ResultItem] = []
        var index = 0
        func convert(_ node: ExtensionNode) -> ResultItem? {
            index += 1
            let item = self.item(node, index: index, grid: grid, listActions: listActions)
            guard !filtering || Self.matches(node, item: item, query: query) else { return nil }
            nodesByItemID[item.id] = node
            orderedItemIDs.append(item.id)
            return item
        }
        for child in view.content {
            switch child.type {
            case "list-section", "grid-section":
                let items = child.all(grid ? "grid-item" : "list-item").compactMap(convert)
                guard !items.isEmpty else { continue }
                let sectionColumns = grid ? Self.columns(child, fallback: columns) : 1
                sections.append(ResultSection(id: "s\(sections.count)", title: child.string("title").map { title in
                    child.string("subtitle").map { "\(title) · \($0)" } ?? title
                }, items: items, columns: sectionColumns, cellHeight: grid ? Self.cellHeight(sectionColumns) : 62))
            case "list-item", "grid-item":
                if let item = convert(child) { loose.append(item) }
            default:
                continue
            }
        }
        if !loose.isEmpty {
            sections.insert(ResultSection(id: "loose", title: nil, items: loose, columns: columns, cellHeight: grid ? Self.cellHeight(columns) : 62), at: 0)
        }
        if filtering {
            // Les meilleurs résultats d'abord, comme la recherche de Raycast, sauf demande de garder l'ordre des sections.
            let keepOrder = (view["filtering"] as? [String: Any])?["keepSectionOrder"] as? Bool ?? false
            if !keepOrder {
                sections = sections.map { section in
                    var sorted = section
                    sorted.items.sort { Self.score($0, query) > Self.score($1, query) }
                    return sorted
                }
            }
        }
        return sections
    }

    private static func columns(_ node: ExtensionNode, fallback: Int = 5) -> Int {
        if let columns = node.number("columns") { return max(1, min(8, Int(columns))) }
        switch node.string("itemSize") {
        case "small": return 8
        case "large": return 3
        case "medium": return 5
        default: return fallback
        }
    }

    private static func cellHeight(_ columns: Int) -> CGFloat {
        columns >= 7 ? 82 : columns >= 5 ? 112 : 160
    }

    private static func matches(_ node: ExtensionNode, item: ResultItem, query: String) -> Bool {
        score(item, query) > 0
    }

    private static func score(_ item: ResultItem, _ query: String) -> Double {
        let needle = query.normalizedForSearch
        let fields = [item.title, item.subtitle ?? ""] + item.keywords
        return fields.compactMap { Fuzzy.score(needle, $0) }.max() ?? 0
    }

    private func item(_ node: ExtensionNode, index: Int, grid: Bool, listActions: ExtensionNode?) -> ResultItem {
        let id = "x:" + (node.string("id") ?? "\(index)")
        let accessories = node["accessories"] as? [[String: Any]] ?? []
        var texts: [String] = []
        var tags: [String] = []
        for accessory in accessories {
            if let tag = accessory["tag"] {
                if let text = ExtensionValue.text(tag) { tags.append(text) } else if let date = ExtensionValue.date((tag as? [String: Any])?["value"] ?? tag) { tags.append(ExtensionValue.relative(date)) }
            } else if let date = ExtensionValue.date(accessory["date"]) ?? ExtensionValue.date((accessory["date"] as? [String: Any])?["value"]) {
                texts.append(ExtensionValue.relative(date))
            } else if let text = ExtensionValue.text(accessory["text"]) {
                texts.append(text)
            }
        }
        if grid, let accessory = node["accessory"] as? [String: Any], let text = ExtensionValue.text(accessory["tooltip"]) { texts.append(text) }
        var keywords = node["keywords"] as? [String] ?? []
        if let subtitle = node.string("subtitle") { keywords.append(subtitle) }
        let iconSource = grid ? node["content"] : node["icon"]
        let icon = ExtensionIcon.icon(iconSource, assets: installed.assets, fallback: grid ? .glyph("photo") : .none)
        var detail: ItemDetail?
        if let detailNode = node.slot("detail") {
            detail = ItemDetail(text: detailNode.string("markdown") ?? "", metadata: Self.metadataPairs(detailNode.slot("metadata")), isMarkdown: true)
        }
        let actionsNode = node.slot("actions") ?? listActions
        return ResultItem(
            id: id,
            title: node.string("title") ?? "",
            subtitle: grid ? node.string("subtitle") : node.string("subtitle"),
            icon: icon,
            accessory: texts.isEmpty ? nil : texts.joined(separator: " · "),
            tags: tags,
            style: grid ? .thumbnail : .row,
            keywords: keywords,
            detail: detail,
            usageKey: "",
            actions: actions(actionsNode)
        )
    }

    private func menuSections(_ view: ExtensionNode, query: String) -> [ResultSection] {
        var sections: [ResultSection] = []
        var index = 0
        func items(in node: ExtensionNode, prefix: String?) -> [ResultItem] {
            node.children.flatMap { child -> [ResultItem] in
                switch child.type {
                case "menubar-item":
                    index += 1
                    let title = child.string("title") ?? ""
                    let fullTitle = prefix.map { "\($0) › \(title)" } ?? title
                    if !query.isEmpty, Fuzzy.score(query.normalizedForSearch, fullTitle) == nil { return [] }
                    var actions: [ItemAction] = []
                    if let handler = child.handler("onAction") {
                        let session = session
                        actions.append(ItemAction(title: "Ouvrir", symbol: "arrow.right.circle") {
                            session.call(handler, [["type": "left-click"]])
                            return .stay
                        })
                    }
                    let item = ResultItem(id: "m\(index)", title: fullTitle, subtitle: child.string("subtitle"),
                                          icon: ExtensionIcon.icon(child["icon"], assets: installed.assets, fallback: .none),
                                          accessory: ExtensionValue.text(child["tooltip"]), usageKey: "", actions: actions, isDimmed: actions.isEmpty)
                    return [item]
                case "menubar-submenu":
                    return items(in: child, prefix: child.string("title"))
                default:
                    return []
                }
            }
        }
        let header = items(in: view, prefix: nil)
        if !header.isEmpty { sections.append(ResultSection(id: "menu", title: view.string("title") ?? view.string("tooltip"), items: header)) }
        for child in view.children where child.type == "menubar-section" {
            let found = items(in: child, prefix: nil)
            if !found.isEmpty { sections.append(ResultSection(id: "menu\(sections.count)", title: child.string("title"), items: found)) }
        }
        return sections
    }

    override func emptyState(query: String) -> (symbol: String, message: String) {
        if isLoading { return ("hourglass", "Chargement…") }
        if let empty = view?.all("list-empty").first ?? view?.all("grid-empty").first {
            let text = [empty.string("title"), empty.string("description")].compactMap { $0 }.joined(separator: "\n")
            return ("tray", text.isEmpty ? "Rien à afficher" : text)
        }
        return super.emptyState(query: query)
    }

    override func selectionDidChange(_ itemID: String?) {
        guard let view, let itemID, let node = nodesByItemID[itemID] else { return }
        if let handler = view.handler("onSelectionChange") { session.call(handler, [node.string("id") ?? NSNull()]) }
        // Pages suivantes : à cinq éléments de la fin.
        if let pagination = view["pagination"] as? [String: Any], pagination["hasMore"] as? Bool == true,
           let onLoadMore = ExtensionValue.handler(pagination["onLoadMore"]),
           let position = orderedItemIDs.firstIndex(of: itemID), position >= orderedItemIDs.count - 5, requestedPage != orderedItemIDs.count {
            requestedPage = orderedItemIDs.count
            session.call(onLoadMore)
        }
    }

    var selectedQuickLookPath: String? {
        guard let id = host?.selectedItem?.id, let node = nodesByItemID[id] else { return nil }
        return (node["quickLook"] as? [String: Any])?["path"] as? String
    }

    // MARK: - Actions

    static func metadataPairs(_ metadata: ExtensionNode?) -> [(label: String, value: String)] {
        guard let metadata else { return [] }
        return metadata.children.compactMap { child -> (label: String, value: String)? in
            switch child.type {
            case "metadata-label":
                return (child.string("title") ?? "", child.string("text") ?? "")
            case "metadata-link":
                return (child.string("title") ?? "", child.string("text") ?? child.string("target") ?? "")
            case "metadata-taglist":
                return (child.string("title") ?? "", child.children.compactMap { $0.string("text") }.joined(separator: ", "))
            default:
                return nil
            }
        }
    }

    /// Le panneau d'actions d'une extension : sections, sous-menus aplatis, raccourcis, style destructeur.
    func actions(_ panel: ExtensionNode?) -> [ItemAction] {
        var result: [ItemAction] = []
        if let toast {
            result += toast.actions
        }
        guard let panel else { return result }
        let session = session
        func visit(_ node: ExtensionNode, section: String?) {
            for child in node.children {
                switch child.type {
                case "action":
                    guard let handler = child.handler("onAction") else { continue }
                    var action = ItemAction(
                        title: child.string("title") ?? "Action",
                        symbol: ExtensionIcon.actionSymbol(child["icon"]),
                        shortcut: ExtensionShortcut.shortcut(child["shortcut"]),
                        isDestructive: child.string("style") == "destructive"
                    ) {
                        session.call(handler)
                        return .stay
                    }
                    action.section = section
                    result.append(action)
                case "action-section":
                    visit(child, section: child.string("title") ?? section)
                case "action-submenu":
                    if let onOpen = child.handler("onOpen") { session.call(onOpen) }
                    visit(child, section: child.string("title") ?? section)
                default:
                    visit(child, section: section)
                }
            }
        }
        visit(panel, section: panel.string("title"))
        return result
    }

    override var screenActions: [ItemAction] {
        if failure != nil {
            let installed = installed
            return [
                ItemAction(title: "Relancer la commande", symbol: "arrow.clockwise", shortcut: .refresh) { [weak self] in
                    guard let self else { return .stay }
                    return (try? ExtensionsFeature.screen(for: self.installed, command: self.session.command)).map { .replace($0) } ?? .stay
                },
                ItemAction(title: "Ouvrir le journal de l’extension", symbol: "doc.text.magnifyingglass") {
                    NSWorkspace.shared.open(ExtensionSession.logFile(for: installed))
                    return .close
                },
            ]
        }
        guard let view else { return [] }
        return actions(view.slot("actions"))
    }

    override var footerTitle: String? {
        if let toast {
            return [toast.title, toast.message].compactMap { $0 }.joined(separator: " — ")
        }
        return nil
    }

    // MARK: - Clavier

    override func handleKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        if event.keyCode == 53, modifiers.isEmpty, session.depth > 1, host?.isActionPanelOpen == false {
            session.pop()
            return true
        }
        if view?.type == "form", event.keyCode == 36 || event.keyCode == 76, modifiers == .command, let first = screenActions.first {
            host?.perform(first)
            return true
        }
        return false
    }

    override var customViewHandlesNavigation: Bool { view?.type == "form" || view?.type == "detail" || failure != nil }

    override func customView() -> AnyView {
        if let failure {
            return AnyView(ExtensionFailureView(message: failure.message, stack: failure.stack, log: ExtensionSession.logFile(for: installed)))
        }
        guard let view else { return AnyView(ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)) }
        switch view.type {
        case "detail":
            return AnyView(ExtensionDetailView(node: view, assets: installed.assets))
        case "form":
            return AnyView(ExtensionFormView(node: view, model: form, session: session, assets: installed.assets))
        default:
            return AnyView(EmptyView())
        }
    }
}

// MARK: - Détail

struct ExtensionDetailView: View {
    let node: ExtensionNode
    let assets: URL

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                ExtensionMarkdown(source: node.string("markdown") ?? "", assets: assets)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
            if let metadata = node.slot("metadata") {
                Divider()
                ScrollView {
                    ExtensionMetadataView(node: metadata, assets: assets)
                        .padding(14)
                }
                .frame(width: 250)
            }
        }
    }
}

/// Markdown avec ses images (`![](url)`), que le rendu de texte ne montre pas.
struct ExtensionMarkdown: View {
    let source: String
    let assets: URL

    private enum Block {
        case text(String)
        case image(URL, alt: String)
    }

    private var blocks: [Block] {
        var blocks: [Block] = []
        var text: [String] = []
        let pattern = try? NSRegularExpression(pattern: #"^\s*!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)\s*$"#)
        for line in source.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            if let match = pattern?.firstMatch(in: line, range: range),
               let altRange = Range(match.range(at: 1), in: line), let urlRange = Range(match.range(at: 2), in: line) {
                if !text.isEmpty { blocks.append(.text(text.joined(separator: "\n"))); text = [] }
                let raw = String(line[urlRange]).components(separatedBy: "?raycast-")[0]
                let url = raw.hasPrefix("http") ? URL(string: raw) : URL(fileURLWithPath: raw.hasPrefix("/") || raw.hasPrefix("~") ? ExtensionIcon.expand(raw.removingPercentEncoding ?? raw) : assets.appendingPathComponent(raw).path)
                if let url { blocks.append(.image(url, alt: String(line[altRange]))) }
            } else {
                text.append(line)
            }
        }
        if !text.isEmpty { blocks.append(.text(text.joined(separator: "\n"))) }
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    MarkdownText(text)
                case .image(let url, let alt):
                    ExtensionImage(url: url).help(alt)
                }
            }
        }
    }
}

struct ExtensionImage: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: min(image.size.width, 640), maxHeight: 420, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Theme.subtleFill).frame(width: 120, height: 80)
            }
        }
        .task(id: url) {
            if url.isFileURL {
                image = NSImage(contentsOf: url)
            } else if let (data, _) = try? await URLSession.shared.data(from: url) {
                image = NSImage(data: data)
            }
        }
    }
}

struct ExtensionMetadataView: View {
    let node: ExtensionNode
    let assets: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
                row(child)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ child: ExtensionNode) -> some View {
        switch child.type {
        case "metadata-separator":
            Divider()
        case "metadata-label":
            VStack(alignment: .leading, spacing: 3) {
                Text(child.string("title") ?? "").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    if child["icon"] != nil { ItemIconView(icon: ExtensionIcon.icon(child["icon"], assets: assets), size: 16) }
                    Text(child.string("text") ?? "").font(.system(size: 12.5))
                        .foregroundStyle(ExtensionColor.color((child["text"] as? [String: Any])?["color"]) ?? .primary)
                        .textSelection(.enabled)
                }
            }
        case "metadata-link":
            VStack(alignment: .leading, spacing: 3) {
                Text(child.string("title") ?? "").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                if let target = child.string("target"), let url = URL(string: target) {
                    Link(child.string("text") ?? target, destination: url).font(.system(size: 12.5))
                }
            }
        case "metadata-taglist":
            VStack(alignment: .leading, spacing: 5) {
                Text(child.string("title") ?? "").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    ForEach(Array(child.children.enumerated()), id: \.offset) { _, tag in
                        Text(tag.string("text") ?? "")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .foregroundStyle(ExtensionColor.color(tag["color"]) ?? .primary)
                            .background(Capsule().fill((ExtensionColor.color(tag["color"]) ?? .secondary).opacity(0.16)))
                    }
                }
            }
        default:
            EmptyView()
        }
    }
}

struct ExtensionFailureView: View {
    let message: String
    let stack: String
    let log: URL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Label("L’extension a rencontré une erreur", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.orange)
                Text(message).font(.system(size: 13)).textSelection(.enabled)
                if !stack.isEmpty {
                    Text(stack).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("Journal : \(log.path)").font(.system(size: 11)).foregroundStyle(.tertiary).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
    }
}

// MARK: - Formulaire

/// Les valeurs affichées d'un formulaire d'extension ; celles de l'extension l'emportent quand elles changent.
@MainActor
final class ExtensionFormModel: ObservableObject {
    @Published var values: [String: Any] = [:]
    private var lastFromHost: [String: String] = [:]

    func sync(with form: ExtensionNode) {
        for field in form.all("form-field") {
            guard let id = field.string("id") else { continue }
            let raw = field["value"]
            let fingerprint = Self.fingerprint(raw)
            if lastFromHost[id] != fingerprint {
                lastFromHost[id] = fingerprint
                values[id] = raw ?? NSNull()
            }
        }
    }

    private static func fingerprint(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "∅" }
        if let data = try? JSONSerialization.data(withJSONObject: ["v": value]), let text = String(data: data, encoding: .utf8) { return text }
        return String(describing: value)
    }

    func text(_ id: String) -> String { values[id] as? String ?? "" }
    func bool(_ id: String) -> Bool { values[id] as? Bool ?? false }
    func list(_ id: String) -> [String] { values[id] as? [String] ?? [] }
    func date(_ id: String) -> Date? { ExtensionValue.date(values[id]) }
}

struct ExtensionFormView: View {
    let node: ExtensionNode
    @ObservedObject var model: ExtensionFormModel
    let session: ExtensionSession
    let assets: URL
    @FocusState private var focused: String?

    private var formKey: Int { Int(node.number("formKey") ?? 0) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(node.content.enumerated()), id: \.offset) { _, child in
                    field(child)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            focused = node.all("form-field").first { ["textfield", "textarea", "password"].contains($0.string("kind") ?? "") }?.string("id")
        }
    }

    private func change(_ id: String, _ value: Any) {
        model.values[id] = value
        session.formChange(formKey: formKey, id: id, value: value)
    }

    @ViewBuilder
    private func field(_ child: ExtensionNode) -> some View {
        switch child.type {
        case "form-field":
            row(title: child.string("title") ?? "", error: child.string("error"), info: child.string("info")) {
                input(child)
            }
        case "form-description":
            row(title: child.string("title") ?? "", error: nil, info: nil) {
                Text(child.string("text") ?? "").font(.system(size: 12.5)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        case "form-separator":
            Divider()
        default:
            EmptyView()
        }
    }

    private func row<Content: View>(title: String, error: String?, info: String?, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                content()
                if let error, !error.isEmpty {
                    Text(error).font(.system(size: 11.5)).foregroundStyle(Palette.red)
                }
                if let info, !info.isEmpty {
                    Text(info).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func input(_ child: ExtensionNode) -> some View {
        let id = child.string("id") ?? ""
        switch child.string("kind") {
        case "password":
            SecureField(child.string("placeholder") ?? "", text: Binding(get: { model.text(id) }, set: { change(id, $0) }))
                .textFieldStyle(.roundedBorder).focused($focused, equals: id)
        case "textarea":
            TextEditor(text: Binding(get: { model.text(id) }, set: { change(id, $0) }))
                .font(.system(size: 13))
                .frame(minHeight: 80, maxHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.separator))
                .focused($focused, equals: id)
        case "checkbox":
            Toggle(child.string("label") ?? "", isOn: Binding(get: { model.bool(id) }, set: { change(id, $0) }))
                .toggleStyle(.checkbox)
        case "dropdown":
            let options = ExtensionScreen.dropdownItems(child)
            Picker("", selection: Binding(get: { model.text(id).isEmpty ? options.first?.value ?? "" : model.text(id) }, set: { change(id, $0) })) {
                ForEach(options, id: \.value) { option in Text(option.title).tag(option.value) }
            }
            .labelsHidden()
            .frame(maxWidth: 320, alignment: .leading)
        case "datepicker":
            HStack {
                DatePicker("", selection: Binding(get: { model.date(id) ?? Date() }, set: { change(id, ["$date": ISO8601DateFormatter.extensions.string(from: $0)]) }),
                           displayedComponents: child.string("type") == "date" ? [.date] : [.date, .hourAndMinute])
                    .labelsHidden()
                if model.date(id) != nil {
                    Button("Effacer") { change(id, NSNull()) }.buttonStyle(.link)
                }
            }
        case "tagpicker":
            let options = ExtensionScreen.dropdownItems(child)
            ExtensionTagPicker(options: options, selected: model.list(id)) { change(id, $0) }
        case "filepicker":
            HStack {
                Button("Choisir…") {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = child.bool("allowMultipleSelection") ?? true
                    panel.canChooseDirectories = child.bool("canChooseDirectories") ?? false
                    panel.canChooseFiles = child.bool("canChooseFiles") ?? true
                    AppContext.launcher?.keepOpenOnResign = true
                    defer { AppContext.launcher?.keepOpenOnResign = false }
                    if panel.runModal() == .OK { change(id, panel.urls.map(\.path)) }
                }
                Text(model.list(id).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
        default:
            TextField(child.string("placeholder") ?? "", text: Binding(get: { model.text(id) }, set: { change(id, $0) }))
                .textFieldStyle(.roundedBorder).focused($focused, equals: id)
        }
    }
}

struct ExtensionTagPicker: View {
    let options: [(title: String, value: String)]
    let selected: [String]
    let onChange: ([String]) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button {
                    var next = selected
                    if let index = next.firstIndex(of: option.value) { next.remove(at: index) } else { next.append(option.value) }
                    onChange(next)
                } label: {
                    if selected.contains(option.value) { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                }
            }
        } label: {
            let titles = options.filter { selected.contains($0.value) }.map(\.title)
            Text(titles.isEmpty ? "Aucun" : titles.joined(separator: ", ")).lineLimit(1)
        }
        .frame(maxWidth: 320, alignment: .leading)
    }
}

// MARK: - Choix demandés par l'API (ouvrir avec, date, Coup d'œil)

@MainActor
enum ExtensionPickers {
    static func openWith(_ path: String) -> LauncherScreen {
        let url = URL(fileURLWithPath: path)
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        return ListScreen(id: "extension.openWith", title: "Ouvrir avec…", placeholder: "Rechercher une application…", icon: .file(path)) { query in
            let items = apps.compactMap { app -> ResultItem? in
                let name = FileManager.default.displayName(atPath: app.path)
                guard query.isEmpty || Fuzzy.score(query.normalizedForSearch, name) != nil else { return nil }
                return ResultItem(id: app.path, title: name, icon: .file(app.path), actions: [
                    ItemAction(title: "Ouvrir", symbol: "arrow.up.forward.app") {
                        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                        return .close
                    },
                ])
            }
            return [ResultSection(id: "apps", title: nil, items: items)]
        }
    }

    static func pickDate(title: String, includesTime: Bool) -> Any {
        let alert = NSAlert()
        alert.messageText = title
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = includesTime ? [.yearMonthDay, .hourMinute] : [.yearMonthDay]
        picker.dateValue = Date()
        alert.accessoryView = picker
        alert.addButton(withTitle: "Choisir")
        alert.addButton(withTitle: "Annuler")
        AppContext.launcher?.keepOpenOnResign = true
        defer { AppContext.launcher?.keepOpenOnResign = false }
        guard alert.runModal() == .alertFirstButtonReturn else { return NSNull() }
        return ISO8601DateFormatter.extensions.string(from: picker.dateValue)
    }

    static func quickLook(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: ExtensionIcon.expand(path)))
    }
}

// MARK: - OAuth

/// L'autorisation OAuth des extensions : la page du fournisseur s'ouvre dans le navigateur
/// et revient vers `prism://oauth?code=…&state=…`.
@MainActor
enum ExtensionOAuth {
    private static var pending: [String: CheckedContinuation<String, Error>] = [:]

    static func authorize(_ url: URL) async throws -> String {
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
        return try await withCheckedThrowingContinuation { continuation in
            pending[state] = continuation
            NSWorkspace.shared.open(url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                if let waiting = pending.removeValue(forKey: state) {
                    waiting.resume(throwing: ExtensionSession.RequestError("Autorisation abandonnée"))
                }
            }
        }
    }

    static func handle(_ url: URL) -> Bool {
        guard url.host == "oauth" else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let state = items.first { $0.name == "state" }?.value ?? ""
        guard let continuation = pending.removeValue(forKey: state) ?? (pending.count == 1 ? pending.removeValue(forKey: pending.keys.first ?? "") : nil) else { return true }
        if let code = items.first(where: { $0.name == "code" })?.value {
            continuation.resume(returning: code)
        } else {
            continuation.resume(throwing: ExtensionSession.RequestError(items.first { $0.name == "error" }?.value ?? "Autorisation refusée"))
        }
        return true
    }
}
