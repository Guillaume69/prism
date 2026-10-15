import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Recherche de fichiers par Spotlight (`NSMetadataQuery`), dans les portées choisies dans les réglages.
@MainActor
final class FileSearcher {
    static let shared = FileSearcher()

    /// Résultats partiels pendant la collecte, puis définitifs (`true`).
    var onResults: (([URL], Bool) -> Void)?

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?
    private let limit: Int

    init(limit: Int = 60) {
        self.limit = limit
    }

    func search(_ text: String, debounce: Bool = true) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.start(text.trimmingCharacters(in: .whitespaces)) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (debounce ? 0.15 : 0), execute: work)
    }

    func stop() {
        pending?.cancel()
        query?.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        query = nil
    }

    private func start(_ text: String) {
        stop()
        let query = NSMetadataQuery()
        if text.isEmpty {
            query.predicate = NSPredicate(fromMetadataQueryString: "kMDItemLastUsedDate >= $time.today(-14)")
        } else {
            let byName = NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(text)*")
            if FilesSettings.shared.contentSearch, text.count >= 3 {
                // Le contenu indexé par Spotlight : texte des documents, PDF, e-mails…
                let byContent = NSPredicate(format: "%K CONTAINS[cd] %@", "kMDItemTextContent", text)
                query.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [byName, byContent])
            } else {
                query.predicate = byName
            }
        }
        query.searchScopes = FilesSettings.shared.searchScopes
        query.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        query.notificationBatchingInterval = 0.15
        let center = NotificationCenter.default
        // Spotlight peut mettre plusieurs secondes à tout réunir : on montre les premiers résultats aussitôt.
        observers.append(center.addObserver(forName: .NSMetadataQueryGatheringProgress, object: query, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.collect(finished: false) }
        })
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.collect(finished: true) }
            })
        }
        self.query = query
        query.start()
    }

    private func collect(finished: Bool) {
        guard let query else { return }
        query.disableUpdates()
        let settings = FilesSettings.shared
        var urls: [URL] = []
        var index = 0
        let count = min(query.resultCount, 5_000)
        while index < count, urls.count < limit {
            if let item = query.result(at: index) as? NSMetadataItem,
               let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
               !settings.isExcluded(path) {
                urls.append(URL(fileURLWithPath: path))
            }
            index += 1
        }
        query.enableUpdates()
        onResults?(urls, finished)
    }
}

// MARK: - Éléments et actions

@MainActor
enum FileActions {
    /// Toutes les actions sur un fichier ou un dossier. `onChange` : le contenu du dossier a changé.
    static func actions(for url: URL, isDirectory: Bool, browse: Bool = true, onChange: @escaping @MainActor () -> Void = {}) -> [ItemAction] {
        let path = url.path
        let name = url.lastPathComponent
        var actions: [ItemAction] = []
        if isDirectory {
            actions.append(ItemAction(title: "Ouvrir dans le Finder", symbol: "folder") {
                NSWorkspace.shared.open(url)
                return .close
            })
            if browse { actions.append(browseAction(url)) }
            actions.append(Actions.reveal(path))
        } else {
            actions.append(Actions.open(path))
            actions.append(Actions.reveal(path))
        }
        actions.append(ItemAction(title: "Ouvrir avec…", symbol: "arrow.up.right.square", shortcut: .openWith) {
            .push(OpenWith.screen(for: url))
        })
        actions.append(QuickLookPreview.action { [url] })
        let terminal = TerminalApp.preferred
        actions.append(ItemAction(title: "Ouvrir dans \(terminal.title)", symbol: "terminal", shortcut: .openTerminal) {
            terminal.open(isDirectory ? url : url.deletingLastPathComponent())
            return .close
        })

        actions.append(ItemAction(title: "Copier le fichier", symbol: "doc.on.doc", shortcut: KeyShortcut(keyCode: 8, modifiers: [.command, .option, .shift], label: "C"), section: "Copier") {
            Pasteboard.copy(files: [url])
            return .hud("Fichier copié")
        })
        actions.append(ItemAction(title: "Copier le chemin", symbol: "link", shortcut: .copyPath, section: "Copier") {
            Pasteboard.copy(path)
            return .hud("Chemin copié")
        })
        actions.append(ItemAction(title: "Copier le nom", symbol: "textformat", shortcut: .copyName, section: "Copier") {
            Pasteboard.copy(name)
            return .hud("Nom copié")
        })

        actions.append(ItemAction(title: "Dupliquer", symbol: "plus.square.on.square", shortcut: .duplicate, section: "Fichier") {
            do {
                let copy = try FileOps.duplicate(url)
                onChange()
                HUD.shared.show("« \(copy.lastPathComponent) » créé")
                return .refresh
            } catch {
                return .toast("Copie impossible : \(error.localizedDescription)")
            }
        })
        if let createQuicklink = AppHooks.createQuicklink {
            actions.append(ItemAction(title: "Enregistrer comme lien rapide", symbol: "link.badge.plus", section: "Fichier") {
                createQuicklink(url.absoluteString, FileOps.displayName(url))
            })
        }
        actions.append(ItemAction(title: "Partager…", symbol: "square.and.arrow.up", shortcut: .share, section: "Fichier") {
            SharePicker.shared.show([url])
        })
        if !isDirectory, let send = AppHooks.sendToAIChat,
           let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType, FileInfo.isText(type) {
            actions.append(ItemAction(title: "Envoyer à l’IA", symbol: "sparkles", shortcut: .toAI, section: "Fichier") {
                guard let text = FileInfo.fullText(url) else { return .toast("Fichier illisible") }
                return send("À propos du fichier « \(name) » :", ["Fichier « \(name) » :\n\n" + text])
            })
        }
        actions.append(trashAction(url, onChange: onChange))
        return actions
    }

    static func browseAction(_ url: URL) -> ItemAction {
        ItemAction(title: "Parcourir le dossier", symbol: "arrow.turn.down.right") {
            .push(FolderScreen(folder: url))
        }
    }

    static func trashAction(_ url: URL, onChange: @escaping @MainActor () -> Void) -> ItemAction {
        let name = url.lastPathComponent
        return ItemAction(title: "Mettre à la corbeille", symbol: "trash", shortcut: .removeEntry, isDestructive: true, section: "Fichier") {
            .push(DestructiveConfirmScreen(
                title: "Mettre à la corbeille ?",
                message: "« \(name) » sera placé dans la corbeille. Vous pourrez l’en sortir depuis le Finder.",
                confirmTitle: "Mettre à la corbeille"
            ) {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    onChange()
                    HUD.shared.show("« \(name) » mis à la corbeille", symbol: "trash.fill")
                    return .refresh
                } catch {
                    return .toast("Impossible de déplacer le fichier : \(error.localizedDescription)")
                }
            })
        }
    }
}

@MainActor
enum FileItems {
    /// Un fichier dans une liste à détail : aperçu, métadonnées, toutes les actions.
    static func item(for url: URL, idPrefix: String = "file:", showsFolder: Bool = true, onChange: @escaping @MainActor () -> Void = {}) -> ResultItem {
        let isDirectory = FileOps.isDirectory(url)
        return ResultItem(
            id: idPrefix + url.path,
            title: url.path == "/" ? "/" : url.lastPathComponent,
            subtitle: showsFolder ? FileOps.abbreviated(url.deletingLastPathComponent().path) : nil,
            icon: .file(url.path),
            detail: FilePreviewCache.shared.detail(for: url),
            usageKey: "",
            actions: FileActions.actions(for: url, isDirectory: isDirectory, onChange: onChange)
        )
    }

    /// L'URL d'un élément de fichier (identifiant « préfixe:/chemin »).
    static func url(of item: ResultItem?) -> URL? {
        guard let item, let range = item.id.range(of: ":/") else { return nil }
        return URL(fileURLWithPath: String(item.id[item.id.index(after: range.lowerBound)...]))
    }
}

// MARK: - Écrans

/// L'écran « Rechercher des fichiers » : Spotlight au fil de la frappe, fichiers récents sans saisie,
/// détail à droite (aperçu, métadonnées).
@MainActor
final class FilesScreen: LauncherScreen {
    private var results: [URL] = []

    init() {
        super.init(id: "files", title: "Fichiers", placeholder: "Rechercher des fichiers…", icon: .symbol("doc.text.magnifyingglass", Palette.blue))
        layout = .split(listWidth: 330)
    }

    override func didAppear() {
        if FeatureDemo.isActive { return }
        FileSearcher.shared.onResults = { [weak self] urls, finished in
            guard let self else { return }
            self.results = urls
            if finished || !urls.isEmpty { self.isLoading = !finished }
            self.reload()
        }
    }

    override func didDisappear() {
        guard !FeatureDemo.isActive else { return }
        FileSearcher.shared.stop()
        FileSearcher.shared.onResults = nil
        isLoading = false
    }

    override func queryDidChange(_ query: String) {
        if FeatureDemo.isActive {
            results = FilesDemo.files(matching: query)
            return
        }
        isLoading = true
        FileSearcher.shared.search(query)
    }

    override func sections(query: String) -> [ResultSection] {
        guard !results.isEmpty else { return [] }
        FilePreviewCache.shared.prefetch(results) { [weak self] in self?.reload() }
        let items = results.map { FileItems.item(for: $0) { [weak self] in self?.queryDidChange(query) } }
        return [ResultSection(id: "files", title: query.isEmpty ? "Utilisés récemment" : "Fichiers", items: items)]
    }

    override func emptyState(query: String) -> (symbol: String, message: String) {
        if isLoading { return ("hourglass", "Recherche…") }
        return query.isEmpty ? ("doc.text.magnifyingglass", "Tapez un nom de fichier.") : ("magnifyingglass", "Aucun fichier pour « \(query) »")
    }

    /// ⇥ ou → (champ vide) entre dans le dossier sélectionné.
    override func handleKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let host, modifiers.isEmpty, event.keyCode == 48 || (event.keyCode == 124 && host.query.isEmpty),
              let url = FileItems.url(of: host.selectedItem), FileOps.isDirectory(url) else { return false }
        host.push(FolderScreen(folder: url))
        return true
    }
}

/// Le contenu d'un dossier, trié par date ou par nom (⌘P). ⇥ ou → entre dans un sous-dossier ;
/// ⇧⇥, ← ou ⌫ (champ vide) remontent au dossier parent.
@MainActor
final class FolderScreen: LauncherScreen {
    private(set) var folder: URL
    private var listing: [URL]?

    init(folder: URL) {
        self.folder = folder
        super.init(id: "folder", title: FileOps.displayName(folder), placeholder: "Rechercher dans le dossier…", icon: .file(folder.path))
        layout = .split(listWidth: 330)
        filter = ScreenFilter(options: [
            .init(id: "modified", title: "Date de modification"),
            .init(id: "created", title: "Date de création"),
            .init(id: "name", title: "Nom"),
        ], selected: FilesSettings.shared.folderSort)
    }

    override func didAppear() { listing = nil }

    private func entries() -> [URL] {
        if let listing { return listing }
        let options: FileManager.DirectoryEnumerationOptions = FilesSettings.shared.showHidden ? [] : [.skipsHiddenFiles]
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: options)) ?? []
        listing = urls
        return urls
    }

    private func sorted(_ urls: [URL], by sort: String) -> [URL] {
        if sort == "name" {
            return urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        let created = sort == "created"
        let dates = Dictionary(urls.map { url -> (String, Date) in
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            return (url.path, (created ? values?.creationDate : values?.contentModificationDate) ?? .distantPast)
        }, uniquingKeysWith: { first, _ in first })
        return urls.sorted { (dates[$0.path] ?? .distantPast) > (dates[$1.path] ?? .distantPast) }
    }

    override func sections(query: String) -> [ResultSection] {
        let sort = filter?.selected ?? "modified"
        if FilesSettings.shared.folderSort != sort, !FeatureDemo.isHeadless { FilesSettings.shared.folderSort = sort }
        let normalized = query.normalizedForSearch
        let all = entries()
        let urls: [URL]
        if normalized.isEmpty {
            urls = sorted(all, by: sort)
        } else {
            urls = all.compactMap { url in Fuzzy.score(normalized, url.lastPathComponent).map { (url, $0) } }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }
        let shown = Array(urls.prefix(500))
        FilePreviewCache.shared.prefetch(shown) { [weak self] in self?.reload() }
        let items = shown.map { url in
            FileItems.item(for: url, showsFolder: false) { [weak self] in self?.listing = nil }
        }
        let title = FileOps.abbreviated(folder.path) + " · \(all.count) élément\(all.count > 1 ? "s" : "")"
        return items.isEmpty ? [] : [ResultSection(id: "folder", title: title, items: items)]
    }

    override func emptyState(query: String) -> (symbol: String, message: String) {
        query.isEmpty ? ("folder", "Ce dossier est vide.") : ("magnifyingglass", "Rien dans ce dossier pour « \(query) »")
    }

    override var footerTitle: String? { FileOps.abbreviated(folder.path) }

    /// Change de dossier sans empiler d'écran ; en remontant, le dossier quitté reste sélectionné.
    func navigate(to url: URL, select child: URL? = nil) {
        folder = url
        listing = nil
        title = FileOps.displayName(url)
        icon = .file(url.path)
        guard let host else { return }
        if host.query.isEmpty { host.refresh(keepSelection: false) } else { host.query = "" }
        if let child { host.select("file:" + child.path) }
    }

    override func handleKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let host else { return false }
        let empty = host.query.isEmpty
        let enter = modifiers.isEmpty && (event.keyCode == 48 || (event.keyCode == 124 && empty))
        let up = (modifiers == .shift && event.keyCode == 48) || (modifiers.isEmpty && empty && (event.keyCode == 51 || event.keyCode == 123))
        if enter {
            guard let url = FileItems.url(of: host.selectedItem), FileOps.isDirectory(url) else { return false }
            navigate(to: url)
            return true
        }
        if up, folder.path != "/" {
            navigate(to: folder.deletingLastPathComponent(), select: folder)
            return true
        }
        return false
    }
}

// MARK: - Chemins tapés dans la recherche principale

/// Complétion des chemins (« ~/Doc » → « ~/Documents »), sans état : testée par `--selftest`.
enum PathCompletion {
    struct Result {
        var exact: URL?
        var matches: [URL]
        /// La saisie jusqu'au dernier « / », pour compléter.
        var base: String
    }

    static func isPathQuery(_ query: String) -> Bool {
        query == "~" || query.hasPrefix("~/") || query.hasPrefix("/")
    }

    static func expand(_ query: String, home: String) -> String {
        if query == "~" { return home + "/" }
        if query.hasPrefix("~/") { return home + String(query.dropFirst(1)) }
        return query
    }

    static func complete(_ query: String, home: String, showHidden: Bool, limit: Int = 8) -> Result? {
        guard isPathQuery(query) else { return nil }
        let expanded = expand(query, home: home)
        let directory: String
        let prefix: String
        if expanded.hasSuffix("/") {
            directory = expanded
            prefix = ""
        } else {
            directory = (expanded as NSString).deletingLastPathComponent
            prefix = (expanded as NSString).lastPathComponent
        }
        let base: String
        if query == "~" {
            base = "~/"
        } else if let slash = query.lastIndex(of: "/") {
            base = String(query[...slash])
        } else {
            base = query
        }
        let fileManager = FileManager.default
        let exactPath = expanded.count > 1 && expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
        let exact = fileManager.fileExists(atPath: exactPath) ? URL(fileURLWithPath: exactPath) : nil
        let normalizedPrefix = prefix.normalizedForSearch
        let names = ((try? fileManager.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { name in
                guard showHidden || prefix.hasPrefix(".") || !name.hasPrefix(".") else { return false }
                return name.normalizedForSearch.hasPrefix(normalizedPrefix) && !(exact != nil && name == prefix)
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let matches = names.prefix(limit).map { URL(fileURLWithPath: (directory as NSString).appendingPathComponent($0)) }
        return Result(exact: exact, matches: matches, base: base)
    }
}

/// Recherche Spotlight de la recherche principale : asynchrone, gardée en cache par saisie.
@MainActor
final class RootFileSearch {
    static let shared = RootFileSearch()

    private let searcher = FileSearcher(limit: 5)
    private var cache: [String: [URL]] = [:]
    private var running: String?

    private init() {
        searcher.onResults = { [weak self] urls, finished in
            guard let self, let query = self.running else { return }
            guard finished || urls.count >= 5 else { return }
            if self.cache.count > 60 { self.cache.removeAll() }
            self.cache[query] = urls
            if finished { self.running = nil }
            AppContext.launcher?.model.root.reload()
        }
    }

    /// Les résultats déjà trouvés pour cette saisie ; sinon lance la recherche et renvoie `nil`.
    func results(for query: String) -> [URL]? {
        if let cached = cache[query] { return cached }
        if running != query {
            running = query
            searcher.search(query)
        }
        return nil
    }
}

@MainActor
enum FilesFeature: PrismFeature {
    static var commands: [ResultItem] {
        [Command.screen("files", "Rechercher des fichiers", subtitle: "Spotlight", symbol: "doc.text.magnifyingglass", color: Palette.blue, keywords: ["search files", "fichier", "documents", "finder"]) { FilesScreen() }]
    }

    /// Un chemin tapé (« ~/Documents », « /Applications/… ») : le dossier ou le fichier, puis les complétions.
    static func topSections(query: String) -> [ResultSection] {
        let home = FeatureDemo.isActive ? FilesDemo.home.path : NSHomeDirectory()
        guard let result = PathCompletion.complete(query, home: home, showHidden: FilesSettings.shared.showHidden) else { return [] }
        var items: [ResultItem] = []
        if let exact = result.exact {
            var item = FileItems.item(for: exact, idPrefix: "path:")
            item.title = FileOps.displayName(exact)
            item.subtitle = FileOps.abbreviated(exact.path)
            item.accessory = FileOps.isDirectory(exact) ? "Dossier" : "Fichier"
            item.detail = nil
            items.append(item)
        }
        for url in result.matches {
            let isDirectory = FileOps.isDirectory(url)
            let completion = result.base + url.lastPathComponent + (isDirectory ? "/" : "")
            let complete = ItemAction(title: "Compléter le chemin", symbol: "arrow.right.to.line") { .setQuery(completion) }
            var actions = FileActions.actions(for: url, isDirectory: isDirectory)
            actions.insert(complete, at: isDirectory ? 0 : 2)
            items.append(ResultItem(
                id: "path:" + url.path,
                title: url.lastPathComponent,
                subtitle: FileOps.abbreviated(url.deletingLastPathComponent().path),
                icon: .file(url.path),
                accessory: isDirectory ? "Dossier" : nil,
                usageKey: "",
                actions: actions
            ))
        }
        return items.isEmpty ? [] : [ResultSection(id: "path", title: "Chemin", items: items)]
    }

    static func extraSections(query: String) -> [ResultSection] {
        guard Preferences.shared.filesInRootSearch, !FeatureDemo.isHeadless, query.count >= 2, !PathCompletion.isPathQuery(query),
              let urls = RootFileSearch.shared.results(for: query), !urls.isEmpty else { return [] }
        let items = urls.prefix(5).map { url -> ResultItem in
            var item = FileItems.item(for: url, idPrefix: "rootfile:")
            item.detail = nil
            return item
        }
        return [ResultSection(id: "root-files", title: "Fichiers", items: items)]
    }

    static func fallbacks(query: String) -> [ResultItem] {
        [ResultItem(
            id: "fallback.files",
            title: "Rechercher des fichiers",
            subtitle: query,
            icon: .symbol("doc.text.magnifyingglass", Palette.blue),
            accessory: "Commande",
            actions: [ItemAction(title: "Rechercher des fichiers", symbol: "doc.text.magnifyingglass") { .push(FilesScreen(), query: query) }]
        )]
    }

    static var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "files", title: "Fichiers", symbol: "doc.text.magnifyingglass", color: Palette.blue, order: 40) { AnyView(FilesSettingsView()) }]
    }

    /// `prism://files?q=texte` cherche ; `prism://files/browse?path=~/Documents` ouvre un dossier.
    static func handle(url: URL) -> Bool {
        guard url.host == "files", let launcher = AppContext.launcher else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        launcher.show(reset: true)
        if url.path == "/browse" {
            let path = (items.first { $0.name == "path" }?.value ?? "~") as NSString
            launcher.model.push(FolderScreen(folder: URL(fileURLWithPath: path.expandingTildeInPath)))
        } else {
            launcher.model.push(FilesScreen(), query: items.first { $0.name == "q" }?.value ?? "")
        }
        return true
    }

    static func selfTest(_ check: (Bool, String) -> Void) {
        check(FileOps.duplicateName(for: "Rapport.pdf", isDirectory: false) { _ in false } == "Rapport copie.pdf", "nom d’une copie")
        let taken: Set<String> = ["Rapport copie.pdf", "Rapport copie 2.pdf"]
        check(FileOps.duplicateName(for: "Rapport.pdf", isDirectory: false) { taken.contains($0) } == "Rapport copie 3.pdf", "copie numérotée")
        check(FileOps.duplicateName(for: "Projet.v2", isDirectory: true) { _ in false } == "Projet.v2 copie", "copie d’un dossier à point")

        let patterns = FilesSettings.defaultIgnoredPatterns + ["*.xcarchive"]
        check(FileFilter.isExcluded("/Users/a/web/node_modules/react/index.js", patterns: patterns, showHidden: false), "node_modules ignoré")
        check(!FileFilter.isExcluded("/Users/a/Documents/node_modules.txt", patterns: patterns, showHidden: false), "un fichier qui porte le nom d’un motif reste")
        check(FileFilter.isExcluded("/Users/a/Archives/App.xcarchive/Info.plist", patterns: patterns, showHidden: false), "motif avec joker")
        check(FileFilter.isExcluded("/Users/a/.config/fish/config.fish", patterns: patterns, showHidden: false), "fichiers cachés écartés")
        check(!FileFilter.isExcluded("/Users/a/.config/fish/config.fish", patterns: patterns, showHidden: true), "fichiers cachés montrés sur demande")

        check(PathCompletion.isPathQuery("~/Doc") && PathCompletion.isPathQuery("/Applications") && !PathCompletion.isPathQuery("docs"), "saisie de chemin reconnue")
        check(PathCompletion.expand("~/Documents", home: "/Users/test") == "/Users/test/Documents", "tilde développé")

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("prism-selftest-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: root.appendingPathComponent("Alpha"), withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: root.appendingPathComponent("Beta"), withIntermediateDirectories: true)
        fileManager.createFile(atPath: root.appendingPathComponent("alphabet.txt").path, contents: Data("abc".utf8))
        fileManager.createFile(atPath: root.appendingPathComponent(".cache").path, contents: Data())
        defer { try? fileManager.removeItem(at: root) }
        let base = root.path
        let partial = PathCompletion.complete(base + "/al", home: "/nowhere", showHidden: false)
        check(partial?.matches.map(\.lastPathComponent) == ["Alpha", "alphabet.txt"], "complétion d’un début de nom, sans casse")
        check(partial?.base == base + "/", "complétion : base de la saisie")
        let listing = PathCompletion.complete(base + "/", home: "/nowhere", showHidden: false)
        check(listing?.matches.count == 3 && listing?.exact?.path == base, "contenu d’un dossier, sans fichier caché")
        check(PathCompletion.complete(base + "/.", home: "/nowhere", showHidden: false)?.matches.map(\.lastPathComponent) == [".cache"], "fichier caché quand on tape le point")
        let exact = PathCompletion.complete(base + "/Beta", home: "/nowhere", showHidden: false)
        check(exact?.exact?.lastPathComponent == "Beta" && exact?.matches.isEmpty == true, "chemin exact sans doublon")
        let tilde = PathCompletion.complete("~/", home: base, showHidden: false)
        check(tilde?.exact?.path == base && tilde?.matches.count == 3, "« ~/ » liste le dossier personnel")

        let folder = FolderScreen(folder: root)
        folder.filter?.selected = "name"
        let names = folder.sections(query: "").first?.items.map(\.title)
        check(names == ["alphabet.txt", "Alpha", "Beta"].sorted { $0.localizedStandardCompare($1) == .orderedAscending }, "dossier parcouru : trié par nom, sans fichier caché")
        check(folder.sections(query: "bet").first?.items.first?.title == "Beta", "dossier parcouru : recherche dans le dossier")
    }
}
