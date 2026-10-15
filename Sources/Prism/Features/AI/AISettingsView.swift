import AppKit
import SwiftUI

/// Le pane « IA » des réglages : fournisseurs, modèles par défaut, Quick AI, instructions personnelles,
/// préréglages, historique.
struct AISettingsView: View {
    @ObservedObject private var settings = AISettings.shared
    @ObservedObject private var catalog = AIModelCatalog.shared
    @ObservedObject private var history = AIHistory.shared
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                AppleProviderRow()
                OllamaProviderRow()
                KeyedProviderRow(kind: .openAI)
                KeyedProviderRow(kind: .anthropic)
            } header: {
                Text("Fournisseurs")
            } footer: {
                Text("Apple Intelligence et Ollama tournent sur ce Mac : rien ne quitte l’appareil. Les clés d’API sont gardées dans le trousseau.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Modèles par défaut") {
                modelPicker("Quick AI", selection: $settings.quickModel)
                modelPicker("AI Chat", selection: $settings.chatModel)
                modelPicker("Commandes d’IA", selection: $settings.commandsModel)
                Picker("Créativité", selection: Binding(
                    get: { AICreativity.allCases.min { abs($0.rawValue - settings.temperature) < abs($1.rawValue - settings.temperature) } ?? .medium },
                    set: { settings.temperature = $0.rawValue }
                )) {
                    ForEach(AICreativity.allCases) { Text($0.title).tag($0) }
                }
                Text("« Auto » choisit le meilleur modèle disponible : Anthropic ou OpenAI si une clé est enregistrée, sinon Apple Intelligence, sinon Ollama. Certains modèles récents ignorent la créativité.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Quick AI") {
                Picker("↵ sur une réponse", selection: $settings.quickEnterAction) {
                    Text("Coller dans l’application").tag("paste")
                    Text("Copier dans le presse-papiers").tag("copy")
                }
                Picker("Nouvelle conversation après", selection: $settings.quickResetAfter) {
                    Text("5 minutes d’inactivité").tag(300.0)
                    Text("15 minutes").tag(900.0)
                    Text("30 minutes").tag(1_800.0)
                    Text("1 heure").tag(3_600.0)
                    Text("Jamais").tag(0.0)
                }
                Toggle("Masquer l’astuce « Tab pour demander à l’IA »", isOn: $settings.hideTabHint)
            }

            Section {
                TextEditor(text: $settings.aboutMe)
                    .font(.system(size: 12.5))
                    .frame(minHeight: 70)
                    .scrollContentBackground(.hidden)
            } header: {
                Text("À propos de moi")
            } footer: {
                Text("Ajouté à toutes les conversations : votre métier, vos outils, la façon dont vous aimez les réponses (par exemple : « Développeur Swift, réponses courtes, exemples en Swift »).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("AI Chat") {
                Toggle("Notifier quand une réponse arrive dans une autre app", isOn: $settings.chatNotifications)
                Toggle("Empêcher la veille pendant une réponse", isOn: $settings.preventSleep)
                Toggle("Échap ferme la fenêtre", isOn: $settings.escapeClosesChat)
                Picker("Archiver les conversations inactives", selection: $settings.autoArchiveDays) {
                    Text("Jamais").tag(0)
                    Text("Après 7 jours").tag(7)
                    Text("Après 30 jours").tag(30)
                    Text("Après 90 jours").tag(90)
                }
            }

            AICustomProvidersSection()

            AIExtensionsSettingsSections()

            PresetsSection()

            Section("Historique") {
                LabeledContent("Conversations") {
                    Text("\(history.active.count) gardée\(history.active.count > 1 ? "s" : ""), \(history.trash.count) dans la corbeille")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Ouvrir AI Chat") { AIChatWindow.shared.open() }
                    Spacer()
                    Button("Vider la corbeille") { history.emptyTrash() }
                        .disabled(history.trash.isEmpty)
                    Button("Effacer l’historique…", role: .destructive) { confirmClear = true }
                        .disabled(history.active.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { catalog.refresh(force: true) }
        .confirmationDialog("Effacer tout l’historique de l’IA ?", isPresented: $confirmClear) {
            Button("Effacer l’historique", role: .destructive) { history.clearAll() }
        } message: {
            Text("Les conversations vont dans « Récemment supprimées » pendant 60 jours.")
        }
    }

    private func modelPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(choices(including: selection.wrappedValue), id: \.rawValue) { choice in
                Text(label(choice)).tag(choice.rawValue)
            }
        }
    }

    private func choices(including raw: String) -> [AIModelChoice] {
        var options = catalog.options
        let current = AIModelChoice(rawValue: raw)
        if !options.contains(current) { options.append(current) }
        return options
    }

    private func label(_ choice: AIModelChoice) -> String {
        switch choice {
        case .auto: "Auto (le meilleur disponible)"
        case .model(.apple, _): "Apple Intelligence (sur l’appareil)"
        case .model(let kind, _): "\(choice.label) — \(kind.shortTitle)"
        }
    }
}

// MARK: - Fournisseurs

/// L'état d'un fournisseur : pastille et texte.
private struct ProviderStatus: View {
    let ok: Bool?
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ok == nil ? Palette.gray : ok == true ? Palette.green : Palette.orange)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Le bouton « Tester » : une courte demande, le résultat sous le bouton.
private struct ProviderTestButton: View {
    let choice: () -> AIModelChoice
    @State private var running = false
    @State private var result: (ok: Bool, text: String)?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                test()
            } label: {
                if running { ProgressView().controlSize(.small) } else { Text("Tester") }
            }
            .disabled(running || AIRuntime.isDemo)
            if let result {
                Text(result.text)
                    .font(.system(size: 11))
                    .foregroundStyle(result.ok ? Palette.green : Palette.orange)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
        }
    }

    private func test() {
        running = true
        result = nil
        let choice = choice()
        Task {
            let started = Date()
            do {
                let resolved = try await AIRouter.resolve(choice)
                let answer = try await AIRouter.complete([AIMessage(role: .user, content: "Réponds seulement « OK ».")], system: nil, resolved: resolved, temperature: 0)
                let seconds = Date().timeIntervalSince(started)
                result = (true, "\(resolved.label) répond (« \(answer.prefix(30)) », \(String(format: "%.1f", seconds)) s)")
            } catch {
                result = (false, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            running = false
        }
    }
}

private struct ProviderHeader: View {
    let kind: AIProviderKind

    var body: some View {
        HStack(spacing: 8) {
            ItemIconView(icon: .symbol(kind.symbol, kind.isLocal ? Palette.green : Palette.indigo), size: 18)
            Text(kind.title).font(.system(size: 13, weight: .medium))
        }
    }
}

private struct AppleProviderRow: View {
    var body: some View {
        let status = AppleIntelligence.status
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                ProviderHeader(kind: .apple)
                ProviderStatus(ok: status.isAvailable, text: status.isAvailable ? "Disponible, gratuit et privé : tout se passe sur ce Mac." : status.message)
                if !status.isAvailable {
                    Button("Ouvrir les réglages d’Apple Intelligence") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
                }
            }
            Spacer()
            ProviderTestButton { .apple }
        }
        .padding(.vertical, 3)
    }
}

private struct OllamaProviderRow: View {
    @ObservedObject private var settings = AISettings.shared
    @ObservedObject private var catalog = AIModelCatalog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    ProviderHeader(kind: .ollama)
                    ProviderStatus(ok: catalog.ollamaReachable, text: status)
                }
                Spacer()
                ProviderTestButton { .model(.ollama, settings.ollamaModel) }
            }
            TextField("Adresse", text: $settings.ollamaURL, prompt: Text("http://localhost:11434"))
                .onSubmit { catalog.refresh(force: true) }
            HStack {
                Picker("Modèle", selection: $settings.ollamaModel) {
                    Text("Le premier installé").tag("")
                    ForEach(catalog.ollamaModels, id: \.self) { Text(AIModelNames.display($0)).tag($0) }
                    if !settings.ollamaModel.isEmpty, !catalog.ollamaModels.contains(settings.ollamaModel) {
                        Text(settings.ollamaModel).tag(settings.ollamaModel)
                    }
                }
                Button {
                    catalog.refresh(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Actualiser la liste des modèles")
            }
        }
        .padding(.vertical, 3)
    }

    private var status: String {
        switch catalog.ollamaReachable {
        case .none: "Recherche d’Ollama…"
        case .some(false): "Ollama ne répond pas. Installez-le depuis ollama.com, puis lancez-le."
        case .some(true) where catalog.ollamaModels.isEmpty: "Ollama répond, mais aucun modèle n’est installé (ollama pull llama3.2)."
        case .some(true): "\(catalog.ollamaModels.count) modèle\(catalog.ollamaModels.count > 1 ? "s" : "") installé\(catalog.ollamaModels.count > 1 ? "s" : ""), sur ce Mac"
        }
    }
}

/// OpenAI (ou compatible) et Anthropic : clé masquée, adresse, modèle.
private struct KeyedProviderRow: View {
    let kind: AIProviderKind
    @ObservedObject private var settings = AISettings.shared
    @ObservedObject private var catalog = AIModelCatalog.shared
    @State private var keyInput = ""
    @State private var savedKey: String?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    ProviderHeader(kind: kind)
                    ProviderStatus(ok: savedKey == nil ? (keyOptional ? nil : false) : true, text: statusText)
                }
                Spacer()
                ProviderTestButton { .model(kind, "") }
            }
            HStack {
                SecureField("Clé d’API", text: $keyInput, prompt: Text(savedKey == nil ? (kind == .anthropic ? "sk-ant-…" : "sk-…") : "Nouvelle clé pour remplacer l’actuelle"))
                Button("Enregistrer") { save() }
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                if savedKey != nil {
                    Button("Supprimer", role: .destructive) {
                        AIKeychain.delete(kind)
                        savedKey = nil
                        message = "Clé supprimée"
                    }
                }
            }
            if let message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if kind == .openAI {
                TextField("Adresse de base", text: $settings.openAIBaseURL, prompt: Text(OpenAIProvider.defaultBaseURL))
                    .onSubmit { catalog.refresh(force: true) }
                HStack {
                    TextField("Modèle", text: $settings.openAIModel, prompt: Text("gpt-5-mini"))
                    if !catalog.openAIModels.isEmpty {
                        Menu("Choisir") {
                            ForEach(catalog.openAIModels, id: \.self) { model in
                                Button(model) { settings.openAIModel = model }
                            }
                        }
                        .fixedSize()
                    }
                }
                Text("Compatible avec tout service qui suit l’API d’OpenAI (LM Studio, OpenRouter, Mistral…) : changez l’adresse de base ; la clé est facultative pour un serveur local.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    TextField("Modèle", text: $settings.anthropicModel, prompt: Text("claude-opus-5-5"))
                    Menu("Choisir") {
                        ForEach(AIModelNames.anthropicDefaults, id: \.self) { model in
                            Button("\(AIModelNames.display(model)) (\(model))") { settings.anthropicModel = model }
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .padding(.vertical, 3)
        .onAppear { savedKey = AIKeychain.read(kind) }
    }

    private var keyOptional: Bool { kind == .openAI && !settings.openAIBaseURL.contains("api.openai.com") }

    private var statusText: String {
        if let savedKey { return "Clé enregistrée (\(AIKeychain.masked(savedKey))) · modèle \(AIModelNames.display(kind == .openAI ? settings.openAIModel : settings.anthropicModel))" }
        if keyOptional { return "Serveur compatible sans clé · modèle \(settings.openAIModel)" }
        return "Aucune clé : ajoutez-en une pour utiliser \(kind.shortTitle)."
    }

    private func save() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if AIKeychain.save(key, for: kind) {
            savedKey = key
            keyInput = ""
            message = "Clé enregistrée dans le trousseau"
            catalog.refresh(force: true)
        } else {
            message = "Impossible d’enregistrer la clé dans le trousseau"
        }
    }
}

// MARK: - Préréglages

private struct PresetsSection: View {
    @ObservedObject private var store = AIPresetStore.shared
    @ObservedObject private var catalog = AIModelCatalog.shared
    @State private var expanded: UUID?

    var body: some View {
        Section {
            ForEach($store.presets) { $preset in
                DisclosureGroup(isExpanded: Binding(get: { expanded == preset.id }, set: { expanded = $0 ? preset.id : nil })) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Nom", text: $preset.name)
                        Picker("Icône", selection: $preset.symbol) {
                            ForEach(AICommandSymbols.all + [("person.crop.circle", "Personne")], id: \.symbol) { item in
                                Label(item.title, systemImage: item.symbol).tag(item.symbol)
                            }
                        }
                        Picker("Modèle", selection: Binding(get: { preset.model ?? "" }, set: { preset.model = $0.isEmpty ? nil : $0 })) {
                            Text("Modèle par défaut d’AI Chat").tag("")
                            ForEach(catalog.options, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                        }
                        Text("Instructions").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        TextEditor(text: $preset.instructions)
                            .font(.system(size: 12.5))
                            .frame(minHeight: 70)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                        HStack {
                            Spacer()
                            Button("Supprimer le préréglage", role: .destructive) {
                                store.presets.removeAll { $0.id == preset.id }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: preset.symbol).frame(width: 18).foregroundStyle(.secondary)
                        Text(preset.name.isEmpty ? "Sans nom" : preset.name)
                        Spacer()
                        Text(preset.model.map { AIModelChoice(rawValue: $0).label } ?? "Modèle par défaut")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Button {
                let preset = AIPreset(name: "Nouveau préréglage", instructions: "")
                store.presets.append(preset)
                expanded = preset.id
            } label: {
                Label("Ajouter un préréglage", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Préréglages d’AI Chat")
        } footer: {
            Text("Un préréglage donne à une conversation des instructions et un modèle ; choisissez-le en haut de la fenêtre AI Chat.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
