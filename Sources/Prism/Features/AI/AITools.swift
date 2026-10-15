import AppKit
import CoreServices

/// Un outil que l'IA peut appeler (les « AI Extensions » de Raycast) : lire l'agenda, chercher dans le
/// presse-papiers, créer une note, démarrer une session de concentration… ou un outil d'un serveur MCP.
struct AIToolSpec: @unchecked Sendable {
    var name: String
    var description: String
    /// Schéma JSON des paramètres.
    var schema: [String: Any]
    /// Mentions qui joignent son résultat à la question (« @agenda ») : pour les modèles sans appel d'outils.
    var mentions: [String] = []
    /// Agit sur le Mac (crée, démarre, ouvre) : demande confirmation selon le réglage.
    var isAction = false
    /// « Prism » ou le nom du serveur MCP.
    var source = "Prism"
    var run: @MainActor ([String: Any]) async -> String
}

@MainActor
enum AITools {
    private static func schema(_ properties: [String: (type: String, description: String)], required: [String] = []) -> [String: Any] {
        var props: [String: Any] = [:]
        for (name, info) in properties { props[name] = ["type": info.type, "description": info.description] }
        return ["type": "object", "properties": props, "required": required]
    }

    private static func string(_ arguments: [String: Any], _ key: String) -> String? {
        (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func int(_ arguments: [String: Any], _ key: String) -> Int? {
        if let value = arguments[key] as? Int { return value }
        if let value = arguments[key] as? Double { return Int(value) }
        if let text = arguments[key] as? String { return Int(text) }
        return nil
    }

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withFullDate, .withTime, .withColonSeparatorInTime], [.withFullDate]] {
            formatter.formatOptions = options
            formatter.timeZone = .current
            if let date = formatter.date(from: text) { return date }
        }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        return nil
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute().locale(Locale(identifier: "fr_FR")))
    }

    /// Les outils de Prism lui-même.
    static var builtIn: [AIToolSpec] {
        var tools: [AIToolSpec] = []
        tools.append(AIToolSpec(
            name: "current_date_time",
            description: "Date, heure et fuseau horaire actuels de l’utilisateur.",
            schema: schema([:]),
            mentions: ["@date", "@heure"]
        ) { _ in
            let now = Date()
            return "\(stamp(now)) — \(ISO8601DateFormatter().string(from: now)) — fuseau \(TimeZone.current.identifier)"
            })
        tools.append(AIToolSpec(
            name: "calendar_events",
            description: "Liste les évènements de l’agenda de l’utilisateur pour les prochains jours (titre, horaires, lieu, visio).",
            schema: schema(["days": ("integer", "Nombre de jours à partir d’aujourd’hui (1 = aujourd’hui seulement)")]),
            mentions: ["@agenda", "@calendrier", "@calendar"]
        ) { arguments in
            guard CalendarService.shared.isAuthorized else { return "L’accès au calendrier n’est pas autorisé (Réglages de Prism › Calendrier)." }
            CalendarService.shared.refreshIfStale()
            let days = max(1, min(31, int(arguments, "days") ?? 2))
            let start = Calendar.current.startOfDay(for: Date())
            let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
            let events = CalendarService.shared.visibleEvents.filter { $0.end > Date() && $0.start < end }
            guard !events.isEmpty else { return "Aucun évènement." }
            return events.prefix(40).map { event in
                var line = "- \(event.title) : \(event.isAllDay ? "toute la journée du " + event.start.formatted(date: .complete, time: .omitted) : stamp(event.start) + " → " + event.end.formatted(date: .omitted, time: .shortened)) [\(event.calendarTitle)]"
                if let location = event.location, !location.isEmpty { line += " · \(location)" }
                if let meeting = event.meeting { line += " · visio \(meeting.service.title)" }
                return line
            }.joined(separator: "\n")
            })
        tools.append(AIToolSpec(
            name: "calendar_create_event",
            description: "Crée un évènement dans l’agenda par défaut de l’utilisateur.",
            schema: schema([
                "title": ("string", "Titre"),
                "start": ("string", "Début, ISO 8601 en heure locale (2026-10-15T14:00)"),
                "end": ("string", "Fin, ISO 8601 en heure locale"),
                "location": ("string", "Lieu, facultatif"),
            ], required: ["title", "start"]),
            isAction: true
        ) { arguments in
            guard CalendarService.shared.isAuthorized else { return "L’accès au calendrier n’est pas autorisé." }
            guard let title = string(arguments, "title"), let start = date(string(arguments, "start")) else { return "Titre ou début manquant ou illisible." }
            let end = date(string(arguments, "end")) ?? start.addingTimeInterval(3600)
            do {
                let event = try CalendarService.shared.create(.init(title: title, start: start, end: end, location: string(arguments, "location")))
                return "Évènement créé : \(event.title), \(stamp(event.start))."
            } catch {
                return "Création impossible : \(error.localizedDescription)"
            }
            })
        tools.append(AIToolSpec(
            name: "clipboard_history",
            description: "Cherche dans l’historique du presse-papiers de l’utilisateur (textes, liens, couleurs, fichiers copiés).",
            schema: schema(["query": ("string", "Texte à chercher ; vide pour les plus récents"), "limit": ("integer", "Nombre d’entrées, 10 par défaut")]),
            mentions: ["@presse-papiers", "@clipboard"]
        ) { arguments in
            let query = string(arguments, "query")?.normalizedForSearch
            let limit = max(1, min(40, int(arguments, "limit") ?? 10))
            let entries = ClipboardMonitor.shared.entries
                .filter { query == nil || $0.text.normalizedForSearch.contains(query!) || ($0.name?.normalizedForSearch.contains(query!) ?? false) }
                .prefix(limit)
            guard !entries.isEmpty else { return "Aucune entrée." }
            return entries.map { "- [\($0.kind.rawValue), \($0.date.formatted(date: .abbreviated, time: .shortened))] \(String($0.text.prefix(600)))" }.joined(separator: "\n")
            })
        tools.append(AIToolSpec(
            name: "notes_search",
            description: "Cherche dans les notes Prism de l’utilisateur (Markdown) ; sans requête, les plus récentes.",
            schema: schema(["query": ("string", "Texte à chercher")]),
            mentions: ["@notes"]
        ) { arguments in
            let query = string(arguments, "query")?.normalizedForSearch
            let all: [Note] = NotesLibrary.shared.data.notes
            let matching: [Note] = all.filter { note in
                guard note.deleted == nil else { return false }
                guard let query else { return true }
                return note.text.normalizedForSearch.contains(query)
            }
            let recent: [Note] = Array(matching.sorted { $0.modified > $1.modified }.prefix(8))
            guard !recent.isEmpty else { return "Aucune note." }
            let blocks: [String] = recent.map { note in
                let date = note.modified.formatted(date: .abbreviated, time: .shortened)
                return "--- note du \(date)\n" + String(note.text.prefix(2_000))
            }
            return blocks.joined(separator: "\n")
            })
        tools.append(AIToolSpec(
            name: "notes_create",
            description: "Crée une note Prism (Markdown ; la première ligne sert de titre) et l’affiche.",
            schema: schema(["text": ("string", "Contenu de la note en Markdown")], required: ["text"]),
            isAction: true
        ) { arguments in
            guard let text = string(arguments, "text") else { return "Texte manquant." }
            guard let create = AppHooks.createNote else { return "Les notes ne sont pas disponibles." }
            create(text)
            return "Note créée."
            })
        tools.append(AIToolSpec(
            name: "focus_session",
            description: "Démarre une session de concentration (bloque les apps et sites distrayants), donne son état ou la termine.",
            schema: schema([
                "action": ("string", "« start », « status » ou « stop »"),
                "goal": ("string", "Objectif de la session"),
                "minutes": ("integer", "Durée en minutes"),
            ], required: ["action"]),
            mentions: ["@concentration", "@focus"],
            isAction: true
        ) { arguments in
            let manager = FocusManager.shared
            switch string(arguments, "action") ?? "status" {
            case "start":
                var configuration = manager.lastConfiguration ?? .standard
                configuration.goal = string(arguments, "goal") ?? configuration.goal
                if let minutes = int(arguments, "minutes") { configuration.duration = TimeInterval(max(1, min(1_440, minutes)) * 60) }
                manager.start(configuration)
                return "Session démarrée : « \(configuration.goal) »."
            case "stop":
                guard manager.session != nil else { return "Aucune session en cours." }
                manager.complete()
                return "Session terminée."
            default:
                guard let session = manager.session else { return "Aucune session en cours." }
                return "Session en cours : « \(session.goal) », \(session.isPaused ? "en pause" : "active")."
            }
            })
        tools.append(AIToolSpec(
            name: "files_search",
            description: "Cherche des fichiers par leur nom dans le dossier de l’utilisateur (Spotlight).",
            schema: schema(["query": ("string", "Partie du nom de fichier")], required: ["query"]),
            mentions: ["@fichiers", "@files"]
        ) { arguments in
            guard let query = string(arguments, "query") else { return "Requête manquante." }
            let paths = await spotlight("kMDItemFSName == \"*\(query.replacingOccurrences(of: "\"", with: ""))*\"cd", limit: 20)
            return paths.isEmpty ? "Aucun fichier." : paths.map { "- " + ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n")
            })
        tools.append(AIToolSpec(
            name: "snippets_search",
            description: "Cherche dans les snippets de l’utilisateur (textes réutilisables et leurs mots-clés).",
            schema: schema(["query": ("string", "Texte à chercher")]),
            mentions: ["@snippets"]
        ) { arguments in
            let query = string(arguments, "query")?.normalizedForSearch
            let snippets = SnippetStore.shared.snippets
                .filter { query == nil || $0.name.normalizedForSearch.contains(query!) || $0.text.normalizedForSearch.contains(query!) }
                .prefix(15)
            guard !snippets.isEmpty else { return "Aucun snippet." }
            return snippets.map { "- \($0.name)\($0.keyword.map { " (\($0))" } ?? "") : \(String($0.text.prefix(300)))" }.joined(separator: "\n")
            })
        tools.append(AIToolSpec(
            name: "calculate",
            description: "Calcule une expression avec la calculatrice de Prism : arithmétique, unités, devises au taux du jour, fuseaux, dates.",
            schema: schema(["expression": ("string", "Par exemple « 100 usd en eur », « heure à Tokyo », « 15% of 80 »")], required: ["expression"])
        ) { arguments in
            guard let expression = string(arguments, "expression"),
                  let answer = Calculator.answer(for: expression, context: Calculator.liveContext) else { return "Calcul non compris." }
            return "\(answer.expression) = \(answer.result)"
            })
        tools.append(AIToolSpec(
            name: "run_prism_command",
            description: "Lance une commande ou ouvre une application par son nom dans Prism (par exemple « Moitié gauche », « Safari », « Verrouiller l’écran »).",
            schema: schema(["name": ("string", "Nom de la commande ou de l’application")], required: ["name"]),
            isAction: true
        ) { arguments in
            guard let name = string(arguments, "name")?.normalizedForSearch else { return "Nom manquant." }
            let candidates = RootScreen.candidates()
            guard let item = candidates
                .compactMap({ item in Fuzzy.score(name, item.title).map { (item, $0) } })
                .max(by: { $0.1 < $1.1 })?.0 else { return "Aucune commande ne correspond." }
            CommandRunner.run(id: item.id)
            return "Commande lancée : \(item.title)."
            })
        tools.append(AIToolSpec(
            name: "read_webpage",
            description: "Lit le texte d’une page web à partir de son adresse.",
            schema: schema(["url": ("string", "Adresse complète (https://…)")], required: ["url"])
        ) { arguments in
            guard let text = string(arguments, "url"), let url = URL(string: text), url.scheme?.hasPrefix("http") == true else { return "Adresse invalide." }
            return await WebTools.read(url)
            })
        tools.append(AIToolSpec(
            name: "web_search",
            description: "Cherche sur le web (DuckDuckGo) et renvoie les premiers résultats : titre, adresse, extrait.",
            schema: schema(["query": ("string", "Recherche")], required: ["query"]),
            mentions: ["@web"]
        ) { arguments in
            guard let query = string(arguments, "query") else { return "Recherche manquante." }
            return await WebTools.search(query)
            })
        tools.append(AIToolSpec(
            name: "browser_tab",
            description: "Lit l’adresse, le titre et le texte de l’onglet actif du navigateur de l’utilisateur.",
            schema: schema([:]),
            mentions: ["@onglet", "@navigateur", "@browser"]
        ) { _ in
            BrowserTab.content(format: "text").map { String($0.prefix(12_000)) } ?? "Aucun onglet de navigateur lisible."
            })
        tools.append(AIToolSpec(
            name: "screen_text",
            description: "Lit le texte visible à l’écran de l’utilisateur (capture et reconnaissance de texte sur l’appareil).",
            schema: schema([:]),
            mentions: ["@écran", "@ecran", "@screen"]
        ) { _ in
            await ScreenContext.text() ?? "Écran illisible : autorisez Prism dans Réglages Système › Confidentialité › Enregistrement de l’écran."
            })
        tools.append(AIToolSpec(
            name: "remember",
            description: "Mémorise durablement un fait sur l’utilisateur (préférence, information utile) pour les prochaines conversations.",
            schema: schema(["fact": ("string", "Le fait, en une phrase")], required: ["fact"])
        ) { arguments in
            guard let fact = string(arguments, "fact") else { return "Fait manquant." }
            AIMemory.shared.add(fact)
            return "Mémorisé."
            })
        return tools
    }

    /// Les outils proposés au modèle : ceux de Prism activés, puis ceux des serveurs MCP.
    /// `allowed` : les outils permis par l'agent de la conversation (`nil` : tous ; « mcp » pour les serveurs MCP).
    static func available(allowed: [String]? = nil) async -> [AIToolSpec] {
        let disabled = Set(AIToolSettings.shared.disabledTools)
        var tools = builtIn.filter { !disabled.contains($0.name) && (allowed?.contains($0.name) ?? true) }
        if let skills = AISkills.shared.tool { tools.append(skills) }
        if allowed == nil || allowed?.contains("mcp") == true {
            tools += await MCPHub.shared.tools()
        }
        return tools
    }

    /// Le contexte des mentions (« @agenda », « @presse-papiers ») : les outils de lecture correspondants
    /// sont lancés d'avance et leur résultat joint à la question. Marche avec tous les modèles.
    static func mentionContext(in text: String) async -> String? {
        let lowered = text.lowercased()
        var parts: [String] = []
        for tool in builtIn where !tool.isAction || tool.name == "focus_session" {
            guard tool.mentions.contains(where: { lowered.contains($0) }) else { continue }
            var arguments: [String: Any] = [:]
            if tool.name == "focus_session" { arguments["action"] = "status" }
            if tool.name == "calendar_events" { arguments["days"] = 7 }
            let result = await tool.run(arguments)
            parts.append("Résultat de \(tool.mentions.first ?? tool.name) :\n\"\"\"\n\(result)\n\"\"\"")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Une recherche Spotlight dans le dossier de l'utilisateur.
    static func spotlight(_ queryString: String, limit: Int) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let query = MDQueryCreate(kCFAllocatorDefault, queryString as CFString, nil, nil) else {
                    continuation.resume(returning: [])
                    return
                }
                MDQuerySetSearchScope(query, [FileManager.default.homeDirectoryForCurrentUser.path as CFString] as CFArray, 0)
                MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue))
                var paths: [String] = []
                for index in 0..<MDQueryGetResultCount(query) where paths.count < limit {
                    guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
                    let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
                    if let path = MDItemCopyAttribute(item, kMDItemPath) as? String, !path.contains("/Library/"), !path.contains("/.") {
                        paths.append(path)
                    }
                }
                continuation.resume(returning: paths)
            }
        }
    }
}

/// Lire une page, chercher sur le web.
enum WebTools {
    static func read(_ url: URL) async -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return "Page injoignable." }
        guard (response as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { return "La page a répondu par une erreur." }
        let html = String(decoding: data, as: UTF8.self)
        return String(plainText(fromHTML: html).prefix(15_000))
    }

    /// Le texte lisible d'une page : sans scripts, styles ni balises.
    static func plainText(fromHTML html: String) -> String {
        var text = html
        for pattern in [#"(?is)<script.*?</script>"#, #"(?is)<style.*?</style>"#, #"(?is)<noscript.*?</noscript>"#, #"(?is)<!--.*?-->"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"(?i)<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "’", "&rsquo;": "’", "&eacute;": "é", "&egrave;": "è", "&agrave;": "à", "&ccedil;": "ç"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        text = text.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s*\n\\s*(\n\\s*)+", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func search(_ query: String) async -> String {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else { return "Recherche impossible." }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return "Recherche injoignable." }
        let results = parseDuckDuckGo(String(decoding: data, as: UTF8.self))
        guard !results.isEmpty else { return "Aucun résultat." }
        return results.prefix(8).map { "- \($0.title)\n  \($0.url)\n  \($0.snippet)" }.joined(separator: "\n")
    }

    static func parseDuckDuckGo(_ html: String) -> [(title: String, url: String, snippet: String)] {
        guard let regex = try? NSRegularExpression(pattern: #"(?s)<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>.*?class="result__snippet"[^>]*>(.*?)</a>"#) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { match in
            var link = ns.substring(with: match.range(at: 1))
            // Les liens passent par une redirection : « //duckduckgo.com/l/?uddg=<adresse> ».
            if let components = URLComponents(string: link.hasPrefix("//") ? "https:" + link : link),
               let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
                link = target
            }
            return (plainText(fromHTML: ns.substring(with: match.range(at: 2))), link, plainText(fromHTML: ns.substring(with: match.range(at: 3))))
        }
    }
}
