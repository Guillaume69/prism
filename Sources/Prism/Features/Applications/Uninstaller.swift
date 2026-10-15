import AppKit

/// Désinstaller une app : elle et ses fichiers d'assistance de `~/Library` partent à la corbeille
/// (`NSWorkspace.recycle`), jamais supprimés pour de bon. Les apps du système sont intouchables.
@MainActor
enum AppUninstaller {
    /// Les dossiers de `~/Library` où les apps laissent des fichiers, et comment les reconnaître.
    private enum Match { case bundleID, bundleIDOrName, suffix }

    nonisolated private static let locations: [(folder: String, match: Match)] = [
        ("Application Support", .bundleIDOrName),
        ("Caches", .bundleIDOrName),
        ("Preferences", .bundleID),
        ("Preferences/ByHost", .bundleID),
        ("Saved Application State", .bundleID),
        ("Logs", .bundleIDOrName),
        ("HTTPStorages", .bundleID),
        ("WebKit", .bundleID),
        ("Cookies", .bundleID),
        ("LaunchAgents", .bundleID),
        ("Group Containers", .suffix),
    ]

    /// Les fichiers d'assistance d'une app dans une bibliothèque (`~/Library`, ou un dossier factice pour les essais).
    /// Les conteneurs (`Containers`, `Application Scripts`) ne sont que testés, jamais parcourus :
    /// lire le conteneur d'une autre app déclencherait une demande d'autorisation.
    nonisolated static func supportFiles(bundleID: String?, appName: String, library: URL) -> [URL] {
        let fileManager = FileManager.default
        var found: [URL] = []
        let id = bundleID?.lowercased()
        let name = appName.lowercased()
        for (folder, match) in locations {
            let directory = library.appendingPathComponent(folder, isDirectory: true)
            guard let children = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            for child in children {
                let lower = child.lowercased()
                var matches = false
                if let id, id.contains(".") {
                    switch match {
                    case .bundleID, .bundleIDOrName:
                        matches = lower == id || lower.hasPrefix(id + ".")
                    case .suffix:
                        matches = lower == id || lower.hasSuffix("." + id)
                    }
                }
                if !matches, match == .bundleIDOrName, name.count >= 3 {
                    matches = lower == name
                }
                if matches { found.append(directory.appendingPathComponent(child)) }
            }
        }
        if let bundleID {
            for folder in ["Containers", "Application Scripts"] {
                let url = library.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(bundleID)
                if fileManager.fileExists(atPath: url.path) { found.append(url) }
            }
        }
        return found
    }

    /// Taille d'un fichier ou d'un dossier ; `nil` pour un conteneur (protégé) ou illisible.
    nonisolated static func size(of url: URL) -> Int64? {
        if url.path.contains("/Containers/") || url.path.contains("/Group Containers/") { return nil }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        var count = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let file = enumerator?.nextObject() as? URL, count < 50_000 {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
            count += 1
        }
        return total
    }

    static func formatted(_ size: Int64?) -> String {
        size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
    }

    static var library: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
    }

    /// Le formulaire de confirmation : l'app, puis ses fichiers d'assistance à cocher.
    static func form(for entry: AppEntry) -> FormScreen {
        let files = supportFiles(bundleID: entry.bundleID, appName: entry.name, library: library)
        let appSize = formatted(size(of: URL(fileURLWithPath: entry.path)))
        var fields: [FormField] = [
            FormField(id: "app", label: "Application", kind: .info,
                      value: "\(entry.name) — \((entry.path as NSString).abbreviatingWithTildeInPath)" + (appSize.isEmpty ? "" : " · \(appSize)")),
        ]
        for (index, file) in files.enumerated() {
            let size = formatted(size(of: file))
            fields.append(FormField(
                id: "file\(index)",
                label: index == 0 ? "Fichiers d’assistance" : "",
                kind: .checkbox(label: (file.path as NSString).abbreviatingWithTildeInPath + (size.isEmpty ? "" : " (\(size))")),
                value: "true"
            ))
        }
        if files.isEmpty {
            fields.append(FormField(id: "none", label: "Fichiers d’assistance", kind: .info, value: "Aucun fichier trouvé dans ~/Library."))
        }
        fields.append(FormField(id: "note", label: "", kind: .info,
                                value: "Tout part à la corbeille : vous pouvez le récupérer tant qu’elle n’est pas vidée."))
        let form = FormScreen(
            id: "uninstall." + entry.path,
            title: "Désinstaller \(entry.name)",
            icon: .file(entry.path),
            submitTitle: "Mettre à la corbeille",
            fields: fields
        ) { state in
            let chosen = files.enumerated().filter { state.bool("file\($0.offset)") }.map(\.element)
            uninstall(entry, files: chosen)
            return .close
        }
        return form
    }

    /// Quitte l'app si elle tourne, puis met l'app et les fichiers choisis à la corbeille.
    static func uninstall(_ entry: AppEntry, files: [URL]) {
        guard !entry.isSystem else { return }
        let appURL = URL(fileURLWithPath: entry.path)
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == appURL.standardizedFileURL }
        running.forEach { $0.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + (running.isEmpty ? 0 : 1.5)) {
            NSWorkspace.shared.recycle([appURL] + files) { trashed, _ in
                let appTrashed = trashed[appURL] != nil
                let count = files.filter { trashed[$0] != nil }.count
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if appTrashed {
                            HUD.shared.show(count == 0 ? "\(entry.name) mise à la corbeille" : "\(entry.name) et \(count) fichier\(count > 1 ? "s" : "") mis à la corbeille", symbol: "trash.fill")
                        } else {
                            // Une app installée par l'App Store appartient à root : le Finder demande le mot de passe.
                            trashWithFinder(appURL)
                        }
                        AppCatalog.shared.reload()
                    }
                }
            }
        }
    }

    private static func trashWithFinder(_ url: URL) {
        let escaped = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        SystemActions.osascript("tell application \"Finder\" to delete (POSIX file \"\(escaped)\" as alias)")
    }

    /// L'écran « Désinstaller des applications » : toutes les apps qui ne sont pas du système.
    static func listScreen() -> ListScreen {
        ListScreen(id: "applications.uninstall", title: "Désinstaller des applications", placeholder: "Rechercher une application à désinstaller…", icon: .symbol("trash.fill", Palette.red)) { query in
            let normalized = query.normalizedForSearch
            let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
            let items = AppCatalog.shared.apps
                .filter { !$0.isSystem && $0.bundleID != Bundle.main.bundleIdentifier && $0.bundleID != "com.apple.finder" }
                .filter { normalized.isEmpty || Fuzzy.score(normalized, $0.name) != nil }
                .map { entry in
                    ResultItem(
                        id: "uninstall:" + entry.path,
                        title: entry.name,
                        subtitle: ((entry.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath,
                        icon: .file(entry.path),
                        accessory: running.contains(entry.path) ? "Ouverte" : nil,
                        usageKey: "",
                        actions: [
                            ItemAction(title: "Désinstaller…", symbol: "trash", isDestructive: true) { .push(form(for: entry)) },
                            Actions.reveal(entry.path),
                            Actions.copyPath(entry.path),
                        ]
                    )
                }
            return [ResultSection(id: "apps", title: "Applications", items: items)]
        }
    }
}
