import AppKit

/// Serveurs MCP (Model Context Protocol) : leurs outils s'ajoutent à ceux de Prism pour l'IA.
/// Configuration au format de Claude Desktop, dans `~/Library/Application Support/Prism/mcp.json` :
/// `{"mcpServers": {"nom": {"command": "npx", "args": ["-y", "…"], "env": {"CLE": "…"}}}}`.
struct MCPServerConfig: Codable, Equatable {
    var command: String
    var args: [String]?
    var env: [String: String]?
    var disabled: Bool?
}

struct MCPConfigFile: Codable, Equatable {
    var mcpServers: [String: MCPServerConfig] = [:]
}

/// Un serveur MCP lancé en sous-processus, qui parle JSON-RPC 2.0 ligne par ligne sur stdin et stdout.
final class MCPConnection: @unchecked Sendable {
    let name: String
    private let config: MCPServerConfig
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private(set) var isRunning = false
    private(set) var lastError: String?

    init(name: String, config: MCPServerConfig) {
        self.name = name
        self.config = config
    }

    /// Lance le serveur et fait la poignée de main MCP.
    func start() async throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [config.command] + (config.args ?? [])
        var environment = ProcessInfo.processInfo.environment
        // Les commandes habituelles (npx, uvx, node, python) vivent souvent dans Homebrew.
        let path = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:\(NSHomeDirectory())/.cargo/bin:" + path
        for (key, value) in config.env ?? [:] { environment[key] = value }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.receive(data)
        }
        process.terminationHandler = { [weak self] _ in self?.failAll("Le serveur MCP « \(self?.name ?? "") » s’est arrêté.") }
        try process.run()
        isRunning = true
        _ = try await request("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Prism", "version": "2.0"],
        ], timeout: 30)
        notify("notifications/initialized")
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        isRunning = false
    }

    /// Les outils du serveur : nom, description, schéma des paramètres.
    func listTools() async throws -> [[String: Any]] {
        let result = try await request("tools/list", params: [:], timeout: 20)
        return result["tools"] as? [[String: Any]] ?? []
    }

    func callTool(_ name: String, arguments: [String: Any]) async -> String {
        do {
            let result = try await request("tools/call", params: ["name": name, "arguments": arguments], timeout: 120)
            let content = result["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { block -> String? in
                switch block["type"] as? String {
                case "text": return block["text"] as? String
                case "resource": return ((block["resource"] as? [String: Any])?["text"] as? String)
                case "image": return "[image]"
                default: return nil
                }
            }.joined(separator: "\n")
            let isError = result["isError"] as? Bool ?? false
            return (isError ? "Erreur de l’outil : " : "") + (text.isEmpty ? "(aucun contenu)" : text)
        } catch {
            return "Échec de l’outil MCP : \(error.localizedDescription)"
        }
    }

    // MARK: - JSON-RPC

    private func request(_ method: String, params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let id: Int = lock.withLock {
            defer { nextID += 1 }
            return nextID
        }
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waiting[id] = continuation }
            send(message)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                let pending = self.lock.withLock { self.waiting.removeValue(forKey: id) }
                pending?.resume(throwing: AIError.provider("Le serveur MCP « \(self.name) » n’a pas répondu à \(method)."))
            }
        }
    }

    private func notify(_ method: String) {
        send(["jsonrpc": "2.0", "method": method])
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        input.fileHandleForWriting.write(data)
    }

    private func receive(_ data: Data) {
        var lines: [Data] = []
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        for line in lines where !line.isEmpty {
            guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = json["id"] as? Int else { continue }
            let continuation = lock.withLock { waiting.removeValue(forKey: id) }
            if let error = json["error"] as? [String: Any] {
                continuation?.resume(throwing: AIError.provider(error["message"] as? String ?? "Erreur MCP"))
            } else {
                continuation?.resume(returning: json["result"] as? [String: Any] ?? [:])
            }
        }
    }

    private func failAll(_ message: String) {
        isRunning = false
        lastError = message
        let pending = lock.withLock { () -> [CheckedContinuation<[String: Any], Error>] in
            defer { waiting.removeAll() }
            return Array(waiting.values)
        }
        pending.forEach { $0.resume(throwing: AIError.provider(message)) }
    }
}

/// Les serveurs MCP configurés : lancés à la première demande d'outils, puis gardés.
@MainActor
final class MCPHub: ObservableObject {
    static let shared = MCPHub()

    struct ServerState: Identifiable {
        var id: String { name }
        var name: String
        var status: String
        var toolCount: Int
    }

    @Published private(set) var states: [ServerState] = []
    private var connections: [String: MCPConnection] = [:]
    private var toolCache: [String: [AIToolSpec]] = [:]
    private var loadedConfig: MCPConfigFile?

    static var configURL: URL { StoreLocation.file("mcp.json") }

    static func readConfig() -> MCPConfigFile {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(MCPConfigFile.self, from: data) else { return MCPConfigFile() }
        return config
    }

    /// Le texte du fichier de configuration (créé vide s'il n'existe pas).
    static func configText() -> String {
        if let data = try? Data(contentsOf: configURL), let text = String(data: data, encoding: .utf8) { return text }
        return "{\n  \"mcpServers\": {\n  }\n}\n"
    }

    /// Enregistre la configuration si elle est valide, et relance les serveurs.
    func save(configText: String) -> String? {
        guard let data = configText.data(using: .utf8),
              (try? JSONDecoder().decode(MCPConfigFile.self, from: data)) != nil else {
            return "JSON invalide : il faut un objet « mcpServers »."
        }
        do {
            try data.write(to: Self.configURL, options: .atomic)
        } catch {
            return error.localizedDescription
        }
        restart()
        return nil
    }

    /// Reprend les serveurs de Claude Desktop (sur demande de l'utilisateur).
    func importClaudeDesktop() -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        guard let data = try? Data(contentsOf: url), let imported = try? JSONDecoder().decode(MCPConfigFile.self, from: data) else {
            return "Configuration de Claude Desktop introuvable ou illisible."
        }
        var config = Self.readConfig()
        let added = imported.mcpServers.filter { config.mcpServers[$0.key] == nil }
        config.mcpServers.merge(added) { current, _ in current }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let encoded = try? encoder.encode(config) else { return "Écriture impossible." }
        try? encoded.write(to: Self.configURL, options: .atomic)
        restart()
        return added.isEmpty ? "Aucun nouveau serveur." : "\(added.count) serveur(s) importé(s)."
    }

    func restart() {
        connections.values.forEach { $0.stop() }
        connections = [:]
        toolCache = [:]
        loadedConfig = nil
        states = []
    }

    /// Les outils de tous les serveurs actifs. Un serveur en panne est ignoré (et signalé dans les réglages).
    func tools() async -> [AIToolSpec] {
        let config = Self.readConfig()
        if loadedConfig != config { restart(); loadedConfig = config }
        var result: [AIToolSpec] = []
        for (name, server) in config.mcpServers.sorted(by: { $0.key < $1.key }) where server.disabled != true {
            if let cached = toolCache[name] {
                result += cached
                continue
            }
            let connection = MCPConnection(name: name, config: server)
            do {
                try await connection.start()
                let tools = try await connection.listTools()
                connections[name] = connection
                let specs = tools.compactMap { tool -> AIToolSpec? in
                    guard let toolName = tool["name"] as? String else { return nil }
                    return AIToolSpec(
                        name: Self.qualifiedName(server: name, tool: toolName),
                        description: (tool["description"] as? String ?? toolName) + " (serveur MCP « \(name) »)",
                        schema: tool["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [String: Any]()],
                        isAction: true,
                        source: name
                    ) { arguments in
                        await connection.callTool(toolName, arguments: arguments)
                    }
                }
                toolCache[name] = specs
                result += specs
                setState(name, status: "Connecté", tools: specs.count)
            } catch {
                connection.stop()
                setState(name, status: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, tools: 0)
            }
        }
        return result
    }

    /// Les noms d'outils doivent tenir dans `^[a-zA-Z0-9_-]{1,64}$`.
    nonisolated static func qualifiedName(server: String, tool: String) -> String {
        let raw = "\(server)__\(tool)"
        let cleaned = String(raw.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" })
        return String(cleaned.prefix(64))
    }

    private func setState(_ name: String, status: String, tools: Int) {
        states.removeAll { $0.name == name }
        states.append(ServerState(name: name, status: status, toolCount: tools))
        states.sort { $0.name < $1.name }
    }

    /// Démarre tous les serveurs maintenant, pour vérifier la configuration.
    func test() async {
        restart()
        _ = await tools()
    }
}
