import AppKit
import UniformTypeIdentifiers

/// Node.js, qui fait tourner les extensions : réglage, Homebrew, nvm, Volta, ou le `PATH` du shell de connexion.
enum NodeRuntime {
    static let pathKey = "extensions.nodePath"

    nonisolated(unsafe) private static var cachedPath: String??
    nonisolated(unsafe) private static var cachedShellPATH: String?

    static var path: String? {
        if let cachedPath { return cachedPath }
        let found = locate()
        cachedPath = .some(found)
        return found
    }

    static func reset() { cachedPath = nil }

    private static func locate() -> String? {
        let manager = FileManager.default
        var candidates: [String] = []
        if let configured = UserDefaults.standard.string(forKey: pathKey), !configured.isEmpty { candidates.append(configured) }
        candidates += ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        let home = manager.homeDirectoryForCurrentUser.path
        let nvm = home + "/.nvm/versions/node"
        let versions = ((try? manager.contentsOfDirectory(atPath: nvm)) ?? []).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        candidates += versions.map { "\(nvm)/\($0)/bin/node" }
        candidates += [home + "/.volta/bin/node", home + "/.local/share/fnm/aliases/default/bin/node", "/usr/bin/node"]
        for candidate in candidates where manager.isExecutableFile(atPath: candidate) {
            if let major = majorVersion(candidate), major >= 18 { return candidate }
        }
        // Dernier recours : le shell de connexion de l'utilisateur.
        if let viaShell = run("/bin/zsh", ["-lc", "command -v node"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !viaShell.isEmpty, let major = majorVersion(viaShell), major >= 18 {
            return viaShell
        }
        return nil
    }

    static func majorVersion(_ node: String) -> Int? {
        guard let version = run(node, ["--version"])?.trimmingCharacters(in: .whitespacesAndNewlines), version.hasPrefix("v") else { return nil }
        return Int(version.dropFirst().split(separator: ".").first ?? "")
    }

    /// Le `PATH` du shell de connexion : les extensions lancent souvent `brew`, `git`, `gh`…
    static var shellPATH: String {
        if let cachedShellPATH { return cachedShellPATH }
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let value = run("/bin/zsh", ["-lc", "printf %s \"$PATH\""]).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        cachedShellPATH = value
        return value
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    /// Le script de l'hôte : dans l'app, ou dans le dépôt pour une version de développement.
    static var hostScript: URL? {
        if let override = ProcessInfo.processInfo.environment["PRISM_RAYCAST_HOST"] { return URL(fileURLWithPath: override) }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("RaycastHost/host.js"),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("RaycastHost/dist/host.js")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}

/// Une valeur JSON passée d'un fil à l'autre (les dictionnaires de `JSONSerialization` ne sont pas `Sendable`).
private struct Payload: @unchecked Sendable {
    let value: [String: Any]
}

/// Découpe la sortie de l'hôte en lignes JSON, sur le fil de lecture.
private final class LineReader: @unchecked Sendable {
    private var buffer = Data()

    func append(_ data: Data) -> [Payload] {
        buffer.append(data)
        var messages: [Payload] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { messages.append(Payload(value: object)) }
        }
        return messages
    }
}

/// Une commande d'extension en cours : le processus Node, ses messages et les requêtes qu'il adresse à Prism.
@MainActor
final class ExtensionSession {
    let installed: InstalledExtension
    let command: ExtensionManifest.Command
    private let process = Process()
    /// Arrête le processus quand l'écran est libéré (le `deinit` n'est pas sur l'acteur principal).
    nonisolated let reaper = ExtensionReaper()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var finished = false

    var onRender: ((ExtensionNode?, Int) -> Void)?
    var onError: ((String, String) -> Void)?
    var onExit: ((Int) -> Void)?
    /// L'écran qui affiche la commande : les toasts et les fermetures passent par lui.
    weak var screen: ExtensionScreen?

    private(set) var depth = 1
    /// Les commandes sans vue : les toasts deviennent des HUD.
    var isHeadless: Bool { command.mode == "no-view" || screen == nil }

    /// Toutes les sessions vivantes, pour les arrêter quand Prism quitte.
    private static var live: [ObjectIdentifier: ExtensionSession] = [:]

    init(installed: InstalledExtension, command: ExtensionManifest.Command) {
        self.installed = installed
        self.command = command
    }

    enum LaunchError: LocalizedError {
        case noNode, noHost
        var errorDescription: String? {
            switch self {
            case .noNode: "Node.js (version 18 ou plus) est introuvable. Installez-le (brew install node) ou indiquez son chemin dans les réglages des extensions."
            case .noHost: "L’hôte des extensions est absent de Prism."
            }
        }
    }

    func start(arguments: [String: String] = [:], launchType: String = "userInitiated", launchContext: Any? = nil, fallbackText: String? = nil) throws {
        guard let node = NodeRuntime.path else { throw LaunchError.noNode }
        guard let host = NodeRuntime.hostScript else { throw LaunchError.noHost }
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [host.path]
        process.currentDirectoryURL = installed.directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = NodeRuntime.shellPATH
        environment["NODE_ENV"] = "production"
        environment.removeValue(forKey: "PRISM_DEBUG")
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let reader = LineReader()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let messages = reader.append(data)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for message in messages { self?.handle(message.value) }
                }
            }
        }
        let log = Self.logFile(for: installed)
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let file = try? FileHandle(forWritingTo: log) else { return }
            file.seekToEndOfFile()
            file.write(data)
            try? file.close()
        }
        process.terminationHandler = { [weak self] process in
            let status = Int(process.terminationStatus)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.didTerminate(status) }
            }
        }
        try process.run()
        reaper.process = process
        Self.live[ObjectIdentifier(self)] = self

        let support = installed.supportPath
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        var message: [String: Any] = [
            "t": "launch",
            "extensionPath": installed.directory.path,
            "command": command.name,
            "mode": command.mode,
            "preferences": ExtensionPreferences.shared.values(for: installed, command: command),
            "arguments": arguments,
            "launchType": launchType,
            "environment": environmentValues(launchType: launchType),
        ]
        if let launchContext { message["launchContext"] = launchContext }
        if let fallbackText { message["fallbackText"] = fallbackText }
        send(message)
    }

    private func environmentValues(launchType: String) -> [String: Any] {
        [
            "appearance": ExtensionIcon.isDark ? "dark" : "light",
            "theme": ExtensionIcon.isDark ? "dark" : "light",
            "assetsPath": installed.assets.path,
            "supportPath": installed.supportPath.path,
            "commandName": command.name,
            "commandMode": command.mode,
            "extensionName": installed.manifest.name,
            "ownerOrAuthorName": installed.origin.owner,
            "isDevelopment": false,
            "launchType": launchType,
            "raycastVersion": "1.104.0",
            "textSize": "medium",
            "prism": true,
        ]
    }

    /// Une ligne du journal de l'extension, à côté de sa sortie d'erreur.
    func log(_ line: String) {
        guard let file = try? FileHandle(forWritingTo: Self.logFile(for: installed)) else { return }
        file.seekToEndOfFile()
        file.write(Data("[prism] \(line)\n".utf8))
        try? file.close()
    }

    static func logFile(for installed: InstalledExtension) -> URL {
        let url = StoreLocation.subdirectory("Extensions/Logs").appendingPathComponent(installed.id + ".log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int), size > 1_000_000 {
            try? Data().write(to: url)
        }
        return url
    }

    func send(_ message: [String: Any]) {
        guard !finished, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        input.fileHandleForWriting.write(data + Data([0x0A]))
    }

    func call(_ handler: String, _ arguments: [Any] = []) {
        send(["t": "call", "id": handler, "args": arguments])
    }

    func pop() { send(["t": "pop"]) }

    func formChange(formKey: Int, id: String, value: Any) {
        send(["t": "formChange", "formKey": formKey, "id": id, "value": value])
    }

    func terminate() {
        guard !finished else { return }
        send(["t": "quit"])
        let process = process
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning { process.terminate() }
        }
    }

    static func terminateAll() {
        for session in live.values { session.terminate() }
    }

    private func didTerminate(_ status: Int) {
        finished = true
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        Self.live[ObjectIdentifier(self)] = nil
        onExit?(status)
    }

    // MARK: - Messages de l'hôte

    private func handle(_ message: [String: Any]) {
        switch message["t"] as? String {
        case "render":
            depth = (message["depth"] as? NSNumber)?.intValue ?? 1
            onRender?(ExtensionNode(message["view"]), depth)
        case "error":
            let text = message["message"] as? String ?? "Erreur inconnue"
            let stack = message["stack"] as? String ?? ""
            if let onError { onError(text, stack) } else { HUD.shared.show(text, symbol: "exclamationmark.triangle.fill") }
        case "exit":
            terminate()
        case "request":
            guard let rid = message["rid"] else { return }
            let method = message["method"] as? String ?? ""
            let params = message["params"] as? [String: Any] ?? [:]
            log("requête \(method)")
            Task { @MainActor in
                do {
                    let result = try await self.perform(method, params)
                    self.send(["t": "response", "rid": rid, "result": result ?? NSNull()])
                } catch {
                    self.send(["t": "response", "rid": rid, "error": error.localizedDescription])
                }
            }
        default:
            break
        }
    }

    // MARK: - Requêtes : ce que l'API de Raycast demande au Mac

    struct RequestError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private func present(_ outcome: ActionOutcome) {
        if let host = screen?.host, host.screen === screen || host.stack.contains(where: { $0 === screen }) {
            host.apply(outcome)
        } else {
            CommandRunner.present(outcome)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func perform(_ method: String, _ params: [String: Any]) async throws -> Any? {
        switch method {
        case "hud":
            let title = params["title"] as? String ?? ""
            present(.hud(title))
            return nil
        case "closeMainWindow":
            present(.close)
            return nil
        case "popToRoot":
            present(.popToRoot)
            return nil
        case "clearSearchBar":
            present(.setQuery(""))
            return nil
        case "toast.show":
            showToast(params)
            return nil
        case "toast.hide":
            screen?.toast = nil
            screen?.reload()
            return nil
        case "alert":
            return alert(params)
        case "clipboard.copy":
            copy(params)
            return nil
        case "clipboard.paste":
            let text = params["text"] as? String ?? ""
            present(Paster.paste(text))
            return nil
        case "clipboard.read":
            return readClipboard()
        case "clipboard.clear":
            NSPasteboard.general.clearContents()
            return nil
        case "selectedText":
            return await SelectedText.read() ?? ""
        case "selectedFinderItems":
            return finderSelection()
        case "frontmostApplication":
            guard let app = AppContext.previousApp ?? NSWorkspace.shared.frontmostApplication else { throw RequestError("Aucune application au premier plan") }
            return Self.application(app.bundleURL, name: app.localizedName, bundleID: app.bundleIdentifier)
        case "applications":
            return applications(for: params["path"] as? String)
        case "defaultApplication":
            let path = ExtensionIcon.expand(params["path"] as? String ?? "")
            guard let url = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: path)) else { throw RequestError("Aucune application par défaut") }
            return Self.application(url, name: nil, bundleID: nil)
        case "trash":
            let urls = (params["paths"] as? [String] ?? []).map { URL(fileURLWithPath: ExtensionIcon.expand($0)) }
            try await NSWorkspace.shared.recycle(urls)
            return nil
        case "openWith":
            let path = ExtensionIcon.expand(params["path"] as? String ?? "")
            present(.push(ExtensionPickers.openWith(path)))
            return nil
        case "launchCommand":
            try ExtensionsFeature.launch(from: installed, options: params)
            return nil
        case "updateCommandMetadata":
            ExtensionsFeature.setSubtitle(params["subtitle"] as? String, for: installed, command: command)
            return nil
        case "openPreferences":
            let scopedCommand = (params["scope"] as? String) == "command" ? command : nil
            present(.push(ExtensionsFeature.preferencesForm(installed, command: scopedCommand)))
            return nil
        case "ai.ask":
            guard let complete = AppHooks.aiComplete else { throw RequestError("Aucun modèle d’IA n’est configuré dans Prism") }
            return try await complete(params["prompt"] as? String ?? "", nil)
        case "createSnippet":
            let snippet = params["snippet"] as? [String: Any] ?? [:]
            if let create = AppHooks.createSnippet { present(create(snippet["text"] as? String ?? "")) }
            return nil
        case "createQuicklink":
            let link = params["quicklink"] as? [String: Any] ?? [:]
            if let create = AppHooks.createQuicklink { present(create(link["link"] as? String ?? "", link["name"] as? String ?? "")) }
            return nil
        case "pickDate":
            return ExtensionPickers.pickDate(title: params["title"] as? String ?? "Choisir une date", includesTime: (params["type"] as? String) != "date")
        case "quickLook":
            if let path = screen?.selectedQuickLookPath { ExtensionPickers.quickLook(path) }
            return nil
        case "oauth.authorize":
            guard let raw = params["url"] as? String, let url = URL(string: raw) else { throw RequestError("Adresse d’autorisation invalide") }
            let code = try await ExtensionOAuth.authorize(url)
            return ["code": code]
        case "browser.tabs":
            return try ExtensionBrowser.tabs()
        case "browser.content":
            return try ExtensionBrowser.content(format: params["format"] as? String ?? "markdown", selector: params["cssSelector"] as? String, tabID: params["tabId"] as? String)
        case "windows.active":
            return try ExtensionWindows.activeWindow()
        case "windows.list":
            return try ExtensionWindows.windowsOnActiveDesktop()
        case "windows.desktops":
            return ExtensionWindows.desktops()
        case "windows.setBounds":
            try ExtensionWindows.setBounds(params)
            return nil
        case "installMCPServer":
            throw RequestError("L’installation de serveurs MCP par une extension n’est pas prise en charge ; ajoutez-le dans Réglages › IA › MCP.")
        default:
            throw RequestError("« \(method) » n’est pas pris en charge par Prism")
        }
    }

    private func showToast(_ params: [String: Any]) {
        let title = params["title"] as? String ?? ""
        let message = params["message"] as? String
        let style = params["style"] as? String ?? "SUCCESS"
        if isHeadless || screen?.host == nil {
            if style != "ANIMATED" {
                HUD.shared.show(title, symbol: style == "FAILURE" ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            }
            return
        }
        var actions: [ItemAction] = []
        for key in ["primaryAction", "secondaryAction"] {
            guard let action = params[key] as? [String: Any], let handler = ExtensionValue.handler(action["onAction"]) else { continue }
            let session = self
            actions.append(ItemAction(title: action["title"] as? String ?? "Action", symbol: "bolt", section: "Notification") {
                session.call(handler)
                return .stay
            })
        }
        screen?.toast = ExtensionToast(style: style, title: title, message: message, actions: actions)
        screen?.reload()
    }

    private func alert(_ params: [String: Any]) -> Bool {
        let alert = NSAlert()
        alert.messageText = params["title"] as? String ?? ""
        alert.informativeText = params["message"] as? String ?? ""
        let primary = params["primaryAction"] as? [String: Any]
        let dismiss = params["dismissAction"] as? [String: Any]
        let button = alert.addButton(withTitle: primary?["title"] as? String ?? "OK")
        if (primary?["style"] as? String) == "destructive" { button.hasDestructiveAction = true }
        alert.addButton(withTitle: dismiss?["title"] as? String ?? "Annuler")
        let launcher = AppContext.launcher
        launcher?.keepOpenOnResign = true
        defer { launcher?.keepOpenOnResign = false }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func copy(_ params: [String: Any]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let file = params["file"] as? String {
            pasteboard.writeObjects([URL(fileURLWithPath: ExtensionIcon.expand(file)) as NSURL])
        }
        if let html = params["html"] as? String {
            pasteboard.setString(html, forType: .html)
        }
        if let text = params["text"] as? String {
            pasteboard.setString(text, forType: .string)
        }
        if params["concealed"] as? Bool == true {
            pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
    }

    private func readClipboard() -> [String: Any] {
        let pasteboard = NSPasteboard.general
        var result: [String: Any] = [:]
        if let text = pasteboard.string(forType: .string) { result["text"] = text }
        if let html = pasteboard.string(forType: .html) { result["html"] = html }
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first {
            result["file"] = url.path
        }
        return result
    }

    private func finderSelection() -> [[String: Any]] {
        let script = """
        tell application "Finder"
            set output to ""
            repeat with anItem in (get selection)
                set output to output & POSIX path of (anItem as alias) & linefeed
            end repeat
            return output
        end tell
        """
        let paths = (AppleScript.run(script) ?? "").split(separator: "\n").map(String.init)
        return paths.map { ["path": $0] }
    }

    private func applications(for path: String?) -> [[String: Any]] {
        if let path, !path.isEmpty {
            let urls = NSWorkspace.shared.urlsForApplications(toOpen: URL(fileURLWithPath: ExtensionIcon.expand(path)))
            return urls.map { Self.application($0, name: nil, bundleID: nil) }
        }
        AppCatalog.shared.loadSynchronously()
        return AppCatalog.shared.apps.map { app in
            ["name": app.name, "path": app.path, "bundleId": app.bundleID as Any? ?? NSNull()]
        }
    }

    static func application(_ url: URL?, name: String?, bundleID: String?) -> [String: Any] {
        guard let url else { return ["name": name ?? "", "path": "", "bundleId": bundleID ?? ""] }
        let bundle = Bundle(url: url)
        let displayName = name ?? (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? url.deletingPathExtension().lastPathComponent
        return ["name": displayName, "path": url.path, "bundleId": bundleID ?? bundle?.bundleIdentifier ?? ""]
    }
}

/// Un toast d'extension, affiché au pied de l'écran avec ses actions.
struct ExtensionToast {
    let style: String
    let title: String
    let message: String?
    let actions: [ItemAction]
}
