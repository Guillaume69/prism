import AppKit
import SwiftUI

/// Les modèles proposés dans les sélecteurs : Auto, Apple Intelligence, les modèles d'Ollama installés,
/// ceux d'OpenAI (ou compatible) et d'Anthropic.
@MainActor
final class AIModelCatalog: ObservableObject {
    static let shared = AIModelCatalog()

    @Published private(set) var ollamaModels: [String] = []
    @Published private(set) var openAIModels: [String] = []
    @Published private(set) var ollamaReachable: Bool?
    private var lastRefresh = Date.distantPast

    var options: [AIModelChoice] {
        let settings = AISettings.shared
        var result: [AIModelChoice] = [.auto, .apple]
        let ollama = ollamaModels.isEmpty && !settings.ollamaModel.isEmpty ? [settings.ollamaModel] : ollamaModels
        result += ollama.map { .model(.ollama, $0) }
        var openAI = openAIModels
        if !openAI.contains(settings.openAIModel), !settings.openAIModel.isEmpty { openAI.insert(settings.openAIModel, at: 0) }
        result += openAI.prefix(12).map { .model(.openAI, $0) }
        var anthropic = AIModelNames.anthropicDefaults
        if !anthropic.contains(settings.anthropicModel), !settings.anthropicModel.isEmpty { anthropic.append(settings.anthropicModel) }
        result += anthropic.map { .model(.anthropic, $0) }
        result += AICustomProviders.choices
        return result
    }

    /// Relit la liste des modèles d'Ollama (et d'OpenAI si une clé est là), au plus toutes les 30 secondes.
    func refresh(force: Bool = false) {
        guard !AIRuntime.isDemo, force || Date().timeIntervalSince(lastRefresh) > 30 else { return }
        lastRefresh = Date()
        let settings = AISettings.shared
        let ollamaURL = settings.ollamaURL
        Task {
            let models = await OllamaProvider.models(baseURL: ollamaURL)
            self.ollamaReachable = models != nil
            self.ollamaModels = models ?? []
        }
        let key = AIKeychain.read(.openAI)
        let base = settings.openAIBaseURL
        if !(key ?? "").isEmpty || !base.contains("api.openai.com") {
            Task {
                if let models = try? await OpenAIProvider.models(baseURL: base, key: key) { self.openAIModels = models }
            }
        }
    }

    /// Pour les rendus : une liste fixe.
    func loadDemo() {
        ollamaModels = ["llama3.2:latest", "qwen2.5-coder:7b"]
        ollamaReachable = true
    }
}

// MARK: - L'écran de réponse

/// Une réponse de l'IA dans le lanceur : Quick AI, ou le résultat d'une commande d'IA.
/// La barre de recherche sert à poser la question suivante.
@MainActor
final class AIAnswerScreen: LauncherScreen {
    enum Mode {
        case quick
        case command(AICommandDefinition, hadSelection: Bool)
    }

    let session: AIChatSession
    let mode: Mode
    /// Question à envoyer à l'ouverture (Tab, repli, lien profond, commande).
    var pendingPrompt: (text: String, display: String?)?
    /// Contexte joint à la prochaine question.
    var pendingAttachments: [AIAttachment] = []
    private var isAttaching = false

    init(session: AIChatSession, mode: Mode) {
        self.session = session
        self.mode = mode
        switch mode {
        case .quick:
            super.init(id: "ai.quick", title: "Quick AI", placeholder: "Posez une question…", icon: .symbol("sparkles", Palette.violet))
        case .command(let command, _):
            super.init(id: "ai.result." + command.id, title: command.name, placeholder: "Posez une question complémentaire…", icon: command.icon)
        }
        layout = .custom
    }

    /// Quick AI, sur la conversation suivie, avec une première question éventuelle.
    static func quick(prompt: String? = nil, forceNew: Bool = false) -> AIAnswerScreen {
        let session = AIRuntime.isDemo ? demoSession() : AIQuickState.current(forceNew: forceNew)
        let screen = AIAnswerScreen(session: session, mode: .quick)
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !AIRuntime.isDemo {
            screen.pendingPrompt = (prompt, nil)
        }
        return screen
    }

    override var placeholder: String {
        get { session.conversation.messages.isEmpty && !session.isGenerating ? (isCommand ? "Posez une question complémentaire…" : "Posez une question…") : "Posez une question complémentaire…" }
        set {}
    }

    var isCommand: Bool {
        if case .command = mode { return true }
        return false
    }

    override func didAppear() {
        session.onStateChange = { [weak self] in self?.host?.screenStateChanged() }
        if let pending = pendingPrompt {
            pendingPrompt = nil
            session.send(pending.text, displayText: pending.display)
        }
    }

    override func customView() -> AnyView { AnyView(AIAnswerView(screen: self, session: session, attachments: pendingAttachments)) }

    override var footerTitle: String? {
        "\(title) · \(session.modelLabel)"
    }

    private var query: String { host?.query.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    // MARK: Actions

    func submitQuery() {
        let text = query
        guard !text.isEmpty else { return }
        session.send(text, attachments: pendingAttachments)
        pendingAttachments = []
        host?.query = ""
    }

    private func pasteAnswer() -> ActionOutcome {
        guard let answer = session.lastAnswer else { return .stay }
        return Paster.paste(answer)
    }

    private func copyAnswer() -> ActionOutcome {
        guard let answer = session.lastAnswer else { return .stay }
        Pasteboard.copy(answer)
        return .hud("Réponse copiée")
    }

    private func enterOutcome() -> ActionOutcome {
        if isCommand { return pasteAnswer() }
        return AISettings.shared.quickEnterAction == "copy" ? copyAnswer() : pasteAnswer()
    }

    func newConversation() {
        guard !isCommand else { return }
        session.stop()
        let fresh = AIQuickState.current(forceNew: true)
        host?.replace(with: AIAnswerScreen(session: fresh, mode: .quick))
    }

    func continueInChat() -> ActionOutcome {
        session.stop()
        var conversation = session.conversation
        if conversation.messages.isEmpty {
            AIChatWindow.shared.open(text: query, attachments: pendingAttachments)
        } else {
            conversation.origin = "chat"
            if session.persists {
                AIHistory.shared.update(conversation.id) { $0.origin = "chat" }
            } else {
                AIHistory.shared.upsert(conversation)
            }
            AIChatWindow.shared.open(conversation: conversation)
        }
        if case .quick = mode { AIQuickState.session = nil }
        return .close
    }

    func attachSelection() {
        guard !isAttaching else { return }
        isAttaching = true
        Task {
            let text = await AIContext.selection()
            isAttaching = false
            guard let text else {
                host?.showToast(Paster.isTrusted ? "Aucun texte sélectionné" : "Autorisez Prism dans Accessibilité pour lire la sélection")
                return
            }
            pendingAttachments.removeAll { $0.kind == .selection }
            pendingAttachments.append(AIAttachment(kind: .selection, title: "Texte sélectionné", content: text))
            host?.screenStateChanged()
        }
    }

    func attachBrowserTab() {
        guard let attachment = AIContext.browserTab() else {
            host?.showToast("Aucun onglet de navigateur lisible")
            return
        }
        pendingAttachments.removeAll { $0.kind == .browserTab }
        pendingAttachments.append(attachment)
        host?.screenStateChanged()
    }

    /// « Screen Awareness » : le texte visible à l'écran, lu sur l'appareil.
    func attachScreen() {
        isLoading = true
        Task {
            let attachment = await ScreenContext.attachment()
            isLoading = false
            guard let attachment else {
                host?.showToast("Écran illisible : autorisez Prism dans Réglages Système › Enregistrement de l’écran")
                return
            }
            pendingAttachments.removeAll { $0.title == attachment.title }
            pendingAttachments.append(attachment)
            host?.screenStateChanged()
        }
    }

    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
        host?.screenStateChanged()
    }

    override var screenActions: [ItemAction] {
        var actions: [ItemAction] = []
        let hasAnswer = session.lastAnswer != nil
        if !query.isEmpty {
            actions.append(ItemAction(title: "Envoyer la question", symbol: "paperplane", shortcut: KeyShortcut(keyCode: 36, modifiers: [], label: "↵")) { [weak self] in
                self?.submitQuery()
                return .stay
            })
        }
        if session.isGenerating {
            actions.append(ItemAction(title: "Arrêter", symbol: "stop.circle", shortcut: KeyShortcut(keyCode: 53, modifiers: [], label: "Échap")) { [weak self] in
                self?.session.stop()
                return .stay
            })
        }
        if hasAnswer {
            let pasteTitle = Actions.pasteTitle
            if isCommand {
                actions.append(ItemAction(title: pasteTitle, symbol: "doc.on.clipboard", shortcut: query.isEmpty ? KeyShortcut(keyCode: 36, modifiers: [], label: "↵") : nil) { [weak self] in
                    self?.pasteAnswer() ?? .stay
                })
                if case .command(_, true) = mode {
                    actions.append(ItemAction(title: "Remplacer la sélection", symbol: "arrow.left.arrow.right", shortcut: KeyShortcut(keyCode: 36, modifiers: [.command, .shift], label: "↵")) { [weak self] in
                        self?.pasteAnswer() ?? .stay
                    })
                }
                actions.append(ItemAction(title: "Copier la réponse", symbol: "doc.on.doc", shortcut: KeyShortcut(keyCode: 36, modifiers: [.command], label: "↵")) { [weak self] in
                    self?.copyAnswer() ?? .stay
                })
            } else {
                let copyFirst = AISettings.shared.quickEnterAction == "copy"
                let enter = query.isEmpty ? KeyShortcut(keyCode: 36, modifiers: [], label: "↵") : nil
                let paste = ItemAction(title: pasteTitle, symbol: "doc.on.clipboard", shortcut: copyFirst ? nil : enter) { [weak self] in self?.pasteAnswer() ?? .stay }
                let copy = ItemAction(title: "Copier la réponse", symbol: "doc.on.doc", shortcut: copyFirst ? enter : KeyShortcut(keyCode: 36, modifiers: [.command], label: "↵")) { [weak self] in self?.copyAnswer() ?? .stay }
                actions += copyFirst ? [copy, paste] : [paste, copy]
            }
        }
        actions.append(ItemAction(title: "Continuer dans AI Chat", symbol: "bubble.left.and.bubble.right", shortcut: .toAI) { [weak self] in
            self?.continueInChat() ?? .stay
        })
        if hasAnswer || session.error != nil {
            actions.append(ItemAction(title: "Régénérer la réponse", symbol: "arrow.clockwise", shortcut: .refresh) { [weak self] in
                self?.session.regenerate()
                return .stay
            })
        }
        if !isCommand {
            actions.append(ItemAction(title: "Nouvelle conversation", symbol: "square.and.pencil", shortcut: .create) { [weak self] in
                self?.newConversation()
                return .stay
            })
        }
        actions.append(ItemAction(title: "Joindre la sélection", symbol: "text.cursor", shortcut: KeyShortcut(keyCode: 1, modifiers: [.command, .option], label: "S"), section: "Contexte") { [weak self] in
            self?.attachSelection()
            return .stay
        })
        actions.append(ItemAction(title: "Joindre l’onglet du navigateur", symbol: "safari", shortcut: KeyShortcut(keyCode: 11, modifiers: [.command, .option], label: "B"), section: "Contexte") { [weak self] in
            self?.attachBrowserTab()
            return .stay
        })
        actions.append(ItemAction(title: "Dicter la question", symbol: "mic.fill", shortcut: KeyShortcut(keyCode: 46, modifiers: [.control], label: "M"), section: "Contexte") { [weak self] in
            DictationController.shared.dictate { text in
                guard let host = self?.host else { return }
                host.query = text
                host.moveCaretToEnd?()
            }
            return .stay
        })
        actions.append(ItemAction(title: "Joindre le texte de l’écran", symbol: "rectangle.dashed.and.paperclip", shortcut: KeyShortcut(keyCode: 14, modifiers: [.command, .option], label: "E"), section: "Contexte") { [weak self] in
            self?.attachScreen()
            return .stay
        })
        actions.append(ItemAction(title: "Changer de modèle…", symbol: "cpu", shortcut: KeyShortcut(keyCode: 46, modifiers: [.command, .shift], label: "M"), section: "Modèle") { [weak self] in
            guard let self else { return .stay }
            return .push(AIModelPickerScreen.make(session: self.session))
        })
        if let answer = session.lastAnswer {
            actions.append(ItemAction(title: "Copier toute la conversation", symbol: "text.append", section: "Modèle") { [weak self] in
                Pasteboard.copy(self.map { AIExport.markdown($0.session.conversation) } ?? answer)
                return .hud("Conversation copiée")
            })
        }
        return actions
    }

    override func handleKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        switch (event.keyCode, modifiers) {
        case (36, []), (76, []):
            if !query.isEmpty {
                submitQuery()
            } else if session.lastAnswer != nil, !session.isGenerating {
                host?.apply(enterOutcome())
            }
            return true
        case (36, [.command]), (76, [.command]):
            host?.apply(copyAnswer())
            return true
        case (36, [.command, .shift]) where isCommand:
            host?.apply(pasteAnswer())
            return true
        case (15, [.command]): // ⌘R
            session.regenerate()
            return true
        case (45, [.command]) where !isCommand: // ⌘N
            newConversation()
            return true
        case (38, [.command]): // ⌘J
            host?.apply(continueInChat())
            return true
        case (53, []) where session.isGenerating: // Échap pendant la génération : arrêter
            session.stop()
            return true
        case (51, []) where query.isEmpty && !pendingAttachments.isEmpty: // ⌫ retire la dernière pièce jointe
            pendingAttachments.removeLast()
            host?.screenStateChanged()
            return true
        default:
            return false
        }
    }
}

/// Choisir le modèle de la conversation, depuis le lanceur.
@MainActor
enum AIModelPickerScreen {
    static func make(session: AIChatSession) -> LauncherScreen {
        AIModelCatalog.shared.refresh()
        return ListScreen(id: "ai.model-picker", title: "Modèle", placeholder: "Rechercher un modèle…", icon: .symbol("cpu", Palette.indigo)) { query in
            let normalized = query.normalizedForSearch
            let current = session.choice
            let groups: [(String, [AIModelChoice])] = [
                ("Automatique", [.auto]),
                ("Sur l’appareil", AIModelCatalog.shared.options.filter { $0.provider?.isLocal == true }),
                ("En ligne", AIModelCatalog.shared.options.filter { $0.provider?.isLocal == false }),
            ]
            return groups.compactMap { title, choices in
                let items = choices.filter { normalized.isEmpty || Fuzzy.score(normalized, $0.label) != nil }.map { choice in
                    ResultItem(
                        id: "ai.model." + choice.rawValue,
                        title: choice.label,
                        subtitle: choice.provider?.title ?? "Le meilleur disponible",
                        icon: .symbol(choice.provider?.symbol ?? "wand.and.stars", choice.provider?.isLocal == false ? Palette.indigo : Palette.green),
                        accessory: choice == current ? "Actuel" : nil,
                        usageKey: "",
                        actions: [ItemAction(title: "Utiliser ce modèle", symbol: "checkmark") {
                            session.setModel(choice)
                            return .pop
                        }]
                    )
                }
                return items.isEmpty ? nil : ResultSection(id: title, title: title, items: items)
            }
        }
    }
}

// MARK: - La vue

struct AIAnswerView: View {
    let screen: AIAnswerScreen
    @ObservedObject var session: AIChatSession
    /// Copie des pièces jointes en attente : la vue se redessine quand elles changent.
    let attachments: [AIAttachment]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    if session.conversation.messages.isEmpty, !session.isGenerating, session.error == nil {
                        emptyState
                    }
                    ForEach(session.conversation.messages) { message in
                        if message.role == .user {
                            question(message)
                        } else if message.role == .assistant {
                            answer(message.content, model: message.model)
                        }
                    }
                    if session.isGenerating {
                        if session.streamingText.isEmpty {
                            AIThinkingIndicator(label: session.modelLabel)
                        } else {
                            MarkdownText(session.streamingText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let error = session.error {
                        AIErrorBox(message: error)
                    }
                    if !attachments.isEmpty {
                        AIAttachmentChips(attachments: attachments, onRemove: screen.removeAttachment)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.automatic)
            .onChange(of: session.streamingText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.conversation.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ItemIconView(icon: .symbol("sparkles", Palette.violet), size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Posez une question à l’IA")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Avec \(session.modelLabel)" + (session.choice.provider?.isLocal == true ? ", sur votre Mac" : ""))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                hint(["↵"], "envoie la question ; ensuite, colle la réponse dans l’app")
                hint(["⌘", "↵"], "copie la réponse")
                hint(["⌘", "J"], "continue la conversation dans AI Chat")
                hint(["⌘", "K"], "joint la sélection ou la page du navigateur, change de modèle")
            }
        }
        .padding(.top, 6)
    }

    private func hint(_ keys: [String], _ text: String) -> some View {
        HStack(spacing: 8) {
            KeycapRow(symbols: keys).frame(width: 52, alignment: .leading)
            Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func question(_ message: AIChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: screen.isCommand && message.displayText != nil ? "sparkles" : "person.crop.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Text(message.displayText ?? message.content)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            if !message.attachments.isEmpty {
                AIAttachmentChips(attachments: message.attachments, onRemove: nil)
                    .padding(.leading, 20)
            }
        }
        .padding(.top, 2)
    }

    private func answer(_ text: String, model: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MarkdownText(text)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let model {
                Text(model)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// « Réflexion… » avec trois points qui s'animent.
struct AIThinkingIndicator: View {
    let label: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate * 4) % 4
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Palette.violet.opacity(index < step ? 0.9 : 0.25))
                            .frame(width: 6, height: 6)
                    }
                }
                Text("\(label) réfléchit…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct AIErrorBox: View {
    let message: String
    var scale: CGFloat = 1

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.orange)
                .font(.system(size: 13 * scale))
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 12.5 * scale))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button("Ouvrir les réglages de l’IA") {
                    NotificationCenter.default.post(name: .prismOpenSettings, object: AIFeature.settingsPaneID)
                }
                .buttonStyle(.link)
                .font(.system(size: 12 * scale))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.orange.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.orange.opacity(0.25)))
    }
}

/// Les pièces jointes, en pastilles.
struct AIAttachmentChips: View {
    let attachments: [AIAttachment]
    let onRemove: ((UUID) -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(attachments) { attachment in
                HStack(spacing: 5) {
                    Image(systemName: attachment.symbol).font(.system(size: 10.5, weight: .semibold))
                    Text(attachment.title).lineLimit(1)
                    Text("· \(attachment.content.count) caractères").foregroundStyle(.tertiary)
                    if let onRemove {
                        Button {
                            onRemove(attachment.id)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .help("Retirer")
                    }
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule(style: .continuous).fill(Theme.keycap))
                .help(String(attachment.content.prefix(400)))
            }
        }
    }
}

// MARK: - Démonstration (rendus)

extension AIAnswerScreen {
    static let demoQuestion = "Comment inverser une chaîne en Swift ?"
    static let demoAnswer = """
    Le plus simple est d’utiliser `reversed()`, qui parcourt les caractères à l’envers, puis de recréer une `String` :

    ```swift
    let mot = "Prism"
    let inverse = String(mot.reversed())
    print(inverse) // « msirP »
    ```

    Quelques remarques :
    - `reversed()` respecte les **graphèmes** : les emojis et les lettres accentuées restent intacts.
    - Le résultat de `reversed()` est une vue paresseuse ; `String(…)` la matérialise.
    """

    static func demoSession() -> AIChatSession {
        var conversation = AIConversation()
        conversation.origin = "quick"
        conversation.messages = [
            AIChatMessage(role: .user, content: demoQuestion),
            AIChatMessage(role: .assistant, content: demoAnswer, model: "Apple Intelligence"),
        ]
        return AIChatSession(conversation: conversation, usage: .quick, persists: false)
    }

    static func demoCommand(_ command: AICommandDefinition) -> AIAnswerScreen {
        var conversation = AIConversation()
        conversation.origin = "command"
        conversation.messages = [
            AIChatMessage(role: .user, content: command.prompt, displayText: command.name),
            AIChatMessage(role: .assistant, content: "Merci pour votre message. Je vous confirme notre rendez-vous de jeudi à 10 h ; je vous enverrai l’ordre du jour d’ici demain.", model: "Apple Intelligence"),
        ]
        let session = AIChatSession(conversation: conversation, usage: .commands, persists: false)
        return AIAnswerScreen(session: session, mode: .command(command, hadSelection: true))
    }
}
