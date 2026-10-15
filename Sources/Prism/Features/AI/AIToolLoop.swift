import AppKit

/// Réglages des outils de l'IA (« ai.tools. »).
@MainActor
final class AIToolSettings: ObservableObject {
    static let shared = AIToolSettings()
    private let defaults = UserDefaults.standard

    /// Les modèles qui savent appeler des outils (Anthropic, OpenAI, Ollama) peuvent utiliser ceux de Prism.
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "ai.tools.enabled") } }
    /// Demander avant une action (créer un évènement, lancer une commande…). Les lectures passent sans demander.
    @Published var confirmActions: Bool { didSet { defaults.set(confirmActions, forKey: "ai.tools.confirmActions") } }
    @Published var disabledTools: [String] { didSet { defaults.set(disabledTools, forKey: "ai.tools.disabled") } }

    private init() {
        enabled = defaults.object(forKey: "ai.tools.enabled") as? Bool ?? true
        confirmActions = defaults.object(forKey: "ai.tools.confirmActions") as? Bool ?? true
        disabledTools = defaults.stringArray(forKey: "ai.tools.disabled") ?? []
    }
}

/// La boucle d'appels d'outils : le modèle demande un outil, Prism l'exécute, le résultat repart au modèle,
/// jusqu'à la réponse finale (8 tours au plus). Requêtes sans flux, la réponse finale s'affiche d'un coup.
@MainActor
enum AIToolLoop {
    struct Call {
        var id: String
        var name: String
        var arguments: [String: Any]
    }

    static func supports(_ kind: AIProviderKind) -> Bool { kind != .apple }

    /// Un modèle personnalisé n'appelle des outils que s'il le déclare (`abilities.tools.supported`).
    static func supports(_ resolved: AIResolvedModel) -> Bool {
        if let custom = AICustomProviders.resolve(resolved.model) { return custom.supportsTools }
        return supports(resolved.kind)
    }

    static func run(
        resolved: AIResolvedModel,
        messages: [AIMessage],
        system: String?,
        temperature: Double,
        tools: [AIToolSpec],
        status: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let settings = AISettings.shared
        var transcript: [[String: Any]] = AIRequestBuilder.conversation(messages).map { ["role": $0.role.rawValue, "content": $0.content] }
        let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for _ in 0..<8 {
            try Task.checkCancellation()
            if let error = AIUsage.shared.budgetError(for: resolved.kind) { throw error }
            let (text, calls, assistantMessage) = try await request(resolved: resolved, transcript: transcript, system: system, temperature: temperature, tools: tools, settings: settings)
            // Chaque tour compte : l'envoi (conversation et outils), la réponse et les appels d'outils.
            let sent = ((try? JSONSerialization.data(withJSONObject: transcript))?.count ?? 0) + (system?.count ?? 0) + tools.reduce(0) { $0 + $1.description.count + $1.name.count }
            let received = text.count + calls.reduce(0) { $0 + $1.name.count + "\($1.arguments)".count }
            AIUsage.shared.record(kind: resolved.kind, model: resolved.model, inputCharacters: sent, outputCharacters: received)
            guard !calls.isEmpty else { return text }
            transcript.append(assistantMessage)
            var results: [(Call, String)] = []
            for call in calls {
                guard let tool = byName[call.name] else {
                    results.append((call, "Outil inconnu : \(call.name)"))
                    continue
                }
                status("Outil : \(label(tool))…")
                if tool.isAction, AIToolSettings.shared.confirmActions, !confirm(tool, call: call) {
                    results.append((call, "L’utilisateur a refusé cette action."))
                    continue
                }
                results.append((call, await tool.run(call.arguments)))
            }
            transcript += resultMessages(results, kind: resolved.kind)
        }
        throw AIError.provider("Trop d’appels d’outils à la suite : la réponse a été interrompue.")
    }

    static let titles: [String: String] = [
        "current_date_time": "Date et heure", "calendar_events": "Lire l’agenda", "calendar_create_event": "Créer un évènement",
        "clipboard_history": "Chercher dans le presse-papiers", "notes_search": "Chercher dans les notes", "notes_create": "Créer une note",
        "focus_session": "Session de concentration", "files_search": "Chercher des fichiers", "snippets_search": "Chercher dans les snippets",
        "calculate": "Calculer", "run_prism_command": "Lancer une commande de Prism", "read_webpage": "Lire une page web",
        "web_search": "Chercher sur le web", "browser_tab": "Lire l’onglet du navigateur", "screen_text": "Lire l’écran",
        "remember": "Mémoriser un fait",
    ]

    static func label(_ tool: AIToolSpec) -> String {
        tool.source == "Prism" ? (titles[tool.name] ?? tool.name.replacingOccurrences(of: "_", with: " ")) : "\(tool.source) › \(tool.name)"
    }

    /// Demande l'accord avant une action.
    private static func confirm(_ tool: AIToolSpec, call: Call) -> Bool {
        let details = call.arguments.map { "\($0.key) : \($0.value)" }.sorted().joined(separator: "\n")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "L’IA veut utiliser « \(label(tool)) »"
        alert.informativeText = "\(tool.description)\n\n\(details)"
        alert.addButton(withTitle: "Autoriser")
        alert.addButton(withTitle: "Refuser")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Requêtes par fournisseur

    private static func request(
        resolved: AIResolvedModel,
        transcript: [[String: Any]],
        system: String?,
        temperature: Double,
        tools: [AIToolSpec],
        settings: AISettings
    ) async throws -> (String, [Call], [String: Any]) {
        switch resolved.kind {
        case .anthropic:
            guard let key = AIKeychain.read(.anthropic), !key.isEmpty else { throw AIError.missingKey(.anthropic) }
            var body: [String: Any] = [
                "model": resolved.model,
                "max_tokens": AIRequestBuilder.anthropicMaxTokens(resolved.model),
                "messages": transcript,
                "tools": tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema] },
            ]
            if let system, !system.isEmpty { body["system"] = system }
            if AIRequestBuilder.anthropicAcceptsTemperature(resolved.model) { body["temperature"] = min(max(temperature, 0), 1) }
            let json = try await post(AnthropicProvider.baseURL + "/v1/messages", body: body, headers: [
                "x-api-key": key, "anthropic-version": AIRequestBuilder.anthropicVersion,
            ], provider: .anthropic)
            return parseAnthropic(json)
        case .openAI:
            let custom = AICustomProviders.resolve(resolved.model)
            var messages = transcript
            if let system, !system.isEmpty { messages.insert(["role": custom?.supportsSystem == false ? "user" : "system", "content": system], at: 0) }
            var body: [String: Any] = [
                "model": custom?.modelID ?? resolved.model,
                "messages": messages,
                "tools": tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema]] },
            ]
            if custom?.supportsTemperature ?? AIRequestBuilder.openAIAcceptsTemperature(resolved.model) { body["temperature"] = temperature }
            guard let url = AIRequestBuilder.endpoint(custom?.baseURL ?? settings.openAIBaseURL, "/chat/completions") else { throw AIError.unavailable("Adresse de base invalide") }
            var headers: [String: String] = [:]
            let key = custom != nil ? custom?.key : AIKeychain.read(.openAI)
            if let key, !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
            let json = try await post(url.absoluteString, body: body, headers: headers, provider: .openAI)
            return parseOpenAI(json)
        case .ollama:
            var messages = transcript
            if let system, !system.isEmpty { messages.insert(["role": "system", "content": system], at: 0) }
            let body: [String: Any] = [
                "model": resolved.model,
                "messages": messages,
                "stream": false,
                "options": ["temperature": temperature],
                "tools": tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema]] },
            ]
            guard let url = AIRequestBuilder.endpoint(settings.ollamaURL, "/api/chat") else { throw AIError.unavailable("Adresse d’Ollama invalide") }
            let json = try await post(url.absoluteString, body: body, headers: [:], provider: .ollama)
            return parseOllama(json)
        case .apple:
            throw AIError.unavailable("Apple Intelligence n’appelle pas d’outils : utilisez les mentions (@agenda…).")
        }
    }

    private static func post(_ address: String, body: [String: Any], headers: [String: String], provider: AIProviderKind) async throws -> [String: Any] {
        guard let url = URL(string: address) else { throw AIError.unavailable("Adresse invalide") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AIStreaming.network(error, provider: provider, url: url)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AIError.http(status: status, message: AIError.message(fromBody: data)) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.provider("Réponse illisible") }
        return json
    }

    // MARK: - Lecture des réponses

    static func parseAnthropic(_ json: [String: Any]) -> (String, [Call], [String: Any]) {
        let content = json["content"] as? [[String: Any]] ?? []
        var text = ""
        var calls: [Call] = []
        for block in content {
            switch block["type"] as? String {
            case "text": text += block["text"] as? String ?? ""
            case "tool_use":
                calls.append(Call(id: block["id"] as? String ?? UUID().uuidString, name: block["name"] as? String ?? "", arguments: block["input"] as? [String: Any] ?? [:]))
            default: break
            }
        }
        return (text, calls, ["role": "assistant", "content": content])
    }

    static func parseOpenAI(_ json: [String: Any]) -> (String, [Call], [String: Any]) {
        let message = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) ?? [:]
        let toolCalls = message["tool_calls"] as? [[String: Any]] ?? []
        let calls = toolCalls.map { call -> Call in
            let function = call["function"] as? [String: Any] ?? [:]
            let raw = function["arguments"] as? String ?? "{}"
            let arguments = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
            return Call(id: call["id"] as? String ?? UUID().uuidString, name: function["name"] as? String ?? "", arguments: arguments)
        }
        var assistant: [String: Any] = ["role": "assistant", "content": message["content"] as? String ?? ""]
        if !toolCalls.isEmpty { assistant["tool_calls"] = toolCalls }
        return (message["content"] as? String ?? "", calls, assistant)
    }

    static func parseOllama(_ json: [String: Any]) -> (String, [Call], [String: Any]) {
        let message = json["message"] as? [String: Any] ?? [:]
        let toolCalls = message["tool_calls"] as? [[String: Any]] ?? []
        let calls = toolCalls.enumerated().map { index, call -> Call in
            let function = call["function"] as? [String: Any] ?? [:]
            return Call(id: "call_\(index)", name: function["name"] as? String ?? "", arguments: function["arguments"] as? [String: Any] ?? [:])
        }
        var assistant: [String: Any] = ["role": "assistant", "content": message["content"] as? String ?? ""]
        if !toolCalls.isEmpty { assistant["tool_calls"] = toolCalls }
        return (message["content"] as? String ?? "", calls, assistant)
    }

    static func resultMessages(_ results: [(Call, String)], kind: AIProviderKind) -> [[String: Any]] {
        switch kind {
        case .anthropic:
            return [["role": "user", "content": results.map { ["type": "tool_result", "tool_use_id": $0.0.id, "content": $0.1] }]]
        case .openAI:
            return results.map { ["role": "tool", "tool_call_id": $0.0.id, "content": $0.1] }
        default:
            return results.map { ["role": "tool", "content": $0.1] }
        }
    }
}
