import AppKit
import SwiftUI

/// Les modes d'exécution sans interface : rendus et autotests travaillent sur des données en mémoire,
/// sans toucher aux fichiers ni au trousseau de l'utilisateur.
enum AIRuntime {
    private static let arguments = CommandLine.arguments
    /// Rendus hors écran et autotests : données de démonstration, aucun appel à un service.
    static let isDemo = arguments.contains("--snapshot") || arguments.contains("--snapshot-chat") || arguments.contains("--selftest")
    /// Aucune écriture : rendus, autotests et essai en ligne de commande.
    static let isEphemeral = isDemo || arguments.contains("--ai-test")
}

// MARK: - Préférences

/// La créativité (température), comme le réglage de Raycast.
enum AICreativity: Double, CaseIterable, Identifiable {
    case none = 0
    case low = 0.3
    case medium = 0.7
    case high = 1.0
    case maximum = 1.3

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .none: "Aucune"
        case .low: "Faible"
        case .medium: "Moyenne"
        case .high: "Élevée"
        case .maximum: "Maximale"
        }
    }

    static func title(for value: Double) -> String {
        allCases.min { abs($0.rawValue - value) < abs($1.rawValue - value) }?.title ?? "Moyenne"
    }
}

/// Préférences de l'IA, dans UserDefaults sous « ai. ».
@MainActor
final class AISettings: ObservableObject {
    static let shared = AISettings()
    private let defaults = UserDefaults.standard

    private func string(_ key: String, _ fallback: String) -> String { defaults.string(forKey: "ai." + key) ?? fallback }
    private func double(_ key: String, _ fallback: Double) -> Double { defaults.object(forKey: "ai." + key) as? Double ?? fallback }
    private func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: "ai." + key) as? Bool ?? fallback }
    private func store(_ value: Any, _ key: String) {
        guard !AIRuntime.isEphemeral else { return }
        defaults.set(value, forKey: "ai." + key)
    }

    // Modèles par défaut : Apple Intelligence, gratuit et privé.
    @Published var quickModel: String { didSet { store(quickModel, "model.quick") } }
    @Published var chatModel: String { didSet { store(chatModel, "model.chat") } }
    @Published var commandsModel: String { didSet { store(commandsModel, "model.commands") } }
    @Published var temperature: Double { didSet { store(temperature, "temperature") } }

    @Published var ollamaURL: String { didSet { store(ollamaURL, "ollama.url") } }
    @Published var ollamaModel: String { didSet { store(ollamaModel, "ollama.model") } }
    @Published var openAIBaseURL: String { didSet { store(openAIBaseURL, "openai.baseURL") } }
    @Published var openAIModel: String { didSet { store(openAIModel, "openai.model") } }
    @Published var anthropicModel: String { didSet { store(anthropicModel, "anthropic.model") } }

    /// ↵ sur une réponse de Quick AI : « paste » ou « copy ».
    @Published var quickEnterAction: String { didSet { store(quickEnterAction, "quick.enterAction") } }
    /// Inactivité (secondes) après laquelle Quick AI repart d'une conversation neuve ; 0 : jamais.
    @Published var quickResetAfter: Double { didSet { store(quickResetAfter, "quick.resetAfter") } }
    @Published var hideTabHint: Bool { didSet { store(hideTabHint, "quick.hideTabHint") } }

    /// « À propos de moi » : instructions ajoutées à toutes les conversations.
    @Published var aboutMe: String { didSet { store(aboutMe, "aboutMe") } }

    @Published var chatAlwaysOnTop: Bool { didSet { store(chatAlwaysOnTop, "chat.alwaysOnTop") } }
    @Published var chatZoom: Double { didSet { store(chatZoom, "chat.zoom") } }
    /// Notification quand une réponse arrive alors qu'on est dans une autre app.
    @Published var chatNotifications: Bool { didSet { store(chatNotifications, "chat.notifications") } }
    /// Empêche la veille du Mac pendant une génération.
    @Published var preventSleep: Bool { didSet { store(preventSleep, "chat.preventSleep") } }
    /// Archive les conversations inactives depuis ce nombre de jours (0 : jamais).
    @Published var autoArchiveDays: Int { didSet { store(autoArchiveDays, "chat.autoArchiveDays") } }
    /// Échap ferme la fenêtre AI Chat quand rien d'autre n'est en cours.
    @Published var escapeClosesChat: Bool { didSet { store(escapeClosesChat, "chat.escapeCloses") } }

    private init() {
        quickModel = ""
        chatModel = ""
        commandsModel = ""
        temperature = 0.7
        ollamaURL = ""
        ollamaModel = ""
        openAIBaseURL = ""
        openAIModel = ""
        anthropicModel = ""
        quickEnterAction = "paste"
        quickResetAfter = 300
        hideTabHint = false
        aboutMe = ""
        chatAlwaysOnTop = false
        chatZoom = 1
        let standard = UserDefaults.standard
        chatNotifications = standard.object(forKey: "ai.chat.notifications") as? Bool ?? false
        preventSleep = standard.object(forKey: "ai.chat.preventSleep") as? Bool ?? false
        autoArchiveDays = standard.object(forKey: "ai.chat.autoArchiveDays") as? Int ?? 0
        escapeClosesChat = standard.object(forKey: "ai.chat.escapeCloses") as? Bool ?? true
        quickModel = string("model.quick", "apple")
        chatModel = string("model.chat", "apple")
        commandsModel = string("model.commands", "apple")
        temperature = double("temperature", AICreativity.medium.rawValue)
        ollamaURL = ProcessInfo.processInfo.environment["PRISM_OLLAMA_URL"] ?? string("ollama.url", "http://localhost:11434")
        ollamaModel = string("ollama.model", "")
        openAIBaseURL = string("openai.baseURL", OpenAIProvider.defaultBaseURL)
        openAIModel = string("openai.model", "gpt-5-mini")
        anthropicModel = string("anthropic.model", "claude-opus-5-5")
        quickEnterAction = string("quick.enterAction", "paste")
        quickResetAfter = double("quick.resetAfter", 300)
        hideTabHint = bool("quick.hideTabHint", false)
        aboutMe = string("aboutMe", "")
        chatAlwaysOnTop = bool("chat.alwaysOnTop", false)
        chatZoom = double("chat.zoom", 1)
    }

    /// Le modèle choisi par défaut pour un usage.
    enum Usage { case quick, chat, commands }

    func choice(for usage: Usage) -> AIModelChoice {
        switch usage {
        case .quick: AIModelChoice(rawValue: quickModel)
        case .chat: AIModelChoice(rawValue: chatModel)
        case .commands: AIModelChoice(rawValue: commandsModel)
        }
    }

    /// Les instructions communes : la date, la langue, le Markdown, puis « À propos de moi ».
    func systemPrompt(extra: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateStyle = .full
        // Formulation éprouvée : « intégré à… Nous sommes le… » déclenche les filtres du modèle d'Apple.
        var parts = [
            "Tu es l’assistant de Prism, un lanceur pour macOS. Réponds dans la langue de l’utilisateur, de façon directe et précise. Utilise le Markdown quand c’est utile (listes, blocs de code). Date du jour : \(formatter.string(from: Date())).",
        ]
        if let extra, !extra.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(extra) }
        let about = aboutMe.trimmingCharacters(in: .whitespacesAndNewlines)
        if !about.isEmpty { parts.append("Ce que l’utilisateur dit de lui-même :\n\(about)") }
        if let memory = AIMemory.shared.promptSection { parts.append(memory) }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Données

/// Contexte joint à une question : sélection, onglet du navigateur, texte envoyé d'ailleurs.
struct AIAttachment: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case selection, browserTab, clipboard, text
    }

    var id = UUID()
    var kind: Kind
    var title: String
    var content: String

    var symbol: String {
        switch kind {
        case .selection: "text.cursor"
        case .browserTab: "safari"
        case .clipboard: "doc.on.clipboard"
        case .text: "doc.text"
        }
    }

    /// Le texte ajouté à la question envoyée au modèle.
    var promptText: String { "\(title) :\n\"\"\"\n\(content)\n\"\"\"" }
}

struct AIChatMessage: Codable, Equatable, Identifiable {
    var id = UUID()
    var role: AIMessage.Role
    var content: String
    var date = Date()
    /// Le modèle qui a répondu (« Claude Opus 5.5 »).
    var model: String?
    var attachments: [AIAttachment] = []
    /// Ce qu'on affiche à la place du texte envoyé (le nom d'une commande d'IA plutôt que son prompt).
    var displayText: String?

    /// Le message tel qu'envoyé au modèle, pièces jointes en tête.
    var forModel: AIMessage {
        guard !attachments.isEmpty else { return AIMessage(role: role, content: content) }
        let context = attachments.map(\.promptText).joined(separator: "\n\n")
        return AIMessage(role: role, content: context + "\n\n" + content)
    }
}

struct AIConversation: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String = "Nouvelle conversation"
    /// Renommée à la main : le titre automatique ne la touche plus.
    var isTitleManual = false
    var messages: [AIChatMessage] = []
    var created = Date()
    var updated = Date()
    var pinned = false
    var presetID: UUID?
    /// Le projet qui regroupe la conversation.
    var projectID: UUID?
    /// Archivée : hors de la barre latérale, retrouvable dans « Archivées ».
    var archived: Bool?
    /// Le modèle de cette conversation ; `nil` : celui par défaut (ou du préréglage).
    var model: String?
    /// Dans la corbeille depuis cette date.
    var deletedAt: Date?
    /// « chat », « quick » ou « command ».
    var origin = "chat"

    var lastAnswer: String? { messages.last { $0.role == .assistant }?.content }
}

/// Un préréglage (« agent ») : nom, instructions système, modèle.
/// Un agent (les « préréglages » de Raycast v1) : rôle, instructions, modèle et outils permis.
struct AIPreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var instructions: String
    var model: String?
    var symbol = "person.crop.circle"
    /// Les outils que l'agent peut appeler (`nil` : tous ; « mcp » : ceux des serveurs MCP).
    var tools: [String]?
    /// Livré avec Prism : modifiable par duplication seulement.
    var builtIn: Bool?

    var isBuiltIn: Bool { builtIn == true }

    /// « Recherche approfondie », l'agent Deep Research de Raycast.
    static let deepResearch = AIPreset(
        id: UUID(uuidString: "D33B0000-0000-4000-8000-00000000AE5E")!,
        name: "Recherche approfondie",
        instructions: """
        Tu fais des recherches approfondies et sourcées. Pour chaque question : décompose-la, cherche sur le web avec plusieurs formulations (web_search), lis les sources les plus pertinentes (read_webpage), croise-les, puis rédige une synthèse structurée en Markdown avec des titres. Cite chaque affirmation importante avec un lien [source](url). Signale les désaccords entre sources et ce qui reste incertain. N'invente jamais de source.
        """,
        symbol: "magnifyingglass.circle.fill",
        tools: ["web_search", "read_webpage", "current_date_time", "calculate"],
        builtIn: true
    )

    static let defaults: [AIPreset] = [
        AIPreset(name: "Développeur", instructions: "Tu es un développeur expérimenté. Réponds avec du code correct et idiomatique, explique brièvement les choix, signale les pièges.", symbol: "chevron.left.forwardslash.chevron.right"),
        AIPreset(name: "Rédacteur", instructions: "Tu es un rédacteur exigeant. Écris des textes clairs, naturels et sans jargon, en respectant la typographie de la langue.", symbol: "pencil.and.outline"),
        AIPreset(name: "Traducteur", instructions: "Tu es un traducteur professionnel. Traduis fidèlement en gardant le ton et la mise en forme ; ne réponds qu’avec la traduction sauf demande contraire.", symbol: "character.bubble"),
    ]
}

/// Une valeur JSON gardée dans Application Support, ou en mémoire seulement pendant les essais.
@MainActor
final class AIPersisted<Value: Codable>: ObservableObject {
    @Published var value: Value {
        didSet { store?.value = value }
    }

    private let store: JSONStore<Value>?

    init(_ fileName: String, default defaultValue: Value) {
        if AIRuntime.isEphemeral {
            store = nil
            value = defaultValue
        } else {
            let store = JSONStore(fileName, default: defaultValue)
            self.store = store
            value = store.value
        }
    }

    func flush() { store?.flush() }
}

// MARK: - Historique

@MainActor
final class AIHistory: ObservableObject {
    static let shared = AIHistory()
    static let trashRetention: TimeInterval = 60 * 24 * 3600

    private let persisted = AIPersisted<[AIConversation]>("ai-conversations.json", default: [])

    @Published private(set) var conversations: [AIConversation] = []

    private init() {
        conversations = Self.purged(persisted.value, now: Date())
    }

    private func save() {
        persisted.value = conversations
    }

    /// Les conversations de la corbeille de plus de 60 jours disparaissent.
    static func purged(_ list: [AIConversation], now: Date) -> [AIConversation] {
        list.filter { conversation in
            guard let deleted = conversation.deletedAt else { return true }
            return now.timeIntervalSince(deleted) < trashRetention
        }
    }

    var active: [AIConversation] {
        conversations.filter { $0.deletedAt == nil && $0.archived != true }.sorted { $0.updated > $1.updated }
    }

    var archived: [AIConversation] {
        conversations.filter { $0.deletedAt == nil && $0.archived == true }.sorted { $0.updated > $1.updated }
    }

    /// Archive les conversations inactives depuis `days` jours (sauf épinglées).
    func autoArchive(days: Int, now: Date = Date()) {
        guard days > 0 else { return }
        var changed = false
        for index in conversations.indices where conversations[index].deletedAt == nil && conversations[index].archived != true && !conversations[index].pinned {
            if now.timeIntervalSince(conversations[index].updated) > Double(days) * 86_400 {
                conversations[index].archived = true
                changed = true
            }
        }
        if changed { save() }
    }

    var trash: [AIConversation] {
        conversations.filter { $0.deletedAt != nil }.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    func conversation(_ id: UUID) -> AIConversation? {
        conversations.first { $0.id == id }
    }

    /// Ajoute ou remplace (les conversations vides ne sont pas gardées).
    func upsert(_ conversation: AIConversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            guard !conversation.messages.isEmpty else { return }
            conversations.append(conversation)
        }
        save()
    }

    func update(_ id: UUID, _ change: (inout AIConversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        change(&conversations[index])
        save()
    }

    func moveToTrash(_ id: UUID) {
        update(id) { $0.deletedAt = Date(); $0.pinned = false }
    }

    func restore(_ id: UUID) {
        update(id) { $0.deletedAt = nil }
    }

    func deleteForever(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        save()
    }

    func emptyTrash() {
        conversations.removeAll { $0.deletedAt != nil }
        save()
    }

    /// Tout l'historique part dans la corbeille.
    func clearAll() {
        let now = Date()
        for index in conversations.indices where conversations[index].deletedAt == nil {
            conversations[index].deletedAt = now
            conversations[index].pinned = false
        }
        save()
    }

    /// Une copie, éventuellement coupée après un message (« brancher »).
    @discardableResult
    func duplicate(_ id: UUID, upTo messageID: UUID? = nil) -> AIConversation? {
        guard var copy = conversation(id) else { return nil }
        copy.id = UUID()
        copy.pinned = false
        copy.deletedAt = nil
        copy.created = Date()
        copy.updated = Date()
        if let messageID, let index = copy.messages.firstIndex(where: { $0.id == messageID }) {
            copy.messages = Array(copy.messages.prefix(through: index))
            copy.title = "\(copy.title) (branche)"
        } else {
            copy.title = "\(copy.title) (copie)"
        }
        copy.isTitleManual = true
        conversations.append(copy)
        save()
        return copy
    }

    /// Pour les rendus : une histoire de démonstration.
    func loadDemo(_ list: [AIConversation]) {
        conversations = list
    }

    func flush() { persisted.flush() }
}

@MainActor
final class AIPresetStore: ObservableObject {
    static let shared = AIPresetStore()
    private let persisted = AIPersisted<[AIPreset]>("ai-presets.json", default: AIPreset.defaults)

    @Published var presets: [AIPreset] {
        didSet { persisted.value = presets }
    }

    private init() {
        presets = []
        var loaded = persisted.value
        if !loaded.contains(where: { $0.id == AIPreset.deepResearch.id }) { loaded.insert(AIPreset.deepResearch, at: 0) }
        presets = loaded
    }

    func preset(_ id: UUID?) -> AIPreset? {
        guard let id else { return nil }
        return presets.first { $0.id == id }
    }
}

// MARK: - Titres, sections, export

enum AITitle {
    /// Un titre lisible tiré de la première question : première ligne, sans Markdown, coupée sur un mot.
    static func make(from text: String, limit: Int = 48) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var cleaned = firstLine
            .replacingOccurrences(of: #"[*_`#>\[\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = cleaned.last, "?!.:;,…".contains(last) || last == " " || last == "\u{00A0}" {
            cleaned.removeLast()
        }
        guard !cleaned.isEmpty else { return "Nouvelle conversation" }
        if cleaned.count > limit {
            let cut = cleaned.prefix(limit)
            if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
                cleaned = String(cut[..<space]) + "…"
            } else {
                cleaned = String(cut) + "…"
            }
        }
        return cleaned.prefix(1).uppercased() + cleaned.dropFirst()
    }

    /// Nettoie un titre proposé par le modèle (guillemets, point final, préfixe « Titre : »).
    static func clean(generated: String) -> String? {
        var title = generated.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        title = title.replacingOccurrences(of: #"^(titre|title)\s*:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'«»“”*#. \u{00A0}"))
        guard !title.isEmpty, title.count <= 70 else { return nil }
        return title.prefix(1).uppercased() + title.dropFirst()
    }
}

enum AIDateSections {
    /// La section de la barre latérale : « Aujourd’hui », « Hier », « 7 derniers jours », « 30 derniers jours », puis le mois.
    static func title(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Aujourd’hui" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Hier" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return "7 derniers jours" }
        if days < 30 { return "30 derniers jours" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "LLLL" : "LLLL yyyy"
        let text = formatter.string(from: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Regroupe des conversations triées, épinglées en tête.
    static func group(_ conversations: [AIConversation], now: Date = Date()) -> [(title: String, items: [AIConversation])] {
        var groups: [(title: String, items: [AIConversation])] = []
        let pinned = conversations.filter(\.pinned)
        if !pinned.isEmpty { groups.append(("Épinglées", pinned)) }
        for conversation in conversations where !conversation.pinned {
            let title = title(for: conversation.updated, now: now)
            if let index = groups.firstIndex(where: { $0.title == title }) {
                groups[index].items.append(conversation)
            } else {
                groups.append((title, [conversation]))
            }
        }
        return groups
    }
}

enum AIExport {
    /// La conversation en Markdown : titre, date, puis chaque message.
    static func markdown(_ conversation: AIConversation) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        var lines = ["# \(conversation.title)", "", "_\(formatter.string(from: conversation.created))_", ""]
        for message in conversation.messages where message.role != .system {
            if message.role == .user {
                lines.append("## Vous")
            } else {
                lines.append("## IA" + (message.model.map { " (\($0))" } ?? ""))
            }
            lines.append("")
            for attachment in message.attachments {
                lines.append("> **\(attachment.title)**")
                lines.append(contentsOf: attachment.content.split(separator: "\n", omittingEmptySubsequences: false).prefix(40).map { "> " + $0 })
                lines.append("")
            }
            lines.append(message.content)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Un nom de fichier sûr.
    static func fileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        return String(cleaned.prefix(80)) + ".md"
    }
}

/// Quick AI repart-il d'une conversation neuve ? Après l'inactivité réglée (0 : jamais).
enum AIQuickReset {
    static func shouldStartNew(lastActivity: Date?, now: Date, delay: TimeInterval) -> Bool {
        guard let lastActivity, delay > 0 else { return false }
        return now.timeIntervalSince(lastActivity) > delay
    }
}
