import AppKit
import SwiftUI

// MARK: - Dossiers et catalogue

/// Les dossiers de scripts, les recherches de repli choisies et l'état des exemples, dans `scripts.json`.
@MainActor
final class ScriptsStore: ObservableObject {
    static let shared = ScriptsStore()

    struct Content: Codable {
        /// Dossiers ajoutés par l'utilisateur ; vide : seulement le dossier par défaut.
        var directories: [String] = []
        /// Le dossier par défaut est-il lu ? (on peut le retirer s'il ne sert pas)
        var includesDefaultDirectory = true
        /// Scripts proposés comme recherche de repli (identifiants de commande).
        var fallbackScripts: [String] = []
        var didCreateExamples = false
    }

    let store = JSONStore("scripts.json", default: Content())

    private init() {}

    var data: Content {
        get { store.value }
        set { store.value = newValue; objectWillChange.send() }
    }

    /// `~/Library/Application Support/Prism/Scripts`.
    nonisolated static var defaultDirectory: URL { StoreLocation.directory.appendingPathComponent("Scripts", isDirectory: true) }

    /// Les dossiers lus. `PRISM_SCRIPT_DIRECTORIES` (chemins séparés par « : ») les remplace pour les essais.
    var directories: [String] {
        if let override = ProcessInfo.processInfo.environment["PRISM_SCRIPT_DIRECTORIES"] {
            return override.split(separator: ":").map(String.init)
        }
        var result = data.includesDefaultDirectory ? [Self.defaultDirectory.path] : []
        for directory in data.directories where !result.contains(directory) { result.append(directory) }
        return result
    }

    /// Le dossier où créer les nouveaux scripts.
    var primaryDirectory: String { directories.first ?? Self.defaultDirectory.path }
}

/// Les scripts trouvés dans les dossiers, relus quand un dossier change (surveillance) ou qu'un fichier est modifié.
@MainActor
final class ScriptCatalog: ObservableObject {
    static let shared = ScriptCatalog()

    @Published private(set) var scripts: [ScriptCommand] = []
    private var signature: [String] = []
    private var lastCheck = Date.distantPast
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]

    private init() {
        // Un script installé ou retiré depuis le Store.
        NotificationCenter.default.addObserver(forName: .prismScriptsDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ScriptCatalog.shared.reload() }
        }
    }

    /// Fichiers ignorés : cachés, notes, données.
    private static let ignoredExtensions: Set<String> = ["md", "txt", "json", "png", "jpg", "jpeg", "gif", "svg", "icns", "pdf", "plist", "lock", "log"]

    /// La liste à jour : les dates de modification sont revues au plus toutes les deux secondes.
    var current: [ScriptCommand] {
        if Date().timeIntervalSince(lastCheck) > 2 { reloadIfChanged() }
        return scripts
    }

    var valid: [ScriptCommand] { current.filter(\.isValid) }

    func reloadIfChanged() {
        lastCheck = Date()
        let files = Self.scriptFiles(in: ScriptsStore.shared.directories)
        let newSignature = files.map { "\($0.path)|\($0.modified.timeIntervalSince1970)|\($0.size)" }
        guard newSignature != signature else { return }
        signature = newSignature
        scripts = files.map { ScriptCommand.load(path: $0.path) }
            .sorted { ($0.title ?? $0.fileName).localizedStandardCompare($1.title ?? $1.fileName) == .orderedAscending }
        InlineScripts.shared.scriptsDidChange(scripts)
        NotificationCenter.default.post(name: .prismDataDidChange, object: nil)
    }

    func reload() {
        signature = []
        reloadIfChanged()
        watch()
    }

    /// Les scripts des dossiers, sur trois niveaux : le Store installe dans `Scripts/Store/<groupe>/`.
    static func scriptFiles(in directories: [String]) -> [(path: String, modified: Date, size: Int)] {
        let manager = FileManager.default
        var result: [(String, Date, Int)] = []
        func visit(_ directory: String, depth: Int) {
            guard let names = try? manager.contentsOfDirectory(atPath: directory) else { return }
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = (directory as NSString).appendingPathComponent(name)
                guard let attributes = try? manager.attributesOfItem(atPath: path) else { continue }
                if attributes[.type] as? FileAttributeType == .typeDirectory {
                    if depth < 3, name != "images", name != "node_modules" { visit(path, depth: depth + 1) }
                    continue
                }
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      !ignoredExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
                result.append((path, attributes[.modificationDate] as? Date ?? .distantPast, (attributes[.size] as? Int) ?? 0))
            }
        }
        for directory in directories { visit(directory, depth: 0) }
        return result
    }

    /// Surveille chaque dossier : un fichier ajouté, renommé ou supprimé relit aussitôt le catalogue.
    func watch() {
        let wanted = Set(ScriptsStore.shared.directories)
        for (path, source) in watchers where !wanted.contains(path) {
            source.cancel()
            watchers[path] = nil
        }
        for path in wanted where watchers[path] == nil {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .attrib], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.lastCheck = .distantPast
                    self?.reloadIfChanged()
                }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watchers[path] = source
        }
    }

    func script(id: String) -> ScriptCommand? { current.first { $0.id == id } }
}

/// La dernière ligne des scripts `inline`, rafraîchie en arrière-plan selon leur `refreshTime` (au plus toutes les 10 s).
@MainActor
final class InlineScripts {
    static let shared = InlineScripts()

    private(set) var lines: [String: String] = [:]
    private var lastRun: [String: Date] = [:]
    private var running: [String: ScriptExecution] = [:]
    private var timer: Timer?

    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { InlineScripts.shared.tick() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func scriptsDidChange(_ scripts: [ScriptCommand]) {
        let paths = Set(scripts.map(\.path))
        lines = lines.filter { paths.contains($0.key) }
        // Un script modifié est relancé au prochain passage.
        lastRun = [:]
    }

    private func tick() {
        for script in ScriptCatalog.shared.valid where script.mode == .inline && script.arguments.allSatisfy(\.isOptional) {
            guard running[script.path] == nil else { continue }
            let interval = max(script.refreshTime ?? .infinity, 10)
            if let last = lastRun[script.path], Date().timeIntervalSince(last) < interval { continue }
            refresh(script)
        }
    }

    /// Relance un script tout de suite ; `completion` reçoit l'exécution terminée.
    func refresh(_ script: ScriptCommand, arguments: [String] = [], completion: ((ScriptExecution) -> Void)? = nil) {
        lastRun[script.path] = Date()
        let execution = ScriptExecution(command: script, arguments: arguments)
        running[script.path] = execution
        execution.start(timeout: 30) { [weak self] finished in
            MainActor.assumeIsolated {
                self?.running[script.path] = nil
                let line = finished.lastLine ?? ""
                let shown = finished.succeeded ? line : "⚠︎ " + line
                if self?.lines[script.path] != shown {
                    self?.lines[script.path] = shown
                    NotificationCenter.default.post(name: .prismDataDidChange, object: nil)
                }
                completion?(finished)
            }
        }
    }
}

// MARK: - Exécution depuis le lanceur

@MainActor
enum ScriptLauncher {
    /// Lance un script avec ses arguments saisis, selon son mode ; demande d'abord confirmation si nécessaire.
    static func run(_ script: ScriptCommand, rawArguments: [String], confirmed: Bool = false) -> ActionOutcome {
        if script.needsConfirmation, !confirmed {
            return .push(confirmationForm(script, rawArguments: rawArguments))
        }
        let arguments = zip(script.arguments, rawArguments).map { $0.value(for: $1) }
        let model = AppContext.launcher?.model
        let fromRoot = model?.isRoot ?? true
        switch script.mode ?? .compact {
        case .silent:
            let execution = ScriptExecution(command: script, arguments: arguments)
            execution.start { finished in
                MainActor.assumeIsolated {
                    if finished.succeeded {
                        if let line = finished.lastLine { HUD.shared.show(line) }
                    } else {
                        HUD.shared.show(finished.lastLine ?? "Échec du script (code \(finished.exitCode ?? -1))", symbol: "exclamationmark.triangle.fill")
                    }
                }
            }
            return .close
        case .compact, .inline:
            // Le lanceur reste ouvert, l'indicateur tourne sur la recherche principale.
            let root = model?.root
            root?.isLoading = true
            let done: (ScriptExecution) -> Void = { finished in
                root?.isLoading = false
                let line = finished.lastLine
                if finished.succeeded {
                    AppContext.launcher?.model.showToast(line ?? "\(script.title ?? "Script") terminé", isError: false)
                } else {
                    AppContext.launcher?.model.showToast(line ?? "Échec du script (code \(finished.exitCode ?? -1))", isError: true)
                }
                AppContext.launcher?.model.refresh(keepSelection: true)
            }
            if script.mode == .inline {
                InlineScripts.shared.refresh(script, arguments: arguments, completion: done)
            } else {
                let execution = ScriptExecution(command: script, arguments: arguments)
                execution.start { finished in MainActor.assumeIsolated { done(finished) } }
            }
            return fromRoot ? .stay : .popToRoot
        case .fullOutput:
            let screen = ScriptOutputScreen(script: script, arguments: arguments)
            return fromRoot ? .push(screen) : .replace(screen)
        }
    }

    static func confirmationForm(_ script: ScriptCommand, rawArguments: [String]) -> FormScreen {
        var details = "Le script « \(script.fileName) » va s’exécuter"
        if !rawArguments.filter({ !$0.isEmpty }).isEmpty {
            details += " avec : " + rawArguments.filter { !$0.isEmpty }.map { "« \($0) »" }.joined(separator: ", ")
        }
        return FormScreen(
            id: "script-confirm." + script.id,
            title: "Lancer « \(script.title ?? script.fileName) » ?",
            icon: ScriptIcons.icon(for: script),
            submitTitle: "Lancer",
            fields: [
                FormField(id: "info", label: "Confirmation", kind: .info, value: details + ".\n⌘↵ pour lancer, Échap pour annuler."),
            ]
        ) { _ in
            run(script, rawArguments: rawArguments, confirmed: true)
        }
    }
}

/// La sortie complète d'un script, au fil de l'eau, en police à chasse fixe.
@MainActor
final class ScriptOutputScreen: LauncherScreen {
    let script: ScriptCommand
    let arguments: [String]
    private(set) var execution: ScriptExecution

    init(script: ScriptCommand, arguments: [String]) {
        self.script = script
        self.arguments = arguments
        execution = ScriptExecution(command: script, arguments: arguments)
        super.init(id: "script-output." + script.id, title: script.title ?? script.fileName, icon: ScriptIcons.icon(for: script))
        layout = .custom
        hidesSearchField = true
        start()
    }

    private func start() {
        isLoading = true
        execution.start { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isLoading = false
                self?.host?.screenStateChanged()
            }
        }
    }

    func rerun() {
        execution.stop()
        execution = ScriptExecution(command: script, arguments: arguments)
        start()
        host?.screenStateChanged()
    }

    override func customView() -> AnyView { AnyView(ScriptOutputView(execution: execution)) }

    override var footerTitle: String? {
        if execution.isRunning { return "\(script.title ?? script.fileName) — en cours…" }
        if let code = execution.exitCode, code != 0 { return "Échec (code \(code))" }
        return script.title
    }

    override var screenActions: [ItemAction] {
        [
            ItemAction(title: "Copier la sortie", symbol: "doc.on.doc", shortcut: KeyShortcut(keyCode: 8, modifiers: [.command, .shift], label: "C")) { [weak self] in
                Pasteboard.copy(self?.execution.cleanOutput ?? "")
                return .hud("Sortie copiée")
            },
            ItemAction(title: "Relancer", symbol: "arrow.clockwise", shortcut: .refresh) { [weak self] in
                self?.rerun()
                return .stay
            },
            ItemAction(title: "Arrêter", symbol: "stop.circle", shortcut: KeyShortcut(keyCode: 8, modifiers: [.control], label: "C"), isDestructive: true) { [weak self] in
                self?.execution.stop()
                return .stay
            },
            ScriptActions.edit(script),
            ScriptActions.reveal(script),
        ]
    }

    override var customViewHandlesNavigation: Bool { true }

    override func didDisappear() { execution.stop() }
}

private struct ScriptOutputView: View {
    @ObservedObject var execution: ScriptExecution

    var body: some View {
        let text = execution.cleanOutput
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if text.isEmpty {
                        Text(execution.isRunning ? "En attente de la sortie…" : "Aucune sortie.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(text)
                            .textSelection(.enabled)
                    }
                    if let code = execution.exitCode, code != 0 {
                        Label("Code de sortie \(code)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.orange)
                            .padding(.top, 10)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .font(.system(size: 12.5, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(18)
            }
            .onChange(of: execution.output) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

// MARK: - Icônes et actions

@MainActor
enum ScriptIcons {
    private static var images: [String: NSImage] = [:]

    /// Emoji, image locale (chemin relatif au script, `~` ou `file://`), sinon un terminal.
    static func icon(for script: ScriptCommand) -> ItemIcon {
        // Le thème n'est lu que si le script a une icône sombre (et jamais sans application, dans les autotests).
        let dark = script.iconDark != nil && NSApp != nil && ThemeStore.shared.current.isDark
        let value = (dark ? script.iconDark : nil) ?? script.icon
        guard let value, !value.isEmpty else { return .symbol("terminal.fill", Palette.gray) }
        let lowered = value.lowercased()
        let isImage = ["png", "jpg", "jpeg", "gif", "icns", "pdf", "tiff", "heic", "svg"].contains((lowered as NSString).pathExtension)
        if !isImage, !value.contains("/"), value.count <= 4 { return .emoji(value) }
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") { return .symbol("terminal.fill", Palette.gray) }
        var path = value.hasPrefix("file://") ? (URL(string: value)?.path ?? value) : (value as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = (script.directory as NSString).appendingPathComponent(path) }
        if let cached = images[path] { return .image(cached) }
        guard let image = NSImage(contentsOfFile: path) else { return .symbol("terminal.fill", Palette.gray) }
        images[path] = image
        return .image(image)
    }
}

@MainActor
enum ScriptActions {
    static func edit(_ script: ScriptCommand) -> ItemAction {
        ItemAction(title: "Modifier le script", symbol: "pencil", shortcut: .edit, section: "Script") {
            let editor = NSWorkspace.shared.urlForApplication(toOpen: script.url)
            // Un script s'ouvre sinon avec le Terminal, qui l'exécuterait : on préfère un éditeur de texte.
            if let editor, !editor.path.contains("Terminal.app") {
                NSWorkspace.shared.open(script.url)
            } else if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
                NSWorkspace.shared.open([script.url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
            }
            return .close
        }
    }

    static func reveal(_ script: ScriptCommand) -> ItemAction {
        ItemAction(title: "Afficher dans le Finder", symbol: "folder", shortcut: KeyShortcut(keyCode: 15, modifiers: [.command, .shift], label: "R"), section: "Script") {
            NSWorkspace.shared.activateFileViewerSelecting([script.url])
            return .close
        }
    }

    static func copyPath(_ script: ScriptCommand) -> ItemAction {
        Actions.copy(script.path, title: "Copier le chemin", symbol: "link", shortcut: .copyPath, hud: "Chemin copié").inSection("Script")
    }
}

// MARK: - Fonctionnalité

@MainActor
enum ScriptsFeature: PrismFeature {
    static func start() {
        createExamplesIfNeeded()
        ScriptCatalog.shared.reload()
        InlineScripts.shared.start()
    }

    /// La commande de la recherche principale qui lance un script.
    static func item(for script: ScriptCommand) -> ResultItem {
        let title = script.title ?? script.fileName
        let mode = script.mode ?? .compact
        let runTitle = mode == .inline ? "Rafraîchir" : "Lancer le script"
        var subtitle = script.packageName ?? "Script"
        if mode == .inline, let line = InlineScripts.shared.lines[script.path], !line.isEmpty { subtitle = line }
        var keywords = ["script"]
        if let package = script.packageName { keywords.append(package) }
        if let description = script.description { keywords.append(description) }
        let arguments = script.arguments.map { argument in
            ItemArgument(
                name: argument.placeholder,
                placeholder: argument.placeholder,
                isOptional: argument.isOptional,
                isSecure: argument.kind == .password,
                options: argument.kind == .dropdown ? argument.options.map(\.title) : []
            )
        }
        let id = script.id
        var runWithArguments: (@MainActor ([String]) -> ActionOutcome)?
        if !arguments.isEmpty {
            runWithArguments = { (values: [String]) -> ActionOutcome in
                guard let current = ScriptCatalog.shared.script(id: id) else { return ActionOutcome.toast("Script introuvable") }
                return ScriptLauncher.run(current, rawArguments: values)
            }
        }
        let runAction = ItemAction(title: runTitle, symbol: mode == .inline ? "arrow.clockwise" : "play.fill") {
            guard let current = ScriptCatalog.shared.script(id: id) else { return .toast("Script introuvable") }
            return ScriptLauncher.run(current, rawArguments: [])
        }
        var item = Command.make(
            script.id, title, subtitle: subtitle, symbol: "terminal.fill", color: Palette.gray,
            keywords: keywords, accessory: "Script",
            arguments: arguments,
            runWithArguments: runWithArguments,
            actions: [
                runAction,
                ScriptActions.edit(script),
                ScriptActions.reveal(script),
                ScriptActions.copyPath(script),
            ]
        )
        item.icon = ScriptIcons.icon(for: script)
        return item
    }

    static var commands: [ResultItem] {
        let scripts = ScriptCatalog.shared.valid.map(item(for:))
        return scripts + [
            Command.screen("scripts", "Rechercher les commandes scripts", subtitle: "Scripts", symbol: "terminal.fill", color: Palette.gray,
                           keywords: ["script commands", "scripts", "bash", "python", "raycast"], screen: listScreen),
            Command.make("scripts.create", "Créer une commande script", subtitle: "Scripts", symbol: "plus.rectangle.on.rectangle", color: Palette.gray,
                         keywords: ["create script command", "nouveau script", "bash", "python", "node", "swift"],
                         actions: [ItemAction(title: "Créer une commande script", symbol: "plus") { .push(createForm()) }]),
            Command.run("scripts.open-folder", "Ouvrir le dossier des scripts", subtitle: "Scripts", symbol: "folder.fill", color: Palette.gray,
                        keywords: ["script directory", "dossier"]) {
                let url = URL(fileURLWithPath: ScriptsStore.shared.primaryDirectory, isDirectory: true)
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                NSWorkspace.shared.open(url)
                return .close
            },
            Command.run("scripts.reload", "Recharger les scripts", subtitle: "Scripts", symbol: "arrow.clockwise", color: Palette.gray,
                        keywords: ["reload script commands", "actualiser"]) {
                ScriptCatalog.shared.reload()
                let all = ScriptCatalog.shared.current
                let invalid = all.filter { !$0.isValid }.count
                return .toast("\(all.count - invalid) script\(all.count - invalid > 1 ? "s" : "") chargé\(all.count - invalid > 1 ? "s" : "")" + (invalid > 0 ? ", \(invalid) à corriger" : ""))
            },
        ]
    }

    /// Un script dont le premier argument est du texte peut recevoir la saisie, si l'utilisateur l'a choisi.
    static func fallbacks(query: String) -> [ResultItem] {
        let chosen = Set(ScriptsStore.shared.data.fallbackScripts)
        guard !chosen.isEmpty else { return [] }
        return ScriptCatalog.shared.valid.filter { chosen.contains($0.id) && $0.canBeFallback }.map { script in
            ResultItem(
                id: "fallback." + script.id,
                title: script.title ?? script.fileName,
                subtitle: query,
                icon: ScriptIcons.icon(for: script),
                accessory: "Script",
                actions: [ItemAction(title: "Lancer avec « \(query) »", symbol: "play.fill") {
                    ScriptLauncher.run(script, rawArguments: [query])
                }]
            )
        }
    }

    static var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "scripts", title: "Commandes scripts", symbol: "terminal.fill", color: Palette.gray, order: 45) { AnyView(ScriptsSettingsView()) }]
    }

    /// `prism://scripts/reload`, `prism://scripts/create`.
    static func handle(url: URL) -> Bool {
        guard url.host == "scripts" else { return false }
        switch url.path {
        case "/reload": ScriptCatalog.shared.reload()
        case "/create": CommandRunner.present(.push(createForm()))
        default: CommandRunner.present(.push(listScreen()))
        }
        return true
    }

    // MARK: Écrans

    /// Tous les scripts trouvés, y compris ceux à corriger, avec leurs métadonnées à droite.
    static func listScreen() -> LauncherScreen {
        ListScreen(
            id: "scripts",
            title: "Commandes scripts",
            placeholder: "Rechercher une commande script…",
            icon: .symbol("terminal.fill", Palette.gray),
            layout: .split(listWidth: 330),
            empty: { query in
                query.isEmpty
                    ? ("terminal", "Aucun script dans \(ScriptsStore.shared.directories.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")).\nCréez-en un avec « Créer une commande script ».")
                    : ("magnifyingglass", "Aucun script pour « \(query) »")
            }
        ) { query in
            let normalized = query.normalizedForSearch
            let scripts = ScriptCatalog.shared.current.filter { script in
                normalized.isEmpty || [script.title ?? "", script.fileName, script.packageName ?? "", script.description ?? ""]
                    .contains { Fuzzy.score(normalized, $0) != nil }
            }
            let valid = scripts.filter(\.isValid).map(listItem)
            let invalid = scripts.filter { !$0.isValid }.map(listItem)
            var sections: [ResultSection] = []
            if !valid.isEmpty { sections.append(ResultSection(id: "scripts", title: "Scripts", items: valid)) }
            if !invalid.isEmpty { sections.append(ResultSection(id: "scripts-invalid", title: "À corriger", items: invalid)) }
            return sections
        }
    }

    private static func listItem(_ script: ScriptCommand) -> ResultItem {
        var metadata: [(label: String, value: String)] = [
            ("Mode", script.mode?.title ?? "—"),
            ("Paquet", script.packageName ?? "—"),
            ("Fichier", (script.path as NSString).abbreviatingWithTildeInPath),
        ]
        if let refresh = script.refreshTime { metadata.append(("Rafraîchissement", Self.duration(refresh))) }
        if !script.arguments.isEmpty {
            metadata.append(("Arguments", script.arguments.map { $0.placeholder + ($0.isOptional ? "" : " *") }.joined(separator: ", ")))
        }
        if script.needsConfirmation { metadata.append(("Confirmation", "Demandée")) }
        if let author = script.author { metadata.append(("Auteur", author)) }
        let text: String
        if script.isValid {
            var lines = [script.description ?? "Pas de description (@raycast.description)."]
            if let line = InlineScripts.shared.lines[script.path] { lines.append("\nDernière sortie : \(line)") }
            text = lines.joined(separator: "\n")
        } else {
            text = "À corriger :\n" + script.issues.map { "• " + $0 }.joined(separator: "\n")
        }
        var actions: [ItemAction] = []
        if script.isValid {
            actions.append(ItemAction(title: "Lancer le script", symbol: "play.fill") {
                if script.arguments.isEmpty { return ScriptLauncher.run(script, rawArguments: []) }
                return ArgumentsForm.screen(for: item(for: script)).map { .push($0) } ?? .stay
            })
        }
        actions += [ScriptActions.edit(script), ScriptActions.reveal(script), ScriptActions.copyPath(script)]
        return ResultItem(
            id: "script-list:" + script.path,
            title: script.title ?? script.fileName,
            subtitle: script.isValid ? script.packageName : script.issues.first,
            icon: script.isValid ? ScriptIcons.icon(for: script) : .tinted("exclamationmark.triangle.fill", Palette.orange),
            accessory: script.isValid ? (script.mode?.rawValue ?? "") : "À corriger",
            detail: ItemDetail(text: text, metadata: metadata, isMarkdown: true),
            usageKey: "",
            actions: actions
        )
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds >= 86_400, seconds.truncatingRemainder(dividingBy: 86_400) == 0 { return "\(Int(seconds / 86_400)) j" }
        if seconds >= 3_600, seconds.truncatingRemainder(dividingBy: 3_600) == 0 { return "\(Int(seconds / 3_600)) h" }
        if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(seconds / 60)) min" }
        return "\(Int(seconds)) s"
    }

    // MARK: Création

    enum Template: String, CaseIterable {
        case bash, python, node, swift

        var title: String {
            switch self {
            case .bash: "Bash"
            case .python: "Python 3"
            case .node: "Node.js"
            case .swift: "Swift"
            }
        }

        var fileExtension: String {
            switch self {
            case .bash: "sh"
            case .python: "py"
            case .node: "js"
            case .swift: "swift"
            }
        }

        var shebang: String {
            switch self {
            case .bash: "#!/bin/bash"
            case .python: "#!/usr/bin/env python3"
            case .node: "#!/usr/bin/env node"
            case .swift: "#!/usr/bin/env swift"
            }
        }

        var comment: String { self == .node || self == .swift ? "//" : "#" }

        func body(argumentCount: Int) -> String {
            switch self {
            case .bash:
                argumentCount > 0 ? "echo \"Bonjour, ${1:-le monde} !\"" : "echo \"Bonjour, le monde !\""
            case .python:
                argumentCount > 0
                    ? "import sys\n\nname = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else \"le monde\"\nprint(f\"Bonjour, {name} !\")"
                    : "print(\"Bonjour, le monde !\")"
            case .node:
                argumentCount > 0
                    ? "const name = process.argv[2] || \"le monde\";\nconsole.log(`Bonjour, ${name} !`);"
                    : "console.log(\"Bonjour, le monde !\");"
            case .swift:
                argumentCount > 0
                    ? "import Foundation\n\nlet arguments = CommandLine.arguments.dropFirst()\nlet name = arguments.first.flatMap { $0.isEmpty ? nil : $0 } ?? \"le monde\"\nprint(\"Bonjour, \\(name) !\")"
                    : "print(\"Bonjour, le monde !\")"
            }
        }
    }

    /// Le texte d'un nouveau script : métadonnées Raycast puis un corps d'exemple.
    static func source(template: Template, title: String, mode: ScriptMode, packageName: String, icon: String,
                       arguments: [String], description: String, refreshTime: String? = nil, needsConfirmation: Bool = false) -> String {
        let c = template.comment
        var lines = [template.shebang, "", "\(c) Paramètres requis :", "\(c) @raycast.schemaVersion 1", "\(c) @raycast.title \(title)", "\(c) @raycast.mode \(mode.rawValue)"]
        lines += ["", "\(c) Paramètres facultatifs :"]
        if !icon.isEmpty { lines.append("\(c) @raycast.icon \(icon)") }
        if !packageName.isEmpty { lines.append("\(c) @raycast.packageName \(packageName)") }
        if let refreshTime { lines.append("\(c) @raycast.refreshTime \(refreshTime)") }
        if needsConfirmation { lines.append("\(c) @raycast.needsConfirmation true") }
        for (index, placeholder) in arguments.prefix(3).enumerated() {
            let escaped = placeholder.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("\(c) @raycast.argument\(index + 1) { \"type\": \"text\", \"placeholder\": \"\(escaped)\", \"optional\": true }")
        }
        if !description.isEmpty {
            lines += ["", "\(c) Documentation :", "\(c) @raycast.description \(description)"]
        }
        lines += ["", template.body(argumentCount: arguments.count), ""]
        return lines.joined(separator: "\n")
    }

    /// « Mon Script Génial ! » → « mon-script-genial ».
    static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR")).lowercased()
        let parts = folded.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
        let slug = parts.joined(separator: "-")
        return slug.isEmpty ? "script" : String(slug.prefix(60))
    }

    /// Écrit un script exécutable dans le dossier, sans écraser un fichier existant.
    @discardableResult
    static func write(_ source: String, name: String, fileExtension: String, in directory: String) throws -> URL {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent("\(name).\(fileExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name)-\(counter).\(fileExtension)")
            counter += 1
        }
        try source.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static func createForm() -> FormScreen {
        let directories = ScriptsStore.shared.directories
        var fields = [
            FormField(id: "template", label: "Modèle", kind: .dropdown(Template.allCases.map { ($0.rawValue, $0.title) }), value: Template.bash.rawValue),
            FormField(id: "mode", label: "Mode", kind: .dropdown(ScriptMode.allCases.map { ($0.rawValue, $0.title) }), value: ScriptMode.compact.rawValue,
                      info: "Compact : la dernière ligne s’affiche en bas du lanceur. En ligne : elle s’affiche dans la recherche, rafraîchie toutes les 10 minutes."),
            FormField(id: "title", label: "Titre", kind: .text, placeholder: "Par exemple : Ouvrir le projet"),
            FormField(id: "package", label: "Nom de paquet", kind: .text, placeholder: "Par exemple : Développement", info: "Affiché en sous-titre dans la recherche."),
            FormField(id: "icon", label: "Icône", kind: .text, placeholder: "Un emoji, ou le chemin d’une image", value: "🤖"),
            FormField(id: "arguments", label: "Arguments", kind: .text, placeholder: "Jusqu’à trois, séparés par des virgules : Nom, Ville",
                      info: "Demandés avant le lancement ; le script les reçoit dans l’ordre ($1, $2, $3)."),
            FormField(id: "description", label: "Description", kind: .text, placeholder: "Ce que fait le script"),
            FormField(id: "confirm", label: "", kind: .checkbox(label: "Demander une confirmation avant de lancer"), value: "false"),
        ]
        if directories.count > 1 {
            fields.append(FormField(id: "directory", label: "Dossier", kind: .dropdown(directories.map { ($0, ($0 as NSString).abbreviatingWithTildeInPath) }), value: directories[0]))
        } else {
            fields.append(FormField(id: "directory-info", label: "Dossier", kind: .info, value: (ScriptsStore.shared.primaryDirectory as NSString).abbreviatingWithTildeInPath))
        }
        return FormScreen(id: "scripts.create", title: "Créer une commande script", icon: .symbol("plus.rectangle.on.rectangle", Palette.gray), submitTitle: "Créer le script", fields: fields) { state in
            let title = state.trimmed("title")
            guard !title.isEmpty else {
                state.error = "Donnez un titre au script"
                return .stay
            }
            let template = Template(rawValue: state["template"]) ?? .bash
            let mode = ScriptMode(rawValue: state["mode"]) ?? .compact
            let arguments = state.trimmed("arguments").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard arguments.count <= 3 else {
                state.error = "Trois arguments au plus"
                return .stay
            }
            let source = source(
                template: template, title: title, mode: mode, packageName: state.trimmed("package"), icon: state.trimmed("icon"),
                arguments: arguments, description: state.trimmed("description"), refreshTime: mode == .inline ? "10m" : nil,
                needsConfirmation: state.bool("confirm")
            )
            let directory = state["directory"].isEmpty ? ScriptsStore.shared.primaryDirectory : state["directory"]
            do {
                let url = try write(source, name: slug(title), fileExtension: template.fileExtension, in: directory)
                ScriptCatalog.shared.reload()
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return .hud("Script « \(title) » créé")
            } catch {
                state.error = "Écriture impossible : \(error.localizedDescription)"
                return .stay
            }
        }
    }

    // MARK: Exemples

    static let examples: [(name: String, source: String)] = [
        ("bonjour.sh", source(template: .bash, title: "Bonjour", mode: .compact, packageName: "Exemples", icon: "👋", arguments: ["Prénom"],
                              description: "Dit bonjour ; la réponse s’affiche en bas du lanceur.")),
        ("date-du-jour.sh", """
        #!/bin/bash

        # Paramètres requis :
        # @raycast.schemaVersion 1
        # @raycast.title Date du jour
        # @raycast.mode inline

        # Paramètres facultatifs :
        # @raycast.icon 📅
        # @raycast.packageName Exemples
        # @raycast.refreshTime 10m

        # Documentation :
        # @raycast.description Affiche la date du jour dans la recherche, rafraîchie toutes les 10 minutes.

        LC_ALL=fr_FR.UTF-8 date "+%A %-d %B %Y, semaine %V"

        """),
    ]

    /// Au premier démarrage : le dossier par défaut et deux exemples.
    static func createExamplesIfNeeded(in directory: URL = ScriptsStore.defaultDirectory) {
        guard !ScriptsStore.shared.data.didCreateExamples else { return }
        createExamples(in: directory)
        ScriptsStore.shared.data.didCreateExamples = true
    }

    static func createExamples(in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for example in examples {
            let url = directory.appendingPathComponent(example.name)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try? example.source.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    // MARK: Autotests

    static func selfTest(_ check: (Bool, String) -> Void) {
        let bash = ScriptCommand.parse("""
        #!/bin/bash
        # @raycast.schemaVersion 1
        # @raycast.title Ouvrir un ticket
        # @raycast.mode compact
        # @raycast.packageName Travail
        # @raycast.icon 🎫
        # @raycast.argument1 { "type": "text", "placeholder": "Numéro" }
        # @raycast.argument2 { "type": "password", "placeholder": "Jeton", "optional": true }
        # @raycast.currentDirectoryPath ~/Projets
        # @raycast.author Ada
        # @raycast.authorURL https://example.com
        echo ok
        """, path: "/tmp/scripts/ticket.sh")
        check(bash.isValid && bash.title == "Ouvrir un ticket" && bash.mode == .compact && bash.packageName == "Travail", "script bash : titre, mode, paquet")
        check(bash.arguments.count == 2 && bash.arguments[0].kind == .text && !bash.arguments[0].isOptional
              && bash.arguments[1].kind == .password && bash.arguments[1].isOptional, "script bash : arguments texte et mot de passe")
        check(bash.workingDirectory == ("~/Projets" as NSString).expandingTildeInPath && bash.author == "Ada", "script bash : dossier d'exécution et auteur")
        check(bash.canBeFallback, "un premier argument texte permet la recherche de repli")

        let python = ScriptCommand.parse("""
        #!/usr/bin/env python3
        # @raycast.schemaVersion 1
        # @raycast.title Chercher sur le wiki
        # @raycast.mode fullOutput
        # @raycast.argument1 { "type": "dropdown", "placeholder": "Langue", "data": [{"title": "Français", "value": "fr"}, {"title": "Anglais", "value": "en"}] }
        # @raycast.argument2 { "type": "text", "placeholder": "Recherche", "percentEncoded": true }
        # @raycast.description Cherche une page.
        """, path: "/tmp/scripts/wiki.py")
        check(python.mode == .fullOutput && python.arguments.count == 2 && python.arguments[0].options.map(\.value) == ["fr", "en"], "script python : liste déroulante")
        check(python.arguments[0].value(for: "Anglais") == "en" && python.arguments[1].value(for: "été à Paris") == "%C3%A9t%C3%A9%20%C3%A0%20Paris", "valeur choisie et encodage URL")

        let node = ScriptCommand.parse("""
        #!/usr/bin/env node
        // @raycast.schemaVersion 1
        // @raycast.title Cours du bitcoin
        // @raycast.mode inline
        // @raycast.refreshTime 1m
        // @raycast.iconDark images/bitcoin-dark.png
        """, path: "/tmp/scripts/btc.js")
        check(node.isValid && node.mode == .inline && node.refreshTime == 60 && node.iconDark == "images/bitcoin-dark.png", "script node : en ligne, rafraîchi chaque minute")

        let swift = ScriptCommand.parse("""
        #!/usr/bin/swift
        // @prism.title Vider la corbeille
        // @prism.mode silent
        // @prism.needsConfirmation true
        // @prism.refreshTime 5s
        """, path: "/tmp/scripts/trash.swift")
        check(swift.isValid && swift.mode == .silent && swift.needsConfirmation && swift.refreshTime == 10, "script swift : @prism.*, confirmation, 10 s au moins")

        let broken = ScriptCommand.parse("# @raycast.mode flashy\n# @raycast.argument1 {pas du json}", path: "/tmp/scripts/x.sh")
        check(!broken.isValid && broken.issues.count == 3, "script incomplet : titre, mode et argument signalés")
        check(ScriptCommand.parseInterval("2h") == 7_200 && ScriptCommand.parseInterval("1d") == 86_400 && ScriptCommand.parseInterval("5") == nil, "intervalles de rafraîchissement")
        check(ScriptCommand.invocation(path: "/s/a.py", firstLine: "#!/usr/bin/env python3", arguments: ["x"]) == ("/usr/bin/env", ["python3", "/s/a.py", "x"]), "interpréteur d'après le shebang")
        check(ScriptCommand.invocation(path: "/s/a.js", firstLine: "console.log(1)", arguments: []).arguments == ["node", "/s/a.js"], "interpréteur d'après l'extension")
        check(TerminalText.clean("\u{1B}[1;32mvert\u{1B}[0m\n10 %\r100 %") == "vert\n100 %", "codes ANSI et retours chariot retirés")
        check(slug("Mon Script Génial !") == "mon-script-genial", "nom de fichier d'après le titre")
        let generated = ScriptCommand.parse(source(template: .node, title: "Essai", mode: .inline, packageName: "Paquet", icon: "🧪",
                                                   arguments: ["Nom \"court\""], description: "Test", refreshTime: "10m"), path: "/tmp/e.js")
        check(generated.isValid && generated.arguments.first?.placeholder == "Nom \"court\"" && generated.refreshTime == 600, "modèle de script relu")

        let form = createForm()
        check(form.fields.map(\.id).starts(with: ["template", "mode", "title", "package", "icon", "arguments"]) && form.state["mode"] == "compact",
              "formulaire de création : modèle, mode, titre, paquet, icône, arguments")
        check(ScriptLauncher.confirmationForm(swift, rawArguments: []).submitTitle == "Lancer", "formulaire de confirmation")

        // Exécution réelle dans un dossier temporaire.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("prism-scripts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        createExamples(in: folder)
        let examples = ScriptCatalog.scriptFiles(in: [folder.path]).map { ScriptCommand.load(path: $0.path) }
        check(examples.count == 2 && examples.allSatisfy(\.isValid), "les deux exemples sont valides")
        if let hello = examples.first(where: { $0.title == "Bonjour" }) {
            let run = ScriptExecution.runSynchronously(hello, arguments: ["Ada"])
            check(run.succeeded && run.lastLine == "Bonjour, Ada !", "exécution : dernière ligne « \(run.lastLine ?? "") »")
        }
        if let url = try? write("#!/bin/bash\necho début\necho 'raté' >&2\nexit 3\n", name: "echec", fileExtension: "sh", in: folder.path) {
            let run = ScriptExecution.runSynchronously(ScriptCommand.load(path: url.path))
            check(!run.succeeded && run.exitCode == 3 && run.lastLine == "raté", "code de sortie non nul : message d'erreur")
        }
    }
}

// MARK: - Réglages

struct ScriptsSettingsView: View {
    @ObservedObject private var store = ScriptsStore.shared
    @ObservedObject private var catalog = ScriptCatalog.shared

    var body: some View {
        Form {
            Section {
                ForEach(store.directories, id: \.self) { directory in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(Palette.blue)
                        Text((directory as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if directory == ScriptsStore.defaultDirectory.path {
                            Text("par défaut").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Ouvrir") { NSWorkspace.shared.open(URL(fileURLWithPath: directory, isDirectory: true)) }
                        Button {
                            if directory == ScriptsStore.defaultDirectory.path {
                                store.data.includesDefaultDirectory = false
                            } else {
                                store.data.directories.removeAll { $0 == directory }
                            }
                            catalog.reload()
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Ne plus lire ce dossier (les fichiers restent)")
                    }
                }
                HStack {
                    Button("Ajouter un dossier…", action: addDirectory)
                    if !store.data.includesDefaultDirectory {
                        Button("Lire de nouveau le dossier par défaut") {
                            store.data.includesDefaultDirectory = true
                            catalog.reload()
                        }
                    }
                    Spacer()
                    Button("Recharger") { catalog.reload() }
                    Button("Créer les exemples") {
                        ScriptsFeature.createExamples(in: URL(fileURLWithPath: store.primaryDirectory, isDirectory: true))
                        catalog.reload()
                    }
                }
            } header: {
                Text("Dossiers de scripts")
            } footer: {
                Text("Les scripts compatibles avec Raycast (métadonnées @raycast.* ou @prism.* en commentaires) deviennent des commandes de la recherche principale. Un fichier ajouté ou modifié est pris en compte aussitôt.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                if catalog.scripts.isEmpty {
                    Text("Aucun script trouvé.").foregroundStyle(.secondary)
                }
                ForEach(catalog.scripts, id: \.path) { script in
                    ScriptSettingsRow(script: script)
                }
            } header: {
                Text("Scripts")
            } footer: {
                Text("« Repli » : un script dont le premier argument est du texte peut recevoir la saisie de la recherche principale, comme « Rechercher sur Google ». L’ordre se règle dans Commandes.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { catalog.reloadIfChanged() }
    }

    private func addDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Ajouter"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !store.data.directories.contains(url.path) { store.data.directories.append(url.path) }
        catalog.reload()
    }
}

private struct ScriptSettingsRow: View {
    let script: ScriptCommand
    @ObservedObject private var store = ScriptsStore.shared

    var body: some View {
        HStack(spacing: 8) {
            ItemIconView(icon: script.isValid ? ScriptIcons.icon(for: script) : .tinted("exclamationmark.triangle.fill", Palette.orange), size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(script.title ?? script.fileName).font(.system(size: 12.5))
                Text(script.isValid ? [script.mode?.rawValue, script.packageName, script.fileName].compactMap { $0 }.joined(separator: " · ") : script.issues.joined(separator: " · "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(script.isValid ? Color.secondary : Palette.orange)
                    .lineLimit(1)
            }
            Spacer()
            if script.canBeFallback, script.isValid {
                Toggle("Repli", isOn: Binding(
                    get: { store.data.fallbackScripts.contains(script.id) },
                    set: { enabled in
                        store.data.fallbackScripts.removeAll { $0 == script.id }
                        if enabled { store.data.fallbackScripts.append(script.id) }
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
            }
        }
    }
}
