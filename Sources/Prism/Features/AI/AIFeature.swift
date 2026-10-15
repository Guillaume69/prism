import AppKit
import SwiftUI

/// L'IA de Prism, comme Raycast AI : Quick AI dans le lanceur, la fenêtre AI Chat, les commandes d'IA,
/// sur Apple Intelligence (par défaut, sur l'appareil), Ollama, OpenAI (ou compatible) et Anthropic.
@MainActor
enum AIFeature: PrismFeature {
    static let settingsPaneID = "ai"

    static func start() {
        AppHooks.quickAI = { prompt in AIAnswerScreen.quick(prompt: prompt) }
        AppHooks.sendToAIChat = { text, attachments in
            let attached = attachments.enumerated().map { index, content in
                AIAttachment(kind: .text, title: attachments.count > 1 ? "Pièce jointe \(index + 1)" : "Pièce jointe", content: content)
            }
            AIChatWindow.shared.open(text: text, attachments: attached)
            return .close
        }
        AIAutomations.shared.start()
        AIHistory.shared.autoArchive(days: AISettings.shared.autoArchiveDays)
        AppHooks.aiComplete = { prompt, system in
            try await AIRouter.complete([AIMessage(role: .user, content: prompt)], system: system, choice: AISettings.shared.choice(for: .commands))
        }
    }

    static var commands: [ResultItem] {
        [
            Command.screen(
                "ai.quick", "Quick AI", subtitle: "IA",
                symbol: "sparkles", color: Palette.violet,
                keywords: ["ia", "ai", "question", "demander", "chatgpt", "claude", "assistant"]
            ) { AIAnswerScreen.quick() },
            Command.run(
                "ai.chat", "AI Chat", subtitle: "IA",
                symbol: "bubble.left.and.bubble.right.fill", color: Palette.violet,
                keywords: ["ia", "ai", "conversation", "discussion", "chat"]
            ) {
                AIChatWindow.shared.open()
                return .close
            },
            Command.screen(
                "ai.commands", "Rechercher les commandes d’IA", subtitle: "IA",
                symbol: "sparkle.magnifyingglass", color: Palette.violet,
                keywords: ["ia", "ai", "commandes", "prompts", "ai commands"]
            ) { AICommandsScreen.make() },
            Command.screen(
                "ai.create-command", "Créer une commande d’IA", subtitle: "IA",
                symbol: "plus.bubble.fill", color: Palette.violet,
                keywords: ["ia", "ai", "prompt", "nouvelle commande", "create ai command"]
            ) { AICommandForm.screen() },
        ] + AIExtensionsUI.commands + AIAgentsUI.commands + AICommandStore.shared.all.map(AICommandRunner.item)
    }

    static func fallbacks(query: String) -> [ResultItem] {
        [ResultItem(
            id: "fallback.ai",
            title: "Demander à l’IA",
            subtitle: query,
            icon: .symbol("sparkles", Palette.violet),
            accessory: "Quick AI",
            tags: AISettings.shared.hideTabHint ? [] : ["⇥ Tab"],
            actions: [ItemAction(title: "Demander à l’IA", symbol: "sparkles") { .push(AIAnswerScreen.quick(prompt: query)) }]
        )]
    }

    static var settingsPanes: [SettingsPane] {
        [SettingsPane(id: settingsPaneID, title: "IA", symbol: "sparkles", color: Palette.violet, order: 30) { AnyView(AISettingsView()) }]
    }

    /// `prism://ai/ask?q=…` ouvre Quick AI avec la question ; `prism://ai/chat[?q=…]` ouvre AI Chat.
    static func handle(url: URL) -> Bool {
        guard url.host == "ai" else { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
        switch url.path {
        case "/ask", "/quick":
            guard let launcher = AppContext.launcher else { return true }
            launcher.show(reset: true)
            launcher.model.push(AIAnswerScreen.quick(prompt: query))
        case "/chat", "":
            if query.isEmpty { AIChatWindow.shared.open() } else { AIChatWindow.shared.open(text: query, attachments: []) }
        case "/project":
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value.flatMap(UUID.init(uuidString:))
            AIChatWindow.shared.model.newConversation(projectID: id)
            AIChatWindow.shared.open()
        default:
            return false
        }
        return true
    }

    // MARK: - Ligne de commande

    /// `--snapshot-chat sortie.png [--light]` et `--ai-test "question" [--provider apple|ollama|auto]`.
    /// Essai réel des extensions : un serveur MCP local (script fourni), la recherche web, une page,
    /// la mention @date avec Apple Intelligence. N'écrit rien dans les données de l'utilisateur.
    static func toolsCommandLineTest(mcpScript: String) -> Int32 {
        var finished = false
        var failures = 0
        Task {
            func check(_ ok: Bool, _ label: String) {
                print((ok ? "✓ " : "✗ ") + label)
                if !ok { failures += 1 }
            }
            let connection = MCPConnection(name: "essai", config: MCPServerConfig(command: "python3", args: [mcpScript], env: nil))
            do {
                try await connection.start()
                let tools = try await connection.listTools()
                check(tools.contains { $0["name"] as? String == "add" }, "MCP : outils listés (\(tools.compactMap { $0["name"] as? String }))")
                let sum = await connection.callTool("add", arguments: ["a": 20, "b": 22])
                check(sum.contains("42"), "MCP : appel d’outil → \(sum)")
            } catch {
                check(false, "MCP : \(error.localizedDescription)")
            }
            connection.stop()
            let search = await WebTools.search("Swift programming language")
            check(search.contains("http"), "recherche web : \(search.split(separator: "\n").first ?? "rien")")
            let page = await WebTools.read(URL(string: "https://www.swift.org")!)
            check(page.count > 200 && !page.contains("<div"), "lecture de page : \(page.count) caractères de texte")
            let mention = await AITools.mentionContext(in: "Quelle heure est-il ? @date") ?? ""
            check(mention.contains("fuseau"), "mention @date jointe à la question")
            if AppleIntelligence.status.isAvailable {
                let answer = (try? await AIEngineBridge.answer(prompt: "Quel jour sommes-nous ? Réponds en une phrase. @date", resolved: AIResolvedModel(kind: .apple, model: ""))) ?? ""
                let weekday = Date().formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "fr_FR")))
                check(answer.lowercased().contains(weekday.lowercased()), "Apple Intelligence + @date : « \(answer) »")
            }
            finished = true
        }
        while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        return failures == 0 ? 0 : 1
    }

    /// Essai d'un fournisseur personnalisé (providers.json donné par PRISM_PROVIDERS_FILE) : flux, puis boucle d'outils.
    static func customProviderCommandLineTest(model: String) -> Int32 {
        var finished = false
        var failures = 0
        Task {
            func check(_ ok: Bool, _ label: String) {
                print((ok ? "✓ " : "✗ ") + label)
                if !ok { failures += 1 }
            }
            do {
                let resolved = try await AIRouter.resolve(AIModelChoice(rawValue: "openai:" + model))
                check(AIModelChoice(rawValue: "openai:" + model).label.contains("("), "libellé : \(AIModelChoice(rawValue: "openai:" + model).label)")
                let streamed = try await AIRouter.complete([AIMessage(role: .user, content: "Salut")], system: "Sois bref.", resolved: resolved)
                check(streamed == "Bonjour depuis le serveur.", "flux : « \(streamed) »")
                check(AIToolLoop.supports(resolved), "outils déclarés par le modèle")
                let answer = try await AIToolLoop.run(resolved: resolved, messages: [AIMessage(role: .user, content: "Quelle heure ?")], system: nil, temperature: 0.3, tools: AITools.builtIn) { _ in }
                check(answer.hasPrefix("Réponse finale avec l’outil") && answer.contains("fuseau"), "boucle d’outils : « \(answer.prefix(90))… »")
            } catch {
                check(false, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            finished = true
        }
        while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        return failures == 0 ? 0 : 1
    }

    /// Essai d'Anthropic ou d'Ollama contre un serveur local factice : flux, puis boucle d'outils.
    static func providerCommandLineTest(kind: String) -> Int32 {
        var finished = false
        var failures = 0
        Task {
            func check(_ ok: Bool, _ label: String) {
                print((ok ? "✓ " : "✗ ") + label)
                if !ok { failures += 1 }
            }
            let choice = kind == "ollama" ? AIModelChoice.model(.ollama, "faux:latest") : AIModelChoice.model(.anthropic, "claude-sonnet-5-5")
            do {
                let resolved = try await AIRouter.resolve(choice)
                let streamed = try await AIRouter.complete([AIMessage(role: .user, content: "Salut")], system: "Sois bref.", resolved: resolved)
                check(streamed == "Bonjour depuis le serveur.", "\(kind) : flux « \(streamed) »")
                let usage = AIUsage.shared
                let before = usage.content
                let key = AIUsage.key(kind: resolved.kind, model: resolved.model)
                let requestsBefore = usage.month()[key]?.requests ?? 0
                let answer = try await AIToolLoop.run(resolved: resolved, messages: [AIMessage(role: .user, content: "Quelle heure ?")], system: "Système", temperature: 0.3, tools: AITools.builtIn) { _ in }
                check(answer.hasPrefix("Réponse finale avec l’outil") && answer.contains("fuseau"), "\(kind) : boucle d’outils « \(answer.prefix(70))… »")
                // Utilisation : les deux tours de la boucle sont comptés ; un budget atteint bloque les modèles payants.
                let counted = (usage.month()[key]?.requests ?? 0) - requestsBefore
                check(counted == 2, "\(kind) : utilisation comptée (\(counted) requête(s) de plus)")
                if AIUsage.isPaid(resolved.kind) {
                    usage.monthlyBudget = 0.000001
                    do {
                        _ = try await AIRouter.complete([AIMessage(role: .user, content: "Encore")], system: nil, resolved: resolved)
                        check(false, "\(kind) : budget atteint, requête refusée")
                    } catch {
                        check((error as? LocalizedError)?.errorDescription?.contains("Budget mensuel") == true, "\(kind) : budget atteint, requête refusée")
                    }
                }
                usage.restore(before)
            } catch {
                check(false, "\(kind) : " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
            finished = true
        }
        while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        return failures == 0 ? 0 : 1
    }

    static func runCommandLine(_ arguments: [String]) -> Int32 {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        if let output = value("--snapshot-chat") {
            return AIChatWindow.renderSnapshot(to: output, dark: !arguments.contains("--light"))
        }
        if let kind = value("--provider-test") {
            return providerCommandLineTest(kind: kind)
        }
        if let model = value("--custom-provider-test") {
            return customProviderCommandLineTest(model: model)
        }
        if let server = value("--ai-tools-test") {
            return toolsCommandLineTest(mcpScript: server)
        }
        guard let question = value("--ai-test") else { return 1 }
        // Essai sur l'appareil seulement : Apple Intelligence ou Ollama, jamais un service en ligne.
        let choice: AIModelChoice
        switch value("--provider") ?? "apple" {
        case "ollama": choice = .model(.ollama, value("--model") ?? "")
        case "auto": choice = .auto
        default: choice = .apple
        }
        print("Apple Intelligence : \(AppleIntelligence.status.message)")
        var finished = false
        var status: Int32 = 0
        Task {
            do {
                let resolved = try await AIRouter.resolve(choice)
                guard resolved.kind.isLocal else {
                    print("✗ \(resolved.label) n’est pas un modèle local : essai refusé.")
                    status = 1
                    finished = true
                    return
                }
                print("Modèle : \(resolved.label)\n")
                // « --dictation » : le nettoyage d'une dictée, avec ses consignes et son contrôle de fidélité.
                let dictation = arguments.contains("--dictation")
                let request = dictation
                    ? AIRequest(model: resolved.model, messages: [AIMessage(role: .user, content: DictationCleanup.aiUserMessage(question))],
                                system: DictationCleanup.aiSystemPrompt(language: "fr-FR", style: .standard, instructions: "", vocabulary: []), temperature: 0.4)
                    : AIRequest(model: resolved.model, messages: [AIMessage(role: .user, content: question)], system: AISettings.shared.systemPrompt(), temperature: 0.4)
                var answer = ""
                let started = Date()
                var first: TimeInterval?
                var count = 0
                for try await chunk in AIRouter.stream(resolved, request: request) {
                    if first == nil { first = Date().timeIntervalSince(started) }
                    count += 1
                    answer += chunk
                    FileHandle.standardOutput.write(Data(chunk.utf8))
                }
                if dictation {
                    let faithful = DictationCleanup.isFaithful(raw: question, cleaned: DictationCleanup.stripTranscriptTags(answer))
                    print(faithful ? "\n✓ fidèle à la dictée : texte de l’IA gardé" : "\n✗ pas fidèle à la dictée : nettoyage par règles gardé")
                }
                print(String(format: "\n\n✓ %d morceaux, premier après %.2f s, total %.2f s", count, first ?? 0, Date().timeIntervalSince(started)))
            } catch {
                print("✗ \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                status = 1
            }
            finished = true
        }
        let deadline = Date().addingTimeInterval(180)
        while !finished, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return finished ? status : 1
    }

    // MARK: - Autotests

    static func selfTest(_ check: (Bool, String) -> Void) {
        AIUsage.selfTest(check)
        // Skills, projets, agents.
        let header = AISkills.frontmatter("---\nname: relecture-swift\ndescription: \"Relit du code Swift\"\n---\nCorps du skill")
        check(header?["name"] == "relecture-swift" && header?["description"] == "Relit du code Swift", "skills : en-tête YAML lu")
        check(AISkills.stripFrontmatter("---\nname: a\n---\nCorps") == "Corps", "skills : corps sans en-tête")
        check(AISkills.isValidName("relecture-swift") && !AISkills.isValidName("Relecture") && !AISkills.isValidName("a--b") && !AISkills.isValidName("-a"), "skills : noms valides")
        let skillRoot = FileManager.default.temporaryDirectory.appendingPathComponent("prism-skills-\(UUID().uuidString)")
        let skillFolder = skillRoot.appendingPathComponent("relecture-swift")
        try? FileManager.default.createDirectory(at: skillFolder, withIntermediateDirectories: true)
        try? "---\nname: relecture-swift\ndescription: Relit du code Swift\n---\nRègles".write(to: skillFolder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let mismatched = skillRoot.appendingPathComponent("autre-nom")
        try? FileManager.default.createDirectory(at: mismatched, withIntermediateDirectories: true)
        try? "---\nname: pas-pareil\ndescription: x\n---\n".write(to: mismatched.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let scanned = AISkills.scan(folders: [skillRoot.path])
        check(scanned.map(\.name) == ["relecture-swift"] && scanned.first?.body == "Règles", "skills : dossier lu, nom du dossier vérifié")
        try? FileManager.default.removeItem(at: skillRoot)
        check(AIPreset.deepResearch.isBuiltIn && AIPreset.deepResearch.tools?.contains("web_search") == true, "agents : « Recherche approfondie » intégré, avec la recherche web")

        // Appels d'outils : décodage des réponses de chaque fournisseur.
        let toolAnthropic = AIToolLoop.parseAnthropic(["content": [
            ["type": "text", "text": "Je regarde."],
            ["type": "tool_use", "id": "toolu_1", "name": "calendar_events", "input": ["days": 2]],
        ]])
        check(toolAnthropic.0 == "Je regarde." && toolAnthropic.1.first?.name == "calendar_events" && toolAnthropic.1.first?.arguments["days"] as? Int == 2, "outils : réponse Anthropic décodée")
        let toolOpenAI = AIToolLoop.parseOpenAI(["choices": [["message": ["content": NSNull(), "tool_calls": [
            ["id": "call_1", "type": "function", "function": ["name": "web_search", "arguments": "{\"query\":\"météo\"}"]],
        ]]]]])
        check(toolOpenAI.1.first?.id == "call_1" && toolOpenAI.1.first?.arguments["query"] as? String == "météo", "outils : réponse OpenAI décodée")
        let toolOllama = AIToolLoop.parseOllama(["message": ["content": "", "tool_calls": [["function": ["name": "calculate", "arguments": ["expression": "2+2"]]]]]])
        check(toolOllama.1.first?.name == "calculate", "outils : réponse Ollama décodée")
        let anthropicResults = AIToolLoop.resultMessages([(AIToolLoop.Call(id: "toolu_1", name: "x", arguments: [:]), "ok")], kind: .anthropic)
        check(((anthropicResults.first?["content"] as? [[String: Any]])?.first?["tool_use_id"] as? String) == "toolu_1", "outils : résultat renvoyé à Anthropic")
        check(MCPHub.qualifiedName(server: "Mon serveur", tool: "read.file") == "Mon_serveur__read_file", "MCP : nom d’outil valide")
        check(AITools.builtIn.count >= 15 && Set(AITools.builtIn.map(\.name)).count == AITools.builtIn.count, "outils : noms uniques")
        check(WebTools.plainText(fromHTML: "<html><script>x()</script><p>Bonjour&nbsp;<b>monde</b></p></html>") == "Bonjour monde", "page web : texte sans balises")
        let ddg = WebTools.parseDuckDuckGo(##"<a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fswift.org%2F&amp;rut=x">Swift</a> <a class="result__snippet" href="#">Le langage</a>"##)
        check(ddg.first?.url == "https://swift.org/" && ddg.first?.title == "Swift", "recherche web : résultat DuckDuckGo lu")
        check(AITools.date("2026-10-15T14:00") != nil && AITools.date("2026-10-15") != nil, "outils : dates ISO lues")
        // Automatisations
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .current
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 10))!
        let daily = AIAutomation(name: "a", prompt: "p", schedule: .daily, hour: 9, minute: 0)
        check(daily.nextRun(after: monday, calendar: calendar) == calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 9)), "automatisation quotidienne : lendemain 9 h")
        let friday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 10))!
        let weekdays = AIAutomation(name: "a", prompt: "p", schedule: .weekdays, hour: 9, minute: 0)
        check(weekdays.nextRun(after: friday, calendar: calendar) == calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 9)), "automatisation en semaine : saute le week-end")
        let interval = AIAutomation(name: "a", prompt: "p", schedule: .interval, intervalMinutes: 30, lastRun: monday)
        check(interval.isDue(now: monday.addingTimeInterval(31 * 60), created: monday) && !interval.isDue(now: monday.addingTimeInterval(10 * 60), created: monday), "automatisation par intervalle")

        // Flux SSE d'OpenAI.
        let openAI = [
            #"data: {"id":"1","choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}"#,
            #"data: {"id":"1","choices":[{"index":0,"delta":{"content":"Bon"}}]}"#,
            "",
            #"data: {"id":"1","choices":[{"index":0,"delta":{"content":"jour !"}}]}"#,
            #"data: {"id":"1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            "data: [DONE]",
        ].flatMap(AIStreamDecoder.openAI)
        check(openAI == [.text("Bon"), .text("jour !"), .done], "flux SSE d’OpenAI : morceaux puis [DONE]")
        check(AIStreamDecoder.openAI(#"data: {"error":{"message":"quota dépassé"}}"#) == [.error("quota dépassé")], "erreur dans le flux d’OpenAI")

        // Flux SSE d'Anthropic.
        let anthropic = [
            "event: message_start",
            #"data: {"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[]}}"#,
            "event: content_block_start",
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Je réfléchis"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Salut"}}"#,
            "event: ping",
            #"data: {"type":"ping"}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" à toi"}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#,
            #"data: {"type":"message_stop"}"#,
        ].flatMap(AIStreamDecoder.anthropic)
        check(anthropic == [.text("Salut"), .text(" à toi"), .done], "flux SSE d’Anthropic : texte seul, réflexion ignorée")
        check(AIStreamDecoder.anthropic(#"data: {"type":"error","error":{"type":"invalid_request_error","message":"modèle inconnu"}}"#) == [.error("modèle inconnu")], "erreur dans le flux d’Anthropic")
        check(AIStreamDecoder.anthropic(#"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#).first.map { if case .error = $0 { true } else { false } } == true, "refus d’Anthropic signalé")

        // NDJSON d'Ollama.
        let ollama = [
            #"{"model":"llama3.2","message":{"role":"assistant","content":"Un"},"done":false}"#,
            #"{"model":"llama3.2","message":{"role":"assistant","content":" deux"},"done":false}"#,
            #"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,"total_duration":1}"#,
        ].flatMap(AIStreamDecoder.ollama)
        check(ollama == [.text("Un"), .text(" deux"), .done], "flux NDJSON d’Ollama")
        check(AIStreamDecoder.ollama(#"{"error":"model 'x' not found"}"#) == [.error("model 'x' not found")], "erreur d’Ollama")

        // Construction des requêtes.
        let request = AIRequest(model: "", messages: [
            AIMessage(role: .user, content: "Bonjour"),
            AIMessage(role: .assistant, content: ""),
            AIMessage(role: .assistant, content: "Salut"),
            AIMessage(role: .user, content: "Ça va ?"),
        ], system: "Sois bref.", temperature: 0.7)
        func body(_ urlRequest: URLRequest?) -> [String: Any] {
            guard let data = urlRequest?.httpBody else { return [:] }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        var openAIRequest = request
        openAIRequest.model = "gpt-4.1"
        let openAIURL = try? AIRequestBuilder.openAI(openAIRequest, baseURL: "https://api.openai.com/v1/", key: "sk-test")
        let openAIBody = body(openAIURL)
        let openAIMessages = openAIBody["messages"] as? [[String: String]] ?? []
        check(openAIURL?.url?.absoluteString == "https://api.openai.com/v1/chat/completions", "OpenAI : adresse /chat/completions")
        check(openAIURL?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test", "OpenAI : clé en Bearer")
        check(openAIMessages.first?["role"] == "system" && openAIMessages.count == 4, "OpenAI : système en tête, message vide retiré")
        check(openAIBody["stream"] as? Bool == true && openAIBody["temperature"] as? Double == 0.7, "OpenAI : flux et température")
        openAIRequest.model = "gpt-5-mini"
        check(body(try? AIRequestBuilder.openAI(openAIRequest, baseURL: OpenAIProvider.defaultBaseURL, key: nil))["temperature"] == nil, "OpenAI : pas de température pour GPT-5")

        var anthropicRequest = request
        anthropicRequest.model = "claude-opus-5-5"
        let anthropicURL = try? AIRequestBuilder.anthropic(anthropicRequest, key: "sk-ant-test")
        let anthropicBody = body(anthropicURL)
        check(anthropicURL?.url?.absoluteString == "https://api.anthropic.com/v1/messages", "Anthropic : adresse /v1/messages")
        check(anthropicURL?.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test" && anthropicURL?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "Anthropic : en-têtes x-api-key et anthropic-version")
        check(anthropicBody["system"] as? String == "Sois bref." && (anthropicBody["messages"] as? [[String: String]])?.count == 3, "Anthropic : système à part, messages vides retirés")
        check(anthropicBody["temperature"] == nil && anthropicBody["max_tokens"] as? Int == 64_000, "Anthropic : pas de température sur Opus 5.5, 64 000 jetons")
        anthropicRequest.model = "claude-3-5-haiku-latest"
        let older = body(try? AIRequestBuilder.anthropic(anthropicRequest, key: "k"))
        check(older["temperature"] as? Double == 0.7 && older["max_tokens"] as? Int == 8_192, "Anthropic : température et plafond des anciens modèles")

        var ollamaRequest = request
        ollamaRequest.model = "llama3.2"
        let ollamaURL = try? AIRequestBuilder.ollama(ollamaRequest, baseURL: "http://localhost:11434")
        let ollamaBody = body(ollamaURL)
        check(ollamaURL?.url?.absoluteString == "http://localhost:11434/api/chat", "Ollama : adresse /api/chat")
        check((ollamaBody["options"] as? [String: Any])?["temperature"] as? Double == 0.7 && ollamaBody["stream"] as? Bool == true, "Ollama : flux et température dans options")

        // Choix des modèles.
        check(AIModelChoice(rawValue: "ollama:llama3.2:latest") == .model(.ollama, "llama3.2:latest"), "choix d’un modèle Ollama avec « : »")
        check(AIModelChoice(rawValue: "auto") == .auto && AIModelChoice(rawValue: "inconnu:x") == .auto, "choix « Auto » et repli")
        check(AIModelChoice(rawValue: AIModelChoice.model(.anthropic, "claude-sonnet-5-5").rawValue).label == "Claude Sonnet 5.5", "nom lisible d’un modèle Claude")
        check(AIModelNames.display("gpt-5-mini") == "GPT-5 mini" && AIModelNames.display("llama3.2:latest") == "llama3.2", "noms lisibles d’OpenAI et d’Ollama")
        check(!AppleIntelligence.prompt(for: request.messages).isEmpty && AppleIntelligence.prompt(for: request.messages).hasSuffix("Ça va ?"), "Apple Intelligence : historique replié dans la demande")

        // Commandes d'IA.
        let builtIns = AIBuiltInCommands.all
        check(builtIns.count == 10 && Set(builtIns.map(\.id)).count == 10, "10 commandes intégrées, identifiants uniques")
        if let improve = builtIns.first(where: { $0.id == "improve-writing" }) {
            let prompt = AICommandRunner.expand(improve, selection: "un texte mal écrit", arguments: [])
            check(prompt.contains("\"\"\"\nun texte mal écrit\n\"\"\"") && !prompt.contains("{selection}"), "prompt : sélection remplacée et entourée de \"\"\"")
            check(improve.needsSelection, "« Améliorer l’écriture » lit la sélection")
        }
        if let ask = builtIns.first(where: { $0.id == "ask-page" }) {
            check(Placeholders.arguments(in: ask.prompt).map(\.name) == ["question"], "« Poser une question sur la page web » demande la question")
            check(ask.usesBrowserTab && !ask.needsSelection, "la question sur la page lit l’onglet, pas la sélection")
            check(AICommandRunner.displayText(for: ask, arguments: ["Quel prix ?"]) == "Poser une question sur la page web : Quel prix ?", "intitulé affiché avec l’argument")
        }
        let custom = AICommandDefinition(id: "x", name: "Essai", symbol: "sparkles", color: "violet", prompt: "Le {date format=\"yyyy\"} : {argument name=\"sujet\"}", output: .copy)
        let expanded = AICommandRunner.expand(custom, selection: nil, arguments: ["les impôts"])
        check(expanded.contains("les impôts") && expanded.contains(String(Calendar.current.component(.year, from: Date()))), "prompt personnalisé : date et argument")
        let exported = (try? JSONEncoder.prism.encode([custom])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(AICommandStore.decode(exported)?.first == custom, "export puis import JSON d’une commande")

        // Titres, sections, historique.
        check(AITitle.make(from: "  comment **écrire** un script `bash` ?\nautre ligne") == "Comment écrire un script bash", "titre tiré de la question")
        check(AITitle.make(from: String(repeating: "mot ", count: 30)).hasSuffix("…") && AITitle.make(from: String(repeating: "mot ", count: 30)).count <= 49, "titre coupé sur un mot")
        check(AITitle.make(from: "") == "Nouvelle conversation", "titre par défaut")
        check(AITitle.clean(generated: "Titre : « Recette des crêpes ».") == "Recette des crêpes", "titre proposé nettoyé")
        let now = Date()
        check(AIDateSections.title(for: now, now: now) == "Aujourd’hui" && AIDateSections.title(for: now.addingTimeInterval(-86_400), now: now) == "Hier", "sections : aujourd’hui, hier")
        check(AIDateSections.title(for: now.addingTimeInterval(-4 * 86_400), now: now) == "7 derniers jours" && AIDateSections.title(for: now.addingTimeInterval(-20 * 86_400), now: now) == "30 derniers jours", "sections : 7 et 30 jours")
        var pinned = AIConversation(title: "Épinglée")
        pinned.pinned = true
        check(AIDateSections.group([AIConversation(title: "A"), pinned], now: now).first?.title == "Épinglées", "les épinglées en tête")
        var old = AIConversation(title: "Ancienne")
        old.deletedAt = now.addingTimeInterval(-61 * 86_400)
        var recent = AIConversation(title: "Récente")
        recent.deletedAt = now.addingTimeInterval(-3 * 86_400)
        check(AIHistory.purged([old, recent, AIConversation()], now: now).count == 2, "corbeille : effacée après 60 jours")
        let markdown = AIExport.markdown(AIConversation(title: "Essai", messages: [AIChatMessage(role: .user, content: "Question"), AIChatMessage(role: .assistant, content: "Réponse", model: "Apple Intelligence")]))
        check(markdown.hasPrefix("# Essai") && markdown.contains("## Vous") && markdown.contains("## IA (Apple Intelligence)"), "export Markdown")
        var withAttachment = AIChatMessage(role: .user, content: "Résume")
        withAttachment.attachments = [AIAttachment(kind: .selection, title: "Texte sélectionné", content: "abc")]
        check(withAttachment.forModel.content.hasPrefix("Texte sélectionné :\n\"\"\"\nabc") && withAttachment.forModel.content.hasSuffix("Résume"), "pièce jointe envoyée avant la question")
        check(!AIQuickReset.shouldStartNew(lastActivity: now.addingTimeInterval(-60), now: now, delay: 300), "Quick AI : conversation reprise avant le délai")
        check(AIQuickReset.shouldStartNew(lastActivity: now.addingTimeInterval(-600), now: now, delay: 300), "Quick AI : nouvelle conversation après le délai")
        check(!AIQuickReset.shouldStartNew(lastActivity: now.addingTimeInterval(-99_999), now: now, delay: 0), "Quick AI : « Jamais » garde la conversation")
        check(AIError.http(status: 401, message: "").errorDescription?.contains("Clé d’API refusée") == true, "message clair pour une clé refusée")
        check(AIError.message(fromBody: Data(#"{"error":{"type":"x","message":"Trop de requêtes"}}"#.utf8)) == "Trop de requêtes", "message d’erreur lu dans le corps")
        check(AIKeychain.read(.anthropic) == nil, "trousseau jamais lu pendant les essais")
    }
}
