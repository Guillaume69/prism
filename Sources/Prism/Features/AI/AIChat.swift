import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - La fenêtre

/// La fenêtre AI Chat : conversations à gauche, messages et compositeur à droite.
@MainActor
final class AIChatWindow: NSObject, NSWindowDelegate {
    static let shared = AIChatWindow()

    let model = AIChatModel()
    private var window: NSWindow?
    private var keyMonitor: Any?
    private var subscriptions: Set<AnyCancellable> = []

    var isVisible: Bool { window?.isVisible == true }

    /// Ouvre la fenêtre (sur une conversation neuve si rien n'est choisi).
    func open() {
        let window = window ?? makeWindow()
        self.window = window
        applyLevel()
        // L'activation est coopérative depuis macOS 14 : on la demande tant que le lanceur
        // détient encore l'interaction, et on ne le masque qu'ensuite.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        AppContext.launcher?.hide()
        model.requestComposerFocus()
    }

    func open(conversation: AIConversation) {
        if AIHistory.shared.conversation(conversation.id) == nil { AIHistory.shared.upsert(conversation) }
        model.select(conversation.id)
        open()
    }

    /// Nouvelle conversation avec du texte dans le compositeur et du contexte joint.
    func open(text: String, attachments: [AIAttachment]) {
        model.newConversation()
        model.composerText = text
        model.composerAttachments = attachments
        open()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Chat"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 460)
        window.setFrameAutosaveName("PrismAIChat")
        window.contentView = NSHostingView(rootView: AIChatView(model: model))
        if !window.setFrameUsingName("PrismAIChat") { window.center() }
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return event }
                return self.model.handleKey(event) ? nil : event
            }
        }
        AISettings.shared.$chatAlwaysOnTop
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.applyLevel() } }
            .store(in: &subscriptions)
        return window
    }

    private func applyLevel() {
        window?.level = AISettings.shared.chatAlwaysOnTop ? .floating : .normal
    }

    /// Fenêtre fermée : Prism redevient discret si plus rien n'est ouvert.
    func windowWillClose(_ notification: Notification) {
        model.stopAll()
        AIHistory.shared.flush()
        DispatchQueue.main.async {
            let others = NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) && $0 !== self.window }
            if others.isEmpty { NSApp.hide(nil) }
        }
    }
}

// MARK: - Le modèle de la fenêtre

@MainActor
final class AIChatModel: ObservableObject {
    @Published var selectedID: UUID?
    /// La conversation neuve, pas encore dans l'historique.
    @Published private(set) var draft: AIChatSession
    @Published var sidebarSearch = ""
    @Published var composerText = ""
    @Published var composerAttachments: [AIAttachment] = []
    @Published var showTrash = false
    @Published var showArchived = false
    @Published var sidebarVisible = true
    @Published var renamingID: UUID?
    @Published var renameText = ""
    @Published var editingMessageID: UUID?
    @Published var editText = ""
    @Published var findVisible = false
    @Published var findText = ""
    @Published var findIndex = 0
    @Published var copiedMessageID: UUID?
    /// Change pour demander le focus du compositeur ou du champ de recherche.
    @Published private(set) var composerFocusToken = 0
    @Published private(set) var findFocusToken = 0
    /// Change pour faire défiler jusqu'à un message.
    @Published private(set) var scrollTarget: UUID?

    let history = AIHistory.shared
    private var sessions: [UUID: AIChatSession] = [:]
    private var subscriptions: Set<AnyCancellable> = []

    init() {
        draft = AIChatSession(usage: .chat)
        history.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        AISettings.shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        wire(draft)
    }

    private func wire(_ session: AIChatSession) {
        session.onStateChange = { [weak self, weak session] in
            guard let self, let session else { return }
            // La conversation neuve rejoint l'historique dès son premier message.
            if session === self.draft, !session.conversation.messages.isEmpty, self.history.conversation(session.id) != nil {
                self.sessions[session.id] = session
                if self.selectedID == nil { self.selectedID = session.id }
            }
            self.objectWillChange.send()
        }
    }

    // MARK: Lecture

    /// La conversation affichée : celle choisie, sinon la neuve.
    var current: AIChatSession {
        if let selectedID, let session = session(for: selectedID) { return session }
        return draft
    }

    func session(for id: UUID) -> AIChatSession? {
        if let session = sessions[id] { return session }
        if draft.id == id { return draft }
        guard let conversation = history.conversation(id) else { return nil }
        let session = AIChatSession(conversation: conversation, usage: .chat)
        sessions[id] = session
        wire(session)
        return session
    }

    var isDraftShown: Bool { current === draft }

    /// Les conversations de la barre latérale, filtrées par la recherche (titres et contenus).
    var filtered: [AIConversation] {
        let query = sidebarSearch.normalizedForSearch
        let list = history.active.map { sessions[$0.id]?.conversation ?? $0 }
        guard !query.isEmpty else { return list }
        return list.filter { conversation in
            conversation.title.normalizedForSearch.contains(query)
                || conversation.messages.contains { $0.content.normalizedForSearch.contains(query) }
        }
    }

    var groups: [(title: String, items: [AIConversation])] {
        let projects = Set(AIProjectStore.shared.projects.map(\.id))
        return AIDateSections.group(filtered.filter { $0.projectID.map { !projects.contains($0) } ?? true })
    }

    /// Les messages qui contiennent le texte cherché (⌘F).
    var findMatches: [UUID] {
        let query = findText.normalizedForSearch
        guard !query.isEmpty else { return [] }
        return current.conversation.messages.filter { ($0.displayText ?? $0.content).normalizedForSearch.contains(query) }.map(\.id)
    }

    // MARK: Conversations

    func select(_ id: UUID?) {
        guard selectedID != id else { return }
        selectedID = id
        editingMessageID = nil
        findIndex = 0
        if let id { scrollTarget = session(for: id)?.conversation.messages.last?.id }
        requestComposerFocus()
    }

    func newConversation(presetID: UUID? = nil, projectID: UUID? = nil) {
        if draft.conversation.messages.isEmpty {
            draft.conversation.presetID = presetID ?? draft.conversation.presetID
            draft.conversation.projectID = projectID
        } else {
            draft = AIChatSession(usage: .chat)
            draft.conversation.presetID = presetID
            draft.conversation.projectID = projectID
            wire(draft)
        }
        selectedID = nil
        editingMessageID = nil
        composerAttachments = []
        requestComposerFocus()
    }

    /// Modifie une conversation dans l'historique et dans sa session ouverte.
    func mutate(_ id: UUID, _ change: (inout AIConversation) -> Void) {
        if let session = sessions[id] ?? (draft.id == id ? draft : nil) {
            change(&session.conversation)
            session.save()
        } else {
            history.update(id, change)
        }
        objectWillChange.send()
    }

    func togglePin(_ id: UUID) {
        mutate(id) { $0.pinned.toggle() }
    }

    func beginRename(_ id: UUID) {
        renameText = session(for: id)?.conversation.title ?? ""
        renamingID = id
    }

    func commitRename() {
        guard let id = renamingID else { return }
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            mutate(id) {
                $0.title = title
                $0.isTitleManual = true
            }
        }
        renamingID = nil
    }

    func delete(_ id: UUID) {
        sessions[id]?.stop()
        sessions[id] = nil
        history.moveToTrash(id)
        if selectedID == id { selectedID = history.active.first?.id }
    }

    func duplicate(_ id: UUID, upTo messageID: UUID? = nil) {
        if let session = sessions[id] { session.save() }
        if let copy = history.duplicate(id, upTo: messageID) { select(copy.id) }
    }

    func copyConversation(_ id: UUID) {
        guard let conversation = session(for: id)?.conversation else { return }
        Pasteboard.copy(AIExport.markdown(conversation))
    }

    func exportMarkdown(_ id: UUID) {
        guard let conversation = session(for: id)?.conversation else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = AIExport.fileName(conversation.title)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? AIExport.markdown(conversation).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func setPreset(_ presetID: UUID?) {
        let session = current
        session.conversation.presetID = presetID
        session.save()
        objectWillChange.send()
    }

    /// Range une conversation dans un projet (`nil` : la sort du projet).
    func setProject(_ projectID: UUID?, for id: UUID? = nil) {
        if let id, id != current.id {
            mutate(id) { $0.projectID = projectID }
            return
        }
        let session = current
        session.conversation.projectID = projectID
        session.save()
        objectWillChange.send()
    }

    /// Les conversations de chaque projet, en tête de la barre latérale.
    var projectGroups: [(project: AIProject, items: [AIConversation])] {
        let list = filtered
        return AIProjectStore.shared.projects.map { project in (project, list.filter { $0.projectID == project.id }) }
            .filter { !$0.items.isEmpty || sidebarSearch.isEmpty }
    }

    func setModel(_ choice: AIModelChoice?) {
        current.setModel(choice)
        objectWillChange.send()
    }

    func stopAll() {
        draft.stop()
        sessions.values.forEach { $0.stop() }
    }

    // MARK: Messages

    func send() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !composerAttachments.isEmpty else { return }
        let session = current
        session.send(text, attachments: composerAttachments)
        composerText = ""
        composerAttachments = []
        if session === draft {
            sessions[session.id] = session
            selectedID = session.id
            draft = AIChatSession(usage: .chat)
            draft.conversation.presetID = session.conversation.presetID
            draft.conversation.projectID = session.conversation.projectID
            wire(draft)
        }
        scrollTarget = nil
        objectWillChange.send()
    }

    func beginEdit(_ message: AIChatMessage) {
        editText = message.content
        editingMessageID = message.id
    }

    func commitEdit() {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        editingMessageID = nil
        guard !text.isEmpty else { return }
        current.editLastUserMessage(text)
    }

    func copy(_ message: AIChatMessage) {
        Pasteboard.copy(message.content)
        copiedMessageID = message.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            if self?.copiedMessageID == message.id { self?.copiedMessageID = nil }
        }
    }

    func attachClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        composerAttachments.append(AIAttachment(kind: .clipboard, title: "Presse-papiers", content: text))
    }

    func attachBrowserTab() {
        if let attachment = AIContext.browserTab() { composerAttachments.append(attachment) }
    }

    func attachFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .sourceCode, .json, .commaSeparatedText, .xml, .html]
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK else { return }
                for url in panel.urls {
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    self?.composerAttachments.append(AIAttachment(kind: .text, title: url.lastPathComponent, content: String(text.prefix(200_000))))
                }
            }
        }
    }

    // MARK: Recherche dans la conversation

    func showFind() {
        findVisible = true
        findFocusToken += 1
    }

    func closeFind() {
        findVisible = false
        findText = ""
        requestComposerFocus()
    }

    func nextMatch(_ delta: Int = 1) {
        let matches = findMatches
        guard !matches.isEmpty else { return }
        findIndex = (findIndex + delta + matches.count) % matches.count
        scrollTarget = matches[findIndex]
    }

    func requestComposerFocus() {
        composerFocusToken += 1
    }

    // MARK: Zoom

    var zoom: CGFloat { CGFloat(AISettings.shared.chatZoom) }

    func zoom(by delta: Double) {
        AISettings.shared.chatZoom = min(1.6, max(0.8, (AISettings.shared.chatZoom + delta) * 10).rounded() / 10)
    }

    // MARK: Clavier

    func archive(_ id: UUID, _ archived: Bool = true) {
        mutate(id) { $0.archived = archived ? true : nil }
        if archived, selectedID == id { selectedID = history.active.first?.id }
    }

    /// ⇧⌘Y : la créativité de la conversation, d'un cran à l'autre.
    func cycleCreativity() {
        let levels: [Double] = [0, 0.3, 0.7, 1.0, 1.3]
        let currentValue = current.temperatureOverride ?? AISettings.shared.temperature
        let index = levels.firstIndex { $0 > currentValue + 0.01 } ?? 0
        current.temperatureOverride = levels[index]
        objectWillChange.send()
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // ⌘1 à ⌘9 : les conversations de la barre latérale, dans l'ordre.
        let digits: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
        if modifiers == .command, let index = digits[event.keyCode] {
            let ordered = projectGroups.flatMap(\.items) + groups.flatMap(\.items)
            if ordered.indices.contains(index) { select(ordered[index].id) }
            return true
        }
        switch (event.keyCode, modifiers) {
        case (1, [.command, .shift]), (11, [.command]): // ⇧⌘S, ⌘B : barre latérale
            sidebarVisible.toggle()
        case (11, [.command, .shift]): // ⇧⌘B : brancher la conversation
            duplicate(current.id)
        case (0, [.command, .option]): // ⌥⌘A : archiver
            archive(current.id)
        case (0, [.command, .shift]): // ⇧⌘A : joindre un fichier
            attachFile()
        case (46, [.control]): // ⌃M : dicter dans le compositeur
            DictationController.shared.dictate { [weak self] text in
                guard let self else { return }
                self.composerText += (self.composerText.isEmpty ? "" : " ") + text
                self.requestComposerFocus()
            }
        case (16, [.command, .shift]): // ⇧⌘Y : créativité
            cycleCreativity()
        case (126, []) where composerText.isEmpty && editingMessageID == nil && NSApp.keyWindow?.firstResponder is NSTextView:
            // ↑ dans un compositeur vide : modifier le dernier message.
            guard let last = current.conversation.messages.last(where: { $0.role == .user }) else { return false }
            beginEdit(last)
        case (45, [.command]): // ⌘N
            newConversation()
        case (15, [.command]): // ⌘R
            current.regenerate()
        case (3, [.command]): // ⌘F
            showFind()
        case (5, [.command]) where findVisible: // ⌘G
            nextMatch()
        case (24, [.command]), (24, [.command, .shift]), (69, [.command]): // ⌘+
            zoom(by: 0.1)
        case (27, [.command]), (78, [.command]): // ⌘-
            zoom(by: -0.1)
        case (29, [.command]), (82, [.command]): // ⌘0
            AISettings.shared.chatZoom = 1
        case (8, [.command, .shift]): // ⌘⇧C : copier toute la conversation
            copyConversation(current.id)
        case (53, []):
            if current.isGenerating {
                current.stop()
            } else if findVisible {
                closeFind()
            } else if editingMessageID != nil {
                editingMessageID = nil
            } else if renamingID != nil {
                renamingID = nil
            } else if AISettings.shared.escapeClosesChat {
                NSApp.keyWindow?.performClose(nil)
            } else {
                return false
            }
        default:
            return false
        }
        return true
    }
}

// MARK: - Les vues

struct AIChatView: View {
    @ObservedObject var model: AIChatModel

    var body: some View {
        HStack(spacing: 0) {
            if model.sidebarVisible {
                AIChatSidebar(model: model)
                    .frame(width: 262)
                Divider()
            }
            AIChatDetail(model: model, session: model.current)
                .id(model.current.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct AIChatSidebar: View {
    @ObservedObject var model: AIChatModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    TextField("Rechercher", text: $model.sidebarSearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                    if !model.sidebarSearch.isEmpty {
                        Button { model.sidebarSearch = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
                Button { model.newConversation() } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Nouvelle conversation (⌘N)")
            }
            .padding(.horizontal, 12)
            .padding(.top, 40)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    let groups = model.groups
                    if groups.isEmpty {
                        Text(model.sidebarSearch.isEmpty ? "Aucune conversation" : "Aucun résultat")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                    }
                    ProjectsSection(model: model)
                    ForEach(groups, id: \.title) { group in
                        Text(group.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.top, 12)
                            .padding(.bottom, 3)
                        ForEach(group.items) { conversation in
                            AIConversationRow(model: model, conversation: conversation)
                        }
                    }
                    archivedSection
                    trash
                }
                .padding(.bottom, 10)
            }
            .scrollIndicators(.automatic)
        }
        .background(VisualEffectBackground(material: .sidebar, blending: .behindWindow))
    }

    @ViewBuilder
    private var archivedSection: some View {
        let archived = model.history.archived
        if !archived.isEmpty, model.sidebarSearch.isEmpty {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { model.showArchived.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: model.showArchived ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                    Text("Archivées (\(archived.count))").font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 3)
            if model.showArchived {
                ForEach(archived) { conversation in
                    HStack {
                        Text(conversation.title).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button { model.archive(conversation.id, false) } label: { Image(systemName: "tray.and.arrow.up") }
                            .buttonStyle(.borderless)
                            .help("Désarchiver")
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                    .onTapGesture { model.select(conversation.id) }
                }
            }
        }
    }

    @ViewBuilder
    private var trash: some View {
        let trash = model.history.trash
        if !trash.isEmpty, model.sidebarSearch.isEmpty {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { model.showTrash.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: model.showTrash ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                    Text("Récemment supprimées (\(trash.count))").font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 3)
            if model.showTrash {
                ForEach(trash) { conversation in
                    HStack {
                        Text(conversation.title).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button { model.history.restore(conversation.id) } label: { Image(systemName: "arrow.uturn.backward") }
                            .buttonStyle(.borderless)
                            .help("Restaurer")
                        Button { model.history.deleteForever(conversation.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Supprimer définitivement")
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 26)
                }
                Text("Effacées définitivement au bout de 60 jours.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
                Button("Vider la corbeille") { model.history.emptyTrash() }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
            }
        }
    }
}

/// Les projets en tête de la barre latérale, chacun avec ses conversations.
private struct ProjectsSection: View {
    @ObservedObject var model: AIChatModel
    @ObservedObject private var projects = AIProjectStore.shared

    var body: some View {
        let groups = model.projectGroups
        if !groups.isEmpty {
            HStack {
                Text("Projets").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    AppContext.launcher?.show(reset: true)
                    AppContext.launcher?.model.push(AIAgentsUI.projectForm(nil))
                } label: { Image(systemName: "plus").font(.system(size: 10.5, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Créer un projet (⌃⌘N)")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 3)
            ForEach(groups, id: \.project.id) { group in
                HStack(spacing: 7) {
                    Image(systemName: group.project.symbol).font(.system(size: 11.5)).foregroundStyle(Palette.indigo)
                    Text(group.project.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Spacer()
                    Button { model.newConversation(projectID: group.project.id) } label: {
                        Image(systemName: "square.and.pencil").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Nouvelle conversation dans le projet")
                }
                .padding(.horizontal, 15)
                .frame(height: 24)
                ForEach(group.items) { conversation in
                    AIConversationRow(model: model, conversation: conversation)
                        .padding(.leading, 10)
                }
            }
        }
    }
}

private struct AIConversationRow: View {
    @ObservedObject var model: AIChatModel
    let conversation: AIConversation
    @FocusState private var renameFocused: Bool
    @State private var hovering = false

    var body: some View {
        let isSelected = model.selectedID == conversation.id
        let isGenerating = model.session(for: conversation.id)?.isGenerating == true
        HStack(spacing: 7) {
            if model.renamingID == conversation.id {
                TextField("Titre", text: $model.renameText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5))
                    .focused($renameFocused)
                    .onSubmit { model.commitRename() }
                    .onAppear { renameFocused = true }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(conversation.title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    if let preview = preview {
                        Text(preview)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isGenerating {
                    ProgressView().controlSize(.mini)
                } else if conversation.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : hovering ? Color.primary.opacity(0.05) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.select(conversation.id) }
        .padding(.horizontal, 6)
        .contextMenu {
            Button("Renommer") { model.beginRename(conversation.id) }
            Button(conversation.pinned ? "Désépingler" : "Épingler") { model.togglePin(conversation.id) }
            Button("Dupliquer") { model.duplicate(conversation.id) }
            Button("Archiver") { model.archive(conversation.id) }
            Menu("Déplacer vers un projet") {
                ForEach(AIProjectStore.shared.projects) { project in
                    Button(project.name) { model.setProject(project.id, for: conversation.id) }
                }
                if conversation.projectID != nil {
                    Divider()
                    Button("Sortir du projet") { model.setProject(nil, for: conversation.id) }
                }
            }
            Divider()
            Button("Copier la conversation") { model.copyConversation(conversation.id) }
            Button("Exporter en Markdown…") { model.exportMarkdown(conversation.id) }
            Divider()
            Button("Supprimer", role: .destructive) { model.delete(conversation.id) }
        }
    }

    private var preview: String? {
        guard let last = conversation.messages.last else { return nil }
        let text = (last.displayText ?? last.content).replacingOccurrences(of: "\n", with: " ")
        return text.isEmpty ? nil : String(text.prefix(90))
    }
}

private struct AIChatDetail: View {
    @ObservedObject var model: AIChatModel
    @ObservedObject var session: AIChatSession
    @ObservedObject private var presets = AIPresetStore.shared
    @ObservedObject private var settings = AISettings.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.findVisible { findBar }
            Divider()
            AIChatMessages(model: model, session: session)
            AIComposer(model: model, session: session)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.conversation.messages.isEmpty ? "Nouvelle conversation" : session.conversation.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            projectMenu
            presetMenu
            AIModelMenu(selected: session.conversation.model.map(AIModelChoice.init(rawValue:)), defaultLabel: (session.preset?.model.map { AIModelChoice(rawValue: $0) } ?? settings.choice(for: .chat)).label) { choice in
                model.setModel(choice)
            }
            Button {
                settings.chatAlwaysOnTop.toggle()
            } label: {
                Image(systemName: settings.chatAlwaysOnTop ? "pin.fill" : "pin")
                    .font(.system(size: 12.5))
                    .foregroundStyle(settings.chatAlwaysOnTop ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(settings.chatAlwaysOnTop ? "Ne plus garder au premier plan" : "Toujours au premier plan")
            moreMenu
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .frame(height: 52)
    }

    private var subtitle: String {
        let count = session.conversation.messages.count
        let model = session.modelLabel
        let preset = session.preset.map { " · \($0.name)" } ?? ""
        return count == 0 ? "\(model)\(preset)" : "\(count) message\(count > 1 ? "s" : "") · \(model)\(preset)"
    }

    private var presetMenu: some View {
        Menu {
            Button {
                model.setPreset(nil)
            } label: {
                if session.conversation.presetID == nil { Label("Sans agent", systemImage: "checkmark") } else { Text("Sans agent") }
            }
            Divider()
            ForEach(presets.presets) { preset in
                Button {
                    model.setPreset(preset.id)
                } label: {
                    if session.conversation.presetID == preset.id { Label(preset.name, systemImage: "checkmark") } else { Text(preset.name) }
                }
            }
            Divider()
            Button("Gérer les agents…") {
                AppContext.launcher?.show(reset: true)
                AppContext.launcher?.model.push(AIAgentsUI.agentsScreen())
            }
        } label: {
            Label(session.preset?.name ?? "Agent", systemImage: session.preset?.symbol ?? "person.crop.circle")
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Agent : rôle, instructions, modèle et outils de la conversation")
    }

    private var projectMenu: some View {
        Menu {
            Button {
                model.setProject(nil)
            } label: {
                if session.conversation.projectID == nil { Label("Hors projet", systemImage: "checkmark") } else { Text("Hors projet") }
            }
            Divider()
            ForEach(AIProjectStore.shared.projects) { project in
                Button {
                    model.setProject(project.id)
                } label: {
                    if session.conversation.projectID == project.id { Label(project.name, systemImage: "checkmark") } else { Text(project.name) }
                }
            }
            Divider()
            Button("Créer un projet…") {
                AppContext.launcher?.show(reset: true)
                AppContext.launcher?.model.push(AIAgentsUI.projectForm(nil))
            }
        } label: {
            Label(AIProjectStore.shared.project(session.conversation.projectID)?.name ?? "Projet", systemImage: AIProjectStore.shared.project(session.conversation.projectID)?.symbol ?? "folder")
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Projet : instructions communes et dossier de travail")
    }

    private var moreMenu: some View {
        Menu {
            Button("Nouvelle conversation") { model.newConversation() }
            if !session.conversation.messages.isEmpty {
                Button("Régénérer la réponse") { session.regenerate() }
                Button("Chercher dans la conversation") { model.showFind() }
                Divider()
                Button("Renommer") { model.beginRename(session.id) }
                Button(session.conversation.pinned ? "Désépingler" : "Épingler") { model.togglePin(session.id) }
                Button("Dupliquer") { model.duplicate(session.id) }
                Button("Copier la conversation") { model.copyConversation(session.id) }
                Button("Exporter en Markdown…") { model.exportMarkdown(session.id) }
                Divider()
                Button("Supprimer", role: .destructive) { model.delete(session.id) }
            }
            Divider()
            Button("Agrandir le texte") { model.zoom(by: 0.1) }
            Button("Réduire le texte") { model.zoom(by: -0.1) }
            Button("Taille réelle") { settings.chatZoom = 1 }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 13))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary).font(.system(size: 12))
            AIFindField(text: $model.findText, focusToken: model.findFocusToken) { backwards in
                model.nextMatch(backwards ? -1 : 1)
            }
            .frame(height: 22)
            let matches = model.findMatches
            Text(matches.isEmpty ? (model.findText.isEmpty ? "" : "Aucun résultat") : "\(min(model.findIndex, matches.count - 1) + 1) sur \(matches.count)")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize()
            Button { model.nextMatch(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(matches.isEmpty)
            Button { model.nextMatch() } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(matches.isEmpty)
            Button("OK") { model.closeFind() }.controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
    }
}

/// Le menu des modèles : par défaut, puis Auto, sur l'appareil, en ligne.
struct AIModelMenu: View {
    let selected: AIModelChoice?
    let defaultLabel: String
    let onSelect: (AIModelChoice?) -> Void
    @ObservedObject private var catalog = AIModelCatalog.shared

    var body: some View {
        Menu {
            item(nil, title: "Par défaut (\(defaultLabel))")
            Divider()
            item(.auto, title: "Auto (le meilleur disponible)")
            ForEach(AIProviderKind.allCases) { kind in
                let choices = catalog.options.filter { $0.provider == kind }
                if !choices.isEmpty {
                    Section(kind.title) {
                        ForEach(choices, id: \.rawValue) { choice in item(choice, title: choice.label) }
                    }
                }
            }
        } label: {
            Label(selected?.label ?? defaultLabel, systemImage: "cpu")
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Modèle de la conversation")
        .onAppear { catalog.refresh() }
    }

    @ViewBuilder
    private func item(_ choice: AIModelChoice?, title: String) -> some View {
        Button {
            onSelect(choice)
        } label: {
            if selected == choice { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

private struct AIChatMessages: View {
    @ObservedObject var model: AIChatModel
    @ObservedObject var session: AIChatSession

    var body: some View {
        let zoom = model.zoom
        let matches = Set(model.findMatches)
        let current = model.findMatches.indices.contains(model.findIndex) ? model.findMatches[model.findIndex] : nil
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 18 * zoom) {
                    if session.conversation.messages.isEmpty, !session.isGenerating {
                        AIChatEmptyState(session: session, zoom: zoom) { suggestion in
                            model.composerText = suggestion
                            model.requestComposerFocus()
                        }
                    }
                    let lastUser = session.conversation.messages.lastIndex { $0.role == .user }
                    let lastAssistant = session.conversation.messages.lastIndex { $0.role == .assistant }
                    ForEach(Array(session.conversation.messages.enumerated()), id: \.element.id) { index, message in
                        AIMessageView(
                            model: model, session: session, message: message, zoom: zoom,
                            isLastUser: index == lastUser, isLastAnswer: index == lastAssistant && index == session.conversation.messages.count - 1,
                            highlight: current == message.id ? .current : matches.contains(message.id) ? .match : .none
                        )
                        .id(message.id)
                    }
                    if session.isGenerating {
                        Group {
                            if session.streamingText.isEmpty {
                                AIThinkingIndicator(label: session.modelLabel)
                            } else {
                                AIMarkdownView(source: session.streamingText, scale: zoom)
                            }
                        }
                        .frame(maxWidth: 760, alignment: .leading)
                    }
                    if let error = session.error {
                        AIErrorBox(message: error, scale: zoom)
                            .frame(maxWidth: 760, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.streamingText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.conversation.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: model.scrollTarget) { _, target in
                if let target { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target, anchor: .center) } }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

private struct AIChatEmptyState: View {
    @ObservedObject var session: AIChatSession
    let zoom: CGFloat
    let onSuggestion: (String) -> Void

    private let suggestions = [
        "Explique-moi la différence entre un processus et un thread",
        "Rédige un courriel pour décaler une réunion à jeudi",
        "Propose trois idées de nom pour une application de notes",
    ]

    var body: some View {
        VStack(spacing: 14) {
            ItemIconView(icon: .symbol(session.preset?.symbol ?? "sparkles", Palette.violet), size: 40)
            Text(session.preset?.name ?? "Comment puis-je vous aider ?")
                .font(.system(size: 19 * zoom, weight: .semibold))
            Text("\(session.modelLabel)" + (session.choice.provider?.isLocal == true ? " · sur votre Mac, rien ne quitte l’appareil" : ""))
                .font(.system(size: 12 * zoom))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button { onSuggestion(suggestion) } label: {
                        Text(suggestion)
                            .font(.system(size: 12.5 * zoom))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .frame(maxWidth: 420)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

private enum AIHighlight { case none, match, current }

private struct AIMessageView: View {
    @ObservedObject var model: AIChatModel
    @ObservedObject var session: AIChatSession
    let message: AIChatMessage
    let zoom: CGFloat
    let isLastUser: Bool
    let isLastAnswer: Bool
    let highlight: AIHighlight
    @State private var hovering = false

    var body: some View {
        Group {
            if message.role == .user { user } else { assistant }
        }
        .padding(highlight == .none ? 0 : 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(highlight == .current ? Palette.yellow.opacity(0.18) : highlight == .match ? Palette.yellow.opacity(0.07) : .clear)
        )
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var user: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !message.attachments.isEmpty {
                AIAttachmentChips(attachments: message.attachments, onRemove: nil)
            }
            if model.editingMessageID == message.id {
                VStack(alignment: .trailing, spacing: 8) {
                    TextEditor(text: $model.editText)
                        .font(.system(size: 13.5 * zoom))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 60, maxHeight: 200)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.6)))
                    HStack {
                        Button("Annuler") { model.editingMessageID = nil }
                        Button("Envoyer") { model.commitEdit() }.keyboardShortcut(.defaultAction)
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: 560)
            } else {
                Text(message.displayText ?? message.content)
                    .font(.system(size: 13.5 * zoom))
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.accentColor.opacity(0.16)))
                    .frame(maxWidth: 560, alignment: .trailing)
                HStack(spacing: 10) {
                    if isLastUser, !session.isGenerating {
                        toolbarButton("Modifier", symbol: "pencil") { model.beginEdit(message) }
                    }
                    toolbarButton(model.copiedMessageID == message.id ? "Copié" : "Copier", symbol: model.copiedMessageID == message.id ? "checkmark" : "doc.on.doc") { model.copy(message) }
                }
                .opacity(hovering || isLastUser ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 8) {
            AIMarkdownView(source: message.content, scale: zoom)
            HStack(spacing: 12) {
                if let model = message.model {
                    Text(model).font(.system(size: 10.5 * zoom, weight: .medium)).foregroundStyle(.tertiary)
                }
                toolbarButton(model.copiedMessageID == message.id ? "Copié" : "Copier", symbol: model.copiedMessageID == message.id ? "checkmark" : "doc.on.doc") { model.copy(message) }
                if isLastAnswer, !session.isGenerating {
                    toolbarButton("Régénérer", symbol: "arrow.clockwise") { session.regenerate() }
                }
                toolbarButton("Brancher ici", symbol: "arrow.triangle.branch") { model.duplicate(session.id, upTo: message.id) }
            }
            .opacity(hovering || isLastAnswer ? 1 : 0)
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private func toolbarButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11 * zoom))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

private struct AIComposer: View {
    @ObservedObject var model: AIChatModel
    @ObservedObject var session: AIChatSession
    @State private var height: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.composerAttachments.isEmpty {
                AIAttachmentChips(attachments: model.composerAttachments) { id in
                    model.composerAttachments.removeAll { $0.id == id }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button("Joindre le presse-papiers") { model.attachClipboard() }
                    Button("Joindre l’onglet du navigateur") { model.attachBrowserTab() }
                    Button("Joindre un fichier texte…") { model.attachFile() }
                } label: {
                    Image(systemName: "paperclip").font(.system(size: 14))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.bottom, 3)
                .help("Joindre du contexte")
                ZStack(alignment: .topLeading) {
                    if model.composerText.isEmpty {
                        Text(session.conversation.messages.isEmpty ? "Écrivez un message…" : "Répondez…")
                            .font(.system(size: 13.5 * model.zoom))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    AIComposerTextView(text: $model.composerText, height: $height, fontSize: 13.5 * model.zoom, focusToken: model.composerFocusToken) {
                        model.send()
                    }
                    .frame(height: min(max(height, 20), 180))
                }
                if session.isGenerating {
                    Button { session.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 22))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Arrêter (Échap)")
                } else {
                    Button { model.send() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.composerAttachments.isEmpty ? Color.secondary.opacity(0.5) : Color.accentColor)
                    .help("Envoyer (↵)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            Text("↵ envoie · ⇧↵ nouvelle ligne · ⌘R régénère · ⌘F cherche")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

// MARK: - Champs AppKit

/// Le compositeur : ↵ envoie, ⇧↵ (ou ⌥↵) ajoute une ligne ; la hauteur suit le texte.
struct AIComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var fontSize: CGFloat
    var focusToken: Int
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let textView = SubmitTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .systemFont(ofSize: fontSize)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.onSubmit = { context.coordinator.parent.onSubmit() }
        textView.string = text
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.updateHeight()
        }
        if textView.font?.pointSize != fontSize {
            textView.font = .systemFont(ofSize: fontSize)
            context.coordinator.updateHeight()
        }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AIComposerTextView
        weak var textView: NSTextView?
        var focusToken = -1

        init(_ parent: AIComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            updateHeight()
        }

        func updateHeight() {
            guard let textView, let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let height = ceil(layout.usedRect(for: container).height) + 6
            DispatchQueue.main.async { [weak self] in
                if abs((self?.parent.height ?? 0) - height) > 0.5 { self?.parent.height = height }
            }
        }
    }

    final class SubmitTextView: NSTextView {
        var onSubmit: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection([.shift, .option, .command, .control])
            if (event.keyCode == 36 || event.keyCode == 76), flags.isEmpty, !hasMarkedText() {
                onSubmit?()
                return
            }
            if (event.keyCode == 36 || event.keyCode == 76), flags == .shift || flags == .option {
                insertNewlineIgnoringFieldEditor(nil)
                return
            }
            super.keyDown(with: event)
        }
    }
}

/// Le champ de recherche dans la conversation : ↵ suivant, ⇧↵ précédent.
private struct AIFindField: NSViewRepresentable {
    @Binding var text: String
    var focusToken: Int
    var onNext: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Chercher dans la conversation"
        field.font = .systemFont(ofSize: 12.5)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AIFindField
        var focusToken = -1

        init(_ parent: AIFindField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onNext(NSEvent.modifierFlags.contains(.shift))
                return true
            }
            return false
        }
    }
}

// MARK: - Markdown à l'échelle

/// Le Markdown des réponses, à la taille du zoom de la fenêtre, avec copie des blocs de code.
struct AIMarkdownView: View {
    let source: String
    var scale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 9 * scale) {
            ForEach(Array(MarkdownBlock.parse(source).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(.system(size: (level == 1 ? 19 : level == 2 ? 16.5 : 14.5) * scale, weight: .semibold))
                .padding(.top, 2)
        case .paragraph(let text):
            inline(text).font(.system(size: 13.5 * scale)).lineSpacing(2.5 * scale)
        case .bullet(let text, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(marker).foregroundStyle(.secondary).font(.system(size: 13.5 * scale))
                inline(text).font(.system(size: 13.5 * scale)).lineSpacing(2 * scale)
            }
            .padding(.leading, 4)
        case .quote(let text):
            HStack(spacing: 9) {
                Rectangle().fill(Color.accentColor.opacity(0.6)).frame(width: 3)
                inline(text).font(.system(size: 13.5 * scale)).foregroundStyle(.secondary)
            }
        case .code(let language, let code):
            AICodeBlock(language: language, code: code, scale: scale)
        case .rule:
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
        }
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}

private struct AICodeBlock: View {
    let language: String
    let code: String
    let scale: CGFloat
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 10.5 * scale, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Pasteboard.copy(code)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    Label(copied ? "Copié" : "Copier", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5 * scale))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05))
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 12 * scale, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
            }
            .scrollIndicators(.never)
        }
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.035)))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
    }
}

// MARK: - Rendu hors écran

extension AIChatWindow {
    /// `Prism --snapshot-chat sortie.png [--light]` : la fenêtre avec une histoire de démonstration.
    static func renderSnapshot(to output: String, dark: Bool) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        AIModelCatalog.shared.loadDemo()
        let now = Date()
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
        var main = AIConversation(title: "Inverser une chaîne en Swift", messages: [
            AIChatMessage(role: .user, content: AIAnswerScreen.demoQuestion, date: ago(0.01)),
            AIChatMessage(role: .assistant, content: AIAnswerScreen.demoAnswer, date: ago(0.01), model: "Claude Opus 5.5"),
            AIChatMessage(role: .user, content: "Et sans utiliser reversed() ?", date: ago(0.005)),
            AIChatMessage(role: .assistant, content: "On peut parcourir les caractères et les ajouter en tête :\n\n```swift\nvar inverse = \"\"\nfor caractere in mot { inverse = String(caractere) + inverse }\n```\n\nC’est plus lent (chaque ajout recopie la chaîne) : préférez `reversed()`.", date: ago(0.004), model: "Claude Opus 5.5"),
        ], created: ago(0.01), updated: ago(0.004))
        main.pinned = false
        let demo: [AIConversation] = [
            main,
            AIConversation(title: "Ordre du jour de la réunion produit", messages: [AIChatMessage(role: .user, content: "Prépare un ordre du jour")], created: ago(0.2), updated: ago(0.2), pinned: true),
            AIConversation(title: "Recette de pâte à crêpes", messages: [AIChatMessage(role: .user, content: "Une recette de crêpes pour 4")], created: ago(1), updated: ago(1)),
            AIConversation(title: "Résumé de l’article sur les puces M5", messages: [AIChatMessage(role: .user, content: "Résume cet article")], created: ago(3), updated: ago(3)),
            AIConversation(title: "Script de sauvegarde rsync", messages: [AIChatMessage(role: .user, content: "Un script rsync")], created: ago(12), updated: ago(12)),
            AIConversation(title: "Traduction de la lettre de motivation", messages: [AIChatMessage(role: .user, content: "Traduis en anglais")], created: ago(45), updated: ago(45)),
        ]
        AIHistory.shared.loadDemo(demo)
        let model = AIChatWindow.shared.model
        model.select(main.id)

        let size = NSSize(width: 1040, height: 700)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)
        let hosting = NSHostingView(rootView: AIChatView(model: model))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 1 }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        do {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        } catch {
            print("Écriture impossible : \(error)")
            return 1
        }
        print("✓ \(output)")
        return 0
    }
}
