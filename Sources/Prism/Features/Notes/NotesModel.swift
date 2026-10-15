import AppKit

/// Une note : du Markdown, comme dans Raycast Notes. Le titre est sa première ligne.
struct Note: Codable, Identifiable, Equatable {
    var id: UUID
    var text: String
    var created: Date
    var modified: Date
    /// Date d'épinglage : les notes épinglées gardent l'ordre où on les a épinglées (⌘1 à ⌘9).
    var pinned: Date?
    /// Date de suppression : la note attend dans « Récemment supprimées ».
    var deleted: Date?

    init(id: UUID = UUID(), text: String = "", date: Date = Date()) {
        self.id = id
        self.text = text
        created = date
        modified = date
    }

    var title: String { Note.title(of: text) }
    var isPinned: Bool { pinned != nil }
    var isDeleted: Bool { deleted != nil }
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    static let untitled = "Note sans titre"

    /// La première ligne non vide, débarrassée de la syntaxe Markdown.
    static func title(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .lazy
            .map { NotesMarkdown.plainLine(String($0), boxes: false) }
            .first { !$0.isEmpty }
        guard let line else { return untitled }
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }

    /// Un extrait de ce qui suit le titre, pour les listes.
    var excerpt: String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { NotesMarkdown.plainLine(String($0)) }
            .filter { !$0.isEmpty }
        return lines.dropFirst().prefix(3).joined(separator: " · ")
    }

    var wordCount: Int {
        text.split { $0.isWhitespace || $0.isNewline }.filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }
}

/// L'historique de navigation de la fenêtre des notes (⌘[ et ⌘]), comme celui d'un navigateur.
struct NotesHistory: Equatable {
    private(set) var entries: [UUID] = []
    private(set) var index = -1

    var current: UUID? { entries.indices.contains(index) ? entries[index] : nil }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < entries.count }

    /// Ouvre une note : l'historique « suivant » est abandonné.
    mutating func visit(_ id: UUID) {
        guard current != id else { return }
        if index + 1 < entries.count { entries.removeSubrange((index + 1)...) }
        entries.append(id)
        if entries.count > 100 { entries.removeFirst(entries.count - 100) }
        index = entries.count - 1
    }

    mutating func back() -> UUID? {
        guard canGoBack else { return nil }
        index -= 1
        return current
    }

    mutating func forward() -> UUID? {
        guard canGoForward else { return nil }
        index += 1
        return current
    }

    /// Retire une note supprimée ; deux entrées voisines identiques fusionnent.
    mutating func remove(_ id: UUID) {
        var kept: [UUID] = []
        var newIndex = -1
        for (position, entry) in entries.enumerated() {
            if entry != id, kept.last != entry { kept.append(entry) }
            if position <= index { newIndex = kept.count - 1 }
        }
        entries = kept
        index = kept.isEmpty ? -1 : max(0, newIndex)
    }
}

/// Le contenu de `notes.json`.
struct NotesData: Codable, Equatable {
    var notes: [Note] = []
    /// La note affichée par la fenêtre, retrouvée à la réouverture.
    var currentID: UUID?
}

/// Les notes, gardées en Markdown dans `notes.json`. La sauvegarde attend une pause dans la frappe.
@MainActor
final class NotesLibrary: ObservableObject {
    /// Les rendus hors écran et les autotests travaillent sur des notes en mémoire,
    /// sans jamais lire ni écrire celles de l'utilisateur.
    static let isSandboxed = CommandLine.arguments.contains { $0.hasPrefix("--snapshot") || $0 == "--selftest" }

    static let shared: NotesLibrary = isSandboxed ? NotesLibrary(notes: NotesSamples.notes()) : NotesLibrary(fileName: "notes.json")

    /// Délai de conservation des notes supprimées.
    static let retention: TimeInterval = 30 * 24 * 3600

    @Published private(set) var data: NotesData

    private let store: JSONStore<NotesData>?
    private var saveWork: DispatchWorkItem?

    /// Notes persistées dans Application Support.
    init(fileName: String) {
        let store = JSONStore(fileName, default: NotesData())
        self.store = store
        data = store.value
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    /// Notes en mémoire seulement (autotests, rendus).
    init(notes: [Note]) {
        store = nil
        data = NotesData(notes: notes, currentID: notes.first?.id)
    }

    // MARK: - Lecture

    /// Les notes en vigueur, de la plus récemment modifiée à la plus ancienne.
    var active: [Note] {
        data.notes.filter { !$0.isDeleted }.sorted { $0.modified > $1.modified }
    }

    /// Les notes épinglées, dans l'ordre d'épinglage.
    var pinned: [Note] {
        data.notes.filter { !$0.isDeleted && $0.isPinned }.sorted { ($0.pinned ?? .distantPast) < ($1.pinned ?? .distantPast) }
    }

    /// Épinglées d'abord, puis les autres par date.
    var browsable: [Note] {
        pinned + active.filter { !$0.isPinned }
    }

    var deleted: [Note] {
        data.notes.filter(\.isDeleted).sorted { ($0.deleted ?? .distantPast) > ($1.deleted ?? .distantPast) }
    }

    func note(_ id: UUID?) -> Note? {
        guard let id else { return nil }
        return data.notes.first { $0.id == id }
    }

    var currentID: UUID? {
        get { data.currentID }
        set { mutate(save: .soon) { $0.currentID = newValue } }
    }

    // MARK: - Écriture

    enum SaveTiming {
        /// Après une pause dans la frappe.
        case debounced
        /// Au prochain tour : création, suppression, épinglage.
        case soon
    }

    private func mutate(save timing: SaveTiming, _ change: (inout NotesData) -> Void) {
        var copy = data
        change(&copy)
        guard copy != data else { return }
        data = copy
        scheduleSave(timing)
    }

    @discardableResult
    func create(text: String = "", now: Date = Date()) -> Note {
        let note = Note(text: text, date: now)
        mutate(save: .soon) { $0.notes.append(note) }
        return note
    }

    func update(_ id: UUID, text: String, now: Date = Date()) {
        mutate(save: .debounced) { data in
            guard let index = data.notes.firstIndex(where: { $0.id == id }), data.notes[index].text != text else { return }
            data.notes[index].text = text
            data.notes[index].modified = now
        }
    }

    func togglePin(_ id: UUID, now: Date = Date()) {
        mutate(save: .soon) { data in
            guard let index = data.notes.firstIndex(where: { $0.id == id }) else { return }
            data.notes[index].pinned = data.notes[index].pinned == nil ? now : nil
        }
    }

    /// Place la note dans « Récemment supprimées ».
    func delete(_ id: UUID, now: Date = Date()) {
        mutate(save: .soon) { data in
            guard let index = data.notes.firstIndex(where: { $0.id == id }) else { return }
            if data.notes[index].isEmpty {
                // Une note vide ne mérite pas la corbeille.
                data.notes.remove(at: index)
            } else {
                data.notes[index].deleted = now
                data.notes[index].pinned = nil
            }
        }
    }

    /// Toutes les notes vont dans « Récemment supprimées ».
    func deleteAll(now: Date = Date()) {
        for note in active { delete(note.id, now: now) }
    }

    func restore(_ id: UUID, now: Date = Date()) {
        mutate(save: .soon) { data in
            guard let index = data.notes.firstIndex(where: { $0.id == id }) else { return }
            data.notes[index].deleted = nil
            data.notes[index].modified = now
        }
    }

    func deletePermanently(_ id: UUID) {
        mutate(save: .soon) { $0.notes.removeAll { $0.id == id } }
    }

    func emptyTrash() {
        mutate(save: .soon) { $0.notes.removeAll(where: \.isDeleted) }
    }

    /// Efface pour de bon les notes supprimées depuis plus de 30 jours.
    func purge(now: Date = Date()) {
        mutate(save: .soon) { data in
            data.notes.removeAll { note in
                guard let deleted = note.deleted else { return false }
                return now.timeIntervalSince(deleted) > NotesLibrary.retention
            }
        }
    }

    /// Jours restant avant l'effacement définitif.
    static func daysLeft(_ note: Note, now: Date = Date()) -> Int {
        guard let deleted = note.deleted else { return 30 }
        return max(0, Int(ceil((retention - now.timeIntervalSince(deleted)) / 86_400)))
    }

    // MARK: - Sauvegarde

    private func scheduleSave(_ timing: SaveTiming) {
        guard store != nil else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.commit() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (timing == .debounced ? 0.6 : 0.05), execute: work)
    }

    /// Passe les notes au `JSONStore`, qui les écrit et prévient le lanceur.
    private func commit() {
        guard let store, store.value != data else { return }
        store.value = data
    }

    /// Écrit tout de suite (fermeture de la fenêtre, fin de l'application).
    func flush() {
        saveWork?.cancel()
        commit()
        store?.flush()
    }
}

/// Des notes d'exemple, pour les rendus hors écran et les autotests.
enum NotesSamples {
    static let rich = """
    # Lancement de Prism 2.0

    Notes de la réunion du **mardi 14 octobre**, avec _l’équipe produit_.

    ## À faire avant vendredi
    - [x] Finaliser la fenêtre des notes
    - [x] Relire les textes de l’interface
    - [ ] Préparer la ~~démo~~ présentation
    - [ ] Publier la <u>version bêta</u>

    ## Points clés
    1. Rapidité : tout doit s’ouvrir en `< 50 ms`
    2. Le Markdown reste du texte, simplement mis en forme
    - Détails sur [le site de Raycast](https://www.raycast.com)

    > Une bonne note se relit en dix secondes.

    ```swift
    let note = NotesLibrary.shared.create(text: "Bonjour")
    print(note.title)
    ```

    ---

    Prochaine réunion : jeudi à 10 h.
    """

    static func notes(now: Date = Date()) -> [Note] {
        var first = Note(text: rich, date: now.addingTimeInterval(-600))
        first.modified = now.addingTimeInterval(-120)
        var groceries = Note(text: "Courses\n- [ ] Pain\n- [x] Café\n- [ ] Tomates\n- [ ] Comté", date: now.addingTimeInterval(-86_400 * 2))
        groceries.pinned = now.addingTimeInterval(-86_400)
        var ideas = Note(text: "## Idées d’articles\n- Les raccourcis qui changent tout\n- Écrire en *Markdown* sans y penser\n- Notes flottantes et concentration", date: now.addingTimeInterval(-86_400 * 5))
        ideas.modified = now.addingTimeInterval(-3_600 * 5)
        let book = Note(text: "Livres à lire\n1. *L’Art de la simplicité*\n2. Deep Work\n3. Le Petit Prince", date: now.addingTimeInterval(-86_400 * 9))
        var removed = Note(text: "Brouillon abandonné\nQuelques idées en vrac.", date: now.addingTimeInterval(-86_400 * 12))
        removed.deleted = now.addingTimeInterval(-86_400 * 3)
        return [first, groceries, ideas, book, removed]
    }
}
