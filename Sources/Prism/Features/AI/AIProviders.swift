import Foundation
import Security
#if canImport(FoundationModels)
@_weakLinked import FoundationModels
#endif

// MARK: - Messages et demandes

/// Un message d'une conversation avec un modèle.
struct AIMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case system, user, assistant
    }

    var role: Role
    var content: String
}

/// Une demande à un modèle : l'historique, les instructions système, la créativité.
struct AIRequest: Sendable {
    var model: String
    var messages: [AIMessage]
    var system: String?
    var temperature: Double
}

/// Les fournisseurs pris en charge.
enum AIProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case apple
    case ollama
    case openAI = "openai"
    case anthropic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple Intelligence (sur l’appareil)"
        case .ollama: "Ollama (local)"
        case .openAI: "OpenAI ou compatible"
        case .anthropic: "Anthropic"
        }
    }

    var shortTitle: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .ollama: "Ollama"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        }
    }

    var symbol: String {
        switch self {
        case .apple: "apple.logo"
        case .ollama: "desktopcomputer"
        case .openAI: "circle.hexagongrid.fill"
        case .anthropic: "asterisk"
        }
    }

    /// Rien ne quitte le Mac.
    var isLocal: Bool { self == .apple || self == .ollama }
}

/// Le modèle choisi pour Quick AI, AI Chat, une commande ou un préréglage.
/// Forme texte : « auto », « apple », « ollama:llama3.2:latest », « anthropic:claude-opus-5-5 ».
enum AIModelChoice: Hashable, Sendable {
    case auto
    case model(AIProviderKind, String)

    static let apple = AIModelChoice.model(.apple, "")

    init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "auto" else { self = .auto; return }
        let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
        guard let kind = AIProviderKind(rawValue: parts[0]) else { self = .auto; return }
        let model = parts.count > 1 ? parts[1] : ""
        self = .model(kind, kind == .apple ? "" : model)
    }

    var rawValue: String {
        switch self {
        case .auto: "auto"
        case .model(let kind, let model): model.isEmpty ? kind.rawValue : "\(kind.rawValue):\(model)"
        }
    }

    var provider: AIProviderKind? {
        if case .model(let kind, _) = self { return kind }
        return nil
    }

    /// « Claude Opus 5.5 », « llama3.2 », « Apple Intelligence ».
    var label: String {
        switch self {
        case .auto: "Auto"
        case .model(.apple, _): "Apple Intelligence"
        case .model(.openAI, let model) where model.hasPrefix("custom:"):
            AICustomProviders.label(model) ?? model
        case .model(let kind, let model): model.isEmpty ? kind.shortTitle : AIModelNames.display(model)
        }
    }
}

/// Noms lisibles des modèles.
enum AIModelNames {
    static let anthropicDefaults = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]

    /// « claude-opus-5-5 » devient « Claude Opus 5.5 » ; « gpt-5-mini », « GPT-5 mini » ; « llama3.2:latest », « llama3.2 ».
    static func display(_ id: String) -> String {
        if id.hasPrefix("claude-") {
            var words: [String] = []
            var version: [String] = []
            for part in id.dropFirst(7).split(separator: "-").map(String.init) {
                if part.count == 8, part.allSatisfy(\.isNumber) { break } // date d'un instantané
                if part.allSatisfy(\.isNumber) { version.append(part) } else { words.append(part.prefix(1).uppercased() + part.dropFirst()) }
            }
            return (["Claude"] + words + (version.isEmpty ? [] : [version.joined(separator: ".")])).joined(separator: " ")
        }
        if id.hasPrefix("gpt-") {
            let rest = id.dropFirst(4).split(separator: "-").map(String.init)
            guard let first = rest.first else { return id }
            return (["GPT-" + first] + rest.dropFirst()).joined(separator: " ")
        }
        if id.hasSuffix(":latest") { return String(id.dropLast(7)) }
        return id
    }
}

// MARK: - Erreurs

enum AIError: LocalizedError, Equatable {
    /// Fournisseur indisponible, avec l'explication.
    case unavailable(String)
    case missingKey(AIProviderKind)
    case http(status: Int, message: String)
    case provider(String)
    case network(String)
    case refusal

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .provider(let message), .network(let message):
            return message
        case .missingKey(let kind):
            return "Aucune clé d’API pour \(kind.shortTitle). Ajoutez-la dans Réglages de Prism › IA."
        case .refusal:
            return "Le modèle a refusé de répondre à cette demande."
        case .http(let status, let message):
            switch status {
            case 401, 403: return "Clé d’API refusée (\(status)). Vérifiez-la dans Réglages de Prism › IA." + (message.isEmpty ? "" : "\n\(message)")
            case 404: return "Modèle ou adresse introuvable (404)." + (message.isEmpty ? "" : "\n\(message)")
            case 429: return "Limite de débit ou de crédit atteinte (429). Réessayez plus tard." + (message.isEmpty ? "" : "\n\(message)")
            case 529, 503: return "Le service est surchargé (\(status)). Réessayez dans un instant."
            default: return "Erreur du service (\(status))" + (message.isEmpty ? "." : " : \(message)")
            }
        }
    }

    /// Le message d'erreur d'un corps de réponse JSON (OpenAI, Anthropic, Ollama).
    static func message(fromBody data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let error = json["error"] as? String { return error }
        if let message = json["message"] as? String { return message }
        return ""
    }
}

// MARK: - Lecture des flux

/// Ce qu'une ligne d'un flux de réponse apporte.
enum AIStreamEvent: Equatable {
    case text(String)
    case done
    case error(String)
}

/// Décodage ligne à ligne des flux : SSE d'OpenAI et d'Anthropic, NDJSON d'Ollama.
enum AIStreamDecoder {
    private static func json(_ text: Substring) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// La charge utile d'une ligne `data: …` (les lignes `event:` et les commentaires sont ignorés).
    private static func ssePayload(_ line: String) -> Substring? {
        guard line.hasPrefix("data:") else { return nil }
        return line.dropFirst(5).drop { $0 == " " }
    }

    /// `/v1/chat/completions` : `data: {"choices":[{"delta":{"content":"…"}}]}` puis `data: [DONE]`.
    static func openAI(_ line: String) -> [AIStreamEvent] {
        guard let payload = ssePayload(line) else { return [] }
        if payload.trimmingCharacters(in: .whitespaces) == "[DONE]" { return [.done] }
        guard let object = json(payload) else { return [] }
        if let error = object["error"] as? [String: Any] {
            return [.error(error["message"] as? String ?? "Erreur du service")]
        }
        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else { return [] }
        if let delta = first["delta"] as? [String: Any], let content = delta["content"] as? String, !content.isEmpty {
            return [.text(content)]
        }
        return []
    }

    /// `/v1/messages` : `content_block_delta` (texte ; la réflexion est ignorée), `message_delta`, `message_stop`, `error`.
    static func anthropic(_ line: String) -> [AIStreamEvent] {
        guard let payload = ssePayload(line), let object = json(payload) else { return [] }
        switch object["type"] as? String {
        case "content_block_delta":
            if let delta = object["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String, !text.isEmpty {
                return [.text(text)]
            }
            return []
        case "message_delta":
            if let delta = object["delta"] as? [String: Any], delta["stop_reason"] as? String == "refusal" {
                return [.error(AIError.refusal.errorDescription ?? "")]
            }
            return []
        case "message_stop":
            return [.done]
        case "error":
            let error = object["error"] as? [String: Any]
            let kind = error?["type"] as? String
            if kind == "overloaded_error" { return [.error(AIError.http(status: 529, message: "").errorDescription ?? "")] }
            return [.error(error?["message"] as? String ?? "Erreur du service")]
        default:
            return []
        }
    }

    /// `/api/chat` d'Ollama : un objet JSON par ligne, `done: true` à la fin.
    static func ollama(_ line: String) -> [AIStreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let object = json(Substring(trimmed)) else { return [] }
        if let error = object["error"] as? String { return [.error(error)] }
        var events: [AIStreamEvent] = []
        if let message = object["message"] as? [String: Any], let content = message["content"] as? String, !content.isEmpty {
            events.append(.text(content))
        }
        if object["done"] as? Bool == true { events.append(.done) }
        return events
    }
}

// MARK: - Construction des requêtes

enum AIRequestBuilder {
    static let anthropicVersion = "2023-06-01"

    /// Les messages sans les messages système, sans les vides : les API les refusent.
    static func conversation(_ messages: [AIMessage]) -> [AIMessage] {
        messages.filter { $0.role != .system && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func endpoint(_ base: String, _ path: String) -> URL? {
        var base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path)
    }

    private static func post(_ url: URL, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Les modèles de raisonnement d'OpenAI n'acceptent que la température par défaut.
    static func openAIAcceptsTemperature(_ model: String) -> Bool {
        let lower = model.lowercased()
        return !(lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4") || lower.hasPrefix("gpt-5"))
    }

    /// `POST {base}/chat/completions`, en flux SSE. La clé est facultative pour les serveurs locaux compatibles.
    static func openAI(_ request: AIRequest, baseURL: String, key: String?) throws -> URLRequest {
        guard let url = endpoint(baseURL, "/chat/completions") else { throw AIError.unavailable("Adresse de base invalide : \(baseURL)") }
        var messages: [[String: String]] = []
        if let system = request.system, !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages += conversation(request.messages).map { ["role": $0.role.rawValue, "content": $0.content] }
        var body: [String: Any] = ["model": request.model, "messages": messages, "stream": true]
        if openAIAcceptsTemperature(request.model) { body["temperature"] = request.temperature }
        var urlRequest = try post(url, body: body)
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let key, !key.isEmpty { urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return urlRequest
    }

    /// Depuis Claude Opus 4.7, et sur toute la génération 5, la température n'est plus réglable (400 sinon).
    static func anthropicAcceptsTemperature(_ model: String) -> Bool {
        if model.hasPrefix("claude-3") { return true }
        return model.range(of: #"^claude-(opus|sonnet|haiku)-4(-[0-6])?($|-)"#, options: .regularExpression) != nil
    }

    /// Plafond de sortie : large en flux pour les modèles récents, celui des anciennes générations sinon.
    static func anthropicMaxTokens(_ model: String) -> Int {
        if model.hasPrefix("claude-3") { return 8_192 }
        if model.range(of: #"^claude-(opus|sonnet|haiku)-4(-[0-5])?($|-)"#, options: .regularExpression) != nil { return 32_000 }
        return 64_000
    }

    /// `POST /v1/messages`, en flux SSE. Les messages système vont dans `system`.
    static func anthropic(_ request: AIRequest, key: String, baseURL: String = "https://api.anthropic.com") throws -> URLRequest {
        guard let url = endpoint(baseURL, "/v1/messages") else { throw AIError.unavailable("Adresse invalide") }
        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": anthropicMaxTokens(request.model),
            "stream": true,
            "messages": conversation(request.messages).map { ["role": $0.role.rawValue, "content": $0.content] },
        ]
        if let system = request.system, !system.isEmpty { body["system"] = system }
        if anthropicAcceptsTemperature(request.model) { body["temperature"] = min(max(request.temperature, 0), 1) }
        var urlRequest = try post(url, body: body)
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return urlRequest
    }

    /// `POST /api/chat` d'Ollama, en NDJSON.
    static func ollama(_ request: AIRequest, baseURL: String) throws -> URLRequest {
        guard let url = endpoint(baseURL, "/api/chat") else { throw AIError.unavailable("Adresse d’Ollama invalide : \(baseURL)") }
        var messages: [[String: String]] = []
        if let system = request.system, !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages += conversation(request.messages).map { ["role": $0.role.rawValue, "content": $0.content] }
        return try post(url, body: [
            "model": request.model,
            "messages": messages,
            "stream": true,
            "options": ["temperature": request.temperature],
        ])
    }
}

// MARK: - Transport

enum AIStreaming {
    /// Envoie la requête et décode le flux ligne à ligne. Annuler la tâche consommatrice coupe la connexion.
    static func lines(
        _ request: URLRequest,
        provider: AIProviderKind,
        decode: @escaping @Sendable (String) -> [AIStreamEvent]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 64_000 { break }
                        }
                        throw AIError.http(status: http.statusCode, message: AIError.message(fromBody: body))
                    }
                    for try await line in bytes.lines {
                        for event in decode(line) {
                            switch event {
                            case .text(let text): continuation.yield(text)
                            case .done: continuation.finish(); return
                            case .error(let message): throw AIError.provider(message)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: network(error, provider: provider, url: request.url))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Un message clair pour les erreurs réseau.
    static func network(_ error: Error, provider: AIProviderKind, url: URL?) -> Error {
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost where provider == .ollama:
            return AIError.network("Ollama ne répond pas sur \(url?.host ?? "localhost"):\(url?.port ?? 11434). Lancez l’application Ollama ou « ollama serve ».")
        case .notConnectedToInternet, .networkConnectionLost:
            return AIError.network("Pas de connexion à Internet.")
        case .timedOut:
            return AIError.network("Le service ne répond pas (délai dépassé).")
        default:
            return AIError.network(urlError.localizedDescription)
        }
    }

    /// Un GET JSON (listes de modèles).
    static func getJSON(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 4) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AIError.http(status: http.statusCode, message: AIError.message(fromBody: data))
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

// MARK: - Fournisseurs

enum OllamaProvider {
    static func stream(_ request: AIRequest, baseURL: String) -> AsyncThrowingStream<String, Error> {
        do {
            return AIStreaming.lines(try AIRequestBuilder.ollama(request, baseURL: baseURL), provider: .ollama, decode: AIStreamDecoder.ollama)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    /// Les modèles installés (`/api/tags`) ; `nil` si Ollama ne répond pas.
    static func models(baseURL: String) async -> [String]? {
        guard let url = AIRequestBuilder.endpoint(baseURL, "/api/tags"),
              let json = try? await AIStreaming.getJSON(url, timeout: 1.5) else { return nil }
        let models = (json["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return models.sorted()
    }
}

enum OpenAIProvider {
    static let defaultBaseURL = "https://api.openai.com/v1"

    static func stream(_ request: AIRequest, baseURL: String, key: String?) -> AsyncThrowingStream<String, Error> {
        do {
            return AIStreaming.lines(try AIRequestBuilder.openAI(request, baseURL: baseURL, key: key), provider: .openAI, decode: AIStreamDecoder.openAI)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    /// `GET {base}/models`. Chez OpenAI, seuls les modèles de conversation sont gardés.
    static func models(baseURL: String, key: String?) async throws -> [String] {
        guard let url = AIRequestBuilder.endpoint(baseURL, "/models") else { return [] }
        var headers: [String: String] = [:]
        if let key, !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
        let json = try await AIStreaming.getJSON(url, headers: headers, timeout: 8)
        let ids = (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        guard baseURL.contains("api.openai.com") else { return ids.sorted() }
        let excluded = ["audio", "realtime", "transcribe", "tts", "image", "embedding", "search", "moderation", "whisper", "dall-e", "davinci", "babbage", "instruct"]
        return ids.filter { id in
            (id.hasPrefix("gpt-") || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") || id.hasPrefix("chatgpt"))
                && !excluded.contains { id.contains($0) }
        }.sorted()
    }
}

enum AnthropicProvider {
    /// L'adresse de l'API ; `PRISM_ANTHROPIC_BASE_URL` la remplace pour les essais contre un serveur local.
    static var baseURL: String { ProcessInfo.processInfo.environment["PRISM_ANTHROPIC_BASE_URL"] ?? "https://api.anthropic.com" }

    static func stream(_ request: AIRequest, key: String) -> AsyncThrowingStream<String, Error> {
        do {
            return AIStreaming.lines(try AIRequestBuilder.anthropic(request, key: key, baseURL: baseURL), provider: .anthropic, decode: AIStreamDecoder.anthropic)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }
}

/// Le modèle d'Apple Intelligence, sur l'appareil, sans réseau (FoundationModels, macOS 26).
enum AppleIntelligence {
    /// Disponibilité et, sinon, l'explication à montrer.
    static var status: (isAvailable: Bool, message: String) {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return (true, "Disponible, sur l’appareil")
            case .unavailable(.deviceNotEligible):
                return (false, "Ce Mac ne prend pas en charge Apple Intelligence (puce Apple M1 ou plus récente requise).")
            case .unavailable(.appleIntelligenceNotEnabled):
                return (false, "Apple Intelligence est désactivée : activez-la dans Réglages Système › Apple Intelligence et Siri.")
            case .unavailable(.modelNotReady):
                return (false, "Le modèle d’Apple Intelligence se télécharge ou se prépare. Réessayez dans quelques minutes.")
            case .unavailable:
                return (false, "Apple Intelligence n’est pas disponible pour le moment.")
            }
        }
        return (false, "Apple Intelligence sur l’appareil demande macOS 26 ou plus récent.")
        #else
        return (false, "Cette version de Prism a été compilée sans FoundationModels.")
        #endif
    }

    /// Le modèle n'a que 4 096 jetons de contexte : l'historique est replié dans la demande, le plus récent d'abord.
    static func prompt(for messages: [AIMessage], budget: Int = 7_000) -> String {
        let turns = AIRequestBuilder.conversation(messages)
        guard let last = turns.last else { return "" }
        let previous = turns.dropLast()
        guard !previous.isEmpty else { return last.content }
        var history: [String] = []
        var used = 0
        for message in previous.reversed() {
            let line = (message.role == .user ? "Utilisateur : " : "Assistant : ") + message.content
            if used + line.count > budget { break }
            history.insert(line, at: 0)
            used += line.count
        }
        guard !history.isEmpty else { return last.content }
        return "Conversation jusqu’ici :\n\(history.joined(separator: "\n\n"))\n\nNouvelle demande de l’utilisateur :\n\(last.content)"
    }

    static func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let status = status
            guard status.isAvailable else {
                return AsyncThrowingStream { $0.finish(throwing: AIError.unavailable(status.message)) }
            }
            let prompt = prompt(for: request.messages)
            let instructions = request.system
            let temperature = min(max(request.temperature, 0), 1.5)
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let session = LanguageModelSession(instructions: instructions)
                        let stream = session.streamResponse(to: prompt, options: GenerationOptions(temperature: temperature))
                        // Chaque instantané contient toute la réponse jusque-là : on n'envoie que la suite.
                        var sent = ""
                        for try await snapshot in stream {
                            let content = snapshot.content
                            if content.hasPrefix(sent) {
                                let delta = String(content.dropFirst(sent.count))
                                if !delta.isEmpty { continuation.yield(delta) }
                            } else {
                                continuation.yield(content)
                            }
                            sent = content
                        }
                        continuation.finish()
                    } catch let error as LanguageModelSession.GenerationError {
                        continuation.finish(throwing: AIError.provider(describe(error)))
                    } catch {
                        if Task.isCancelled || error is CancellationError { continuation.finish() } else { continuation.finish(throwing: error) }
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        #endif
        return AsyncThrowingStream { $0.finish(throwing: AIError.unavailable(status.message)) }
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize:
            return "La conversation dépasse ce que le modèle d’Apple peut lire (4 096 jetons). Commencez une nouvelle conversation (⌘N) ou choisissez un autre modèle."
        case .guardrailViolation, .refusal:
            return "Apple Intelligence a refusé de répondre à cette demande (filtres de sécurité d’Apple)."
        case .unsupportedLanguageOrLocale:
            return "Cette langue n’est pas prise en charge par le modèle d’Apple Intelligence."
        case .assetsUnavailable:
            return "Le modèle d’Apple Intelligence n’est pas prêt (téléchargement en cours ou espace insuffisant)."
        case .rateLimited, .concurrentRequests:
            return "Apple Intelligence est occupée. Réessayez dans un instant."
        default:
            return error.localizedDescription
        }
    }
    #endif
}

// MARK: - Clés d'API

/// Les clés d'API dans le trousseau (service « app.prism.launcher.ai »). Jamais lues pendant les essais.
@MainActor
enum AIKeychain {
    static let service = "app.prism.launcher.ai"
    private static var cache: [String: String?] = [:]

    static func read(_ provider: AIProviderKind) -> String? {
        // Essais contre un serveur local : une clé factice, sans toucher au trousseau.
        if provider == .anthropic, let key = ProcessInfo.processInfo.environment["PRISM_ANTHROPIC_TEST_KEY"] { return key }
        guard !AIRuntime.isEphemeral else { return nil }
        let account = provider.rawValue
        if let cached = cache[account] { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let value = status == errSecSuccess ? (result as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        cache[account] = .some(value)
        return value
    }

    static func hasKey(_ provider: AIProviderKind) -> Bool {
        !(read(provider) ?? "").isEmpty
    }

    @discardableResult
    static func save(_ value: String, for provider: AIProviderKind) -> Bool {
        guard !AIRuntime.isEphemeral else { return false }
        let account = provider.rawValue
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = "Prism — clé d’API \(provider.shortTitle)"
        let status = SecItemAdd(item as CFDictionary, nil)
        cache[account] = .some(status == errSecSuccess ? value : nil)
        return status == errSecSuccess
    }

    static func delete(_ provider: AIProviderKind) {
        guard !AIRuntime.isEphemeral else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
        cache[provider.rawValue] = .some(nil)
    }

    /// « sk-…a1b2 » : de quoi reconnaître la clé sans l'afficher.
    static func masked(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        return String(key.prefix(3)) + "…" + String(key.suffix(4))
    }
}
