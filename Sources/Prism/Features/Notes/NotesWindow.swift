import AppKit
import Combine
import SwiftUI

/// La fenêtre flottante des notes : au-dessus des autres, sur tous les Spaces, sans voler
/// l'activation à l'application de premier plan.
final class NotesPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        title = "Notes"
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        minSize = NSSize(width: 340, height: 260)
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Ce que la barre d'outils, la barre de format et les menus affichent.
@MainActor
final class NotesWindowState: ObservableObject {
    @Published var title = Note.untitled
    @Published var isPinned = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var wordCount = 0
    @Published var browsing = false
    @Published var browseQuery = ""
    @Published var browseSelection: UUID?
    @Published var popup: NotesPopup?
    @Published var confirmDeleteAll = false
    @Published var toast: String?
    @Published var showFormatBar: Bool
    @Published var style: NotesStyle

    init(style: NotesStyle, showFormatBar: Bool) {
        self.style = style
        self.showFormatBar = showFormatBar
    }
}

/// Le menu qui s'ouvre en tapant « / » en début de ligne, ou « : » suivi d'un mot (emojis).
struct NotesPopup: Equatable {
    enum Kind { case slash, emoji }

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        var symbol: String?
        var emoji: String?
        var hint: String = ""
        var block: NoteBlockStyle?
    }

    var kind: Kind
    /// « /requête » ou « :requête », remplacé par le choix.
    var range: NSRange
    var items: [Item]
    var selected = 0
    /// Sous le curseur, dans le repère de la fenêtre (origine en haut à gauche).
    var anchor: CGPoint
}

/// Les mises en forme de la barre de format et des raccourcis.
enum NotesFormat {
    case bold, italic, strike, underline, code, link
    case block(NoteBlockStyle)
    case toggleTask
}

@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate, NSTextStorageDelegate {
    private static var instance: NotesWindowController?

    /// La fenêtre de l'application, créée à la première ouverture.
    static var shared: NotesWindowController {
        if let instance { return instance }
        let controller = NotesWindowController(library: .shared)
        instance = controller
        return controller
    }

    /// La fenêtre si elle a déjà été créée.
    static var existing: NotesWindowController? { instance }

    let library: NotesLibrary
    let state: NotesWindowState
    let panel: NotesPanel
    let textView: NotesTextView
    let scrollView: NSScrollView
    private var hosting: NSHostingView<NotesWindowView>?
    private(set) var currentID: UUID?
    private(set) var history = NotesHistory()
    private var selections: [UUID: NSRange] = [:]
    private var keyMonitor: Any?
    private let theme: PrismTheme?
    private var isLoading = false
    /// Le menu « / » ou « : » fermé par Échap reste fermé tant qu'on reste sur le même mot.
    private var dismissedPopupLocation: Int?
    private var toastWork: DispatchWorkItem?
    private var subscriptions: Set<AnyCancellable> = []
    weak var browseField: NSTextField?

    var isVisible: Bool { panel.isVisible }

    init(library: NotesLibrary, theme: PrismTheme? = nil) {
        self.library = library
        self.theme = theme
        let preferences = NotesPreferences.shared
        state = NotesWindowState(style: NotesStyle.current(theme: theme), showFormatBar: preferences.showFormatBar)
        panel = NotesPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 540))
        textView = NotesTextView.make()
        scrollView = NSScrollView()
        super.init()

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.contentView.drawsBackground = false
        textView.delegate = self
        textView.textStorage?.delegate = self
        textView.onToggleCheckbox = { [weak self] index in self?.toggleCheckbox(at: index) }
        textView.onOpenLink = { url in
            guard let target = URL(string: url.contains("://") || url.hasPrefix("mailto:") ? url : "https://" + url) else { return }
            NSWorkspace.shared.open(target)
        }

        let hosting = NSHostingView(rootView: NotesWindowView(state: state, controller: self))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.hosting = hosting
        panel.delegate = self
        applyStyle()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.panel else { return event }
                return self.handleKey(event) ? nil : event
            }
        }
        let center = NotificationCenter.default
        center.addObserver(forName: .notesPreferencesDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyStyle() }
        }
        center.addObserver(forName: .prismThemeDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyStyle() }
        }
        NotesPreferences.shared.$showFormatBar
            .sink { [weak self] value in self?.state.showFormatBar = value }
            .store(in: &subscriptions)
        library.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshChrome() } }
            .store(in: &subscriptions)
    }

    // MARK: - Ouverture

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        if !panel.isVisible { placeWindow() }
        ensureNote()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        if !state.browsing { panel.makeFirstResponder(textView) }
    }

    func hide() {
        closeOverlays()
        commitText()
        library.flush()
        panel.orderOut(nil)
    }

    /// Le dernier cadre, ou en haut à droite de l'écran de la souris.
    private func placeWindow() {
        if let frame = NotesPreferences.shared.windowFrame,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            panel.setFrame(frame, display: false)
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let size = NSSize(width: 440, height: 540)
        panel.setFrame(NSRect(x: area.maxX - size.width - 40, y: area.maxY - size.height - 40, width: size.width, height: size.height), display: false)
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard !NotesLibrary.isSandboxed, panel.isVisible else { return }
        NotesPreferences.shared.windowFrame = panel.frame
    }

    func windowDidResize(_ notification: Notification) {
        if state.popup != nil { updatePopup() }
    }

    /// La note à afficher : la dernière ouverte, sinon la plus récente, sinon une nouvelle.
    private func ensureNote() {
        if let currentID, let note = library.note(currentID), !note.isDeleted { return }
        if let id = library.currentID, library.note(id)?.isDeleted == false {
            open(id)
        } else if let first = library.browsable.first {
            open(first.id)
        } else {
            open(library.create().id)
        }
    }

    // MARK: - Navigation entre notes

    var currentNote: Note? { library.note(currentID) }

    func open(_ id: UUID, recordHistory: Bool = true) {
        guard let note = library.note(id), !note.isDeleted else { return }
        commitText()
        if let previous = currentID, previous != id {
            selections[previous] = textView.selectedRange()
            // Une note restée vide disparaît quand on la quitte.
            if library.note(previous)?.isEmpty == true {
                library.deletePermanently(previous)
                history.remove(previous)
            }
        }
        currentID = id
        library.currentID = id
        if recordHistory { history.visit(id) }
        isLoading = true
        textView.string = note.text
        isLoading = false
        textView.undoManager?.removeAllActions()
        let length = (note.text as NSString).length
        let selection = selections[id].flatMap { NSMaxRange($0) <= length ? $0 : nil } ?? NSRange(location: length, length: 0)
        textView.setSelectedRange(selection)
        textView.scrollRangeToVisible(selection)
        state.popup = nil
        refreshChrome()
        textView.window?.invalidateCursorRects(for: textView)
    }

    func newNote(text: String = "") {
        closeOverlays()
        if text.isEmpty, let note = currentNote, note.isEmpty {
            panel.makeFirstResponder(textView)
            return
        }
        open(library.create(text: text).id)
        panel.makeFirstResponder(textView)
    }

    func goBack() {
        commitText()
        guard let id = history.back() else { return }
        open(id, recordHistory: false)
    }

    func goForward() {
        commitText()
        guard let id = history.forward() else { return }
        open(id, recordHistory: false)
    }

    func togglePin() {
        guard let id = currentID else { return }
        commitText()
        library.togglePin(id)
        if let index = library.pinned.firstIndex(where: { $0.id == id }) {
            showToast(index < 9 ? "Note épinglée : ⌘\(index + 1) pour l’ouvrir" : "Note épinglée")
        } else {
            showToast("Note désépinglée")
        }
        refreshChrome()
    }

    func openPinned(_ index: Int) {
        let pinned = library.pinned
        guard pinned.indices.contains(index) else {
            NSSound.beep()
            return
        }
        closeOverlays()
        open(pinned[index].id)
    }

    func deleteCurrent() {
        guard let id = currentID else { return }
        let wasEmpty = currentNote?.isEmpty ?? true
        commitText()
        library.delete(id)
        noteRemoved(id)
        if !wasEmpty { showToast("Note placée dans « Récemment supprimées »") }
    }

    /// Une note a disparu (supprimée ici ou depuis le lanceur) : on passe à une autre.
    func noteRemoved(_ id: UUID) {
        history.remove(id)
        selections[id] = nil
        guard currentID == id else { refreshChrome(); return }
        currentID = nil
        let next = history.current.flatMap { library.note($0)?.isDeleted == false ? $0 : nil } ?? library.browsable.first?.id
        if let next {
            open(next, recordHistory: history.current != next)
        } else {
            open(library.create().id)
        }
    }

    func deleteAll() {
        commitText()
        let count = library.active.filter { !$0.isEmpty }.count
        library.deleteAll()
        history = NotesHistory()
        currentID = nil
        open(library.create().id)
        state.confirmDeleteAll = false
        showToast(count > 1 ? "\(count) notes placées dans « Récemment supprimées »" : "Note placée dans « Récemment supprimées »")
    }

    // MARK: - Texte

    /// Enregistre le texte de l'éditeur dans la note.
    private func commitText() {
        guard let id = currentID, !isLoading else { return }
        library.update(id, text: textView.string)
    }

    func textDidChange(_ notification: Notification) {
        guard !isLoading else { return }
        commitText()
        refreshChrome()
        updatePopup()
        textView.window?.invalidateCursorRects(for: textView)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isLoading else { return }
        updatePopup()
    }

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            // Pendant une composition (accent mort, saisie japonaise), on attend la fin.
            guard !textView.hasMarkedText() else { return }
            NotesHighlighter.apply(to: textStorage, style: state.style)
        }
    }

    /// Polices, couleurs et zoom : tout le texte est remis en forme.
    func applyStyle() {
        let style = NotesStyle.current(theme: theme)
        state.style = style
        panel.appearance = NSAppearance(named: style.dark ? .darkAqua : .aqua)
        panel.backgroundColor = style.background
        textView.notesLayoutManager?.style = style
        textView.insertionPointColor = style.accent
        textView.placeholderColor = style.tertiary
        textView.selectedTextAttributes = [.backgroundColor: style.accent.withAlphaComponent(style.dark ? 0.32 : 0.22)]
        textView.linkTextAttributes = [:]
        let inset = (14 * min(style.zoom, 1.4)).rounded()
        textView.textContainerInset = NSSize(width: inset, height: 8)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = (style.baseSize * 0.28).rounded()
        textView.typingAttributes = [.font: style.bodyFont(), .foregroundColor: style.text, .paragraphStyle: paragraph]
        if let storage = textView.textStorage {
            storage.beginEditing()
            NotesHighlighter.apply(to: storage, style: style)
            storage.endEditing()
        }
        textView.needsDisplay = true
    }

    func refreshChrome() {
        let note = currentNote
        let title = note.map { $0.isEmpty ? "Nouvelle note" : $0.title } ?? Note.untitled
        if state.title != title { state.title = title }
        let pinned = note?.isPinned ?? false
        if state.isPinned != pinned { state.isPinned = pinned }
        if state.canGoBack != history.canGoBack { state.canGoBack = history.canGoBack }
        if state.canGoForward != history.canGoForward { state.canGoForward = history.canGoForward }
        let words = note?.wordCount ?? 0
        if state.wordCount != words { state.wordCount = words }
        panel.title = title
    }

    func showToast(_ message: String) {
        state.toast = message
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.state.toast = nil }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    // MARK: - Mise en forme

    /// Remplace du texte en passant par l'annulation de l'éditeur.
    private func replace(_ range: NSRange, with string: String, select selection: NSRange? = nil) {
        guard textView.shouldChangeText(in: range, replacementString: string) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: string)
        textView.didChangeText()
        if let selection { textView.setSelectedRange(selection) }
    }

    func format(_ format: NotesFormat) {
        panel.makeFirstResponder(textView)
        switch format {
        case .bold: toggleWrap("**", "**")
        case .italic: toggleWrap("*", "*")
        case .strike: toggleWrap("~~", "~~")
        case .underline: toggleWrap("<u>", "</u>")
        case .code: toggleWrap("`", "`")
        case .link: insertLink()
        case .toggleTask: transformLines { lines in
            lines.map { $0.trimmingCharacters(in: .whitespaces).isEmpty && lines.count > 1 ? $0 : NotesMarkdown.toggledTask($0) }
        }
        case .block(let style): applyBlock(style)
        }
    }

    /// Entoure la sélection de la syntaxe, ou la retire si elle y est déjà.
    private func toggleWrap(_ open: String, _ close: String) {
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let openLength = (open as NSString).length
        let closeLength = (close as NSString).length
        let selected = text.substring(with: selection)

        // La syntaxe entoure la sélection : on la retire.
        if selection.location >= openLength, NSMaxRange(selection) + closeLength <= text.length,
           text.substring(with: NSRange(location: selection.location - openLength, length: openLength)) == open,
           text.substring(with: NSRange(location: NSMaxRange(selection), length: closeLength)) == close {
            // « * » d'un « ** » n'est pas de l'italique.
            let doubled = openLength == 1 && selection.location >= 2 && text.substring(with: NSRange(location: selection.location - 2, length: 1)) == open
            if !doubled {
                replace(NSRange(location: selection.location - openLength, length: selection.length + openLength + closeLength), with: selected,
                        select: NSRange(location: selection.location - openLength, length: selection.length))
                return
            }
        }
        // La sélection contient la syntaxe : on la retire aussi.
        if selected.count >= open.count + close.count, selected.hasPrefix(open), selected.hasSuffix(close) {
            let inner = (selected as NSString).substring(with: NSRange(location: openLength, length: (selected as NSString).length - openLength - closeLength))
            replace(selection, with: inner, select: NSRange(location: selection.location, length: (inner as NSString).length))
            return
        }
        replace(selection, with: open + selected + close, select: NSRange(location: selection.location + openLength, length: selection.length))
    }

    /// ⌘L : un lien autour de la sélection, avec l'adresse du presse-papiers s'il y en a une.
    private func insertLink() {
        let selection = textView.selectedRange()
        let selected = (textView.string as NSString).substring(with: selection)
        let clipboard = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = clipboard.hasPrefix("http://") || clipboard.hasPrefix("https://") ? clipboard : ""
        if selected.isEmpty {
            replace(selection, with: "[](\(url))", select: NSRange(location: selection.location + 1, length: 0))
        } else if url.isEmpty {
            let text = "[\(selected)]()"
            replace(selection, with: text, select: NSRange(location: selection.location + (text as NSString).length - 1, length: 0))
        } else {
            let text = "[\(selected)](\(url))"
            replace(selection, with: text, select: NSRange(location: selection.location + (text as NSString).length, length: 0))
        }
    }

    /// Transforme les lignes de la sélection en gardant le curseur à sa place dans le texte.
    private func transformLines(_ transform: ([String]) -> [String]) {
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let lineRange = text.lineRange(for: selection)
        var original = text.substring(with: lineRange)
        let hadNewline = original.hasSuffix("\n")
        if hadNewline { original.removeLast() }
        var replacement = transform(original.components(separatedBy: "\n")).joined(separator: "\n")
        if hadNewline { replacement += "\n" }
        let newLength = (replacement as NSString).length
        let newSelection: NSRange
        if selection.length == 0 {
            let fromEnd = NSMaxRange(lineRange) - selection.location
            newSelection = NSRange(location: max(lineRange.location, lineRange.location + newLength - fromEnd), length: 0)
        } else {
            newSelection = NSRange(location: lineRange.location, length: newLength - (hadNewline ? 1 : 0))
        }
        replace(lineRange, with: replacement, select: newSelection)
    }

    private func currentLine() -> (range: NSRange, text: String) {
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        var start = 0
        var contentsEnd = 0
        text.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: selection.location, length: 0))
        let range = NSRange(location: start, length: contentsEnd - start)
        return (range, text.substring(with: range))
    }

    private func applyBlock(_ style: NoteBlockStyle) {
        let selection = textView.selectedRange()
        let line = currentLine()
        switch style {
        case .code:
            if selection.length == 0, line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                replace(line.range, with: "```\n\n```", select: NSRange(location: line.range.location + 4, length: 0))
            } else {
                transformLines { ["```"] + $0 + ["```"] }
            }
        case .rule:
            if line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                replace(line.range, with: "---\n", select: NSRange(location: line.range.location + 4, length: 0))
            } else {
                let end = NSMaxRange(line.range)
                replace(NSRange(location: end, length: 0), with: "\n---\n", select: NSRange(location: end + 5, length: 0))
            }
        default:
            transformLines { NotesMarkdown.apply(style, to: $0) }
        }
    }

    /// Clic sur une case : on coche ou décoche sans déplacer le curseur.
    private func toggleCheckbox(at index: Int) {
        let text = textView.string as NSString
        var lineStart = 0
        var contentsEnd = 0
        text.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: index, length: 0))
        let range = NSRange(location: lineStart, length: contentsEnd - lineStart)
        let line = text.substring(with: range)
        let toggled = NotesMarkdown.toggledTask(line)
        guard toggled != line else { return }
        let selection = textView.selectedRange()
        replace(range, with: toggled, select: selection)
    }

    // MARK: - Commandes de l'éditeur

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if state.popup != nil {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): movePopup(-1); return true
            case #selector(NSResponder.moveDown(_:)): movePopup(1); return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): applyPopup(); return true
            case #selector(NSResponder.cancelOperation(_:)): dismissPopup(); return true
            default: break
            }
        }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): return handleNewline()
        case #selector(NSResponder.insertTab(_:)): return indentList(1)
        case #selector(NSResponder.insertBacktab(_:)): return indentList(-1)
        default: return false
        }
    }

    /// Entrée continue les listes, sort d'une liste vide et ferme les blocs de code.
    private func handleNewline() -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        let text = textView.string as NSString
        let line = currentLine()
        let lines = NotesMarkdown.lines(in: text)
        guard let index = lines.firstIndex(where: { $0.range.location == line.range.location }) else { return false }
        let kind = lines[index].kind
        let indent = (line.text as NSString).substring(to: lines[index].indent)

        if kind == .fence {
            let fencesBefore = lines[...index].filter { $0.kind == .fence }.count
            let hasClosing = lines[(index + 1)...].contains { $0.kind == .fence }
            if fencesBefore % 2 == 1, !hasClosing, selection.location == NSMaxRange(line.range) {
                replace(selection, with: "\n" + indent + "\n" + indent + "```", select: NSRange(location: selection.location + 1 + (indent as NSString).length, length: 0))
                return true
            }
            return false
        }
        if kind == .code {
            textView.insertText("\n" + indent, replacementRange: selection)
            return true
        }
        // Le curseur dans la syntaxe de début de ligne : Entrée normale.
        guard selection.location >= NSMaxRange(lines[index].marker) else { return false }
        switch NotesMarkdown.continuation(for: line.text) {
        case .prefix(let prefix):
            textView.insertText("\n" + prefix, replacementRange: selection)
            return true
        case .endList:
            replace(line.range, with: indent.isEmpty ? "" : String(indent.dropLast()), select: nil)
            return true
        case nil:
            return false
        }
    }

    /// Tab et ⇧Tab décalent les éléments de liste.
    private func indentList(_ delta: Int) -> Bool {
        switch NotesMarkdown.classify(currentLine().text).kind {
        case .bullet, .ordered, .task: break
        default: return false
        }
        transformLines { lines in
            lines.map { line in
                if delta > 0 { return "\t" + line }
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                let spaces = line.prefix { $0 == " " }.count
                return String(line.dropFirst(min(spaces, 4)))
            }
        }
        return true
    }

    // MARK: - Menus « / » et « : »

    private static let slashPattern = try! NSRegularExpression(pattern: #"^\s*/([\p{L}\p{N} ]{0,20})$"#)
    private static let emojiPattern = try! NSRegularExpression(pattern: #"(?:^|[\s(])(:([\p{L}\p{N}_+-]{2,24}))$"#)

    func updatePopup() {
        let selection = textView.selectedRange()
        let text = textView.string as NSString
        guard selection.length == 0, panel.firstResponder === textView || NotesLibrary.isSandboxed else { closePopup(); return }
        let line = currentLine()
        let before = text.substring(with: NSRange(location: line.range.location, length: selection.location - line.range.location))
        let beforeRange = NSRange(location: 0, length: (before as NSString).length)
        let lineKind = NotesMarkdown.lines(in: text).first { $0.range.location == line.range.location }?.kind
        guard lineKind != .code, lineKind != .fence else { closePopup(); return }

        var popup: NotesPopup?
        if let match = Self.slashPattern.firstMatch(in: before, range: beforeRange) {
            let query = (before as NSString).substring(with: match.range(at: 1))
            let slash = (before as NSString).range(of: "/", options: .backwards)
            let range = NSRange(location: line.range.location + slash.location, length: selection.location - line.range.location - slash.location)
            let items = Self.slashItems(query)
            if !items.isEmpty { popup = NotesPopup(kind: .slash, range: range, items: items, anchor: .zero) }
        } else if let match = Self.emojiPattern.firstMatch(in: before, range: beforeRange) {
            let query = (before as NSString).substring(with: match.range(at: 2))
            let range = NSRange(location: line.range.location + match.range(at: 1).location, length: match.range(at: 1).length)
            let items = Self.emojiItems(query)
            if !items.isEmpty { popup = NotesPopup(kind: .emoji, range: range, items: items, anchor: .zero) }
        }
        guard var popup, popup.range.location != dismissedPopupLocation else {
            closePopup(resetDismissal: popup == nil)
            return
        }
        if let previous = state.popup, previous.kind == popup.kind, previous.range.location == popup.range.location {
            popup.selected = popup.items.firstIndex { $0.id == previous.items[min(previous.selected, previous.items.count - 1)].id } ?? 0
        }
        popup.anchor = caretAnchor(at: popup.range.location)
        state.popup = popup
    }

    private func closePopup(resetDismissal: Bool = true) {
        if resetDismissal { dismissedPopupLocation = nil }
        if state.popup != nil { state.popup = nil }
    }

    private func dismissPopup() {
        dismissedPopupLocation = state.popup?.range.location
        state.popup = nil
    }

    private func movePopup(_ delta: Int) {
        guard var popup = state.popup, !popup.items.isEmpty else { return }
        popup.selected = (popup.selected + delta + popup.items.count) % popup.items.count
        state.popup = popup
    }

    func applyPopup(index: Int? = nil) {
        guard let popup = state.popup else { return }
        let item = popup.items[min(index ?? popup.selected, popup.items.count - 1)]
        state.popup = nil
        switch popup.kind {
        case .emoji:
            let emoji = item.emoji ?? ""
            replace(popup.range, with: emoji, select: NSRange(location: popup.range.location + (emoji as NSString).length, length: 0))
        case .slash:
            replace(popup.range, with: "", select: NSRange(location: popup.range.location, length: 0))
            if let block = item.block { applyBlock(block) }
        }
        panel.makeFirstResponder(textView)
    }

    private static func slashItems(_ query: String) -> [NotesPopup.Item] {
        let normalized = query.trimmingCharacters(in: .whitespaces).normalizedForSearch
        return NoteBlockStyle.allCases.compactMap { style -> (NotesPopup.Item, Double)? in
            let score = normalized.isEmpty ? 0 : ([style.title] + style.keywords).compactMap { Fuzzy.score(normalized, $0) }.max()
            guard let score else { return nil }
            return (NotesPopup.Item(id: style.rawValue, title: style.title, symbol: style.symbol, hint: style.hint, block: style), score)
        }
        .enumerated()
        .sorted { $0.element.1 == $1.element.1 ? $0.offset < $1.offset : $0.element.1 > $1.element.1 }
        .map(\.element.0)
    }

    private static func emojiItems(_ query: String) -> [NotesPopup.Item] {
        let terms = EmojiCatalog.searchTerms(for: query)
        let scored: [(EmojiEntry, Int)] = EmojiCatalog.all.compactMap { entry in
            let words = entry.searchName.split(separator: " ")
            var best = 0
            for term in terms {
                if entry.searchName == term { best = max(best, 6) }
                else if words.contains(where: { $0 == term }) { best = max(best, 5) }
                else if entry.searchName.hasPrefix(term) { best = max(best, 3) }
                else if words.contains(where: { $0.hasPrefix(term) }) { best = max(best, 2) }
            }
            return best > 0 ? (entry, best) : nil
        }
        return scored
            .sorted { $0.1 == $1.1 ? $0.0.name.count < $1.0.name.count : $0.1 > $1.1 }
            .prefix(6)
            .map { NotesPopup.Item(id: $0.0.character, title: $0.0.name, emoji: $0.0.character) }
    }

    /// Le point sous le caractère, dans le repère de la vue SwiftUI (origine en haut à gauche).
    private func caretAnchor(at location: Int) -> CGPoint {
        guard let hosting, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return .zero }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: location, length: 0), actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphs.location, length: 0), in: container)
        if layoutManager.numberOfGlyphs > 0, glyphs.location >= layoutManager.numberOfGlyphs {
            rect = layoutManager.extraLineFragmentRect.width > 0 ? layoutManager.extraLineFragmentRect : rect
        }
        rect = rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        let local = hosting.convert(rect, from: textView)
        let bottom = hosting.isFlipped ? local.maxY : hosting.bounds.height - local.minY
        return CGPoint(x: local.minX, y: bottom)
    }

    // MARK: - Parcourir

    func toggleBrowse() {
        state.browsing ? closeBrowse() : openBrowse()
    }

    func openBrowse() {
        commitText()
        state.popup = nil
        state.browseQuery = ""
        state.browseSelection = browseResults.first?.id
        state.browsing = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let field = self.browseField else { return }
            self.panel.makeFirstResponder(field)
        }
    }

    func closeBrowse() {
        guard state.browsing else { return }
        state.browsing = false
        panel.makeFirstResponder(textView)
    }

    /// Les notes de « Parcourir », filtrées par la saisie.
    var browseResults: [Note] {
        let query = state.browseQuery.trimmingCharacters(in: .whitespaces).normalizedForSearch
        let notes = library.browsable
        guard !query.isEmpty else { return notes }
        return notes.filter { $0.text.normalizedForSearch.contains(query) || Fuzzy.score(query, $0.title) != nil }
    }

    func moveBrowseSelection(_ delta: Int) {
        let results = browseResults
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == state.browseSelection } ?? -1
        state.browseSelection = results[max(0, min(results.count - 1, index + delta))].id
    }

    func openFromBrowse(_ id: UUID? = nil) {
        guard let id = id ?? state.browseSelection ?? browseResults.first?.id else {
            // Aucun résultat : la recherche devient une nouvelle note.
            let text = state.browseQuery.trimmingCharacters(in: .whitespaces)
            state.browsing = false
            if !text.isEmpty { newNote(text: "# " + text + "\n") }
            return
        }
        state.browsing = false
        open(id)
        panel.makeFirstResponder(textView)
    }

    func browseQueryChanged() {
        state.browseSelection = browseResults.first?.id
    }

    private func closeOverlays() {
        state.browsing = false
        state.popup = nil
        state.confirmDeleteAll = false
    }

    // MARK: - Menu des actions

    func showActionsMenu(at point: NSPoint? = nil) {
        guard let hosting else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ symbol: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, enabled: Bool = true, _ action: @escaping @MainActor () -> Void) {
            let item = NotesMenuItem(title: title, handler: action)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = modifiers
            item.isEnabled = enabled
            menu.addItem(item)
        }
        let note = currentNote
        add("Nouvelle note", "square.and.pencil", key: "n") { [weak self] in self?.newNote() }
        add("Parcourir les notes", "list.bullet", key: "p") { [weak self] in self?.openBrowse() }
        add(note?.isPinned == true ? "Désépingler la note" : "Épingler la note", note?.isPinned == true ? "pin.slash" : "pin", key: "p", modifiers: [.command, .shift]) { [weak self] in self?.togglePin() }
        add("Note précédente", "chevron.left", key: "[", enabled: history.canGoBack) { [weak self] in self?.goBack() }
        add("Note suivante", "chevron.right", key: "]", enabled: history.canGoForward) { [weak self] in self?.goForward() }
        menu.addItem(.separator())
        add("Copier le texte", "doc.on.doc", key: "c", modifiers: [.command, .shift]) { [weak self] in
            guard let self else { return }
            Pasteboard.copy(NotesMarkdown.plainText(self.textView.string))
            self.showToast("Texte copié")
        }
        add("Copier en Markdown", "text.badge.checkmark", key: "c", modifiers: [.command, .option]) { [weak self] in
            guard let self else { return }
            Pasteboard.copy(self.textView.string)
            self.showToast("Markdown copié")
        }
        add("Exporter en Markdown…", "square.and.arrow.up", key: "e", modifiers: [.command, .shift]) { [weak self] in
            guard let self, let note = self.currentNote else { return }
            self.commitText()
            NotesExport.choose(notes: [self.library.note(note.id) ?? note])
        }
        menu.addItem(.separator())
        add(state.showFormatBar ? "Masquer la barre de format" : "Afficher la barre de format", "textformat") {
            NotesPreferences.shared.showFormatBar.toggle()
        }
        add("Agrandir le texte", "plus.magnifyingglass", key: "+") { NotesPreferences.shared.zoomIn() }
        add("Réduire le texte", "minus.magnifyingglass", key: "-") { NotesPreferences.shared.zoomOut() }
        add("Taille réelle", "1.magnifyingglass", key: "0") { NotesPreferences.shared.resetZoom() }
        menu.addItem(.separator())
        add("Récemment supprimées…", "trash", key: "") { NotesFeature.showDeletedInLauncher() }
        add("Réglages des notes…", "gearshape", key: ",") { NotificationCenter.default.post(name: .prismOpenSettings, object: "notes") }
        menu.addItem(.separator())
        add("Supprimer la note", "trash", key: "\u{8}") { [weak self] in self?.deleteCurrent() }
        add("Supprimer toutes les notes…", "trash.slash", key: "\u{8}", modifiers: [.command, .shift], enabled: !library.active.isEmpty) { [weak self] in
            self?.state.confirmDeleteAll = true
        }
        let location = point ?? NSPoint(x: hosting.bounds.width - 12, y: hosting.isFlipped ? 38 : hosting.bounds.height - 38)
        menu.popUp(positioning: nil, at: location, in: hosting)
    }

    // MARK: - Clavier

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = event.keyCode

        if state.confirmDeleteAll {
            switch code {
            case 53: state.confirmDeleteAll = false; return true
            case 36, 76: deleteAll(); return true
            default: return true
            }
        }
        if state.browsing {
            switch code {
            case 53: closeBrowse(); return true
            case 126: moveBrowseSelection(-1); return true
            case 125: moveBrowseSelection(1); return true
            case 36, 76: openFromBrowse(); return true
            default: break
            }
            if modifiers == .command, code == 51, let id = state.browseSelection {
                // ⌘⌫ dans « Parcourir » : supprime la note sélectionnée.
                let next = browseResults.drop { $0.id != id }.dropFirst().first?.id ?? browseResults.last { $0.id != id }?.id
                library.delete(id)
                noteRemoved(id)
                state.browseSelection = next
                return true
            }
        }
        if code == 53 {
            if state.popup != nil { dismissPopup(); return true }
            if NotesPreferences.shared.escapeUnfocuses, panel.firstResponder === textView {
                panel.makeFirstResponder(nil)
                return true
            }
            hide()
            return true
        }

        let digitCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        if modifiers == .command {
            if let index = digitCodes.firstIndex(of: code) { openPinned(index); return true }
            switch (key, code) {
            case ("n", _): newNote(); return true
            case ("p", _): toggleBrowse(); return true
            case ("[", _), (_, 33): goBack(); return true
            case ("]", _), (_, 30): goForward(); return true
            case (_, 51): if !state.browsing { deleteCurrent() }; return !state.browsing
            case ("+", _), ("=", _), (_, 24): NotesPreferences.shared.zoomIn(); return true
            case ("-", _), (_, 27): NotesPreferences.shared.zoomOut(); return true
            case (_, 29): NotesPreferences.shared.resetZoom(); return true
            case ("k", _): showActionsMenu(); return true
            case ("w", _): hide(); return true
            case (",", _): NotificationCenter.default.post(name: .prismOpenSettings, object: "notes"); return true
            case ("f", _) where !state.browsing:
                let item = NSMenuItem()
                item.tag = NSTextFinder.Action.showFindInterface.rawValue
                textView.performTextFinderAction(item)
                return true
            case ("b", _) where !state.browsing: format(.bold); return true
            case ("i", _) where !state.browsing: format(.italic); return true
            case ("u", _) where !state.browsing: format(.underline); return true
            case ("e", _) where !state.browsing: format(.code); return true
            case ("l", _) where !state.browsing: format(.link); return true
            case (_, 36), (_, 76): if !state.browsing { format(.toggleTask) }; return true
            case ("a", _): return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            case ("c", _): return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            case ("v", _): return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            case ("x", _): return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
            case ("z", _): return NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
            default: return false
            }
        }
        if modifiers == [.command, .shift] {
            switch (key, code) {
            case ("p", _): togglePin(); return true
            case ("x", _) where !state.browsing: format(.strike); return true
            case ("z", _): return NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
            case (_, 26) where !state.browsing: format(.block(.ordered)); return true
            case (_, 28) where !state.browsing: format(.block(.bullet)); return true
            case (_, 25) where !state.browsing: format(.block(.task)); return true
            case (_, 24): NotesPreferences.shared.zoomIn(); return true
            case ("c", _):
                Pasteboard.copy(NotesMarkdown.plainText(textView.string))
                showToast("Texte copié")
                return true
            default: return false
            }
        }
        if modifiers == [.command, .option] {
            switch code {
            case 18 where !state.browsing: format(.block(.heading1)); return true
            case 19 where !state.browsing: format(.block(.heading2)); return true
            case 20 where !state.browsing: format(.block(.heading3)); return true
            case 8:
                Pasteboard.copy(textView.string)
                showToast("Markdown copié")
                return true
            default: return false
            }
        }
        return false
    }

    // MARK: - Rendu hors écran

    /// Prépare un rendu : fenêtre hors écran, curseur en haut de la note.
    func prepareForSnapshot(size: NSSize) {
        panel.setFrame(NSRect(origin: NSPoint(x: -8000, y: -8000), size: size), display: false)
        ensureNote()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        panel.orderFrontRegardless()
        panel.makeFirstResponder(textView)
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    /// Tape du texte comme au clavier, pour montrer les menus « / » et « : ».
    func simulateTyping(_ text: String, at location: Int? = nil) {
        if let location { textView.setSelectedRange(NSRange(location: location, length: 0)) }
        textView.insertText(text, replacementRange: textView.selectedRange())
        updatePopup()
    }
}

/// Élément de menu qui exécute une fermeture.
final class NotesMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) indisponible") }

    @objc private func run() {
        MainActor.assumeIsolated { handler() }
    }
}

/// Export des notes en fichiers `.md` dans un dossier choisi.
@MainActor
enum NotesExport {
    static func choose(notes: [Note]) {
        guard !notes.isEmpty else { return }
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Exporter"
            panel.message = notes.count == 1 ? "Choisissez le dossier où enregistrer « \(notes[0].title) »." : "Choisissez le dossier où enregistrer les \(notes.count) notes."
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let directory = panel.url else { return }
            let count = write(notes, to: directory)
            HUD.shared.show(count == 1 ? "Note exportée" : "\(count) notes exportées", symbol: "square.and.arrow.up")
        }
    }

    /// Écrit chaque note dans `<titre>.md`, sans écraser un fichier existant.
    @discardableResult
    static func write(_ notes: [Note], to directory: URL) -> Int {
        var count = 0
        for note in notes {
            let base = fileName(for: note)
            var url = directory.appendingPathComponent(base + ".md")
            var suffix = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = directory.appendingPathComponent("\(base) \(suffix).md")
                suffix += 1
            }
            if (try? note.text.write(to: url, atomically: true, encoding: .utf8)) != nil { count += 1 }
        }
        return count
    }

    static func fileName(for note: Note) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = note.title.components(separatedBy: forbidden).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(cleaned.prefix(80))
        return trimmed.isEmpty || trimmed.hasPrefix(".") ? "Note" : trimmed
    }
}
