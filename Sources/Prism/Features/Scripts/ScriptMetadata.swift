import Foundation

/// Mode de sortie d'une commande script, comme dans Raycast.
enum ScriptMode: String, CaseIterable, Sendable {
    /// Le lanceur se ferme ; la dernière ligne s'affiche dans un HUD.
    case silent
    /// Le lanceur reste ouvert pendant l'exécution ; la dernière ligne s'affiche dans un toast.
    case compact
    /// Toute la sortie dans un écran du lanceur.
    case fullOutput
    /// La dernière ligne en sous-titre dans la recherche principale, rafraîchie régulièrement.
    case inline

    var title: String {
        switch self {
        case .silent: "Silencieux (HUD)"
        case .compact: "Compact (toast)"
        case .fullOutput: "Sortie complète"
        case .inline: "En ligne (sous-titre rafraîchi)"
        }
    }
}

/// Un argument déclaré par `@raycast.argument1` à `@raycast.argument3`.
struct ScriptArgument: Equatable, Sendable {
    enum Kind: String, Sendable { case text, password, dropdown }

    var kind: Kind
    var placeholder: String
    var isOptional: Bool
    var percentEncoded: Bool
    /// Choix d'une liste déroulante : titre affiché, valeur transmise.
    var options: [(title: String, value: String)]

    static func == (lhs: ScriptArgument, rhs: ScriptArgument) -> Bool {
        lhs.kind == rhs.kind && lhs.placeholder == rhs.placeholder && lhs.isOptional == rhs.isOptional
            && lhs.percentEncoded == rhs.percentEncoded && lhs.options.map(\.value) == rhs.options.map(\.value)
    }

    /// Lit le JSON d'un argument : `{ "type": "text", "placeholder": "Nom", "optional": true }`.
    static func parse(_ json: String) -> ScriptArgument? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let kind = Kind(rawValue: (object["type"] as? String ?? "text").lowercased()) ?? .text
        var options: [(String, String)] = []
        for entry in object["data"] as? [Any] ?? [] {
            if let entry = entry as? [String: Any] {
                let value = entry["value"].map { "\($0)" } ?? entry["title"].map { "\($0)" } ?? ""
                options.append((entry["title"].map { "\($0)" } ?? value, value))
            } else if let text = entry as? String {
                options.append((text, text))
            }
        }
        return ScriptArgument(
            kind: kind,
            placeholder: object["placeholder"] as? String ?? (kind == .dropdown ? "Choix" : "Texte"),
            isOptional: object["optional"] as? Bool ?? false,
            percentEncoded: object["percentEncoded"] as? Bool ?? false,
            options: options
        )
    }

    /// La valeur passée au script : celle du choix pour une liste, encodée pour une URL si demandé.
    func value(for input: String) -> String {
        var value = input
        if kind == .dropdown, let option = options.first(where: { $0.title == input || $0.value == input }) {
            value = option.value
        }
        if percentEncoded {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            value = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        }
        return value
    }
}

/// Une commande script : un fichier exécutable décrit par des commentaires `@raycast.*` (ou `@prism.*`).
struct ScriptCommand: Sendable {
    let path: String
    var schemaVersion: Int?
    var title: String?
    var mode: ScriptMode?
    var packageName: String?
    var icon: String?
    var iconDark: String?
    var currentDirectoryPath: String?
    var needsConfirmation = false
    /// Intervalle de rafraîchissement d'un script `inline`, en secondes (au moins 10).
    var refreshTime: TimeInterval?
    var arguments: [ScriptArgument] = []
    var description: String?
    var author: String?
    var authorURL: String?
    /// Ce qui empêche le script de devenir une commande (titre ou mode manquant…).
    var issues: [String] = []

    var url: URL { URL(fileURLWithPath: path) }
    var directory: String { (path as NSString).deletingLastPathComponent }
    var fileName: String { (path as NSString).lastPathComponent }
    var isValid: Bool { issues.isEmpty }

    /// Identifiant stable de la commande, d'après le chemin du fichier.
    var id: String { "script." + path }

    /// Le dossier d'exécution : `currentDirectoryPath` (relatif au script, `~` accepté), sinon celui du script.
    var workingDirectory: String {
        guard let custom = currentDirectoryPath, !custom.isEmpty else { return directory }
        let expanded = (custom as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : ((directory as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }

    /// Le premier argument est du texte : le script peut servir de recherche de repli.
    var canBeFallback: Bool { arguments.first?.kind == .text }

    // MARK: - Lecture des métadonnées

    /// Lit les métadonnées d'un fichier (les 16 premiers Ko suffisent).
    static func load(path: String) -> ScriptCommand {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            var command = ScriptCommand(path: path)
            command.issues = ["Fichier illisible"]
            return command
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 16_384)) ?? Data()
        return parse(String(decoding: data, as: UTF8.self), path: path)
    }

    static func parse(_ source: String, path: String) -> ScriptCommand {
        var command = ScriptCommand(path: path)
        var arguments: [Int: ScriptArgument] = [:]
        for rawLine in source.split(whereSeparator: \.isNewline) {
            guard let (key, value) = metadata(in: String(rawLine)) else { continue }
            switch key {
            case "schemaVersion": command.schemaVersion = Int(value)
            case "title": command.title = value
            case "mode":
                if let mode = ScriptMode.allCases.first(where: { $0.rawValue.lowercased() == value.lowercased() }) {
                    command.mode = mode
                } else {
                    command.issues.append("Mode inconnu : « \(value) »")
                }
            case "packageName": command.packageName = value
            case "icon": command.icon = value
            case "iconDark": command.iconDark = value
            case "currentDirectoryPath": command.currentDirectoryPath = value
            case "needsConfirmation": command.needsConfirmation = value.lowercased() == "true"
            case "refreshTime":
                if let interval = parseInterval(value) {
                    command.refreshTime = interval
                } else {
                    command.issues.append("Intervalle de rafraîchissement invalide : « \(value) »")
                }
            case "description": command.description = value
            case "author": command.author = value
            case "authorURL": command.authorURL = value
            default:
                if key.hasPrefix("argument"), let index = Int(key.dropFirst("argument".count)), (1...3).contains(index) {
                    if let argument = ScriptArgument.parse(value) {
                        arguments[index] = argument
                    } else {
                        command.issues.append("Argument \(index) : JSON invalide")
                    }
                }
            }
        }
        command.arguments = arguments.keys.sorted().compactMap { arguments[$0] }
        if command.title?.isEmpty ?? true { command.issues.insert("Titre manquant (@raycast.title)", at: 0) }
        if command.mode == nil, !command.issues.contains(where: { $0.hasPrefix("Mode") }) {
            command.issues.append("Mode manquant (@raycast.mode)")
        }
        if let version = command.schemaVersion, version != 1 { command.issues.append("Version de schéma non prise en charge : \(version)") }
        return command
    }

    /// `# @raycast.title Bonjour` → (« title », « Bonjour »). Le commentaire peut commencer par #, //, --, ; ou %.
    static func metadata(in line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var rest = Substring(trimmed)
        guard let marker = ["//", "--", "#", ";", "%"].first(where: { rest.hasPrefix($0) }) else { return nil }
        rest = rest.dropFirst(marker.count)
        while rest.first == "#" || rest.first == "/" { rest = rest.dropFirst() }
        rest = rest.drop(while: { $0 == " " || $0 == "\t" })
        for prefix in ["@raycast.", "@prism."] where rest.hasPrefix(prefix) {
            let body = rest.dropFirst(prefix.count)
            let key = body.prefix { $0.isLetter || $0.isNumber }
            guard !key.isEmpty else { return nil }
            let value = body.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            return (String(key), value)
        }
        return nil
    }

    /// « 10s », « 1m », « 2h », « 1d » → secondes ; au moins 10 secondes, comme Raycast.
    static func parseInterval(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = trimmed.last, let amount = Double(trimmed.dropLast().trimmingCharacters(in: .whitespaces)), amount > 0 else { return nil }
        let seconds: Double
        switch unit {
        case "s": seconds = amount
        case "m": seconds = amount * 60
        case "h": seconds = amount * 3_600
        case "d": seconds = amount * 86_400
        default: return nil
        }
        return max(seconds, 10)
    }

    // MARK: - Lancement

    /// L'exécutable et ses arguments : d'après le shebang, sinon l'extension du fichier.
    static func invocation(path: String, firstLine: String?, arguments: [String]) -> (executable: String, arguments: [String]) {
        if let line = firstLine, line.hasPrefix("#!") {
            let parts = line.dropFirst(2).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if let executable = parts.first {
                return (executable, Array(parts.dropFirst()) + [path] + arguments)
            }
        }
        let interpreter: [String]
        switch (path as NSString).pathExtension.lowercased() {
        case "zsh": interpreter = ["/bin/zsh"]
        case "py": interpreter = ["/usr/bin/env", "python3"]
        case "js", "mjs": interpreter = ["/usr/bin/env", "node"]
        case "swift": interpreter = ["/usr/bin/env", "swift"]
        case "rb": interpreter = ["/usr/bin/env", "ruby"]
        case "php": interpreter = ["/usr/bin/env", "php"]
        case "applescript", "scpt": interpreter = ["/usr/bin/osascript"]
        default: interpreter = ["/bin/bash"]
        }
        return (interpreter[0], Array(interpreter.dropFirst()) + [path] + arguments)
    }
}

/// Sortie d'un terminal → texte lisible : codes ANSI (couleurs, curseur, titres) retirés, retours chariot résolus.
enum TerminalText {
    static func clean(_ text: String) -> String {
        var result = text
        // Séquences OSC (titre de fenêtre, liens), puis CSI (couleurs, déplacements), puis échappements simples.
        result = result.replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\u{1B}[@-Z\\\\-_]", with: "", options: .regularExpression)
        // « 10 %\r20 %\r30 % » : seule la dernière réécriture de la ligne reste.
        result = result.components(separatedBy: "\n").map { line in
            line.components(separatedBy: "\r").last { !$0.isEmpty } ?? ""
        }.joined(separator: "\n")
        return result
    }

    /// La dernière ligne non vide.
    static func lastLine(_ text: String) -> String? {
        clean(text).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}
