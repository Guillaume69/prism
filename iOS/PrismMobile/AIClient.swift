import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// L'IA de Prism sur l'iPhone : Apple Intelligence sur l'appareil (gratuit, privé), ou vos clés Anthropic / OpenAI.
enum AIProvider: String, CaseIterable, Identifiable {
    case apple, anthropic, openai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple Intelligence (sur l’appareil)"
        case .anthropic: "Anthropic"
        case .openai: "OpenAI ou compatible"
        }
    }

    static var current: AIProvider {
        get { AIProvider(rawValue: UserDefaults.standard.string(forKey: "ai.provider") ?? "") ?? .apple }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "ai.provider") }
    }
}

struct AIMessage: Identifiable, Equatable {
    let id = UUID()
    var role: String
    var content: String
}

enum AIClient {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static let system = "Tu es l’assistant de Prism sur iPhone. Réponds dans la langue de l’utilisateur, de façon claire et concise, en Markdown."

    static var anthropicModel: String { UserDefaults.standard.string(forKey: "ai.anthropic.model").flatMap { $0.isEmpty ? nil : $0 } ?? "claude-sonnet-5-5" }
    static var openAIModel: String { UserDefaults.standard.string(forKey: "ai.openai.model").flatMap { $0.isEmpty ? nil : $0 } ?? "gpt-5" }
    static var openAIBase: String { UserDefaults.standard.string(forKey: "ai.openai.base").flatMap { $0.isEmpty ? nil : $0 } ?? "https://api.openai.com/v1" }

    /// La réponse, morceau par morceau.
    static func stream(_ messages: [AIMessage], provider: AIProvider = .current) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch provider {
                    case .apple: try await apple(messages, continuation)
                    case .anthropic: try await anthropic(messages, continuation)
                    case .openai: try await openAI(messages, continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Essai sans interface : `-PrismAITest "question"` au lancement écrit la réponse (ou l'erreur détaillée)
    /// dans Documents/ai-test.txt.
    static func runLaunchTestIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-PrismAITest"), index + 1 < arguments.count else { return }
        let question = arguments[index + 1]
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ai-test.txt")
        Task {
            var report = "fournisseur : \(AIProvider.current.rawValue)\n"
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) { report += "disponibilité : \(SystemLanguageModel.default.availability)\n" }
            #endif
            do {
                var answer = ""
                for try await chunk in stream([AIMessage(role: "user", content: question)]) { answer += chunk }
                report += "réponse : \(answer)\n"
            } catch {
                report += "erreur : \(error.localizedDescription)\ndétail : \(String(reflecting: error))\n"
            }
            try? report.write(to: output, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Apple Intelligence

    private static func apple(_ messages: [AIMessage], _ continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                throw Failure("Apple Intelligence n’est pas disponible sur cet appareil : choisissez Anthropic ou OpenAI dans les réglages.")
            }
            let history = messages.dropLast().map { "\($0.role == "user" ? "Utilisateur" : "Assistant") : \($0.content)" }.joined(separator: "\n\n")
            let instructions = system + (history.isEmpty ? "" : "\n\nConversation jusqu’ici :\n" + history)
            // Garde-fous par défaut ; l'essai sans interface peut demander ceux des transformations de contenu
            // (le simulateur n'a pas les ressources du modèle de sécurité).
            let model = ProcessInfo.processInfo.arguments.contains("-PrismAIPermissive")
                ? SystemLanguageModel(guardrails: .permissiveContentTransformations) : SystemLanguageModel.default
            let session = LanguageModelSession(model: model, instructions: instructions)
            var sent = ""
            do {
                for try await snapshot in session.streamResponse(to: messages.last?.content ?? "") {
                let text = snapshot.content
                if text.count > sent.count, text.hasPrefix(sent) {
                    continuation.yield(String(text.dropFirst(sent.count)))
                } else if text != sent {
                    continuation.yield(text)
                }
                sent = text
                }
            } catch let error as LanguageModelSession.GenerationError {
                throw Failure(describe(error))
            } catch {
                // Le modèle de sécurité absent (ressources pas encore téléchargées, simulateur) remonte ainsi.
                if String(reflecting: error).contains("SensitiveContentAnalysis") {
                    throw Failure("Les ressources de sécurité d’Apple Intelligence ne sont pas encore téléchargées sur cet appareil : réessayez plus tard, ou choisissez un autre modèle dans les réglages.")
                }
                throw error
            }
            return
        }
        #endif
        throw Failure("Apple Intelligence demande iOS 26 : choisissez Anthropic ou OpenAI dans les réglages.")
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .assetsUnavailable: "Le modèle d’Apple Intelligence n’est pas encore téléchargé sur cet appareil."
        case .unsupportedLanguageOrLocale: "Apple Intelligence ne prend pas en charge cette langue ici."
        case .guardrailViolation: "Apple Intelligence a refusé cette demande (garde-fou)."
        case .exceededContextWindowSize: "La conversation est trop longue pour le modèle sur l’appareil."
        case .rateLimited, .concurrentRequests: "Apple Intelligence est occupé : réessayez dans un instant."
        default: "Apple Intelligence n’a pas pu répondre (\(String(describing: error)))."
        }
    }
    #endif

    // MARK: Anthropic

    private static func anthropic(_ messages: [AIMessage], _ continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        guard let key = Keychain.read("ai.anthropic.key"), !key.isEmpty else { throw Failure("Ajoutez votre clé Anthropic dans les réglages.") }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": anthropicModel, "max_tokens": 4096, "stream": true, "system": system,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try await events(request) { event in
            guard event["type"] as? String == "content_block_delta", let delta = event["delta"] as? [String: Any], let text = delta["text"] as? String else { return }
            continuation.yield(text)
        }
    }

    // MARK: OpenAI ou compatible

    private static func openAI(_ messages: [AIMessage], _ continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        guard let key = Keychain.read("ai.openai.key"), !key.isEmpty else { throw Failure("Ajoutez votre clé OpenAI dans les réglages.") }
        guard let url = URL(string: openAIBase.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else { throw Failure("Adresse du service invalide") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": openAIModel, "stream": true,
            "messages": [["role": "system", "content": system]] + messages.map { ["role": $0.role, "content": $0.content] },
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try await events(request) { event in
            guard let choices = event["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any],
                  let text = delta["content"] as? String else { return }
            continuation.yield(text)
        }
    }

    /// Les évènements d'une réponse en flux (`data: {…}`).
    private static func events(_ request: URLRequest, _ handle: ([String: Any]) -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure("Réponse invalide") }
        guard http.statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line }
            let message = ((try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
            throw Failure(message ?? "Erreur \(http.statusCode)")
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            if let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] { handle(event) }
        }
    }
}
