import AppKit
import SwiftUI

/// Fournisseurs personnalisés compatibles avec l'API d'OpenAI (LM Studio, OpenRouter, LiteLLM, Mistral, passerelles…),
/// avec les champs du `providers.yaml` de Raycast, en JSON : `~/Library/Application Support/Prism/providers.json`.
/// Leurs modèles s'appellent « openai:custom:<fournisseur>/<modèle> » dans Prism.
struct AICustomProviderFile: Codable, Equatable {
    struct Ability: Codable, Equatable {
        var supported: Bool
    }

    struct Abilities: Codable, Equatable {
        var temperature: Ability?
        var vision: Ability?
        var system_message: Ability?
        var tools: Ability?
        var reasoning_effort: Ability?
    }

    struct Model: Codable, Equatable {
        var id: String
        var name: String
        /// Alias de clé dans `api_keys` ; la première par défaut.
        var provider: String?
        var description: String?
        var context: Int?
        var abilities: Abilities?
    }

    struct Provider: Codable, Equatable {
        var id: String
        var name: String
        var base_url: String
        var api_keys: [String: String]?
        var models: [Model]
    }

    var providers: [Provider] = []
}

/// Lisible depuis n'importe quel fil (les libellés de modèles le sont parfois hors du fil principal).
enum AICustomProviders {
    static var url: URL {
        // Pour les essais : un autre fichier que celui de l'utilisateur.
        if let override = ProcessInfo.processInfo.environment["PRISM_PROVIDERS_FILE"] { return URL(fileURLWithPath: override) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Prism/providers.json")
    }

    static let template = """
    {
      "providers": [
        {
          "id": "lmstudio",
          "name": "LM Studio",
          "base_url": "http://localhost:1234/v1",
          "models": [
            { "id": "qwen2.5-7b-instruct", "name": "Qwen 2.5 7B", "abilities": { "tools": { "supported": true } } }
          ]
        }
      ]
    }
    """

    nonisolated(unsafe) private static var cache: (date: Date, file: AICustomProviderFile)?
    private static let lock = NSLock()

    /// Le fichier, relu s'il a changé.
    static var file: AICustomProviderFile {
        lock.lock()
        defer { lock.unlock() }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let cache, cache.date == modified { return cache.file }
        let decoded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(AICustomProviderFile.self, from: $0) } ?? AICustomProviderFile()
        cache = (modified, decoded)
        return decoded
    }

    /// L'erreur de lecture du fichier, pour les réglages.
    static var error: String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            _ = try JSONDecoder().decode(AICustomProviderFile.self, from: data)
            return nil
        } catch {
            return "providers.json invalide : \(error.localizedDescription)"
        }
    }

    struct Resolved {
        var baseURL: String
        var key: String?
        var modelID: String
        var name: String
        var supportsTools: Bool
        var supportsTemperature: Bool
        var supportsSystem: Bool
    }

    static func identifier(provider: String, model: String) -> String { "custom:\(provider)/\(model)" }

    static func resolve(_ identifier: String) -> Resolved? {
        guard identifier.hasPrefix("custom:") else { return nil }
        let rest = identifier.dropFirst("custom:".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let providerID = String(rest[..<slash])
        let modelID = String(rest[rest.index(after: slash)...])
        guard let provider = file.providers.first(where: { $0.id == providerID }),
              let model = provider.models.first(where: { $0.id == modelID }) else { return nil }
        let keys = provider.api_keys ?? [:]
        let key = model.provider.flatMap { keys[$0] } ?? keys.sorted { $0.key < $1.key }.first?.value
        return Resolved(
            baseURL: provider.base_url, key: key, modelID: model.id, name: model.name,
            supportsTools: model.abilities?.tools?.supported ?? false,
            supportsTemperature: model.abilities?.temperature?.supported ?? true,
            supportsSystem: model.abilities?.system_message?.supported ?? true
        )
    }

    /// Les modèles proposés dans les sélecteurs.
    static var choices: [AIModelChoice] {
        file.providers.flatMap { provider in provider.models.map { AIModelChoice.model(.openAI, identifier(provider: provider.id, model: $0.id)) } }
    }

    /// « Qwen 2.5 7B (LM Studio) ».
    static func label(_ identifier: String) -> String? {
        guard identifier.hasPrefix("custom:") else { return nil }
        let rest = identifier.dropFirst("custom:".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let providerID = String(rest[..<slash])
        let modelID = String(rest[rest.index(after: slash)...])
        guard let provider = file.providers.first(where: { $0.id == providerID }) else { return modelID }
        let name = provider.models.first { $0.id == modelID }?.name ?? modelID
        return "\(name) (\(provider.name))"
    }
}

/// La section des réglages : éditer `providers.json`.
struct AICustomProvidersSection: View {
    @State private var text = (try? String(contentsOf: AICustomProviders.url, encoding: .utf8)) ?? AICustomProviders.template
    @State private var message: String?

    var body: some View {
        Section {
            TextEditor(text: $text)
                .font(.system(size: 11.5, design: .monospaced))
                .frame(height: 150)
            HStack {
                Button("Enregistrer") {
                    guard let data = text.data(using: .utf8) else { return }
                    do {
                        let decoded = try JSONDecoder().decode(AICustomProviderFile.self, from: data)
                        try data.write(to: AICustomProviders.url, options: .atomic)
                        AIModelCatalog.shared.objectWillChange.send()
                        message = "\(decoded.providers.count) fournisseur(s), \(decoded.providers.reduce(0) { $0 + $1.models.count }) modèle(s)."
                    } catch {
                        message = "JSON invalide : \(error.localizedDescription)"
                    }
                }
                Button("Afficher le fichier") { NSWorkspace.shared.activateFileViewerSelecting([AICustomProviders.url]) }
                Spacer()
                if let message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        } header: {
            Text("Fournisseurs personnalisés")
        } footer: {
            Text("Tout service compatible avec l’API d’OpenAI. Champs du providers.yaml de Raycast : id, name, base_url (sans /chat/completions), api_keys, models (id, name, provider, abilities.tools.supported…). Les modèles apparaissent dans les sélecteurs ; les requêtes partent directement de ce Mac.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
