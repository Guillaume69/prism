import AppKit
import UserNotifications
import Combine
import SwiftUI

/// Un modèle prêt à répondre : le fournisseur et l'identifiant exact.
struct AIResolvedModel: Equatable {
    let kind: AIProviderKind
    let model: String

    var label: String { AIModelChoice.model(kind, model).label }
    var choice: AIModelChoice { .model(kind, model) }
}

/// Choisit le fournisseur, résout « Auto » et lance les demandes.
@MainActor
enum AIRouter {
    /// « Auto » : le meilleur disponible, Anthropic, puis OpenAI, puis Apple Intelligence, puis Ollama.
    static func resolve(_ choice: AIModelChoice) async throws -> AIResolvedModel {
        let settings = AISettings.shared
        switch choice {
        case .auto:
            if AIKeychain.read(.anthropic)?.isEmpty == false { return AIResolvedModel(kind: .anthropic, model: settings.anthropicModel) }
            if AIKeychain.hasKey(.openAI) { return AIResolvedModel(kind: .openAI, model: settings.openAIModel) }
            if AppleIntelligence.status.isAvailable { return AIResolvedModel(kind: .apple, model: "") }
            if let models = await OllamaProvider.models(baseURL: settings.ollamaURL), !models.isEmpty {
                let model = models.contains(settings.ollamaModel) ? settings.ollamaModel : models[0]
                return AIResolvedModel(kind: .ollama, model: model)
            }
            throw AIError.unavailable("Aucun modèle disponible. \(AppleIntelligence.status.message) Vous pouvez aussi lancer Ollama ou ajouter une clé d’API dans Réglages de Prism › IA.")
        case .model(.apple, _):
            let status = AppleIntelligence.status
            guard status.isAvailable else {
                throw AIError.unavailable(status.message + "\nEn attendant, choisissez un autre modèle (⌘K › Changer de modèle) ou « Auto » dans Réglages de Prism › IA.")
            }
            return AIResolvedModel(kind: .apple, model: "")
        case .model(.ollama, let model):
            if !model.isEmpty { return AIResolvedModel(kind: .ollama, model: model) }
            if !settings.ollamaModel.isEmpty { return AIResolvedModel(kind: .ollama, model: settings.ollamaModel) }
            guard let models = await OllamaProvider.models(baseURL: settings.ollamaURL) else {
                throw AIError.network("Ollama ne répond pas sur \(settings.ollamaURL). Lancez l’application Ollama ou « ollama serve ».")
            }
            guard let first = models.first else {
                throw AIError.unavailable("Aucun modèle installé dans Ollama. Installez-en un, par exemple : ollama pull llama3.2")
            }
            return AIResolvedModel(kind: .ollama, model: first)
        case .model(.openAI, let model) where model.hasPrefix("custom:"):
            guard AICustomProviders.resolve(model) != nil else { throw AIError.unavailable("Modèle personnalisé introuvable dans providers.json : \(model)") }
            return AIResolvedModel(kind: .openAI, model: model)
        case .model(.openAI, let model):
            let isOpenAI = settings.openAIBaseURL.contains("api.openai.com")
            if isOpenAI, !AIKeychain.hasKey(.openAI) { throw AIError.missingKey(.openAI) }
            return AIResolvedModel(kind: .openAI, model: model.isEmpty ? settings.openAIModel : model)
        case .model(.anthropic, let model):
            guard AIKeychain.read(.anthropic)?.isEmpty == false else { throw AIError.missingKey(.anthropic) }
            return AIResolvedModel(kind: .anthropic, model: model.isEmpty ? settings.anthropicModel : model)
        }
    }

    /// La réponse en flux, comptée dans « Utilisation de l'IA » et refusée si le budget du mois est atteint.
    static func stream(_ resolved: AIResolvedModel, request: AIRequest) -> AsyncThrowingStream<String, Error> {
        if let error = AIUsage.shared.budgetError(for: resolved.kind) {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let inner = providerStream(resolved, request: request)
        let input = (request.system?.count ?? 0) + request.messages.reduce(0) { $0 + $1.content.count }
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                var output = 0
                do {
                    for try await chunk in inner {
                        output += chunk.count
                        continuation.yield(chunk)
                    }
                    AIUsage.shared.record(kind: resolved.kind, model: resolved.model, inputCharacters: input, outputCharacters: output)
                    continuation.finish()
                } catch {
                    if output > 0 { AIUsage.shared.record(kind: resolved.kind, model: resolved.model, inputCharacters: input, outputCharacters: output) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func providerStream(_ resolved: AIResolvedModel, request: AIRequest) -> AsyncThrowingStream<String, Error> {
        let settings = AISettings.shared
        var request = request
        request.model = resolved.model
        switch resolved.kind {
        case .apple:
            return AppleIntelligence.stream(request)
        case .ollama:
            return OllamaProvider.stream(request, baseURL: settings.ollamaURL)
        case .openAI:
            if let custom = AICustomProviders.resolve(request.model) {
                request.model = custom.modelID
                if !custom.supportsSystem, let system = request.system {
                    request.messages.insert(AIMessage(role: .user, content: system), at: 0)
                    request.system = nil
                }
                return OpenAIProvider.stream(request, baseURL: custom.baseURL, key: custom.key)
            }
            return OpenAIProvider.stream(request, baseURL: settings.openAIBaseURL, key: AIKeychain.read(.openAI))
        case .anthropic:
            guard let key = AIKeychain.read(.anthropic), !key.isEmpty else {
                return AsyncThrowingStream { $0.finish(throwing: AIError.missingKey(.anthropic)) }
            }
            return AnthropicProvider.stream(request, key: key)
        }
    }

    /// Une réponse d'un seul tenant.
    static func complete(_ messages: [AIMessage], system: String?, choice: AIModelChoice, temperature: Double? = nil) async throws -> String {
        let resolved = try await resolve(choice)
        return try await complete(messages, system: system, resolved: resolved, temperature: temperature)
    }

    static func complete(_ messages: [AIMessage], system: String?, resolved: AIResolvedModel, temperature: Double? = nil) async throws -> String {
        let request = AIRequest(model: resolved.model, messages: messages, system: system, temperature: temperature ?? AISettings.shared.temperature)
        var text = ""
        for try await chunk in stream(resolved, request: request) { text += chunk }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Une conversation en cours

/// Une conversation et sa génération en flux, partagée par Quick AI, les commandes et AI Chat.
@MainActor
final class AIChatSession: ObservableObject {
    @Published var conversation: AIConversation
    /// La réponse en train de s'écrire.
    @Published private(set) var streamingText = ""
    @Published private(set) var isGenerating = false
    @Published var error: String?
    /// Le modèle qui répond (ou vient de répondre).
    @Published private(set) var activeModelLabel: String?

    var id: UUID { conversation.id }
    let usage: AISettings.Usage
    /// Gardée dans l'historique.
    var persists: Bool
    /// Instructions ajoutées à celles de Prism (commandes, préréglage).
    var systemExtra: String?
    var temperatureOverride: Double?
    /// Appelé quand l'état change (début, fin, erreur), pas à chaque morceau de réponse.
    var onStateChange: (() -> Void)?
    /// Appelé à la fin d'une réponse complète.
    var onFinish: ((String) -> Void)?
    private(set) var lastActivity: Date?

    private var task: Task<Void, Never>?
    private var generation = 0
    /// Empêche la veille pendant la génération (réglage).
    private var activity: NSObjectProtocol?
    private var partial = ""

    init(conversation: AIConversation = AIConversation(), usage: AISettings.Usage, persists: Bool = true) {
        self.conversation = conversation
        self.usage = usage
        self.persists = persists && !AIRuntime.isEphemeral
    }

    /// Le modèle de la conversation, sinon celui du préréglage, sinon celui par défaut.
    var choice: AIModelChoice {
        if let model = conversation.model { return AIModelChoice(rawValue: model) }
        if let model = preset?.model { return AIModelChoice(rawValue: model) }
        return AISettings.shared.choice(for: usage)
    }

    var preset: AIPreset? { AIPresetStore.shared.preset(conversation.presetID) }

    var modelLabel: String { activeModelLabel ?? choice.label }

    var lastAnswer: String? { conversation.lastAnswer }

    func setModel(_ choice: AIModelChoice?) {
        conversation.model = choice?.rawValue
        activeModelLabel = nil
        save()
        onStateChange?()
    }

    // MARK: Envoi

    func send(_ text: String, attachments: [AIAttachment] = [], displayText: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        if isGenerating { stop() }
        var message = AIChatMessage(role: .user, content: trimmed, attachments: attachments)
        message.displayText = displayText
        conversation.messages.append(message)
        if conversation.messages.filter({ $0.role == .user }).count == 1, !conversation.isTitleManual {
            conversation.title = AITitle.make(from: displayText ?? (trimmed.isEmpty ? attachments.first?.title ?? "" : trimmed))
        }
        conversation.updated = Date()
        save()
        generate()
    }

    /// Refait la dernière réponse.
    func regenerate() {
        cancelCurrent()
        while let last = conversation.messages.last, last.role == .assistant {
            conversation.messages.removeLast()
        }
        guard conversation.messages.last?.role == .user else { return }
        generate()
    }

    /// Modifie le dernier message de l'utilisateur et relance la réponse.
    func editLastUserMessage(_ text: String) {
        guard let index = conversation.messages.lastIndex(where: { $0.role == .user }) else { return }
        cancelCurrent()
        let attachments = conversation.messages[index].attachments
        conversation.messages.removeSubrange(index...)
        send(text, attachments: attachments)
    }

    /// Arrête la génération en gardant ce qui est déjà écrit.
    func stop() {
        guard isGenerating else { return }
        endActivity()
        generation += 1
        task?.cancel()
        task = nil
        let text = partial
        partial = ""
        streamingText = ""
        isGenerating = false
        if !text.isEmpty {
            conversation.messages.append(AIChatMessage(role: .assistant, content: text, model: activeModelLabel))
            conversation.updated = Date()
            save()
        }
        onStateChange?()
    }

    private func cancelCurrent() {
        generation += 1
        task?.cancel()
        task = nil
        partial = ""
        streamingText = ""
        isGenerating = false
    }

    private func generate() {
        generation += 1
        let token = generation
        task?.cancel()
        error = nil
        partial = ""
        streamingText = ""
        isGenerating = true
        lastActivity = Date()
        if AISettings.shared.preventSleep, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Réponse de l’IA en cours")
        }
        onStateChange?()

        let messages = conversation.messages.map(\.forModel)
        let settings = AISettings.shared
        let projectContext = AIProjectStore.shared.context(for: conversation.projectID)
        let extra = [projectContext, preset?.instructions, systemExtra].compactMap { $0 }.joined(separator: "\n\n")
        let allowedTools = preset?.tools
        let system = settings.systemPrompt(extra: extra)
        let temperature = temperatureOverride ?? settings.temperature
        let choice = choice

        task = Task { [weak self] in
            do {
                let resolved = try await AIRouter.resolve(choice)
                guard let self, self.generation == token else { return }
                self.activeModelLabel = resolved.label
                self.onStateChange?()
                var messages = messages
                // « @agenda », « @presse-papiers »… : le résultat des outils de lecture rejoint la question.
                if let last = messages.last, last.role == .user, let context = await AITools.mentionContext(in: last.content) {
                    messages[messages.count - 1].content = context + "\n\n" + last.content
                }
                // « @nom-d-un-skill » : le skill rejoint la question, pour tous les modèles.
                if let last = messages.last, last.role == .user {
                    let skills = AISkills.shared.mentioned(in: last.content)
                    if !skills.isEmpty {
                        let text = skills.map { "Skill « \($0.name) » :\n\($0.body)" }.joined(separator: "\n\n")
                        messages[messages.count - 1].content = text + "\n\n" + messages[messages.count - 1].content
                    }
                }
                guard self.generation == token else { return }
                // Les modèles qui savent appeler des outils utilisent ceux de Prism et des serveurs MCP.
                if AIToolSettings.shared.enabled, AIToolLoop.supports(resolved) {
                    let tools = await AITools.available(allowed: allowedTools)
                    let toolSystem = [system, AISkills.shared.catalog].compactMap { $0 }.joined(separator: "\n\n")
                    let answer = try await AIToolLoop.run(resolved: resolved, messages: messages, system: toolSystem, temperature: temperature, tools: tools) { status in
                        guard self.generation == token else { return }
                        self.streamingText = "_\(status)_"
                    }
                    guard self.generation == token else { return }
                    self.partial = answer
                    self.finish(resolved: resolved)
                    return
                }
                let request = AIRequest(model: resolved.model, messages: messages, system: system, temperature: temperature)
                var lastPublish = Date.distantPast
                for try await chunk in AIRouter.stream(resolved, request: request) {
                    guard self.generation == token else { return }
                    self.partial += chunk
                    if Date().timeIntervalSince(lastPublish) > 0.04 {
                        self.streamingText = self.partial
                        lastPublish = Date()
                    }
                }
                guard self.generation == token else { return }
                self.finish(resolved: resolved)
            } catch {
                guard let self, self.generation == token else { return }
                self.fail(error)
            }
        }
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func finish(resolved: AIResolvedModel) {
        endActivity()
        // Réponse arrivée pendant qu'on est ailleurs : une notification (réglage).
        if usage == .chat, AISettings.shared.chatNotifications, !NSApp.isActive {
            let content = UNMutableNotificationContent()
            content.title = conversation.title
            content.body = String(partial.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        partial = ""
        streamingText = ""
        isGenerating = false
        task = nil
        lastActivity = Date()
        if text.isEmpty {
            error = "Le modèle n’a rien répondu. Réessayez (⌘R) ou changez de modèle."
        } else {
            conversation.messages.append(AIChatMessage(role: .assistant, content: text, model: resolved.label))
            conversation.updated = Date()
            save()
            if usage == .chat, conversation.messages.filter({ $0.role == .assistant }).count == 1 {
                suggestTitle(resolved: resolved)
            }
            onFinish?(text)
        }
        onStateChange?()
    }

    private func fail(_ failure: Error) {
        endActivity()
        let text = partial
        partial = ""
        streamingText = ""
        isGenerating = false
        task = nil
        if !text.isEmpty {
            conversation.messages.append(AIChatMessage(role: .assistant, content: text, model: activeModelLabel))
            save()
        }
        error = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
        onStateChange?()
    }

    /// Un titre court proposé par le modèle, à la place du titre tiré de la question.
    private func suggestTitle(resolved: AIResolvedModel) {
        guard !conversation.isTitleManual, !AIRuntime.isDemo,
              let question = conversation.messages.first(where: { $0.role == .user }),
              let answer = conversation.lastAnswer else { return }
        let id = conversation.id
        let prompt = """
        Propose un titre de 3 à 6 mots pour cette conversation, dans sa langue, sans guillemets ni point final. Réponds seulement avec le titre.

        Question : \(String((question.displayText ?? question.content).prefix(500)))
        Réponse : \(String(answer.prefix(500)))
        """
        Task { [weak self] in
            guard let generated = try? await AIRouter.complete([AIMessage(role: .user, content: prompt)], system: nil, resolved: resolved, temperature: 0.3),
                  let title = AITitle.clean(generated: generated),
                  let self, self.conversation.id == id, !self.conversation.isTitleManual else { return }
            self.conversation.title = title
            self.save()
            self.onStateChange?()
        }
    }

    func save() {
        guard persists, !conversation.messages.isEmpty else { return }
        AIHistory.shared.upsert(conversation)
    }
}

// MARK: - Contexte

@MainActor
enum AIContext {
    /// La sélection de l'application d'avant. Par l'accessibilité si possible ; sinon le lanceur
    /// s'efface le temps d'un ⌘C simulé (il prendrait la frappe), puis revient.
    static func selection() async -> String? {
        if let text = SelectedText.viaAccessibility(AppContext.previousApp), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        guard Paster.isTrusted else { return nil }
        let launcher = AppContext.launcher
        let wasVisible = launcher?.isVisible ?? false
        if wasVisible {
            launcher?.hide()
            try? await Task.sleep(nanoseconds: 180_000_000)
        }
        let text = await SelectedText.read(from: AppContext.previousApp)
        if wasVisible { launcher?.show() }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Le texte de l'onglet actif du navigateur, avec son titre.
    static func browserTab() -> AIAttachment? {
        guard let content = BrowserTab.content(format: "text"), !content.isEmpty else { return nil }
        let title = BrowserTab.current()?.title ?? "Onglet du navigateur"
        return AIAttachment(kind: .browserTab, title: "Page « \(title) »", content: String(content.prefix(60_000)))
    }
}

// MARK: - Quick AI : la conversation suivie

@MainActor
enum AIQuickState {
    /// La conversation de Quick AI, reprise tant que l'inactivité réglée n'est pas dépassée.
    static var session: AIChatSession?

    static func current(forceNew: Bool = false) -> AIChatSession {
        let settings = AISettings.shared
        if !forceNew, let session,
           !AIQuickReset.shouldStartNew(lastActivity: session.lastActivity, now: Date(), delay: settings.quickResetAfter) {
            return session
        }
        var conversation = AIConversation()
        conversation.origin = "quick"
        let session = AIChatSession(conversation: conversation, usage: .quick)
        self.session = session
        return session
    }
}
