import AppKit
import UniformTypeIdentifiers

/// Les documents récents qu'une app sait ouvrir : les types qu'elle déclare (`CFBundleDocumentTypes`),
/// cherchés dans Spotlight et triés par dernière ouverture. La liste propre à chaque app est protégée
/// par macOS (accès complet au disque) : Spotlight en donne une approximation fidèle.
enum RecentDocuments {
    /// Les types de contenu déclarés par l'app (identifiants et extensions converties). Les types trop
    /// généraux (« tout fichier », dossiers) sont écartés : ils ne disent rien des documents de l'app.
    static func contentTypes(ofAppAt url: URL) -> [String] {
        guard let bundle = Bundle(url: url),
              let documentTypes = bundle.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] else { return [] }
        var types = Set<String>()
        for documentType in documentTypes {
            if (documentType["CFBundleTypeRole"] as? String) == "None" { continue }
            for identifier in documentType["LSItemContentTypes"] as? [String] ?? [] { types.insert(identifier) }
            for ext in documentType["CFBundleTypeExtensions"] as? [String] ?? [] where ext != "*" {
                if let type = UTType(filenameExtension: ext) { types.insert(type.identifier) }
            }
        }
        let tooGeneral: Set<String> = ["public.item", "public.data", "public.content", "public.folder", "public.directory", "public.file-url", "public.url", "com.apple.package"]
        return types.subtracting(tooGeneral).sorted()
    }

    /// Les 20 derniers documents ouverts de ces types, en arrière-plan.
    static func search(types: [String], completion: @escaping @MainActor ([URL]) -> Void) {
        guard !types.isEmpty else {
            DispatchQueue.main.async { MainActor.assumeIsolated { completion([]) } }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let clauses = types.prefix(60).map { "kMDItemContentTypeTree == \"\($0)\"" }.joined(separator: " || ")
            let queryString = "(\(clauses)) && kMDItemLastUsedDate >= $time.today(-90)"
            guard let query = MDQueryCreate(kCFAllocatorDefault, queryString as CFString, nil, nil) else {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion([]) } }
                return
            }
            let home = FileManager.default.homeDirectoryForCurrentUser.path as CFString
            MDQuerySetSearchScope(query, [home] as CFArray, 0)
            MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue))
            var found: [(URL, Date)] = []
            for index in 0..<MDQueryGetResultCount(query) {
                guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
                let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
                guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String,
                      !path.contains("/Library/"), !path.contains("/."), !path.contains(".app/") else { continue }
                let used = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date ?? .distantPast
                found.append((URL(fileURLWithPath: path), used))
            }
            let urls = found.sorted { $0.1 > $1.1 }.prefix(20).map(\.0)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(Array(urls)) } }
        }
    }

    /// L'écran « Fichiers récents » d'une app : ↵ ouvre le document avec elle.
    @MainActor
    static func screen(appName: String, appURL: URL) -> LauncherScreen {
        var results: [URL] = []
        var loaded = false
        let screen = ListScreen(
            id: "app.recent." + appURL.path,
            title: "Fichiers récents de \(appName)",
            placeholder: "Rechercher un document…",
            icon: .file(appURL.path),
            empty: { query in
                if !loaded { return ("hourglass", "Recherche des documents…") }
                return query.isEmpty ? ("doc", "Aucun document récent de \(appName)") : ("magnifyingglass", "Aucun document pour « \(query) »")
            }
        ) { query in
            let normalized = query.normalizedForSearch
            let items = results
                .filter { normalized.isEmpty || $0.lastPathComponent.normalizedForSearch.contains(normalized) }
                .map { url in
                    ResultItem(
                        id: "recent:" + url.path,
                        title: url.lastPathComponent,
                        subtitle: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                        icon: .file(url.path),
                        usageKey: "",
                        actions: [
                            ItemAction(title: "Ouvrir avec \(appName)", symbol: "arrow.up.forward.app") {
                                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                                return .close
                            },
                            Actions.reveal(url.path),
                            Actions.copyPath(url.path),
                        ]
                    )
                }
            return items.isEmpty ? [] : [ResultSection(id: "recent", title: "Ouverts récemment", items: items)]
        }
        screen.onAppear = { [weak screen] in
            screen?.isLoading = true
            search(types: contentTypes(ofAppAt: appURL)) { urls in
                results = urls
                loaded = true
                screen?.isLoading = false
                screen?.reload()
            }
        }
        return screen
    }
}
