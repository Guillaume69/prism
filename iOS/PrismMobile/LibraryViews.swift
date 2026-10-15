import SwiftUI
import UIKit

// MARK: - Notes

struct NotesView: View {
    @EnvironmentObject private var store: SyncStore
    @State private var search = ""

    var body: some View {
        NavigationStack {
            let notes = store.notes.filter { search.isEmpty || ($0["text"] as? String ?? "").localizedCaseInsensitiveContains(search) }
            List {
                ForEach(notes.indices, id: \.self) { index in
                    let note = notes[index]
                    let text = note["text"] as? String ?? ""
                    let id = note["id"] as? String ?? ""
                    NavigationLink {
                        NoteEditor(noteID: id, text: text)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Self.title(text)).font(.headline).lineLimit(1)
                            Text(Self.preview(text)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .swipeActions { Button("Supprimer", role: .destructive) { store.deleteNote(id: id) } }
                }
            }
            .overlay {
                if notes.isEmpty { ContentUnavailableView("Aucune note", systemImage: "note.text", description: Text("Les notes de Prism apparaissent ici.")) }
            }
            .searchable(text: $search, prompt: "Rechercher dans les notes")
            .navigationTitle("Notes")
            .toolbar {
                NavigationLink { NoteEditor(noteID: nil, text: "") } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("Nouvelle note")
            }
            .refreshable { store.load() }
        }
    }

    static func title(_ text: String) -> String {
        let first = text.split(separator: "\n").first.map(String.init) ?? ""
        let cleaned = first.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        return cleaned.isEmpty ? "Nouvelle note" : cleaned
    }

    static func preview(_ text: String) -> String {
        text.split(separator: "\n").dropFirst().joined(separator: " ")
    }
}

struct NoteEditor: View {
    @EnvironmentObject private var store: SyncStore
    let noteID: String?
    @State var text: String
    @State private var savedID: String?
    @State private var saved: String = ""

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .padding(.horizontal, 8)
            .navigationTitle(NotesView.title(text))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                savedID = noteID
                saved = text
            }
            .onDisappear(perform: persist)
            .toolbar {
                ShareLink(item: text)
            }
    }

    private func persist() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != saved, !trimmed.isEmpty else { return }
        store.saveNote(id: savedID, text: text)
        saved = text
    }
}

// MARK: - Snippets

struct SnippetsView: View {
    @EnvironmentObject private var store: SyncStore
    @State private var search = ""
    @State private var copied: String?
    @State private var editing: EditedSnippet?

    struct EditedSnippet: Identifiable {
        let id: String?
        var name: String
        var text: String
        var keyword: String
        var identity: String { id ?? "nouveau" }
        var stableID: String { identity }
    }

    var body: some View {
        NavigationStack {
            let snippets = store.snippets.filter { snippet in
                search.isEmpty || ["name", "text", "keyword"].contains { (snippet[$0] as? String ?? "").localizedCaseInsensitiveContains(search) }
            }
            List {
                ForEach(snippets.indices, id: \.self) { index in
                    let snippet = snippets[index]
                    let text = snippet["text"] as? String ?? ""
                    Button {
                        UIPasteboard.general.string = Self.expand(text)
                        copied = snippet["name"] as? String
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = nil }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(snippet["name"] as? String ?? "").font(.headline)
                                if let keyword = snippet["keyword"] as? String, !keyword.isEmpty {
                                    Text(keyword).font(.caption.monospaced()).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(.quaternary))
                                }
                            }
                            Text(text).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .foregroundStyle(.primary)
                    .swipeActions(edge: .leading) {
                        Button("Modifier") {
                            editing = EditedSnippet(id: snippet["id"] as? String, name: snippet["name"] as? String ?? "", text: text, keyword: snippet["keyword"] as? String ?? "")
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        ShareLink(item: text)
                    }
                }
            }
            .overlay {
                if snippets.isEmpty { ContentUnavailableView("Aucun snippet", systemImage: "text.badge.plus", description: Text("Touchez un snippet pour le copier.")) }
            }
            .overlay(alignment: .bottom) {
                if let copied {
                    Label("« \(copied) » copié", systemImage: "checkmark.circle.fill")
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(.regularMaterial))
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: copied)
            .searchable(text: $search, prompt: "Nom, texte ou mot-clé")
            .navigationTitle("Snippets")
            .toolbar {
                Button { editing = EditedSnippet(id: nil, name: "", text: "", keyword: "") } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Nouveau snippet")
            }
            .sheet(item: $editing) { snippet in
                SnippetForm(snippet: snippet)
            }
            .refreshable { store.load() }
        }
    }

    /// Les placeholders usuels, comme sur le Mac : date, heure, presse-papiers ; `{cursor}` disparaît.
    static func expand(_ text: String) -> String {
        let now = Date()
        var result = text
        result = result.replacingOccurrences(of: "{cursor}", with: "")
        // Le presse-papiers n'est lu que s'il est demandé : iOS affiche une alerte à chaque lecture.
        if result.contains("{clipboard}") { result = result.replacingOccurrences(of: "{clipboard}", with: UIPasteboard.general.string ?? "") }
        result = result.replacingOccurrences(of: "{date}", with: now.formatted(date: .long, time: .omitted))
        result = result.replacingOccurrences(of: "{time}", with: now.formatted(date: .omitted, time: .shortened))
        result = result.replacingOccurrences(of: "{datetime}", with: now.formatted(date: .long, time: .shortened))
        result = result.replacingOccurrences(of: "{uuid}", with: UUID().uuidString)
        return result
    }
}

extension SnippetsView.EditedSnippet: Hashable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
    func hash(into hasher: inout Hasher) { hasher.combine(identity) }
}

struct SnippetForm: View {
    @EnvironmentObject private var store: SyncStore
    @Environment(\.dismiss) private var dismiss
    @State var snippet: SnippetsView.EditedSnippet

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nom", text: $snippet.name)
                TextField("Mot-clé (développé sur le Mac)", text: $snippet.keyword).textInputAutocapitalization(.never).autocorrectionDisabled()
                Section("Texte") {
                    TextEditor(text: $snippet.text).frame(minHeight: 160)
                }
            }
            .navigationTitle(snippet.id == nil ? "Nouveau snippet" : "Modifier")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        store.saveSnippet(id: snippet.id, name: snippet.name, text: snippet.text, keyword: snippet.keyword)
                        dismiss()
                    }
                    .disabled(snippet.name.isEmpty || snippet.text.isEmpty)
                }
            }
        }
    }
}

// MARK: - Liens rapides

struct QuicklinksView: View {
    @EnvironmentObject private var store: SyncStore
    @Environment(\.openURL) private var openURL
    @State private var search = ""
    @State private var asking: [String: Any]?
    @State private var argument = ""
    @State private var adding = false
    @State private var newName = ""
    @State private var newLink = ""

    var body: some View {
        NavigationStack {
            let links = store.quicklinks.filter { link in
                search.isEmpty || ["name", "link"].contains { (link[$0] as? String ?? "").localizedCaseInsensitiveContains(search) }
            }
            List {
                ForEach(links.indices, id: \.self) { index in
                    let link = links[index]
                    Button {
                        let template = link["link"] as? String ?? ""
                        if Self.needsArgument(template) {
                            argument = ""
                            asking = link
                        } else if let url = Self.url(template, argument: "") {
                            openURL(url)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            FaviconView(link: link["link"] as? String ?? "")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(link["name"] as? String ?? "").font(.headline)
                                Text(link["link"] as? String ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            .overlay {
                if links.isEmpty { ContentUnavailableView("Aucun lien rapide", systemImage: "link", description: Text("Les liens rapides de Prism apparaissent ici.")) }
            }
            .searchable(text: $search, prompt: "Rechercher un lien")
            .navigationTitle("Liens rapides")
            .toolbar {
                Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Nouveau lien")
            }
            .alert(asking?["name"] as? String ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
                TextField("Recherche", text: $argument)
                Button("Ouvrir") {
                    if let template = asking?["link"] as? String, let url = Self.url(template, argument: argument) { openURL(url) }
                    asking = nil
                }
                Button("Annuler", role: .cancel) { asking = nil }
            }
            .alert("Nouveau lien rapide", isPresented: $adding) {
                TextField("Nom", text: $newName)
                TextField("https://exemple.fr/recherche?q={argument}", text: $newLink).textInputAutocapitalization(.never)
                Button("Ajouter") {
                    store.saveQuicklink(id: nil, name: newName, link: newLink)
                    newName = ""
                    newLink = ""
                }
                Button("Annuler", role: .cancel) {}
            }
            .refreshable { store.load() }
        }
    }

    static func needsArgument(_ template: String) -> Bool {
        template.range(of: #"\{(argument|query)[^}]*\}"#, options: .regularExpression) != nil
    }

    /// Le lien, ses arguments remplacés (encodés pour une adresse web).
    static func url(_ template: String, argument: String) -> URL? {
        let encoded = argument.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? argument
        var link = template.replacingOccurrences(of: #"\{(argument|query)[^}]*\}"#, with: encoded, options: .regularExpression)
        if link.contains("{clipboard}") {
            link = link.replacingOccurrences(of: "{clipboard}", with: UIPasteboard.general.string?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        }
        if !link.contains("://") { link = "https://" + link }
        return URL(string: link)
    }
}

private struct FaviconView: View {
    let link: String

    var body: some View {
        let host = URL(string: link.contains("://") ? link : "https://" + link)?.host
        AsyncImage(url: host.flatMap { URL(string: "https://\($0)/apple-touch-icon.png") }) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: "link").foregroundStyle(.secondary)
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Réglages

struct SettingsView: View {
    @EnvironmentObject private var store: SyncStore
    @State private var importing = false
    @State private var provider = AIProvider.current
    @State private var anthropicKey = Keychain.read("ai.anthropic.key") ?? ""
    @State private var openAIKey = Keychain.read("ai.openai.key") ?? ""
    @AppStorage("ai.anthropic.model") private var anthropicModel = ""
    @AppStorage("ai.openai.model") private var openAIModel = ""
    @AppStorage("ai.openai.base") private var openAIBase = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Synchronisation") {
                    LabeledContent("Fichier", value: store.sourceName.isEmpty ? "—" : store.sourceName)
                    if let date = store.lastLoaded {
                        LabeledContent("Lu", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    if !store.status.isEmpty { Text(store.status).font(.footnote).foregroundStyle(.secondary) }
                    if let error = store.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                    Button("Relire maintenant") { store.load() }
                    Button("Choisir un autre fichier…") { importing = true }
                    Button("Utiliser des données sur l’iPhone") { store.useLocalFile() }
                }
                Section {
                    Picker("Modèle", selection: $provider) {
                        ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: provider) { _, value in AIProvider.current = value }
                    if provider == .anthropic {
                        SecureField("Clé d’API Anthropic", text: $anthropicKey).onChange(of: anthropicKey) { _, value in Keychain.write(value, "ai.anthropic.key") }
                        TextField("Modèle (\(AIClient.anthropicModel))", text: $anthropicModel).textInputAutocapitalization(.never)
                    }
                    if provider == .openai {
                        SecureField("Clé d’API", text: $openAIKey).onChange(of: openAIKey) { _, value in Keychain.write(value, "ai.openai.key") }
                        TextField("Modèle (\(AIClient.openAIModel))", text: $openAIModel).textInputAutocapitalization(.never)
                        TextField("Adresse du service (\(AIClient.openAIBase))", text: $openAIBase).textInputAutocapitalization(.never).keyboardType(.URL)
                    }
                } header: {
                    Text("IA")
                } footer: {
                    Text("Apple Intelligence tourne sur l’iPhone, sans compte ni envoi de données. Les clés restent dans le trousseau.")
                }
                Section("Raccourcis") {
                    Text("« Demander à Prism » est disponible dans l’app Raccourcis et pour Siri.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Réglages")
            .scrollDismissesKeyboard(.interactively)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.prismConfig, .json, .data]) { result in
                if case .success(let url) = result { store.choose(url) }
            }
        }
    }
}
