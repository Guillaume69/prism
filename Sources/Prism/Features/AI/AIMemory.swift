import AppKit
import ScreenCaptureKit
import UserNotifications

// MARK: - Mémoire

/// La mémoire de l'IA : des faits durables sur l'utilisateur, ajoutés par l'outil « remember » ou à la main,
/// rappelés au modèle dans chaque conversation.
@MainActor
final class AIMemory: ObservableObject {
    static let shared = AIMemory()

    struct Fact: Codable, Identifiable, Equatable {
        var id = UUID()
        var text: String
        var date = Date()
    }

    struct Content: Codable {
        var enabled = true
        var facts: [Fact] = []
    }

    let store = JSONStore("ai-memory.json", default: Content())

    var enabled: Bool {
        get { store.value.enabled }
        set { store.value.enabled = newValue; objectWillChange.send() }
    }

    var facts: [Fact] { store.value.facts }

    func add(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !store.value.facts.contains(where: { $0.text.normalizedForSearch == cleaned.normalizedForSearch }) else { return }
        store.value.facts.append(Fact(text: cleaned))
        objectWillChange.send()
    }

    func remove(_ id: UUID) {
        store.value.facts.removeAll { $0.id == id }
        objectWillChange.send()
    }

    func clear() {
        store.value.facts = []
        objectWillChange.send()
    }

    /// Construit la mémoire à partir des conversations récentes (bouton « Générer » de Raycast) :
    /// le modèle en tire des faits durables sur l'utilisateur, ajoutés sans doublon.
    func generate(choice: AIModelChoice) async throws -> Int {
        let recent = AIHistory.shared.active.sorted { $0.updated > $1.updated }.prefix(20)
        let transcript = recent.map { conversation in
            "### \(conversation.title)\n" + conversation.messages.filter { $0.role == .user }.map { String(($0.displayText ?? $0.content).prefix(400)) }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        guard !transcript.isEmpty else { return 0 }
        let existing = facts.map { "- \($0.text)" }.joined(separator: "\n")
        let prompt = """
        Voici des extraits de mes conversations récentes avec toi, et ce que tu sais déjà de moi.
        Tire-en au plus 12 faits durables et utiles sur moi (métier, projets, outils, préférences, façon d’écrire), une phrase courte par fait, sans répéter ce que tu sais déjà. Réponds uniquement par la liste, une ligne par fait, commençant par « - ».

        Déjà connu :
        \(existing.isEmpty ? "(rien)" : existing)

        Conversations :
        \(String(transcript.prefix(12_000)))
        """
        let answer = try await AIRouter.complete([AIMessage(role: .user, content: prompt)], system: nil, choice: choice, temperature: 0.2)
        let lines = answer.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("-") || $0.hasPrefix("•") }
            .map { String($0.dropFirst()).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let before = facts.count
        lines.forEach(add)
        return facts.count - before
    }

    /// Le passage ajouté aux instructions du modèle.
    var promptSection: String? {
        guard enabled, !facts.isEmpty else { return nil }
        return "Mémoire (faits retenus sur l’utilisateur) :\n" + facts.suffix(60).map { "- \($0.text)" }.joined(separator: "\n")
    }
}

// MARK: - Lecture de l'écran

/// « Screen Awareness » : le texte de l'écran, capturé par ScreenCaptureKit puis lu sur l'appareil (Vision).
/// Demande l'autorisation d'enregistrement de l'écran au premier usage.
@MainActor
enum ScreenContext {
    static func text() async -> String? {
        guard let image = await capture() else { return nil }
        return await TextRecognition.recognize(image, accurate: true)
    }

    /// L'écran principal, sans les fenêtres de Prism.
    static func capture() async -> CGImage? {
        guard !CommandLine.arguments.contains("--selftest"), !CommandLine.arguments.contains("--snapshot") else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { return nil }
            let prism = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: prism, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = display.width * 2
            configuration.height = display.height * 2
            configuration.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            return nil
        }
    }

    /// La fenêtre au premier plan d'une app : capture de cette seule fenêtre.
    static func captureWindow(of app: NSRunningApplication) async -> CGImage? {
        guard !CommandLine.arguments.contains("--selftest"), !CommandLine.arguments.contains("--snapshot") else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 80 }) else { return nil }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width * 2)
            configuration.height = Int(window.frame.height * 2)
            return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
        } catch {
            return nil
        }
    }

    /// Le texte lisible d'une fenêtre par l'accessibilité (titres, valeurs, descriptions), sans les champs sécurisés.
    static func accessibilityText(of app: NSRunningApplication, limit: Int = 12_000) -> String? {
        guard Paster.isTrusted else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        var parts: [String] = []
        var total = 0
        var seen = Set<String>()
        func visit(_ node: AXUIElement, depth: Int) {
            guard depth < 40, total < limit else { return }
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &roleRef)
            if (roleRef as? String) == "AXSecureTextField" { return }
            for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success,
                      let text = value as? String else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count > 1, !seen.contains(trimmed) else { continue }
                seen.insert(trimmed)
                parts.append(trimmed)
                total += trimmed.count
            }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
                  let list = children as? [AXUIElement] else { return }
            for child in list.prefix(400) { visit(child, depth: depth + 1) }
        }
        visit(unsafeBitCast(windowRef, to: AXUIElement.self), depth: 0)
        return parts.isEmpty ? nil : String(parts.joined(separator: "\n").prefix(limit))
    }

    /// « Envoyer la fenêtre active à l'IA » : app, titre, sélection, texte de la fenêtre, texte de sa capture.
    static func focusedWindow(_ app: NSRunningApplication?) async -> AIAttachment? {
        guard let app else { return nil }
        var sections: [String] = ["Application : \(app.localizedName ?? "?")"]
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        if Paster.isTrusted, AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &windowRef) == .success, let windowRef {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(unsafeBitCast(windowRef, to: AXUIElement.self), kAXTitleAttribute as CFString, &title)
            if let title = title as? String, !title.isEmpty { sections.append("Fenêtre : \(title)") }
        }
        if let selection = SelectedText.viaAccessibility(app), !selection.isEmpty { sections.append("Sélection :\n\(selection)") }
        if let tab = BrowserTab.current(), NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map({ BrowserTab.chromiumBrowsers.contains($0) || $0 == "com.apple.Safari" }) == true {
            sections.append("Onglet : \(tab.title) — \(tab.url)")
        }
        if let text = accessibilityText(of: app) { sections.append("Contenu de la fenêtre :\n\(text)") }
        if let image = await captureWindow(of: app), let text = await TextRecognition.recognize(image, accurate: true) {
            sections.append("Texte lu sur la capture :\n\(String(text.prefix(8_000)))")
        }
        guard sections.count > 1 else { return nil }
        return AIAttachment(kind: .text, title: "Fenêtre : \(app.localizedName ?? "app")", content: sections.joined(separator: "\n\n"))
    }

    /// « Envoyer une zone de l'écran à l'IA » : sélection au réticule (outil système), puis lecture du texte.
    static func area() async -> AIAttachment? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("prism-zone-\(UUID().uuidString).png")
        let done: Bool = await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", file.path]
            process.terminationHandler = { _ in continuation.resume(returning: FileManager.default.fileExists(atPath: file.path)) }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
        defer { try? FileManager.default.removeItem(at: file) }
        guard done, let image = NSImage(contentsOf: file), let text = await TextRecognition.recognize(image, accurate: true) else { return nil }
        return AIAttachment(kind: .text, title: "Zone de l’écran", content: text)
    }

    /// Une pièce jointe « Texte de l'écran » pour Quick AI et AI Chat.
    static func attachment() async -> AIAttachment? {
        guard let text = await text(), !text.isEmpty else { return nil }
        return AIAttachment(kind: .text, title: "Texte de l’écran", content: String(text.prefix(12_000)))
    }
}

// MARK: - Automatisations

/// Une demande à l'IA lancée toute seule, à heure fixe ou à intervalle (les « Automations » de Raycast).
/// Le résultat arrive dans AI Chat, avec une notification.
struct AIAutomation: Codable, Identifiable, Equatable {
    enum Schedule: String, Codable, CaseIterable {
        case once, daily, weekdays, weekly, hourly, interval

        var title: String {
            switch self {
            case .once: "Une seule fois"
            case .daily: "Tous les jours"
            case .weekdays: "Du lundi au vendredi"
            case .weekly: "Chaque semaine"
            case .hourly: "Toutes les heures"
            case .interval: "Toutes les N minutes"
            }
        }
    }

    var id = UUID()
    var name: String
    var prompt: String
    var schedule: Schedule = .daily
    var hour = 9
    var minute = 0
    /// Jour de la semaine pour `.weekly` (1 dimanche … 7 samedi).
    var weekday = 2
    var intervalMinutes = 60
    var model: String?
    var enabled = true
    var lastRun: Date?
    var lastConversation: UUID?
    /// Date et heure d'une automatisation « Une seule fois ».
    var onceAt: Date?
    /// Ajoute chaque réponse à la même conversation (le modèle voit les précédentes) au lieu d'en créer une.
    var appendToSameChat: Bool?

    /// La prochaine échéance après `date`.
    func nextRun(after date: Date, calendar: Calendar = .current) -> Date? {
        switch schedule {
        case .once:
            guard let onceAt, lastRun == nil, onceAt > date.addingTimeInterval(-60) || lastRun == nil else { return nil }
            return onceAt
        case .hourly:
            return calendar.nextDate(after: date, matching: DateComponents(minute: minute), matchingPolicy: .nextTime)
        case .interval:
            return (lastRun ?? date).addingTimeInterval(TimeInterval(max(5, intervalMinutes) * 60))
        case .daily:
            return calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime)
        case .weekly:
            return calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute, weekday: weekday), matchingPolicy: .nextTime)
        case .weekdays:
            var candidate = date
            for _ in 0..<8 {
                guard let next = calendar.nextDate(after: candidate, matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime) else { return nil }
                let day = calendar.component(.weekday, from: next)
                if day != 1, day != 7 { return next }
                candidate = next
            }
            return nil
        }
    }

    /// Doit-elle tourner maintenant ? (une échéance est passée depuis la dernière exécution, ou la création).
    func isDue(now: Date, created: Date) -> Bool {
        guard enabled, let next = nextRun(after: lastRun ?? created) else { return false }
        return next <= now
    }

    var scheduleLabel: String {
        let time = String(format: "%02d:%02d", hour, minute)
        switch schedule {
        case .once: return "Le " + (onceAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
        case .daily: return "Tous les jours à \(time)"
        case .weekdays: return "En semaine à \(time)"
        case .weekly:
            let day = Calendar.current.weekdaySymbols[(weekday - 1 + 7) % 7]
            return "Chaque \(day) à \(time)"
        case .hourly: return "Toutes les heures à \(minute) min"
        case .interval: return "Toutes les \(intervalMinutes) min"
        }
    }
}

@MainActor
final class AIAutomations: ObservableObject {
    static let shared = AIAutomations()

    struct Content: Codable {
        var automations: [AIAutomation] = []
        /// Date de création de chaque automatisation : la première échéance se compte à partir d'elle.
        var created: [UUID: Date] = [:]
    }

    let store = JSONStore("ai-automations.json", default: Content())
    private var timer: Timer?
    private var running = Set<UUID>()

    var automations: [AIAutomation] { store.value.automations }

    func start() {
        guard !SystemFeature.isHeadless, timer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { AIAutomations.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func save(_ automation: AIAutomation) {
        if let index = store.value.automations.firstIndex(where: { $0.id == automation.id }) {
            store.value.automations[index] = automation
        } else {
            store.value.automations.append(automation)
            store.value.created[automation.id] = Date()
            // Les notifications se demandent à la création de la première automatisation.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        objectWillChange.send()
    }

    func delete(_ id: UUID) {
        store.value.automations.removeAll { $0.id == id }
        store.value.created[id] = nil
        objectWillChange.send()
    }

    private func tick() {
        let now = Date()
        for automation in automations where !running.contains(automation.id) {
            let created = store.value.created[automation.id] ?? now
            if automation.isDue(now: now, created: created) { run(automation) }
        }
    }

    /// Lance l'automatisation tout de suite : la réponse devient une conversation d'AI Chat.
    func run(_ automation: AIAutomation) {
        guard !running.contains(automation.id) else { return }
        running.insert(automation.id)
        var updated = automation
        updated.lastRun = Date()
        save(updated)
        Task {
            var conversation = AIConversation()
            conversation.title = "Automatisation : \(automation.name)"
            // Destination « même conversation » : la suite de la précédente, si elle existe encore.
            if automation.appendToSameChat == true, let id = automation.lastConversation, let previous = AIHistory.shared.conversation(id) {
                conversation = previous
            }
            var request = AIChatMessage(role: .user, content: automation.prompt)
            request.displayText = "Automatisé par « \(automation.name) »"
            conversation.messages.append(request)
            let answer: String
            var modelLabel: String?
            do {
                let choice = automation.model.map(AIModelChoice.init(rawValue:)) ?? AISettings.shared.choice(for: .chat)
                let resolved = try await AIRouter.resolve(choice)
                modelLabel = resolved.label
                // Dans la même conversation, les réponses précédentes servent de contexte.
                let history = conversation.messages.dropLast().suffix(10).map { "\($0.role == .user ? "Demande" : "Réponse") : \(String($0.content.prefix(1_500)))" }.joined(separator: "\n\n")
                let prompt = history.isEmpty ? automation.prompt : "Exécutions précédentes :\n\(history)\n\nNouvelle exécution :\n\(automation.prompt)"
                answer = try await AIEngineBridge.answer(prompt: prompt, resolved: resolved)
            } catch {
                answer = "L’automatisation n’a pas pu s’exécuter : \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
            conversation.messages.append(AIChatMessage(role: .assistant, content: answer, model: modelLabel))
            conversation.updated = Date()
            AIHistory.shared.upsert(conversation)
            var finished = updated
            finished.lastConversation = conversation.id
            // Une automatisation « Une seule fois » se retire après son exécution.
            if automation.schedule == .once { delete(automation.id) } else { save(finished) }
            running.remove(automation.id)
            notify(title: automation.name, body: answer)
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(240))
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        HUD.shared.show("Automatisation « \(title) » terminée", symbol: "sparkles")
    }
}

/// Une réponse complète, avec les outils et la mémoire, pour les automatisations et `AppHooks.aiComplete`.
@MainActor
enum AIEngineBridge {
    static func answer(prompt: String, resolved: AIResolvedModel) async throws -> String {
        var content = prompt
        if let context = await AITools.mentionContext(in: prompt) { content = context + "\n\n" + prompt }
        let messages = [AIMessage(role: .user, content: content)]
        let system = AISettings.shared.systemPrompt()
        if AIToolSettings.shared.enabled, AIToolLoop.supports(resolved) {
            return try await AIToolLoop.run(resolved: resolved, messages: messages, system: system, temperature: AISettings.shared.temperature, tools: await AITools.available()) { _ in }
        }
        return try await AIRouter.complete(messages, system: system, resolved: resolved)
    }
}
