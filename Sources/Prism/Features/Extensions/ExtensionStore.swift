import AppKit

/// Une fiche du Store de Raycast (`https://www.raycast.com/api/v1/store_listings`).
struct StoreListing: Decodable, Identifiable {
    struct Person: Decodable {
        let name: String?
        let handle: String
    }

    struct Icons: Decodable {
        let light: String?
        let dark: String?
    }

    struct CommandInfo: Decodable {
        let name: String
        let title: String
        let subtitle: String?
        let description: String?
        let mode: String?
    }

    let id: String
    let name: String
    let title: String
    let description: String?
    let author: Person
    let owner: Person?
    let downloadCount: Int?
    let commitSHA: String?
    let downloadURL: String?
    let storeURL: String?
    let icons: Icons?
    let commands: [CommandInfo]?
    let categories: [String]?
    let platforms: [String]?

    enum CodingKeys: String, CodingKey {
        case id, name, title, description, author, owner, icons, commands, categories, platforms
        case downloadCount = "download_count"
        case commitSHA = "commit_sha"
        case downloadURL = "download_url"
        case storeURL = "store_url"
    }

    /// L'auteur qui publie l'extension (l'organisation quand il y en a une) : la clé du dossier d'installation.
    var publisher: String { owner?.handle ?? author.handle }
}

/// Le Store d'extensions de Raycast : recherche, téléchargement et installation des paquets construits.
@MainActor
enum ExtensionStore {
    static let base = "https://www.raycast.com/api/v1/store_listings"

    private struct Page: Decodable { let data: [StoreListing] }

    static func listings(query: String) async throws -> [StoreListing] {
        var components: URLComponents?
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            components = URLComponents(string: base)
            components?.queryItems = [URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "per_page", value: "60")]
        } else {
            components = URLComponents(string: base + "/search")
            components?.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "per_page", value: "40")]
        }
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ExtensionSession.RequestError("Le Store de Raycast ne répond pas") }
        return try JSONDecoder().decode(Page.self, from: data).data.filter { $0.platforms?.contains("macOS") ?? true }
    }

    /// La fiche à jour d'une extension (le lien de téléchargement signé expire).
    static func fresh(_ listing: StoreListing) async throws -> StoreListing {
        let found = try await listings(query: listing.name)
        return found.first { $0.id == listing.id } ?? listing
    }

    /// Télécharge, décompresse et installe une extension.
    static func install(_ listing: StoreListing) async throws -> InstalledExtension {
        let current = try await fresh(listing)
        guard let raw = current.downloadURL, let url = URL(string: raw) else { throw ExtensionSession.RequestError("Cette extension n’a pas de paquet téléchargeable") }
        let (archive, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ExtensionSession.RequestError("Téléchargement refusé par le Store") }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("prism-extension-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, work.path]
        try unzip.run()
        unzip.waitUntilExit()
        try? FileManager.default.removeItem(at: archive)
        guard unzip.terminationStatus == 0 else { throw ExtensionSession.RequestError("Le paquet est illisible") }
        guard let folder = packageFolder(in: work) else { throw ExtensionSession.RequestError("Le paquet ne contient pas de package.json") }
        let origin = InstalledExtension.Origin(storeID: current.id, owner: current.publisher, name: current.name, commitSHA: current.commitSHA)
        return try ExtensionRegistry.shared.install(from: folder, origin: origin)
    }

    /// Le dossier qui contient `package.json` : la racine, ou son unique sous-dossier.
    static func packageFolder(in directory: URL) -> URL? {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.appendingPathComponent("package.json").path) { return directory }
        let children = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for child in children where !child.lastPathComponent.hasPrefix("__MACOSX") {
            if manager.fileExists(atPath: child.appendingPathComponent("package.json").path) { return child }
        }
        return nil
    }
}

/// L'écran du Store : extensions populaires, recherche, fiche détaillée, installation d'un geste.
@MainActor
final class ExtensionStoreScreen: LauncherScreen {
    private var results: [StoreListing] = []
    private var searchTask: Task<Void, Never>?
    private var lastQuery: String?
    private var error: String?
    private var installing: Set<String> = []

    init() {
        super.init(id: "extensions.store", title: "Store d’extensions Raycast", placeholder: "Rechercher une extension…",
                   icon: .symbol("bag.fill", Palette.violet))
        layout = .split(listWidth: 330)
    }

    override func didAppear() { queryDidChange("") }

    override func queryDidChange(_ query: String) {
        guard query != lastQuery else { return }
        lastQuery = query
        searchTask?.cancel()
        isLoading = true
        searchTask = Task { [weak self] in
            if !query.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard !Task.isCancelled else { return }
            do {
                let found = try await ExtensionStore.listings(query: query)
                guard !Task.isCancelled else { return }
                self?.results = found
                self?.error = nil
            } catch {
                self?.error = error.localizedDescription
            }
            self?.isLoading = false
            self?.reload()
        }
    }

    override func emptyState(query: String) -> (symbol: String, message: String) {
        if let error { return ("wifi.exclamationmark", error) }
        return isLoading ? ("hourglass", "Recherche dans le Store…") : ("bag", "Aucune extension pour « \(query) »")
    }

    override func sections(query: String) -> [ResultSection] {
        let registry = ExtensionRegistry.shared
        let installed = results.filter { registry.installed(owner: $0.publisher, name: $0.name) != nil }
        let others = results.filter { registry.installed(owner: $0.publisher, name: $0.name) == nil }
        var sections: [ResultSection] = []
        if !installed.isEmpty { sections.append(ResultSection(id: "installed", title: "Installées", items: installed.map(item))) }
        sections.append(ResultSection(id: "store", title: query.isEmpty ? "Populaires" : "Résultats", items: others.map(item)))
        return sections
    }

    private func item(_ listing: StoreListing) -> ResultItem {
        let installed = ExtensionRegistry.shared.installed(owner: listing.publisher, name: listing.name)
        let outdated = installed.map { $0.origin.commitSHA != nil && $0.origin.commitSHA != listing.commitSHA } ?? false
        let iconURL = (ExtensionIcon.isDark ? listing.icons?.dark ?? listing.icons?.light : listing.icons?.light).flatMap(URL.init(string:))
        var tags: [String] = []
        if installing.contains(listing.id) { tags.append("Installation…") } else if outdated { tags.append("Mise à jour") } else if installed != nil { tags.append("Installée") }
        let commands = (listing.commands ?? []).map { "• \($0.title)" + ($0.description.map { " — \($0)" } ?? "") }.joined(separator: "\n")
        let detail = ItemDetail(
            text: "## \(listing.title)\n\n\(listing.description ?? "")\n\n### Commandes\n\n\(commands)",
            metadata: [
                ("Auteur", listing.author.name ?? listing.author.handle),
                ("Téléchargements", listing.downloadCount.map { NumberFormatter.localizedString(from: NSNumber(value: $0), number: .decimal) } ?? "—"),
                ("Catégories", (listing.categories ?? []).joined(separator: ", ")),
            ],
            isMarkdown: true
        )
        var actions: [ItemAction] = []
        if let installed {
            if outdated { actions.append(installAction(listing, title: "Mettre à jour")) }
            actions.append(ItemAction(title: "Ouvrir les commandes", symbol: "list.bullet") { .push(ExtensionsFeature.commandsScreen(installed)) })
            actions.append(ItemAction(title: "Préférences de l’extension", symbol: "gearshape", shortcut: KeyShortcut(keyCode: 43, modifiers: [.command], label: ",")) {
                .push(ExtensionsFeature.preferencesForm(installed, command: nil))
            })
            actions.append(ItemAction(title: "Désinstaller", symbol: "trash", shortcut: KeyShortcut(keyCode: 51, modifiers: [.control], label: "⌫"), isDestructive: true) { [weak self] in
                ExtensionRegistry.shared.uninstall(installed)
                self?.reload()
                return .toast("« \(listing.title) » désinstallée")
            })
        } else {
            actions.append(installAction(listing, title: "Installer"))
        }
        if let store = listing.storeURL.flatMap(URL.init(string:)) {
            actions.append(ItemAction(title: "Voir dans le Store de Raycast", symbol: "safari", shortcut: KeyShortcut(keyCode: 31, modifiers: [.command], label: "O")) {
                NSWorkspace.shared.open(store)
                return .close
            })
        }
        return ResultItem(
            id: "store:" + listing.id,
            title: listing.title,
            subtitle: listing.description,
            icon: iconURL.map { .remote($0, fallback: "puzzlepiece.extension") } ?? .symbol("puzzlepiece.extension.fill", Palette.violet),
            accessory: listing.downloadCount.map { "↓ " + Self.compact($0) },
            tags: tags,
            detail: detail,
            usageKey: "",
            actions: actions
        )
    }

    private static func compact(_ count: Int) -> String {
        count >= 1_000_000 ? String(format: "%.1f M", Double(count) / 1_000_000) : count >= 1000 ? "\(count / 1000) k" : "\(count)"
    }

    private func installAction(_ listing: StoreListing, title: String) -> ItemAction {
        ItemAction(title: title, symbol: "arrow.down.circle") { [weak self] in
            guard let self, !self.installing.contains(listing.id) else { return .stay }
            self.installing.insert(listing.id)
            self.reload()
            Task { @MainActor in
                do {
                    let installed = try await ExtensionStore.install(listing)
                    self.installing.remove(listing.id)
                    self.reload()
                    self.host?.showToast("« \(installed.title) » installée : \(installed.manifest.commands.count) commande(s)", isError: false)
                } catch {
                    self.installing.remove(listing.id)
                    self.reload()
                    self.host?.showToast("Installation impossible : \(error.localizedDescription)")
                }
            }
            return .stay
        }
    }
}
