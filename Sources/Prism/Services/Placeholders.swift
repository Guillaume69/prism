import AppKit

/// Placeholders dynamiques de Raycast, avec ses paramètres et ses modificateurs :
/// `{clipboard offset=1 | trim | uppercase}`, `{date format="yyyy-MM-dd" offset="+2d"}`, `{cursor}`,
/// `{argument name="ton" options="gai, triste" default="gai"}`, `{selection}`, `{uuid}`, `{snippet name="…"}`,
/// `{calculator expression="2+2"}`, `{browser-tab}`, `{time}`, `{datetime}`, `{day}`.
enum Placeholders {
    enum Usage {
        case snippet
        /// Les valeurs sont encodées pour une adresse, sauf modificateur `raw`.
        case quicklink
        /// Les valeurs sont entourées de `"""`, sauf modificateur `raw`.
        case aiCommand
        case plain
    }

    struct Token {
        let name: String
        let parameters: [String: String]
        let modifiers: [String]
        let range: Range<String.Index>
    }

    struct Context {
        var usage: Usage = .plain
        /// Valeurs des arguments, par nom (`argument1`… pour les arguments sans nom).
        var arguments: [String: String] = [:]
        var selection: String? = nil
        /// Entrées du presse-papiers : 0 la plus récente.
        var clipboard: (Int) -> String? = { offset in
            offset == 0 ? NSPasteboard.general.string(forType: .string) : nil
        }
        /// Le texte d'un snippet, par nom (un snippet ne peut pas en appeler un autre qui en appelle encore un).
        var snippet: (String) -> String? = { _ in nil }
        var browserTab: () -> String? = { BrowserTab.content(format: "text") }
        var now = Date()
    }

    static let known: Set<String> = [
        "clipboard", "snippet", "cursor", "date", "time", "datetime", "day", "uuid",
        "selection", "argument", "calculator", "browser-tab",
    ]

    // MARK: - Analyse

    static func tokens(in template: String) -> [Token] {
        var result: [Token] = []
        var index = template.startIndex
        while let open = template[index...].firstIndex(of: "{") {
            guard let close = template[open...].firstIndex(of: "}") else { break }
            let inner = String(template[template.index(after: open)..<close])
            if let token = parse(inner, range: open..<template.index(after: close)) {
                result.append(token)
            }
            index = template.index(after: close)
        }
        return result
    }

    private static func parse(_ inner: String, range: Range<String.Index>) -> Token? {
        let pieces = splitOutsideQuotes(inner, separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let head = pieces.first, !head.isEmpty else { return nil }
        let nameEnd = head.firstIndex(where: \.isWhitespace) ?? head.endIndex
        let name = String(head[..<nameEnd]).lowercased()
        guard known.contains(name) else { return nil }
        var parameters: [String: String] = [:]
        let pattern = #"([a-zA-Z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|(\S+))"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let rest = String(head[nameEnd...])
            let ns = rest as NSString
            for match in regex.matches(in: rest, range: NSRange(location: 0, length: ns.length)) {
                let key = ns.substring(with: match.range(at: 1)).lowercased()
                for group in 2...4 where match.range(at: group).location != NSNotFound {
                    parameters[key] = ns.substring(with: match.range(at: group))
                    break
                }
            }
        }
        let modifiers = pieces.dropFirst().map { $0.lowercased() }.filter { !$0.isEmpty }
        return Token(name: name, parameters: parameters, modifiers: modifiers, range: range)
    }

    private static func splitOutsideQuotes(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if character == "\"" || character == "'" {
                if quote == character { quote = nil } else if quote == nil { quote = character }
            }
            if character == separator, quote == nil {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    /// Les arguments à demander, dans l'ordre : trois au plus, les homonymes partagent une valeur.
    static func arguments(in template: String) -> [ItemArgument] {
        var result: [ItemArgument] = []
        var names = Set<String>()
        var unnamed = 0
        for token in tokens(in: template) where token.name == "argument" {
            let name: String
            if let given = token.parameters["name"], !given.isEmpty {
                name = given
            } else {
                unnamed += 1
                name = "argument\(unnamed)"
            }
            guard !names.contains(name) else { continue }
            names.insert(name)
            let options = token.parameters["options"]?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty } ?? []
            let defaultValue = token.parameters["default"] ?? ""
            result.append(ItemArgument(
                name: name.hasPrefix("argument") && token.parameters["name"] == nil ? "Argument \(unnamed)" : name,
                placeholder: name.hasPrefix("argument") && token.parameters["name"] == nil ? "Texte" : name,
                isOptional: token.parameters["default"] != nil,
                options: options,
                defaultValue: defaultValue
            ))
            if result.count == 3 { break }
        }
        return result
    }

    /// Clés des arguments dans l'ordre de `arguments(in:)`, pour associer les valeurs saisies.
    static func argumentKeys(in template: String) -> [String] {
        var keys: [String] = []
        var unnamed = 0
        for token in tokens(in: template) where token.name == "argument" {
            let key: String
            if let given = token.parameters["name"], !given.isEmpty {
                key = given
            } else {
                unnamed += 1
                key = "argument\(unnamed)"
            }
            if !keys.contains(key) { keys.append(key) }
            if keys.count == 3 { break }
        }
        return keys
    }

    /// Associe les valeurs saisies aux arguments du modèle.
    static func argumentValues(_ values: [String], for template: String) -> [String: String] {
        let keys = argumentKeys(in: template)
        var result: [String: String] = [:]
        for (index, key) in keys.enumerated() where index < values.count {
            result[key] = values[index]
        }
        return result
    }

    static func needsSelection(_ template: String) -> Bool {
        tokens(in: template).contains { $0.name == "selection" }
    }

    // MARK: - Remplacement

    /// Le texte final et la position du curseur (`{cursor}`), comptée en caractères depuis la fin.
    static func expand(_ template: String, context: Context, depth: Int = 0) -> (text: String, cursorFromEnd: Int?) {
        var output = ""
        var cursorIndex: Int?
        var index = template.startIndex
        var unnamed = 0
        for token in tokens(in: template) {
            output += template[index..<token.range.lowerBound]
            index = token.range.upperBound
            if token.name == "cursor" {
                if cursorIndex == nil { cursorIndex = output.count }
                continue
            }
            if token.name == "argument", token.parameters["name"] == nil { unnamed += 1 }
            let value = resolve(token, context: context, unnamedIndex: unnamed, depth: depth)
            output += apply(token.modifiers, to: value, usage: context.usage)
        }
        output += template[index...]
        return (output, cursorIndex.map { output.count - $0 })
    }

    private static func resolve(_ token: Token, context: Context, unnamedIndex: Int, depth: Int) -> String {
        let parameters = token.parameters
        switch token.name {
        case "clipboard":
            let offset = parameters["offset"].flatMap(Int.init) ?? 0
            return context.clipboard(offset) ?? ""
        case "snippet":
            guard depth == 0, let name = parameters["name"], let text = context.snippet(name) else { return "" }
            return expand(text, context: context, depth: depth + 1).text
        case "date", "time", "datetime", "day":
            return formatDate(token.name, parameters: parameters, now: context.now)
        case "uuid":
            return UUID().uuidString
        case "selection":
            return context.selection ?? ""
        case "argument":
            let key = parameters["name"] ?? "argument\(unnamedIndex)"
            let value = context.arguments[key] ?? ""
            return value.isEmpty ? (parameters["default"] ?? "") : value
        case "calculator":
            let expression = parameters["expression"] ?? parameters["expr"] ?? ""
            return Calculator.evaluate(expression).map { Calculator.format($0, grouping: false) } ?? ""
        case "browser-tab":
            return BrowserTab.content(format: parameters["format"] ?? "markdown") ?? ""
        default:
            return ""
        }
    }

    private static func apply(_ modifiers: [String], to value: String, usage: Usage) -> String {
        var result = value
        var raw = false
        for modifier in modifiers {
            switch modifier {
            case "uppercase": result = result.uppercased()
            case "lowercase": result = result.lowercased()
            case "trim": result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            case "percent-encode": result = result.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? result
            case "json-stringify":
                if let data = try? JSONSerialization.data(withJSONObject: [result]), let text = String(data: data, encoding: .utf8) {
                    result = String(text.dropFirst(2).dropLast(2))
                }
            case "raw": raw = true
            default: break
            }
        }
        guard !raw else { return result }
        switch usage {
        case .quicklink where !modifiers.contains("percent-encode"):
            return result.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? result
        case .aiCommand:
            return "\"\"\"\n\(result)\n\"\"\""
        default:
            return result
        }
    }

    // MARK: - Dates

    static func formatDate(_ kind: String, parameters: [String: String], now: Date) -> String {
        let date = parameters["offset"].map { applyOffset($0, to: now) } ?? now
        let formatter = DateFormatter()
        if let locale = parameters["locale"] {
            formatter.locale = Locale(identifier: locale.replacingOccurrences(of: "_", with: "-"))
        } else {
            formatter.locale = Locale.current
        }
        if let format = parameters["format"] {
            formatter.dateFormat = format
            return formatter.string(from: date)
        }
        switch kind {
        case "date":
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        case "time":
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        case "datetime":
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        default:
            formatter.dateFormat = "EEEE"
        }
        return formatter.string(from: date)
    }

    /// « +2y +5M -3d +1h +30m » : les unités sont sensibles à la casse (M mois, m minutes).
    static func applyOffset(_ offset: String, to date: Date) -> Date {
        var result = date
        let calendar = Calendar.current
        let pattern = #"([+-])\s*(\d+)\s*([mhdMy])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return date }
        let ns = offset as NSString
        for match in regex.matches(in: offset, range: NSRange(location: 0, length: ns.length)) {
            let sign = ns.substring(with: match.range(at: 1)) == "-" ? -1 : 1
            let amount = (Int(ns.substring(with: match.range(at: 2))) ?? 0) * sign
            let component: Calendar.Component
            switch ns.substring(with: match.range(at: 3)) {
            case "m": component = .minute
            case "h": component = .hour
            case "d": component = .day
            case "M": component = .month
            default: component = .year
            }
            result = calendar.date(byAdding: component, value: amount, to: result) ?? result
        }
        return result
    }
}

extension CharacterSet {
    /// Caractères permis tels quels dans la valeur d'un paramètre d'adresse.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#/:")
        return set
    }()
}

/// Le contenu de l'onglet actif du navigateur, par AppleScript (Safari, Chrome, Arc, Brave, Edge).
enum BrowserTab {
    static let chromiumBrowsers = ["com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi"]

    /// L'adresse et le titre de l'onglet actif du navigateur au premier plan (ou du dernier utilisé).
    static func current() -> (url: String, title: String)? {
        for app in candidates() {
            let script: String
            if app == "com.apple.Safari" {
                script = #"tell application id "com.apple.Safari" to return (URL of current tab of front window) & "\n" & (name of current tab of front window)"#
            } else {
                script = #"tell application id "\#(app)" to return (URL of active tab of front window) & "\n" & (title of active tab of front window)"#
            }
            if let output = AppleScript.run(script) {
                let parts = output.split(separator: "\n", maxSplits: 1).map(String.init)
                if let url = parts.first, !url.isEmpty { return (url, parts.count > 1 ? parts[1] : url) }
            }
        }
        return nil
    }

    /// Le texte de la page : nécessite « Autoriser JavaScript depuis les Apple Events » dans le navigateur ;
    /// à défaut, l'adresse et le titre.
    static func content(format: String) -> String? {
        for app in candidates() {
            let js = format == "html" ? "document.documentElement.outerHTML" : "document.body.innerText"
            let script: String
            if app == "com.apple.Safari" {
                script = #"tell application id "com.apple.Safari" to do JavaScript "\#(js)" in current tab of front window"#
            } else {
                script = #"tell application id "\#(app)" to execute active tab of front window javascript "\#(js)""#
            }
            if let text = AppleScript.run(script), !text.isEmpty { return text }
        }
        guard let tab = current() else { return nil }
        return "\(tab.title)\n\(tab.url)"
    }

    /// Passe à un onglet déjà ouvert sur cette adresse (même hôte et même chemin), dans les navigateurs ouverts.
    /// `false` si aucun onglet ne correspond : l'appelant ouvre alors l'adresse normalement.
    static func focusExisting(_ url: URL) -> Bool {
        guard let host = url.host, url.scheme?.hasPrefix("http") == true else { return false }
        let target = host.replacingOccurrences(of: "www.", with: "") + url.path
        let needle = target.replacingOccurrences(of: "\"", with: "")
        for app in candidates() {
            let script: String
            if app == "com.apple.Safari" {
                script = """
                tell application id "com.apple.Safari"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if (URL of t as text) contains "\(needle)" then
                                set current tab of w to t
                                set index of w to 1
                                activate
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end tell
                return ""
                """
            } else {
                script = """
                tell application id "\(app)"
                    repeat with w in windows
                        set i to 0
                        repeat with t in tabs of w
                            set i to i + 1
                            if (URL of t as text) contains "\(needle)" then
                                set active tab index of w to i
                                set index of w to 1
                                activate
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end tell
                return ""
                """
            }
            if AppleScript.run(script) == "ok" { return true }
        }
        return false
    }

    private static func candidates() -> [String] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var ordered: [String] = []
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? nil,
           front == "com.apple.Safari" || chromiumBrowsers.contains(front) {
            ordered.append(front)
        }
        for id in ["com.apple.Safari"] + chromiumBrowsers where running.contains(id) && !ordered.contains(id) {
            ordered.append(id)
        }
        return ordered
    }
}

/// AppleScript en cours de processus, avec le résultat.
enum AppleScript {
    @discardableResult
    static func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result.stringValue
    }
}
