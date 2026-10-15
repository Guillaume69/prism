import AppKit
import SwiftUI

/// Le contenu de la fenêtre des notes : barre d'outils, éditeur, barre de format et calques.
struct NotesWindowView: View {
    @ObservedObject var state: NotesWindowState
    let controller: NotesWindowController

    var body: some View {
        let style = state.style
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                NotesToolbar(state: state, controller: controller)
                EditorHost(view: controller.scrollView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if state.showFormatBar {
                    Rectangle().fill(style.swiftSeparator).frame(height: 1)
                    NotesFormatBar(state: state, controller: controller)
                }
            }
            if let popup = state.popup {
                GeometryReader { proxy in
                    let size = NotesPopupView.size(for: popup)
                    let x = min(max(8, popup.anchor.x - 6), proxy.size.width - size.width - 8)
                    let below = popup.anchor.y + 4
                    let y = below + size.height > proxy.size.height - 8 ? max(8, popup.anchor.y - size.height - 26) : below
                    NotesPopupView(popup: popup, style: style) { index in controller.applyPopup(index: index) }
                        .offset(x: x, y: y)
                }
            }
            if let toast = state.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(style.swiftText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color(nsColor: style.chrome)).shadow(color: .black.opacity(0.18), radius: 8, y: 2))
                        .overlay(Capsule().strokeBorder(style.swiftSeparator))
                        .padding(.bottom, state.showFormatBar ? 48 : 14)
                }
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            if state.browsing {
                NotesBrowseView(state: state, controller: controller)
            }
            if state.confirmDeleteAll {
                NotesConfirmView(state: state, controller: controller)
            }
        }
        .background(style.swiftBackground)
        .environment(\.colorScheme, style.dark ? .dark : .light)
        .tint(style.swiftAccent)
        .animation(.easeOut(duration: 0.15), value: state.toast)
    }
}

/// L'éditeur AppKit, posé tel quel dans la vue SwiftUI.
private struct EditorHost: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Une zone qui déplace la fenêtre, derrière la barre d'outils.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Barre d'outils

private struct NotesToolbar: View {
    @ObservedObject var state: NotesWindowState
    let controller: NotesWindowController

    var body: some View {
        let style = state.style
        ZStack {
            WindowDragArea()
            Text(state.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(state.title == "Nouvelle note" ? style.swiftTertiary : style.swiftText)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 104)
                .allowsHitTesting(false)
            HStack(spacing: 1) {
                ToolbarButton(symbol: "list.bullet", help: "Parcourir les notes (⌘P)", style: style, isActive: state.browsing) {
                    controller.toggleBrowse()
                }
                ToolbarButton(symbol: "chevron.left", help: "Note précédente (⌘[)", style: style, isEnabled: state.canGoBack) {
                    controller.goBack()
                }
                ToolbarButton(symbol: "chevron.right", help: "Note suivante (⌘])", style: style, isEnabled: state.canGoForward) {
                    controller.goForward()
                }
                Spacer(minLength: 0)
                ToolbarButton(symbol: state.isPinned ? "pin.fill" : "pin", help: state.isPinned ? "Désépingler (⇧⌘P)" : "Épingler (⇧⌘P)", style: style, isActive: state.isPinned) {
                    controller.togglePin()
                }
                ToolbarButton(symbol: "square.and.pencil", help: "Nouvelle note (⌘N)", style: style) {
                    controller.newNote()
                }
                ToolbarButton(symbol: "ellipsis.circle", help: "Actions (⌘K)", style: style) {
                    controller.showActionsMenu()
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 40)
        .background(style.swiftBackground)
    }
}

private struct ToolbarButton: View {
    let symbol: String
    let help: String
    let style: NotesStyle
    var isEnabled = true
    var isActive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? style.swiftAccent : style.swiftSecondary)
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering && isEnabled ? style.swiftFill.opacity(1.6) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Barre de format

private struct NotesFormatBar: View {
    @ObservedObject var state: NotesWindowState
    let controller: NotesWindowController

    var body: some View {
        let style = state.style
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                group([
                    .init(text: "H1", help: "Titre 1 (⌥⌘1)", format: .block(.heading1)),
                    .init(text: "H2", help: "Titre 2 (⌥⌘2)", format: .block(.heading2)),
                    .init(text: "H3", help: "Titre 3 (⌥⌘3)", format: .block(.heading3)),
                ])
                divider
                group([
                    .init(symbol: "bold", help: "Gras (⌘B)", format: .bold),
                    .init(symbol: "italic", help: "Italique (⌘I)", format: .italic),
                    .init(symbol: "strikethrough", help: "Barré (⇧⌘X)", format: .strike),
                    .init(symbol: "underline", help: "Souligné (⌘U)", format: .underline),
                    .init(symbol: "chevron.left.forwardslash.chevron.right", help: "Code (⌘E)", format: .code),
                    .init(symbol: "link", help: "Lien (⌘L)", format: .link),
                ])
                divider
                group([
                    .init(symbol: "list.bullet", help: "Liste à puces (⇧⌘8)", format: .block(.bullet)),
                    .init(symbol: "list.number", help: "Liste numérotée (⇧⌘7)", format: .block(.ordered)),
                    .init(symbol: "checklist", help: "Liste de tâches (⇧⌘9)", format: .block(.task)),
                    .init(symbol: "text.quote", help: "Citation", format: .block(.quote)),
                    .init(symbol: "curlybraces", help: "Bloc de code", format: .block(.code)),
                ])
            }
            .fixedSize()
            Spacer(minLength: 6)
            Text(state.wordCount == 1 ? "1 mot" : "\(state.wordCount) mots")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(style.swiftTertiary)
                .lineLimit(1)
                .layoutPriority(-1)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(style.swiftChrome)
    }

    private var divider: some View {
        Rectangle().fill(state.style.swiftSeparator).frame(width: 1, height: 16).padding(.horizontal, 4)
    }

    private func group(_ buttons: [FormatButton.Model]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(buttons.enumerated()), id: \.offset) { _, model in
                FormatButton(model: model, style: state.style) { controller.format(model.format) }
            }
        }
    }
}

private struct FormatButton: View {
    struct Model {
        var symbol: String?
        var text: String?
        let help: String
        let format: NotesFormat

        init(symbol: String, help: String, format: NotesFormat) {
            self.symbol = symbol
            self.help = help
            self.format = format
        }

        init(text: String, help: String, format: NotesFormat) {
            self.text = text
            self.help = help
            self.format = format
        }
    }

    let model: Model
    let style: NotesStyle
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol = model.symbol {
                    Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                } else if let text = model.text {
                    Text(text).font(.system(size: 11.5, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(hovering ? style.swiftText : style.swiftSecondary)
            .frame(width: 25, height: 24)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering ? style.swiftFill.opacity(1.8) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(model.help)
    }
}

// MARK: - Menu « / » et emojis

struct NotesPopupView: View {
    let popup: NotesPopup
    let style: NotesStyle
    let choose: (Int) -> Void

    static let rowHeight: CGFloat = 28

    static func size(for popup: NotesPopup) -> CGSize {
        CGSize(width: popup.kind == .slash ? 230 : 250, height: CGFloat(popup.items.count) * rowHeight + 12 + (popup.kind == .slash ? 22 : 0))
    }

    var body: some View {
        let size = Self.size(for: popup)
        VStack(alignment: .leading, spacing: 0) {
            if popup.kind == .slash {
                Text("Mettre en forme")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(style.swiftTertiary)
                    .padding(.horizontal, 10)
                    .frame(height: 22, alignment: .bottom)
            }
            ForEach(Array(popup.items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    if let emoji = item.emoji {
                        Text(emoji).font(.system(size: 15)).frame(width: 20)
                    } else if let symbol = item.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(index == popup.selected ? style.swiftAccent : style.swiftSecondary)
                            .frame(width: 20)
                    }
                    Text(item.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(style.swiftText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !item.hint.isEmpty {
                        Text(item.hint)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(style.swiftTertiary)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: Self.rowHeight)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(index == popup.selected ? style.swiftAccent.opacity(style.dark ? 0.22 : 0.14) : .clear)
                )
                .contentShape(Rectangle())
                .onTapGesture { choose(index) }
            }
        }
        .padding(6)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: style.chrome)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(style.swiftSeparator.opacity(1.5)))
        .shadow(color: .black.opacity(style.dark ? 0.45 : 0.16), radius: 14, y: 6)
    }
}

// MARK: - Parcourir

private struct NotesBrowseView: View {
    @ObservedObject var state: NotesWindowState
    @ObservedObject var library: NotesLibrary
    let controller: NotesWindowController

    init(state: NotesWindowState, controller: NotesWindowController) {
        self.state = state
        self.controller = controller
        library = controller.library
    }

    var body: some View {
        let style = state.style
        let results = controller.browseResults
        let pinnedIDs = library.pinned.map(\.id)
        ZStack(alignment: .top) {
            Color.black.opacity(style.dark ? 0.35 : 0.12)
                .contentShape(Rectangle())
                .onTapGesture { controller.closeBrowse() }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(style.swiftTertiary)
                    NotesBrowseField(text: $state.browseQuery, placeholder: "Rechercher dans les notes…", style: style) { field in
                        controller.browseField = field
                    } onChange: {
                        controller.browseQueryChanged()
                    }
                    Text(results.count == 1 ? "1 note" : "\(results.count) notes")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(style.swiftTertiary)
                        .fixedSize()
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                Rectangle().fill(style.swiftSeparator).frame(height: 1)
                if results.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "note.text")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(style.swiftTertiary)
                        Text(state.browseQuery.isEmpty ? "Aucune note" : "Aucune note ne contient « \(state.browseQuery) »")
                            .font(.system(size: 12))
                            .foregroundStyle(style.swiftSecondary)
                        if !state.browseQuery.isEmpty {
                            Text("↵ pour créer une note avec ce titre")
                                .font(.system(size: 11))
                                .foregroundStyle(style.swiftTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(results) { note in
                                    BrowseRow(
                                        note: note,
                                        pinIndex: pinnedIDs.firstIndex(of: note.id),
                                        isSelected: state.browseSelection == note.id,
                                        isCurrent: controller.currentID == note.id,
                                        style: style
                                    )
                                    .id(note.id)
                                    .onTapGesture { controller.openFromBrowse(note.id) }
                                }
                            }
                            .padding(6)
                        }
                        .scrollIndicators(.never)
                        .frame(maxHeight: 360)
                        .fixedSize(horizontal: false, vertical: true)
                        .onChange(of: state.browseSelection) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                    }
                }
                Rectangle().fill(style.swiftSeparator).frame(height: 1)
                HStack(spacing: 14) {
                    hint("↵", "Ouvrir")
                    hint("⌘N", "Nouvelle")
                    hint("⌘⌫", "Supprimer")
                    Spacer()
                    hint("esc", "Fermer")
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(style.swiftChrome)
            }
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(style.swiftBackground))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(style.swiftSeparator.opacity(1.5)))
            .shadow(color: .black.opacity(style.dark ? 0.5 : 0.18), radius: 18, y: 8)
            .padding(.horizontal, 10)
            .padding(.top, 42)
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(state.style.swiftSecondary)
            Text(label).font(.system(size: 10.5)).foregroundStyle(state.style.swiftTertiary)
        }
    }
}

private struct BrowseRow: View {
    let note: Note
    let pinIndex: Int?
    let isSelected: Bool
    let isCurrent: Bool
    let style: NotesStyle

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: pinIndex != nil ? "pin.fill" : "note.text")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(pinIndex != nil ? style.swiftAccent : style.swiftTertiary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.isEmpty ? "Nouvelle note" : note.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(style.swiftText)
                    .lineLimit(1)
                Text(note.excerpt.isEmpty ? "Aucun autre texte" : note.excerpt)
                    .font(.system(size: 11.5))
                    .foregroundStyle(style.swiftSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(Self.relative.localizedString(for: note.modified, relativeTo: Date()))
                    .font(.system(size: 10.5))
                    .foregroundStyle(style.swiftTertiary)
                    .lineLimit(1)
                if let pinIndex, pinIndex < 9 {
                    Text("⌘\(pinIndex + 1)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(style.swiftSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(style.swiftFill.opacity(2)))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? style.swiftAccent.opacity(style.dark ? 0.2 : 0.12) : .clear)
        )
        .overlay(alignment: .leading) {
            if isCurrent {
                Capsule().fill(style.swiftAccent).frame(width: 2.5, height: 16).offset(x: 1)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Le champ de recherche de « Parcourir », en AppKit pour en maîtriser le focus.
private struct NotesBrowseField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let style: NotesStyle
    let onCreate: (NSTextField) -> Void
    let onChange: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.stringValue = text
        field.textColor = style.text
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: style.tertiary,
            .font: NSFont.systemFont(ofSize: 14),
        ])
        onCreate(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NotesBrowseField
        init(_ parent: NotesBrowseField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.onChange()
        }
    }
}

// MARK: - Confirmation

private struct NotesConfirmView: View {
    @ObservedObject var state: NotesWindowState
    let controller: NotesWindowController

    var body: some View {
        let style = state.style
        let count = controller.library.active.filter { !$0.isEmpty }.count
        ZStack {
            Color.black.opacity(style.dark ? 0.4 : 0.15)
                .contentShape(Rectangle())
                .onTapGesture { state.confirmDeleteAll = false }
            VStack(spacing: 10) {
                Image(systemName: "trash")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Palette.red)
                Text("Supprimer toutes les notes ?")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(style.swiftText)
                Text(count == 1
                     ? "La note ira dans « Récemment supprimées », où elle restera 30 jours."
                     : "Les \(count) notes iront dans « Récemment supprimées », où elles resteront 30 jours.")
                    .font(.system(size: 12))
                    .foregroundStyle(style.swiftSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Annuler") { state.confirmDeleteAll = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Tout supprimer", role: .destructive) { controller.deleteAll() }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
                .padding(.top, 4)
            }
            .padding(20)
            .frame(width: 290)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: style.chrome)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(style.swiftSeparator.opacity(1.5)))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        }
    }
}
