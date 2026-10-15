import SwiftUI

/// AI Chat : les conversations de Prism (celles du Mac comprises) et de nouvelles, sur l'iPhone.
struct ChatListView: View {
    @EnvironmentObject private var store: SyncStore
    @State private var search = ""

    private var conversations: [[String: Any]] {
        store.conversations.filter { conversation in
            search.isEmpty || (conversation["title"] as? String ?? "").localizedCaseInsensitiveContains(search)
                || (conversation["messages"] as? [[String: Any]] ?? []).contains { ($0["content"] as? String ?? "").localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(conversations.indices, id: \.self) { index in
                    let conversation = conversations[index]
                    let id = conversation["id"] as? String ?? ""
                    NavigationLink {
                        ChatView(conversationID: id)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                if conversation["pinned"] as? Bool == true { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange) }
                                Text(conversation["title"] as? String ?? "Conversation").font(.headline).lineLimit(1)
                            }
                            Text(Self.plain(((conversation["messages"] as? [[String: Any]])?.last?["content"] as? String ?? "")))
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            if let date = PrismDate.date(conversation["updated"]) {
                                Text(date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Supprimer", role: .destructive) { store.deleteConversation(id: id) }
                    }
                }
            }
            .overlay {
                if conversations.isEmpty {
                    ContentUnavailableView("Aucune conversation", systemImage: "sparkles", description: Text("Commencez-en une : elle apparaîtra aussi dans Prism sur le Mac."))
                }
            }
            .searchable(text: $search, prompt: "Rechercher dans les conversations")
            .navigationTitle("IA")
            .toolbar {
                NavigationLink {
                    ChatView(conversationID: nil)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("Nouvelle conversation")
            }
            .refreshable { store.load() }
        }
    }
}

extension ChatListView {
    /// L'aperçu d'un message, sans la syntaxe Markdown.
    static func plain(_ markdown: String) -> String {
        let text = (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? markdown
        return text.replacingOccurrences(of: "\n", with: " ")
    }
}

struct ChatView: View {
    @EnvironmentObject private var store: SyncStore
    let conversationID: String?
    @State private var messages: [AIMessage] = []
    @State private var draft = ""
    @State private var answering = false
    @State private var failure: String?
    @State private var savedID: String?
    @State private var title = "Nouvelle conversation"
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            Bubble(message: message).id(message.id)
                        }
                        if let failure {
                            Label(failure, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages) { _, _ in
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Demander à l’IA…", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 18).fill(.quaternary.opacity(0.6)))
                Button {
                    send()
                } label: {
                    Image(systemName: answering ? "stop.circle.fill" : "arrow.up.circle.fill").font(.system(size: 30))
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !answering)
                .accessibilityLabel("Envoyer")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadConversation)
    }

    private func loadConversation() {
        guard let conversationID, messages.isEmpty,
              let conversation = store.conversations.first(where: { $0["id"] as? String == conversationID }) else {
            focused = conversationID == nil
            return
        }
        savedID = conversationID
        title = conversation["title"] as? String ?? title
        messages = (conversation["messages"] as? [[String: Any]] ?? []).compactMap { message in
            guard let role = message["role"] as? String, role == "user" || role == "assistant" else { return nil }
            return AIMessage(role: role, content: message["content"] as? String ?? "")
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !answering else { return }
        draft = ""
        failure = nil
        if messages.isEmpty { title = String(text.prefix(48)) }
        messages.append(AIMessage(role: "user", content: text))
        messages.append(AIMessage(role: "assistant", content: ""))
        answering = true
        let history = Array(messages.dropLast())
        Task {
            do {
                for try await chunk in AIClient.stream(history) {
                    messages[messages.count - 1].content += chunk
                }
            } catch {
                failure = error.localizedDescription
                if messages.last?.content.isEmpty == true { messages.removeLast() }
            }
            answering = false
            // Seuls la question et sa réponse s'ajoutent : le reste de la conversation n'est pas réécrit.
            var added: [(role: String, content: String)] = [("user", text)]
            if let answer = messages.last, answer.role == "assistant", !answer.content.isEmpty { added.append(("assistant", answer.content)) }
            savedID = store.appendToConversation(id: savedID, title: title, messages: added)
        }
    }
}

private struct Bubble: View {
    let message: AIMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 40) }
            Group {
                if message.content.isEmpty {
                    ProgressView()
                } else if let attributed = try? AttributedString(markdown: message.content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                    Text(attributed)
                } else {
                    Text(message.content)
                }
            }
            .textSelection(.enabled)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16).fill(message.role == "user" ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(.quaternary.opacity(0.5))))
            if message.role != "user" { Spacer(minLength: 40) }
        }
    }
}
