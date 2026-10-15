import AppKit
import SwiftUI

/// Écrans du lanceur et réglages des extensions de l'IA : outils, serveurs MCP, mémoire, automatisations.
@MainActor
enum AIExtensionsUI {
    static var commands: [ResultItem] {
        [
            Command.screen("ai.automations", "Rechercher les automatisations d’IA", subtitle: "IA",
                           symbol: "clock.badge.checkmark.fill", color: Palette.violet,
                           keywords: ["automations", "automatisations", "planifier", "ia", "ai", "programmer"]) { automationsScreen() },
            Command.screen("ai.create-automation", "Créer une automatisation d’IA", subtitle: "IA",
                           symbol: "calendar.badge.clock", color: Palette.violet,
                           keywords: ["create automation", "planifier", "tous les jours", "ia", "ai"]) { automationForm(nil) },
            Command.screen("ai.memory", "Mémoire de l’IA", subtitle: "IA",
                           symbol: "brain.head.profile", color: Palette.violet,
                           keywords: ["memory", "mémoire", "souvenirs", "ia", "ai", "personnalisation"]) { memoryScreen() },
            sendCommand("ai.send-window", "Envoyer la fenêtre active à l’IA", symbol: "macwindow.and.cursorarrow", keywords: ["screen awareness", "fenetre", "écran", "contexte"]) {
                await ScreenContext.focusedWindow(AppContext.previousApp)
            },
            sendCommand("ai.send-selection", "Envoyer la sélection à l’IA", symbol: "text.cursor", keywords: ["selected text", "selection", "texte"]) {
                guard let text = await SelectedText.read(), !text.isEmpty else { return nil }
                return AIAttachment(kind: .selection, title: "Sélection", content: text)
            },
            sendCommand("ai.send-screen", "Envoyer l’écran à l’IA", symbol: "display", keywords: ["screen", "écran", "capture"]) {
                await ScreenContext.attachment()
            },
            sendCommand("ai.send-area", "Envoyer une zone de l’écran à l’IA", symbol: "rectangle.dashed", keywords: ["area", "zone", "capture", "selection"]) {
                await ScreenContext.area()
            },
            Command.screen("ai.usage", "Utilisation de l’IA", subtitle: "IA", symbol: "chart.bar.xaxis", color: Palette.violet,
                           keywords: ["usage", "credits", "crédits", "budget", "coût", "cost", "jetons", "tokens", "ia", "ai"]) { AIUsage.screen() },
            Command.screen("ai.tools", "Extensions de l’IA", subtitle: "IA",
                           symbol: "puzzlepiece.extension.fill", color: Palette.violet,
                           keywords: ["ai extensions", "outils", "tools", "mcp", "@", "ia"]) { toolsScreen() },
        ]
    }

    /// Une commande « Envoyer … à l'IA » : la pièce jointe part dans AI Chat, prête pour la question.
    private static func sendCommand(_ id: String, _ title: String, symbol: String, keywords: [String], attachment: @escaping @MainActor () async -> AIAttachment?) -> ResultItem {
        Command.run(id, title, subtitle: "Lecture de l’écran", symbol: symbol, color: Palette.violet, keywords: keywords + ["ia", "ai", "envoyer"]) {
            Task { @MainActor in
                // Le lanceur se ferme d'abord : on lit la fenêtre qui était devant, pas Prism.
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let attachment = await attachment() else {
                    HUD.shared.show("Rien à lire : vérifiez les autorisations Accessibilité et Enregistrement de l’écran", symbol: "exclamationmark.triangle.fill")
                    return
                }
                AIChatWindow.shared.open(text: "", attachments: [attachment])
            }
            return .close
        }
    }

    // MARK: - Automatisations

    static func automationsScreen() -> LauncherScreen {
        ListScreen(
            id: "ai.automations", title: "Automatisations d’IA", placeholder: "Rechercher une automatisation…",
            icon: .symbol("clock.badge.checkmark.fill", Palette.violet),
            empty: { _ in ("clock.badge.checkmark", "Aucune automatisation. ⌘N pour en créer une : un résumé de l’agenda chaque matin, une veille hebdomadaire…") }
        ) { query in
            let normalized = query.normalizedForSearch
            let relative = RelativeDateTimeFormatter()
            let items = AIAutomations.shared.automations
                .filter { normalized.isEmpty || $0.name.normalizedForSearch.contains(normalized) || $0.prompt.normalizedForSearch.contains(normalized) }
                .map { automation in
                    ResultItem(
                        id: "automation:" + automation.id.uuidString,
                        title: automation.name,
                        subtitle: automation.scheduleLabel,
                        icon: .symbol(automation.enabled ? "clock.badge.checkmark.fill" : "clock.badge.xmark", automation.enabled ? Palette.violet : Palette.gray),
                        accessory: automation.lastRun.map { "Lancée " + relative.localizedString(for: $0, relativeTo: Date()) } ?? (automation.enabled ? "Active" : "En pause"),
                        detail: ItemDetail(text: automation.prompt, metadata: [
                            ("Échéance", automation.scheduleLabel),
                            ("Prochaine", automation.nextRun(after: Date()).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—"),
                            ("Modèle", automation.model.map { AIModelChoice(rawValue: $0).label } ?? "Celui d’AI Chat"),
                        ], isMarkdown: true),
                        usageKey: "",
                        actions: [
                            ItemAction(title: "Lancer maintenant", symbol: "play.fill") {
                                AIAutomations.shared.run(automation)
                                return .toast("Automatisation lancée : la réponse arrivera dans AI Chat")
                            },
                            ItemAction(title: "Ouvrir la dernière réponse", symbol: "bubble.left.and.bubble.right") {
                                if let id = automation.lastConversation, let conversation = AIHistory.shared.conversation(id) {
                                    AIChatWindow.shared.open(conversation: conversation)
                                } else {
                                    AIChatWindow.shared.open()
                                }
                                return .close
                            },
                            ItemAction(title: "Modifier", symbol: "pencil", shortcut: .edit) { .push(automationForm(automation)) },
                            ItemAction(title: automation.enabled ? "Mettre en pause" : "Réactiver", symbol: automation.enabled ? "pause.circle" : "play.circle") {
                                var updated = automation
                                updated.enabled.toggle()
                                AIAutomations.shared.save(updated)
                                return .refresh
                            },
                            ItemAction(title: "Créer une automatisation", symbol: "plus", shortcut: .create) { .push(automationForm(nil)) },
                            ItemAction(title: "Supprimer", symbol: "trash", shortcut: .removeEntry, isDestructive: true) {
                                AIAutomations.shared.delete(automation.id)
                                return .refresh
                            },
                        ]
                    )
                }
            return items.isEmpty ? [] : [ResultSection(id: "automations", title: "Automatisations", items: items)]
        }.withLayout(.split(listWidth: 340))
    }

    static func automationForm(_ existing: AIAutomation?) -> FormScreen {
        let automation = existing ?? AIAutomation(name: "", prompt: "")
        let times = stride(from: 0, to: 24 * 60, by: 15).map { minutes in
            (value: "\(minutes)", title: String(format: "%02d:%02d", minutes / 60, minutes % 60))
        }
        let weekdays = (1...7).map { (value: "\($0)", title: Calendar.current.weekdaySymbols[$0 - 1].capitalized) }
        return FormScreen(
            id: "ai.automation.form",
            title: existing == nil ? "Créer une automatisation d’IA" : "Modifier l’automatisation",
            icon: .symbol("calendar.badge.clock", Palette.violet),
            submitTitle: existing == nil ? "Créer l’automatisation" : "Enregistrer",
            fields: [
                FormField(id: "name", label: "Nom", kind: .text, placeholder: "Par exemple : Résumé du matin", value: automation.name),
                FormField(id: "prompt", label: "Demande", kind: .textArea(lines: 5), placeholder: "Résume mon @agenda du jour et rappelle-moi les réunions avec visio.", value: automation.prompt,
                          info: "Mentions possibles : @agenda, @presse-papiers, @notes, @web, @écran… Les modèles qui appellent des outils s’en servent seuls."),
                FormField(id: "schedule", label: "Fréquence", kind: .dropdown(AIAutomation.Schedule.allCases.map { ($0.rawValue, $0.title) }), value: automation.schedule.rawValue),
                FormField(id: "time", label: "Heure", kind: .dropdown(times), value: "\(automation.hour * 60 + automation.minute)",
                          info: "Pour « Toutes les heures », seules les minutes comptent."),
                FormField(id: "weekday", label: "Jour (chaque semaine)", kind: .dropdown(weekdays), value: "\(automation.weekday)"),
                FormField(id: "interval", label: "Intervalle (minutes)", kind: .text, placeholder: "60", value: "\(automation.intervalMinutes)"),
                FormField(id: "once", label: "Date (une seule fois)", kind: .date(includesTime: true), value: ISO8601DateFormatter().string(from: automation.onceAt ?? Date().addingTimeInterval(3600))),
                FormField(id: "destination", label: "Destination", kind: .dropdown([("new", "Une nouvelle conversation à chaque fois"), ("same", "Toujours la même conversation")]), value: automation.appendToSameChat == true ? "same" : "new"),
                FormField(id: "enabled", label: "", kind: .checkbox(label: "Active"), value: automation.enabled ? "true" : "false"),
            ]
        ) { state in
            let name = state.trimmed("name")
            let prompt = state.trimmed("prompt")
            guard !name.isEmpty, !prompt.isEmpty else {
                state.error = "Donnez un nom et une demande."
                return .stay
            }
            var updated = automation
            updated.name = name
            updated.prompt = prompt
            updated.schedule = AIAutomation.Schedule(rawValue: state["schedule"]) ?? .daily
            let minutes = Int(state["time"]) ?? 540
            updated.hour = minutes / 60
            updated.minute = minutes % 60
            updated.weekday = Int(state["weekday"]) ?? 2
            updated.intervalMinutes = max(5, Int(state.trimmed("interval")) ?? 60)
            updated.enabled = state.bool("enabled")
            updated.onceAt = updated.schedule == .once ? ISO8601DateFormatter().date(from: state["once"]) : nil
            if updated.schedule == .once, (updated.onceAt ?? .distantPast) <= Date() {
                state.error = "Choisissez une date à venir."
                return .stay
            }
            updated.appendToSameChat = state["destination"] == "same"
            AIAutomations.shared.save(updated)
            return .then(.pop, .toast(existing == nil ? "Automatisation créée : \(updated.scheduleLabel.lowercased())" : "Automatisation enregistrée"))
        }
    }

    // MARK: - Mémoire

    static func memoryScreen() -> LauncherScreen {
        ListScreen(
            id: "ai.memory", title: "Mémoire de l’IA", placeholder: "Ajouter un fait, puis ↵…",
            icon: .symbol("brain.head.profile", Palette.violet),
            empty: { _ in ("brain.head.profile", "La mémoire est vide. Tapez un fait (« Je travaille en Swift ») puis ↵, ou demandez à l’IA de retenir quelque chose.") }
        ) { query in
            var sections: [ResultSection] = []
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                sections.append(ResultSection(id: "add", title: nil, items: [ResultItem(
                    id: "memory.add", title: "Retenir « \(trimmed) »", icon: .symbol("plus", Palette.violet), usageKey: "",
                    actions: [ItemAction(title: "Ajouter à la mémoire", symbol: "plus") {
                        AIMemory.shared.add(trimmed)
                        return .setQuery("")
                    }]
                )]))
            }
            let normalized = trimmed.normalizedForSearch
            let facts = AIMemory.shared.facts.reversed().filter { normalized.isEmpty || $0.text.normalizedForSearch.contains(normalized) }
            if !facts.isEmpty {
                sections.append(ResultSection(id: "facts", title: AIMemory.shared.enabled ? "Ce que l’IA retient" : "Mémoire désactivée", items: facts.map { fact in
                    ResultItem(
                        id: "memory:" + fact.id.uuidString, title: fact.text, icon: .tinted("brain", Palette.violet),
                        accessory: fact.date.formatted(date: .abbreviated, time: .omitted), usageKey: "",
                        actions: [
                            ItemAction(title: "Oublier", symbol: "trash", isDestructive: true) {
                                AIMemory.shared.remove(fact.id)
                                return .refresh
                            },
                            ItemAction(title: "Copier", symbol: "doc.on.doc") {
                                Pasteboard.copy(fact.text)
                                return .toast("Copié")
                            },
                            ItemAction(title: AIMemory.shared.enabled ? "Désactiver la mémoire" : "Activer la mémoire", symbol: "power") {
                                AIMemory.shared.enabled.toggle()
                                return .refresh
                            },
                            ItemAction(title: "Générer depuis les conversations récentes", symbol: "sparkles") {
                                generateMemory()
                                return .stay
                            },
                            ItemAction(title: "Tout oublier", symbol: "trash.slash", shortcut: .removeAll, isDestructive: true) {
                                AIMemory.shared.clear()
                                return .refresh
                            },
                        ]
                    )
                }))
            }
            if facts.isEmpty, trimmed.isEmpty {
                sections.append(ResultSection(id: "generate", title: nil, items: [ResultItem(
                    id: "memory.generate", title: "Générer la mémoire depuis les conversations récentes", icon: .symbol("sparkles", Palette.violet), usageKey: "",
                    actions: [ItemAction(title: "Générer", symbol: "sparkles") {
                        generateMemory()
                        return .stay
                    }]
                )]))
            }
            return sections
        }
    }

    private static func generateMemory() {
        guard let host = AppContext.launcher?.model else { return }
        host.screen.isLoading = true
        Task {
            do {
                let added = try await AIMemory.shared.generate(choice: AISettings.shared.choice(for: .chat))
                host.screen.isLoading = false
                host.showToast(added == 0 ? "Rien de nouveau à retenir" : "\(added) fait(s) ajouté(s) à la mémoire", isError: false)
                host.refresh(keepSelection: false)
            } catch {
                host.screen.isLoading = false
                host.showToast((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    // MARK: - Outils

    static func toolsScreen() -> LauncherScreen {
        ListScreen(
            id: "ai.tools", title: "Extensions de l’IA", placeholder: "Rechercher un outil…",
            icon: .symbol("puzzlepiece.extension.fill", Palette.violet)
        ) { query in
            let normalized = query.normalizedForSearch
            let disabled = Set(AIToolSettings.shared.disabledTools)
            let items = AITools.builtIn
                .filter { normalized.isEmpty || $0.name.normalizedForSearch.contains(normalized) || $0.description.normalizedForSearch.contains(normalized) }
                .map { tool in
                    let enabled = !disabled.contains(tool.name)
                    return ResultItem(
                        id: "tool:" + tool.name,
                        title: AIToolLoop.label(tool).prefix(1).uppercased() + AIToolLoop.label(tool).dropFirst(),
                        subtitle: tool.description,
                        icon: .symbol(tool.isAction ? "bolt.fill" : "eye.fill", enabled ? (tool.isAction ? Palette.orange : Palette.blue) : Palette.gray),
                        accessory: enabled ? (tool.isAction ? "Action" : "Lecture") : "Désactivé",
                        tags: Array(tool.mentions.prefix(2)),
                        usageKey: "",
                        actions: [ItemAction(title: enabled ? "Désactiver l’outil" : "Activer l’outil", symbol: "power") {
                            var list = AIToolSettings.shared.disabledTools
                            if enabled { list.append(tool.name) } else { list.removeAll { $0 == tool.name } }
                            AIToolSettings.shared.disabledTools = list
                            return .refresh
                        }, ItemAction(title: "Réglages des serveurs MCP", symbol: "server.rack") {
                            NotificationCenter.default.post(name: .prismOpenSettings, object: AIFeature.settingsPaneID)
                            return .close
                        }]
                    )
                }
            return [ResultSection(id: "tools", title: "Outils de Prism · les mentions (@agenda…) marchent avec tous les modèles", items: items)]
        }
    }
}

extension ListScreen {
    /// Change la disposition d'un écran construit par fermetures.
    func withLayout(_ layout: ScreenLayout) -> ListScreen {
        self.layout = layout
        return self
    }
}

/// Les réglages des extensions dans le pane IA : outils, serveurs MCP, mémoire, automatisations.
struct AIExtensionsSettingsSections: View {
    @ObservedObject private var tools = AIToolSettings.shared
    @ObservedObject private var memory = AIMemory.shared
    @ObservedObject private var hub = MCPHub.shared
    @ObservedObject private var automations = AIAutomations.shared
    @ObservedObject private var skills = AISkills.shared
    @State private var newFolder = ""
    @State private var config = MCPHub.configText()
    @State private var message: String?

    var body: some View {
        Section {
            Toggle("Laisser l’IA utiliser les outils de Prism et des serveurs MCP", isOn: $tools.enabled)
            Toggle("Demander avant chaque action (créer, lancer, démarrer…)", isOn: $tools.confirmActions)
                .disabled(!tools.enabled)
        } header: {
            Text("Extensions de l’IA")
        } footer: {
            Text("Agenda, presse-papiers, notes, concentration, fichiers, snippets, calculatrice, commandes de Prism, web, écran. Anthropic, OpenAI et Ollama appellent les outils eux-mêmes ; avec Apple Intelligence, mentionnez-les (@agenda, @presse-papiers, @notes, @web, @écran…).")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }

        Section {
            TextEditor(text: $config)
                .font(.system(size: 11.5, design: .monospaced))
                .frame(height: 140)
            HStack {
                Button("Enregistrer") { message = hub.save(configText: config) ?? "Configuration enregistrée." }
                Button("Importer depuis Claude Desktop") {
                    message = hub.importClaudeDesktop()
                    config = MCPHub.configText()
                }
                Button("Tester les serveurs") {
                    message = "Démarrage des serveurs…"
                    Task {
                        await hub.test()
                        message = hub.states.isEmpty ? "Aucun serveur configuré." : "Serveurs testés."
                    }
                }
                Spacer()
                if let message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            ForEach(hub.states) { state in
                LabeledContent(state.name) {
                    Text(state.toolCount > 0 ? "\(state.status) · \(state.toolCount) outil(s)" : state.status)
                        .foregroundStyle(state.toolCount > 0 ? Palette.green : Palette.orange)
                        .lineLimit(2)
                }
            }
        } header: {
            Text("Serveurs MCP")
        } footer: {
            Text("Au format de Claude Desktop : {\"mcpServers\": {\"nom\": {\"command\": \"npx\", \"args\": [\"-y\", \"@modelcontextprotocol/server-filesystem\", \"~/Documents\"]}}}. Les serveurs démarrent à la première question qui peut utiliser des outils.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }

        Section {
            Toggle("Découvrir les skills automatiquement (modèles avec outils)", isOn: $skills.autoDiscover)
            let found = skills.skills
            if found.isEmpty {
                Text("Aucun skill trouvé. Un skill est un dossier contenant un SKILL.md avec « name » et « description » en en-tête.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            ForEach(found) { skill in
                LabeledContent("@" + skill.name) {
                    Text(skill.description).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            ForEach(skills.extraFolders, id: \.self) { folder in
                HStack {
                    Text(folder).font(.system(size: 11.5, design: .monospaced))
                    Spacer()
                    Button("Retirer") { skills.extraFolders.removeAll { $0 == folder } }.buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Ajouter un dossier de skills (~/…)", text: $newFolder)
                Button("Ajouter") {
                    let folder = newFolder.trimmingCharacters(in: .whitespaces)
                    if !folder.isEmpty, !skills.extraFolders.contains(folder) { skills.extraFolders.append(folder) }
                    newFolder = ""
                }
                .disabled(newFolder.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Relire") { skills.invalidate(); skills.objectWillChange.send() }
            }
        } header: {
            Text("Skills")
        } footer: {
            Text("Dossiers lus : \(AISkills.defaultFolders.joined(separator: ", ")). Mentionnez un skill avec @nom pour l’imposer, avec tous les modèles.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }

        Section {
            Toggle("Mémoire : l’IA retient des faits sur vous d’une conversation à l’autre", isOn: Binding(get: { memory.enabled }, set: { memory.enabled = $0 }))
            LabeledContent("Faits retenus", value: "\(memory.facts.count)")
            Button("Tout oublier", role: .destructive) { memory.clear() }
                .disabled(memory.facts.isEmpty)
            LabeledContent("Automatisations", value: "\(automations.automations.filter(\.enabled).count) active(s)")
        } header: {
            Text("Mémoire et automatisations")
        } footer: {
            Text("Commandes « Mémoire de l’IA » et « Rechercher les automatisations d’IA » dans la recherche principale.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
