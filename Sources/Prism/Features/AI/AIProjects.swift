import AppKit
import SwiftUI

// MARK: - Projets

/// Un projet d'IA : des conversations regroupées sous des instructions communes et un dossier de travail
/// (dont le fichier `AGENTS.md` est lu), comme les « Projects » de Raycast.
struct AIProject: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var symbol = "folder.fill"
    var instructions = ""
    /// Dossier de travail, local, jamais synchronisé.
    var workingDirectory: String?
}

@MainActor
final class AIProjectStore: ObservableObject {
    static let shared = AIProjectStore()
    let store = JSONStore("ai-projects.json", default: [AIProject]())

    var projects: [AIProject] { store.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }

    func project(_ id: UUID?) -> AIProject? {
        guard let id else { return nil }
        return store.value.first { $0.id == id }
    }

    func save(_ project: AIProject) {
        if let index = store.value.firstIndex(where: { $0.id == project.id }) {
            store.value[index] = project
        } else {
            store.value.append(project)
        }
        objectWillChange.send()
    }

    /// Supprimer un projet garde ses conversations, qui reviennent dans « Récentes ».
    func delete(_ id: UUID) {
        store.value.removeAll { $0.id == id }
        for conversation in AIHistory.shared.active where conversation.projectID == id {
            AIHistory.shared.update(conversation.id) { $0.projectID = nil }
        }
        objectWillChange.send()
    }

    /// Le contexte du projet, dans l'ordre de Raycast : `AGENTS.md` du dossier, puis les instructions.
    func context(for id: UUID?) -> String? {
        guard let project = project(id) else { return nil }
        var parts: [String] = ["Projet : \(project.name)"]
        if let directory = project.workingDirectory {
            parts.append("Dossier de travail : \(directory)")
            let agents = URL(fileURLWithPath: directory).appendingPathComponent("AGENTS.md")
            if let text = try? String(contentsOf: agents, encoding: .utf8), !text.isEmpty {
                parts.append("AGENTS.md du dossier :\n\(String(text.prefix(20_000)))")
            }
        }
        if !project.instructions.isEmpty { parts.append("Instructions du projet :\n\(project.instructions)") }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Skills

/// Les skills : des fichiers `SKILL.md` (nom et description en en-tête YAML) que le modèle charge quand
/// la conversation en a besoin, dans les mêmes dossiers que Raycast et Claude.
struct AISkill: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var description: String
    var path: String

    var body: String {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        return AISkills.stripFrontmatter(text)
    }
}

@MainActor
final class AISkills: ObservableObject {
    static let shared = AISkills()

    static let defaultFolders = ["~/.claude/skills", "~/.config/agents/skills", "~/.config/raycast/skills", "~/.agents/skills", "~/.config/prism/skills"]

    @Published var extraFolders: [String] {
        didSet { UserDefaults.standard.set(extraFolders, forKey: "ai.skills.folders"); invalidate() }
    }
    @Published var autoDiscover: Bool {
        didSet { UserDefaults.standard.set(autoDiscover, forKey: "ai.skills.autoDiscover") }
    }

    private var cache: [AISkill] = []
    private var cachedAt = Date.distantPast

    private init() {
        extraFolders = UserDefaults.standard.stringArray(forKey: "ai.skills.folders") ?? []
        autoDiscover = UserDefaults.standard.object(forKey: "ai.skills.autoDiscover") as? Bool ?? true
    }

    func invalidate() { cachedAt = .distantPast }

    /// Les skills trouvés (relus au plus toutes les 60 s). Le premier d'un nom l'emporte.
    var skills: [AISkill] {
        if Date().timeIntervalSince(cachedAt) > 60 {
            cache = Self.scan(folders: Self.defaultFolders + extraFolders)
            cachedAt = Date()
        }
        return cache
    }

    nonisolated static func scan(folders: [String]) -> [AISkill] {
        var found: [AISkill] = []
        var names = Set<String>()
        let manager = FileManager.default
        for folder in folders {
            let root = (folder as NSString).expandingTildeInPath
            guard let children = try? manager.contentsOfDirectory(atPath: root) else { continue }
            for child in children.sorted() where !child.hasPrefix(".") {
                let path = (root as NSString).appendingPathComponent(child) + "/SKILL.md"
                guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                      let header = frontmatter(text),
                      let name = header["name"], isValidName(name), name == child,
                      let description = header["description"], (1...1024).contains(description.count),
                      !names.contains(name) else { continue }
                names.insert(name)
                found.append(AISkill(name: name, description: description, path: path))
            }
        }
        return found
    }

    /// L'en-tête YAML simple (`clé: valeur` sur une ligne) entre deux lignes « --- ».
    nonisolated static func frontmatter(_ text: String) -> [String: String]? {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        var result: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }

    nonisolated static func stripFrontmatter(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return text }
        return lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 1 à 64 caractères : minuscules, chiffres, tirets ; pas de tiret au bord ni doublé.
    nonisolated static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.count), !name.hasPrefix("-"), !name.hasSuffix("-"), !name.contains("--") else { return false }
        return name.allSatisfy { ($0.isLowercase && $0.isASCII) || $0.isNumber || $0 == "-" }
    }

    /// Le catalogue donné aux modèles qui appellent des outils : nom et description, sans le corps.
    var catalog: String? {
        guard autoDiscover, !skills.isEmpty else { return nil }
        return "Skills disponibles (charge-en un avec l’outil load_skill quand la demande s’y rapporte) :\n"
            + skills.map { "- \($0.name) : \($0.description)" }.joined(separator: "\n")
    }

    /// Les skills mentionnés (« @nom-du-skill ») : leur contenu rejoint la question, pour tous les modèles.
    func mentioned(in text: String) -> [AISkill] {
        let lowered = text.lowercased()
        return skills.filter { lowered.contains("@" + $0.name) }
    }

    /// L'outil qui charge un skill.
    var tool: AIToolSpec? {
        guard !skills.isEmpty else { return nil }
        return AIToolSpec(
            name: "load_skill",
            description: "Charge les instructions complètes d’un skill du catalogue.",
            schema: ["type": "object", "properties": ["name": ["type": "string", "description": "Nom du skill"]], "required": ["name"]]
        ) { arguments in
            guard let name = arguments["name"] as? String, let skill = AISkills.shared.skills.first(where: { $0.name == name }) else {
                return "Skill introuvable."
            }
            return skill.body
        }
    }
}

// MARK: - Écrans du lanceur : agents et projets

@MainActor
enum AIAgentsUI {
    static var commands: [ResultItem] {
        var items: [ResultItem] = [
            Command.screen("ai.agents", "Rechercher les agents", subtitle: "IA", symbol: "person.crop.circle.badge.checkmark", color: Palette.violet,
                           keywords: ["agents", "presets", "préréglages", "ia", "ai", "deep research"]) { agentsScreen() },
            Command.screen("ai.create-agent", "Créer un agent", subtitle: "IA", symbol: "person.crop.circle.badge.plus", color: Palette.violet,
                           keywords: ["create agent", "agent", "préréglage", "ia"]) { agentForm(nil) },
            Command.screen("ai.projects", "Rechercher les projets d’IA", subtitle: "IA", symbol: "folder.fill.badge.gearshape", color: Palette.violet,
                           keywords: ["projects", "projets", "ia", "ai"]) { projectsScreen() },
            Command.screen("ai.create-project", "Créer un projet d’IA", subtitle: "IA", symbol: "folder.badge.plus", color: Palette.violet,
                           keywords: ["create project", "projet", "ia"]) { projectForm(nil) },
        ]
        // Chaque agent et chaque projet est aussi une commande de la recherche principale.
        items += AIPresetStore.shared.presets.map { agent in
            Command.run("ai.agent." + agent.id.uuidString, agent.name, subtitle: "Agent d’IA", symbol: agent.symbol, color: Palette.violet, keywords: ["agent", "ia", "chat"]) {
                AIChatWindow.shared.model.newConversation(presetID: agent.id)
                AIChatWindow.shared.open()
                return .close
            }
        }
        items += AIProjectStore.shared.projects.map { project in
            Command.run("ai.project." + project.id.uuidString, project.name, subtitle: "Projet d’IA", symbol: project.symbol, color: Palette.indigo, keywords: ["projet", "ia", "chat"]) {
                AIChatWindow.shared.model.newConversation(projectID: project.id)
                AIChatWindow.shared.open()
                return .close
            }
        }
        return items
    }

    static func agentsScreen() -> LauncherScreen {
        ListScreen(id: "ai.agents", title: "Agents d’IA", placeholder: "Rechercher un agent…", icon: .symbol("person.crop.circle.badge.checkmark", Palette.violet)) { query in
            let normalized = query.normalizedForSearch
            let agents = AIPresetStore.shared.presets.filter { normalized.isEmpty || $0.name.normalizedForSearch.contains(normalized) }
            func item(_ agent: AIPreset) -> ResultItem {
                var actions: [ItemAction] = [
                    ItemAction(title: "Nouvelle conversation avec l’agent", symbol: "bubble.left.and.bubble.right") {
                        AIChatWindow.shared.model.newConversation(presetID: agent.id)
                        AIChatWindow.shared.open()
                        return .close
                    },
                    ItemAction(title: "Dupliquer", symbol: "plus.square.on.square", shortcut: .duplicate) {
                        var copy = agent
                        copy.id = UUID()
                        copy.name += " (copie)"
                        copy.builtIn = nil
                        AIPresetStore.shared.presets.append(copy)
                        return .refresh
                    },
                    ItemAction(title: "Créer un agent", symbol: "plus", shortcut: .create) { .push(agentForm(nil)) },
                ]
                if !agent.isBuiltIn {
                    actions.insert(ItemAction(title: "Modifier", symbol: "pencil", shortcut: .edit) { .push(agentForm(agent)) }, at: 1)
                    actions.append(ItemAction(title: "Supprimer l’agent", symbol: "trash", shortcut: .removeEntry, isDestructive: true) {
                        AIPresetStore.shared.presets.removeAll { $0.id == agent.id }
                        return .refresh
                    })
                }
                let tools = agent.tools.map { $0.isEmpty ? "Aucun" : $0.compactMap { AIToolLoop.titles[$0] ?? ($0 == "mcp" ? "Serveurs MCP" : nil) }.joined(separator: ", ") } ?? "Tous"
                return ResultItem(
                    id: "agent:" + agent.id.uuidString,
                    title: agent.name,
                    icon: .symbol(agent.symbol, Palette.violet),
                    accessory: agent.isBuiltIn ? "Intégré" : nil,
                    detail: ItemDetail(text: agent.instructions, metadata: [
                        ("Modèle", agent.model.map { AIModelChoice(rawValue: $0).label } ?? "Celui de la conversation"),
                        ("Outils", tools),
                    ], isMarkdown: true),
                    usageKey: "",
                    actions: actions
                )
            }
            return [
                ResultSection(id: "custom", title: "Mes agents", items: agents.filter { !$0.isBuiltIn }.map(item)),
                ResultSection(id: "builtin", title: "Agents intégrés", items: agents.filter(\.isBuiltIn).map(item)),
            ].filter { !$0.items.isEmpty }
        }.withLayout(.split(listWidth: 320))
    }

    static func agentForm(_ existing: AIPreset?) -> FormScreen {
        let agent = existing ?? AIPreset(name: "", instructions: "")
        let models: [(value: String, title: String)] = [("", "Celui de la conversation"), ("auto", "Auto")]
            + AIProviderKind.allCases.map { ("\($0.rawValue):", $0.title) }
        var fields: [FormField] = [
            FormField(id: "name", label: "Nom", kind: .text, placeholder: "Par exemple : Relecteur de code", value: agent.name),
            FormField(id: "symbol", label: "Symbole SF", kind: .text, placeholder: "person.crop.circle", value: agent.symbol),
            FormField(id: "instructions", label: "Instructions", kind: .textArea(lines: 6), placeholder: "Le rôle, puis les règles à suivre toujours.", value: agent.instructions),
            FormField(id: "model", label: "Modèle", kind: .dropdown(models), value: agent.model ?? ""),
            FormField(id: "allTools", label: "Outils", kind: .checkbox(label: "Tous les outils (sinon : ceux cochés)"), value: agent.tools == nil ? "true" : "false"),
        ]
        for tool in AITools.builtIn {
            fields.append(FormField(id: "tool." + tool.name, label: "", kind: .checkbox(label: AIToolLoop.label(tool)), value: agent.tools?.contains(tool.name) == true ? "true" : "false"))
        }
        fields.append(FormField(id: "tool.mcp", label: "", kind: .checkbox(label: "Serveurs MCP"), value: agent.tools?.contains("mcp") == true ? "true" : "false"))
        return FormScreen(id: "ai.agent.form", title: existing == nil ? "Créer un agent" : "Modifier l’agent", icon: .symbol("person.crop.circle.badge.plus", Palette.violet),
                          submitTitle: existing == nil ? "Créer l’agent" : "Enregistrer", fields: fields) { state in
            let name = state.trimmed("name")
            guard !name.isEmpty, !state.trimmed("instructions").isEmpty else {
                state.error = "Donnez un nom et des instructions."
                return .stay
            }
            var updated = agent
            updated.name = name
            updated.symbol = NSImage(systemSymbolName: state.trimmed("symbol"), accessibilityDescription: nil) == nil ? "person.crop.circle" : state.trimmed("symbol")
            updated.instructions = state.trimmed("instructions")
            updated.model = state["model"].isEmpty ? nil : state["model"]
            if state.bool("allTools") {
                updated.tools = nil
            } else {
                updated.tools = (AITools.builtIn.map(\.name) + ["mcp"]).filter { state.bool("tool." + $0) }
            }
            if let index = AIPresetStore.shared.presets.firstIndex(where: { $0.id == updated.id }) {
                AIPresetStore.shared.presets[index] = updated
            } else {
                AIPresetStore.shared.presets.append(updated)
            }
            return .then(.pop, .toast(existing == nil ? "Agent « \(name) » créé" : "Agent enregistré"))
        }
    }

    static func projectsScreen() -> LauncherScreen {
        ListScreen(
            id: "ai.projects", title: "Projets d’IA", placeholder: "Rechercher un projet…", icon: .symbol("folder.fill.badge.gearshape", Palette.violet),
            empty: { _ in ("folder.badge.plus", "Aucun projet. ⌘N pour en créer un : instructions communes et dossier de travail.") }
        ) { query in
            let normalized = query.normalizedForSearch
            let items = AIProjectStore.shared.projects.filter { normalized.isEmpty || $0.name.normalizedForSearch.contains(normalized) }.map { project in
                let count = AIHistory.shared.active.filter { $0.projectID == project.id }.count
                return ResultItem(
                    id: "project:" + project.id.uuidString,
                    title: project.name,
                    subtitle: project.workingDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath },
                    icon: .symbol(project.symbol, Palette.indigo),
                    accessory: "\(count) conversation\(count > 1 ? "s" : "")",
                    detail: ItemDetail(text: project.instructions.isEmpty ? "_Pas d’instructions._" : project.instructions, metadata: [
                        ("Dossier", project.workingDirectory ?? "—"),
                        ("AGENTS.md", project.workingDirectory.map { FileManager.default.fileExists(atPath: $0 + "/AGENTS.md") ? "Lu" : "Absent" } ?? "—"),
                    ], isMarkdown: true),
                    usageKey: "",
                    actions: [
                        ItemAction(title: "Nouvelle conversation dans le projet", symbol: "bubble.left.and.bubble.right") {
                            AIChatWindow.shared.model.newConversation(projectID: project.id)
                            AIChatWindow.shared.open()
                            return .close
                        },
                        ItemAction(title: "Modifier", symbol: "pencil", shortcut: .edit) { .push(projectForm(project)) },
                        ItemAction(title: "Copier le lien profond", symbol: "link", shortcut: .deeplink) {
                            Pasteboard.copy("prism://ai/project?id=\(project.id.uuidString)")
                            return .toast("Lien copié")
                        },
                        ItemAction(title: "Créer un projet", symbol: "plus", shortcut: .create) { .push(projectForm(nil)) },
                        ItemAction(title: "Supprimer le projet (garde les conversations)", symbol: "trash", shortcut: .removeEntry, isDestructive: true) {
                            AIProjectStore.shared.delete(project.id)
                            return .refresh
                        },
                    ]
                )
            }
            return items.isEmpty ? [] : [ResultSection(id: "projects", title: "Projets", items: items)]
        }.withLayout(.split(listWidth: 320))
    }

    static func projectForm(_ existing: AIProject?) -> FormScreen {
        let project = existing ?? AIProject(name: "")
        return FormScreen(
            id: "ai.project.form", title: existing == nil ? "Créer un projet d’IA" : "Modifier le projet", icon: .symbol("folder.badge.plus", Palette.indigo),
            submitTitle: existing == nil ? "Créer le projet" : "Enregistrer",
            fields: [
                FormField(id: "name", label: "Nom", kind: .text, placeholder: "Par exemple : Refonte du site", value: project.name),
                FormField(id: "symbol", label: "Symbole SF", kind: .text, placeholder: "folder.fill", value: project.symbol),
                FormField(id: "instructions", label: "Instructions", kind: .textArea(lines: 5), placeholder: "Le contexte et les règles communs à toutes les conversations du projet.", value: project.instructions),
                FormField(id: "directory", label: "Dossier de travail", kind: .text, placeholder: "~/Documents/projets/mon-projet", value: project.workingDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "",
                          info: "Facultatif. Son AGENTS.md est lu au début de chaque réponse. Rien n’est envoyé d’autre que ce fichier."),
            ]
        ) { state in
            let name = state.trimmed("name")
            guard !name.isEmpty else {
                state.error = "Donnez un nom au projet."
                return .stay
            }
            var updated = project
            updated.name = name
            updated.symbol = NSImage(systemSymbolName: state.trimmed("symbol"), accessibilityDescription: nil) == nil ? "folder.fill" : state.trimmed("symbol")
            updated.instructions = state.trimmed("instructions")
            let directory = (state.trimmed("directory") as NSString).expandingTildeInPath
            if !directory.isEmpty {
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: directory, isDirectory: &isFolder), isFolder.boolValue else {
                    state.error = "Ce dossier n’existe pas."
                    return .stay
                }
            }
            updated.workingDirectory = directory.isEmpty ? nil : directory
            AIProjectStore.shared.save(updated)
            return .then(.pop, .toast(existing == nil ? "Projet « \(name) » créé" : "Projet enregistré"))
        }
    }
}
