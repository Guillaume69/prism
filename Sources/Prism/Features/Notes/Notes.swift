import AppKit
import SwiftUI

/// Raycast Notes : des notes flottantes en Markdown, une fenêtre au-dessus des autres.
@MainActor
enum NotesFeature: PrismFeature {
    static let color = Palette.yellow

    static func start() {
        AppHooks.createNote = { text in createNote(text: text) }
        NotesLibrary.shared.purge()
        NotesMenuBar.update()
        NotificationCenter.default.addObserver(forName: .notesPreferencesDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NotesMenuBar.update() }
        }
    }

    // MARK: - Fenêtre

    static func toggleWindow() {
        NotesWindowController.shared.toggle()
    }

    static func showWindow() {
        NotesWindowController.shared.show()
    }

    /// Crée une note (vide, ou avec ce texte) et l'affiche dans la fenêtre.
    static func createNote(text: String = "") {
        let controller = NotesWindowController.shared
        controller.show()
        controller.newNote(text: text)
    }

    static func open(_ id: UUID) {
        let controller = NotesWindowController.shared
        controller.show()
        controller.open(id)
    }

    /// Supprime une note depuis le lanceur, en prévenant la fenêtre si elle l'affiche.
    static func delete(_ id: UUID) {
        NotesLibrary.shared.delete(id)
        NotesWindowController.existing?.noteRemoved(id)
    }

    static func showDeletedInLauncher() {
        guard let launcher = AppContext.launcher else { return }
        launcher.show(reset: true)
        launcher.model.push(deletedScreen())
    }

    // MARK: - Commandes

    static var commands: [ResultItem] {
        [
            Command.run("notes", "Notes", subtitle: "Notes", symbol: "note.text", color: color,
                        keywords: ["raycast notes", "floating notes", "notes flottantes", "bloc-notes", "toggle notes"]) {
                toggleWindow()
                return .close
            },
            Command.run("notes.create", "Créer une note", subtitle: "Notes", symbol: "square.and.pencil", color: color,
                        keywords: ["create note", "new note", "nouvelle note"]) {
                createNote()
                return .close
            },
            Command.screen("notes.search", "Rechercher des notes", subtitle: "Notes", symbol: "magnifyingglass", color: color,
                           keywords: ["search notes", "browse notes", "parcourir les notes"], screen: searchScreen),
            Command.screen("notes.deleted", "Notes récemment supprimées", subtitle: "Notes", symbol: "trash", color: color,
                           keywords: ["recently deleted notes", "corbeille", "restaurer une note"], screen: deletedScreen),
        ]
    }

    // MARK: - Écrans du lanceur

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let fullDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let copyMarkdown = KeyShortcut(keyCode: 8, modifiers: [.command, .option], label: "C")
    static let export = KeyShortcut(keyCode: 14, modifiers: [.command, .shift], label: "E")

    static func searchScreen() -> LauncherScreen {
        ListScreen(
            id: "notes.search",
            title: "Rechercher des notes",
            placeholder: "Rechercher dans les notes…",
            icon: .symbol("note.text", color),
            layout: .split(listWidth: 290),
            empty: { query in
                query.isEmpty
                    ? ("note.text", "Aucune note pour l’instant.\n⌘N pour en créer une.")
                    : ("magnifyingglass", "Aucune note ne contient « \(query) »")
            },
            sections: searchSections
        )
    }

    static func searchSections(query: String) -> [ResultSection] {
        let library = NotesLibrary.shared
        let normalized = query.normalizedForSearch
        let notes = library.browsable.filter { note in
            !note.isEmpty && (normalized.isEmpty || note.text.normalizedForSearch.contains(normalized) || Fuzzy.score(normalized, note.title) != nil)
        }
        let pinned = notes.filter(\.isPinned).map(item)
        let others = notes.filter { !$0.isPinned }.map(item)
        return [
            ResultSection(id: "notes.pinned", title: "Épinglées", items: pinned),
            ResultSection(id: "notes.all", title: query.isEmpty ? "Récentes" : "Résultats", items: others),
        ].filter { !$0.items.isEmpty }
    }

    private static func metadata(_ note: Note) -> [(label: String, value: String)] {
        [
            ("Modifiée", fullDate.string(from: note.modified)),
            ("Créée", fullDate.string(from: note.created)),
            ("Mots", "\(note.wordCount)"),
            ("Caractères", "\(note.text.count)"),
        ]
    }

    private static func item(_ note: Note) -> ResultItem {
        let library = NotesLibrary.shared
        return ResultItem(
            id: "note:" + note.id.uuidString,
            title: note.title,
            icon: note.isPinned ? .tinted("pin.fill", Palette.orange) : .tinted("note.text", color),
            accessory: relative.localizedString(for: note.modified, relativeTo: Date()),
            keywords: [note.text],
            detail: ItemDetail(text: NotesMarkdown.previewMarkdown(note.text), metadata: metadata(note), isMarkdown: true),
            usageKey: "",
            actions: [
                ItemAction(title: "Ouvrir dans la fenêtre des notes", symbol: "macwindow") {
                    open(note.id)
                    return .close
                },
                ItemAction(title: "Copier le texte", symbol: "doc.on.doc", shortcut: .copyText) {
                    Pasteboard.copy(NotesMarkdown.plainText(note.text))
                    return .hud("Texte copié")
                },
                ItemAction(title: "Copier en Markdown", symbol: "text.badge.checkmark", shortcut: copyMarkdown) {
                    Pasteboard.copy(note.text)
                    return .hud("Markdown copié")
                },
                ItemAction(title: note.isPinned ? "Désépingler la note" : "Épingler la note", symbol: note.isPinned ? "pin.slash" : "pin", shortcut: .pin) {
                    library.togglePin(note.id)
                    return .refresh
                },
                ItemAction(title: "Créer une note", symbol: "square.and.pencil", shortcut: .create) {
                    createNote()
                    return .close
                },
                ItemAction(title: "Exporter en Markdown…", symbol: "square.and.arrow.up", shortcut: export, section: "Exporter") {
                    NotesExport.choose(notes: [note])
                    return .close
                },
                ItemAction(title: "Exporter toutes les notes…", symbol: "square.and.arrow.up.on.square", section: "Exporter") {
                    NotesExport.choose(notes: library.active.filter { !$0.isEmpty })
                    return .close
                },
                ItemAction(title: "Supprimer la note", symbol: "trash", shortcut: .removeEntry, isDestructive: true, section: "Supprimer") {
                    delete(note.id)
                    return .refresh
                },
                ItemAction(title: "Supprimer toutes les notes", symbol: "trash.slash", shortcut: .removeAll, isDestructive: true, section: "Supprimer") {
                    for note in library.active { delete(note.id) }
                    return .refresh
                },
            ]
        )
    }

    static func deletedScreen() -> LauncherScreen {
        let screen = ListScreen(
            id: "notes.deleted",
            title: "Notes récemment supprimées",
            placeholder: "Rechercher dans les notes supprimées…",
            icon: .symbol("trash", color),
            layout: .split(listWidth: 290),
            empty: { query in
                query.isEmpty
                    ? ("trash", "Aucune note supprimée.\nLes notes supprimées restent ici 30 jours.")
                    : ("magnifyingglass", "Aucune note supprimée ne contient « \(query) »")
            },
            sections: deletedSections
        )
        screen.onAppear = { NotesLibrary.shared.purge() }
        return screen
    }

    static func deletedSections(query: String) -> [ResultSection] {
        let library = NotesLibrary.shared
        let normalized = query.normalizedForSearch
        let items = library.deleted
            .filter { normalized.isEmpty || $0.text.normalizedForSearch.contains(normalized) }
            .map { note -> ResultItem in
                let days = NotesLibrary.daysLeft(note)
                return ResultItem(
                    id: "note.deleted:" + note.id.uuidString,
                    title: note.title,
                    subtitle: nil,
                    icon: .tinted("note.text", Palette.gray),
                    accessory: days <= 1 ? "Effacée demain" : "Encore \(days) j",
                    detail: ItemDetail(
                        text: NotesMarkdown.previewMarkdown(note.text),
                        metadata: [("Supprimée", note.deleted.map { fullDate.string(from: $0) } ?? "—"), ("Effacement définitif", days <= 1 ? "Demain" : "Dans \(days) jours")] + metadata(note),
                        isMarkdown: true
                    ),
                    usageKey: "",
                    actions: [
                        ItemAction(title: "Restaurer la note", symbol: "arrow.uturn.backward") {
                            library.restore(note.id)
                            return .refresh
                        },
                        ItemAction(title: "Restaurer et ouvrir", symbol: "macwindow") {
                            library.restore(note.id)
                            open(note.id)
                            return .close
                        },
                        ItemAction(title: "Copier le texte", symbol: "doc.on.doc", shortcut: .copyText) {
                            Pasteboard.copy(NotesMarkdown.plainText(note.text))
                            return .hud("Texte copié")
                        },
                        ItemAction(title: "Supprimer définitivement", symbol: "trash", shortcut: .removeEntry, isDestructive: true) {
                            library.deletePermanently(note.id)
                            return .refresh
                        },
                        ItemAction(title: "Vider « Récemment supprimées »", symbol: "trash.slash", shortcut: .removeAll, isDestructive: true) {
                            library.emptyTrash()
                            return .refresh
                        },
                    ]
                )
            }
        return items.isEmpty ? [] : [ResultSection(id: "notes.deleted", title: "Supprimées", items: items)]
    }

    // MARK: - Réglages

    static var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "notes", title: "Notes", symbol: "note.text", color: color, order: 45) { AnyView(NotesSettingsView()) }]
    }

    // MARK: - Liens profonds

    /// `prism://notes/new?text=…`, `prism://notes/toggle`, `prism://notes/open`, `prism://notes/search`.
    static func handle(url: URL) -> Bool {
        guard url.host == "notes" else { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.path {
        case "/new", "/create":
            createNote(text: query.first { $0.name == "text" }?.value ?? "")
        case "", "/", "/toggle":
            toggleWindow()
        case "/open":
            if let id = query.first(where: { $0.name == "id" })?.value.flatMap(UUID.init(uuidString:)) {
                open(id)
            } else {
                showWindow()
            }
        case "/search":
            guard let launcher = AppContext.launcher else { return true }
            launcher.show(reset: true)
            launcher.model.push(searchScreen(), query: query.first { $0.name == "q" }?.value ?? "")
        default:
            return false
        }
        return true
    }

    // MARK: - Autotests

    static func selfTest(_ check: (Bool, String) -> Void) {
        check(NotesLibrary.isSandboxed, "notes en mémoire pendant les autotests")

        check(Note.title(of: "\n  # Courses de la semaine\n- pain") == "Courses de la semaine", "titre : première ligne, sans « # »")
        check(Note.title(of: "**Réunion** avec _Paul_ et [Marie](https://x.fr)") == "Réunion avec Paul et Marie", "titre : sans la syntaxe en ligne")
        check(Note.title(of: "- [ ] Appeler le garage") == "Appeler le garage", "titre : tâche sans sa case")
        check(Note.title(of: "  \n\n") == Note.untitled, "titre : note vide")

        check(NotesMarkdown.toggledTask("- [ ] Pain") == "- [x] Pain", "tâche cochée")
        check(NotesMarkdown.toggledTask("  * [X] Café") == "  * [ ] Café", "tâche décochée, indentation gardée")
        check(NotesMarkdown.toggledTask("Tomates") == "- [ ] Tomates", "une ligne devient une tâche")
        check(NotesMarkdown.toggledTask("- Comté") == "- [ ] Comté", "une puce devient une tâche")

        let sample = "# Titre\n## Sous-titre\nTexte\n- puce\n1. un\n- [ ] à faire\n- [x] fait\n> citation\n```swift\nlet a = 1\n```\n---\n"
        let expected: [NoteLineKind] = [.heading(level: 1), .heading(level: 2), .paragraph, .bullet, .ordered(number: 1), .task(checked: false),
                                        .task(checked: true), .quote, .fence, .code, .fence, .rule, .blank]
        check(NotesMarkdown.kinds(of: sample) == expected, "styles de bloc reconnus ligne par ligne")
        check(NotesMarkdown.kinds(of: "```\n# pas un titre\n- pas une puce\n```") == [.fence, .code, .code, .fence], "rien n’est stylé dans un bloc de code")
        check(NotesMarkdown.kinds(of: "#hashtag") == [.paragraph], "« #mot » n’est pas un titre")

        let inline = NotesMarkdown.inlineKinds("**gras** et *italique* ~~barré~~ <u>souligné</u> `code` [lien](https://raycast.com)")
        check(inline.contains(.bold) && inline.contains(.italic) && inline.contains(.strike) && inline.contains(.underline)
              && inline.contains(.code) && inline.contains(.link("https://raycast.com")), "styles en ligne reconnus")
        check(NotesMarkdown.inlineKinds("`**pas gras**`") == [.code], "pas de gras dans du code en ligne")
        check(NotesMarkdown.inlineKinds("2 * 3 * 4") == [], "des étoiles isolées ne font pas d’italique")
        check(NotesMarkdown.inlineKinds("voir https://example.com/page.") == [.link("https://example.com/page")], "lien nu reconnu, sans le point final")
        check(NotesMarkdown.plainText("# Titre\n- [x] fait\n**gras**") == "Titre\n☑ fait\ngras", "copie en texte brut")

        check(NotesMarkdown.continuation(for: "- [x] fait") == .prefix("- [ ] "), "Entrée après une tâche : nouvelle tâche décochée")
        check(NotesMarkdown.continuation(for: "  3. trois") == .prefix("  4. "), "Entrée dans une liste numérotée : numéro suivant")
        check(NotesMarkdown.continuation(for: "- ") == .endList, "Entrée sur une puce vide : sortie de la liste")
        check(NotesMarkdown.continuation(for: "Texte") == nil, "Entrée dans un paragraphe : rien d’ajouté")
        check(NotesMarkdown.apply(.bullet, to: ["a", "b"]) == ["- a", "- b"], "liste à puces appliquée")
        check(NotesMarkdown.apply(.bullet, to: ["- a", "- b"]) == ["a", "b"], "liste à puces retirée")
        check(NotesMarkdown.apply(.heading2, to: ["# Titre"]) == ["## Titre"], "titre 1 changé en titre 2")
        check(NotesMarkdown.apply(.ordered, to: ["a", "b", "c"]) == ["1. a", "2. b", "3. c"], "liste numérotée")

        var history = NotesHistory()
        let (a, b, c, d) = (UUID(), UUID(), UUID(), UUID())
        history.visit(a)
        history.visit(b)
        history.visit(c)
        check(history.back() == b && history.back() == a && !history.canGoBack, "historique : précédent")
        check(history.forward() == b && history.canGoForward, "historique : suivant")
        history.visit(d)
        check(!history.canGoForward && history.current == d, "historique : une nouvelle note efface la suite")
        history.remove(b)
        check(history.entries == [a, d] && history.current == d, "historique : note supprimée retirée")

        let now = Date()
        var old = Note(text: "ancienne", date: now.addingTimeInterval(-86_400 * 40))
        old.deleted = now.addingTimeInterval(-86_400 * 31)
        var recent = Note(text: "récente", date: now.addingTimeInterval(-86_400 * 10))
        recent.deleted = now.addingTimeInterval(-86_400 * 5)
        let kept = Note(text: "gardée", date: now)
        let library = NotesLibrary(notes: [old, recent, kept])
        library.purge(now: now)
        check(library.data.notes.map(\.id) == [recent.id, kept.id], "purge des notes supprimées depuis plus de 30 jours")
        check(NotesLibrary.daysLeft(recent, now: now) == 25, "jours restants avant l’effacement")
        library.delete(kept.id, now: now)
        check(library.active.isEmpty && library.deleted.count == 2, "suppression vers « Récemment supprimées »")
        library.restore(kept.id, now: now)
        check(library.active.map(\.id) == [kept.id], "restauration")
        let empty = library.create(text: "  ")
        library.delete(empty.id)
        check(library.note(empty.id) == nil, "une note vide supprimée ne va pas dans la corbeille")
        library.togglePin(kept.id)
        check(library.pinned.map(\.id) == [kept.id], "épinglage")
        check(NotesExport.fileName(for: Note(text: "# Compte rendu 1/2 : budget")) == "Compte rendu 1-2 - budget", "nom de fichier de l’export")
    }
}

// MARK: - Barre des menus

/// Bouton facultatif de la barre des menus : clic pour afficher ou masquer les notes, clic droit pour un menu.
@MainActor
enum NotesMenuBar {
    private static var item: NSStatusItem?
    private static let target = NotesMenuBarTarget()

    static func update() {
        guard !NotesLibrary.isSandboxed else { return }
        if NotesPreferences.shared.showInMenuBar {
            guard item == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Notes")
            image?.isTemplate = true
            item.button?.image = image
            item.button?.toolTip = "Notes de Prism"
            item.button?.target = target
            item.button?.action = #selector(NotesMenuBarTarget.clicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            self.item = item
        } else if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    fileprivate static func showMenu() {
        guard let item, let button = item.button else { return }
        let menu = NSMenu()
        menu.addItem(NotesMenuItem(title: "Afficher les notes") { NotesFeature.showWindow() })
        menu.addItem(NotesMenuItem(title: "Nouvelle note") { NotesFeature.createNote() })
        let recent = NotesLibrary.shared.browsable.filter { !$0.isEmpty }.prefix(8)
        if !recent.isEmpty {
            menu.addItem(.separator())
            for note in recent {
                let entry = NotesMenuItem(title: note.title) { NotesFeature.open(note.id) }
                entry.image = NSImage(systemSymbolName: note.isPinned ? "pin.fill" : "note.text", accessibilityDescription: nil)
                menu.addItem(entry)
            }
        }
        menu.addItem(.separator())
        menu.addItem(NotesMenuItem(title: "Réglages des notes…") {
            NotificationCenter.default.post(name: .prismOpenSettings, object: "notes")
        })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }
}

private final class NotesMenuBarTarget: NSObject {
    @objc func clicked(_ sender: Any?) {
        MainActor.assumeIsolated {
            let event = NSApp.currentEvent
            if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
                NotesMenuBar.showMenu()
            } else {
                NotesFeature.toggleWindow()
            }
        }
    }
}

// MARK: - Réglages

struct NotesSettingsView: View {
    @ObservedObject private var preferences = NotesPreferences.shared
    @ObservedObject private var library = NotesLibrary.shared

    var body: some View {
        Form {
            Section("Fenêtre") {
                Toggle("Afficher un bouton dans la barre des menus", isOn: $preferences.showInMenuBar)
                Toggle("Échap retire le focus au lieu de fermer la fenêtre", isOn: $preferences.escapeUnfocuses)
                Toggle("Afficher la barre de format", isOn: $preferences.showFormatBar)
            }
            Section("Texte") {
                Picker("Police", selection: $preferences.font) {
                    ForEach(NotesPreferences.FontChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent("Zoom") {
                    HStack(spacing: 8) {
                        Slider(value: $preferences.zoom, in: NotesPreferences.zoomRange, step: 0.1)
                            .frame(width: 180)
                        Text("\(Int((preferences.zoom * 100).rounded())) %")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                        Button("Réinitialiser") { preferences.resetZoom() }
                            .disabled(preferences.zoom == 1)
                    }
                }
            }
            Section {
                LabeledContent("Notes") {
                    Text(summary).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Ouvrir les notes") { NotesFeature.showWindow() }
                    Button("Vider « Récemment supprimées »") { library.emptyTrash() }
                        .disabled(library.deleted.isEmpty)
                }
            } header: {
                Text("Données")
            } footer: {
                Text("Les notes sont enregistrées en Markdown sur ce Mac. Les notes supprimées restent 30 jours dans « Récemment supprimées ».")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("Raccourcis de la fenêtre") {
                shortcut("⌘N", "Nouvelle note")
                shortcut("⌘P", "Parcourir les notes")
                shortcut("⌘[  ⌘]", "Note précédente, note suivante")
                shortcut("⇧⌘P", "Épingler ; ⌘1 à ⌘9 ouvrent les notes épinglées")
                shortcut("⌘K", "Actions")
                shortcut("⌘↵", "Cocher ou décocher une tâche")
                shortcut("⌘B  ⌘I  ⌘U  ⇧⌘X", "Gras, italique, souligné, barré")
                shortcut("⌘E  ⌘L", "Code, lien (⌘-clic pour l’ouvrir)")
                shortcut("/  :", "Menu de mise en forme, emojis")
                shortcut("⌘+  ⌘-  ⌘0", "Zoom")
                shortcut("⌘⌫", "Supprimer la note")
            }
        }
        .formStyle(.grouped)
    }

    private var summary: String {
        let active = library.active.filter { !$0.isEmpty }.count
        let pinned = library.pinned.count
        let deleted = library.deleted.count
        let notes = active == 1 ? "1 note" : "\(active) notes"
        return "\(notes), \(pinned) épinglée\(pinned > 1 ? "s" : ""), \(deleted) supprimée\(deleted > 1 ? "s" : "")"
    }

    private func shortcut(_ keys: String, _ label: String) -> some View {
        LabeledContent(label) {
            Text(keys)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Rendu hors écran

/// `Prism --snapshot-notes sortie.png [--light] [--browse] [--slash] [--emoji] [--no-format] [--width L] [--height H]` :
/// la fenêtre des notes rendue en PNG, avec des notes d'exemple en mémoire.
@MainActor
enum NotesSnapshot {
    static func run(arguments: [String]) -> Int32 {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let output = value("--snapshot-notes") else { return 1 }
        let dark = !arguments.contains("--light")
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        let size = NSSize(width: Double(value("--width") ?? "") ?? 460, height: Double(value("--height") ?? "") ?? 640)
        let library = NotesLibrary(notes: NotesSamples.notes())
        let controller = NotesWindowController(library: library, theme: dark ? .prismDark : .prismLight)
        controller.state.showFormatBar = !arguments.contains("--no-format")
        controller.prepareForSnapshot(size: size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        if arguments.contains("--slash") {
            let end = (controller.textView.string as NSString).length
            controller.simulateTyping("\n\n/ti", at: end)
            controller.textView.scrollToEndOfDocument(nil)
        } else if arguments.contains("--emoji") {
            let end = (controller.textView.string as NSString).length
            controller.simulateTyping("\n\nBravo :coe", at: end)
            controller.textView.scrollToEndOfDocument(nil)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        if arguments.contains("--slash") || arguments.contains("--emoji") { controller.updatePopup() }
        if arguments.contains("--browse") {
            controller.openBrowse()
            controller.moveBrowseSelection(1)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        guard let view = controller.panel.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 1 }
        view.cacheDisplay(in: view.bounds, to: bitmap)

        // La fenêtre sur un fond coloré, avec ses coins arrondis et son ombre.
        let margin: CGFloat = 50
        let canvas = NSSize(width: size.width + margin * 2, height: size.height + margin * 2)
        let image = NSImage(size: canvas, flipped: false) { rect in
            let gradient = NSGradient(colors: dark
                ? [NSColor(srgbRed: 0.16, green: 0.20, blue: 0.33, alpha: 1), NSColor(srgbRed: 0.36, green: 0.18, blue: 0.30, alpha: 1)]
                : [NSColor(srgbRed: 0.62, green: 0.74, blue: 0.92, alpha: 1), NSColor(srgbRed: 0.93, green: 0.78, blue: 0.84, alpha: 1)])
            gradient?.draw(in: rect, angle: -35)
            let frame = NSRect(x: margin, y: margin, width: size.width, height: size.height)
            let path = NSBezierPath(roundedRect: frame, xRadius: 11, yRadius: 11)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = NSSize(width: 0, height: -8)
            shadow.set()
            NSColor.black.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            bitmap.draw(in: frame)
            NSGraphicsContext.restoreGraphicsState()
            NSColor(white: dark ? 1 : 0, alpha: dark ? 0.14 : 0.12).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return 1 }
        do {
            try png.write(to: URL(fileURLWithPath: output))
        } catch {
            print("Écriture impossible : \(error)")
            return 1
        }
        print("✓ \(output)")
        return 0
    }
}
