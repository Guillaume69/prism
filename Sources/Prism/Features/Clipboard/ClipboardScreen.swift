import AppKit
import SwiftUI

/// L'écran « Historique du presse-papiers » : liste à gauche, aperçu et informations à droite, filtre de type (⌘P).
@MainActor
final class ClipboardScreen: LauncherScreen {
    static let listWidth: CGFloat = 300

    init(type: ClipboardTypeFilter = .all) {
        super.init(id: "clipboard", title: "Historique du presse-papiers", placeholder: "Rechercher dans l’historique…", icon: ClipboardFeature.icon)
        layout = .split(listWidth: Self.listWidth)
        filter = ScreenFilter(
            options: ClipboardTypeFilter.allCases.map { ScreenFilter.Option(id: $0.rawValue, title: $0.title) },
            selected: type.rawValue
        )
    }

    private var type: ClipboardTypeFilter {
        filter.flatMap { ClipboardTypeFilter(rawValue: $0.selected) } ?? .all
    }

    override func sections(query: String) -> [ResultSection] {
        ClipboardList.sections(entries: ClipboardMonitor.shared.entries, type: type, query: query)
    }

    override func emptyState(query: String) -> (symbol: String, message: String) {
        if !Preferences.shared.clipboardHistoryEnabled, ClipboardMonitor.shared.entries.isEmpty {
            return ("pause.circle", "L’historique du presse-papiers est désactivé.\nActivez-le dans les réglages (⌘,).")
        }
        if !query.isEmpty { return ("magnifyingglass", "Aucun résultat pour « \(query) »") }
        if type != .all { return ("line.3.horizontal.decrease.circle", "Aucune entrée de type « \(type.title.lowercased()) ».") }
        return ("doc.on.clipboard", "L’historique est vide.\nCopiez du texte, une image ou des fichiers : ils apparaîtront ici.")
    }

    override var screenActions: [ItemAction] {
        [ItemAction(title: "Réglages du presse-papiers", symbol: "gearshape") {
            NotificationCenter.default.post(name: .prismOpenSettings, object: "clipboard")
            return .stay
        }]
    }
}

/// Les sections et les éléments de l'historique.
@MainActor
enum ClipboardList {
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let fullDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    static func sections(entries: [ClipboardEntry], type: ClipboardTypeFilter, query: String, now: Date = Date()) -> [ResultSection] {
        let monitor = ClipboardMonitor.shared
        let matched = ClipboardSearch.filter(entries, type: type, query: query, haystack: monitor.haystack)
        guard !matched.isEmpty else { return [] }

        var sections: [ResultSection] = []
        let pinned = matched.filter(\.isPinned).sorted { ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast) }
        if !pinned.isEmpty {
            sections.append(ResultSection(id: "clipboard.pinned", title: "Épinglés", items: pinned.map { item($0, now: now) }))
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let week = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        let groups: [(id: String, title: String, test: (Date) -> Bool)] = [
            ("today", "Aujourd’hui", { $0 >= today }),
            ("yesterday", "Hier", { $0 >= yesterday && $0 < today }),
            ("week", "7 derniers jours", { $0 >= week && $0 < yesterday }),
            ("older", "Plus ancien", { $0 < week }),
        ]
        let others = matched.filter { !$0.isPinned }
        for group in groups {
            let items = others.filter { group.test($0.date) }.map { item($0, now: now) }
            if !items.isEmpty {
                sections.append(ResultSection(id: "clipboard." + group.id, title: group.title, items: items))
            }
        }
        return sections
    }

    static func item(_ entry: ClipboardEntry, now: Date = Date()) -> ResultItem {
        ResultItem(
            id: "clipboard:" + entry.id.uuidString,
            title: entry.displayTitle,
            icon: icon(entry),
            detail: detail(entry, now: now),
            usageKey: "",
            actions: ClipboardActions.actions(for: entry)
        )
    }

    static func icon(_ entry: ClipboardEntry) -> ItemIcon {
        switch entry.kind {
        case .text: return .glyph(ClipboardClassifier.textSymbol(entry.text))
        case .link:
            if let url = ClipboardClassifier.link(in: entry.text), url.host != nil { return .favicon(url) }
            return .glyph("link")
        case .email: return .glyph("envelope")
        case .color: return ParsedColor(entry.text).map { .color($0.nsColor) } ?? .glyph("paintpalette")
        case .image: return ClipboardImageCache.thumbnail(entry.id).map { .image($0) } ?? .glyph("photo")
        case .files:
            if let first = entry.files.first, FileManager.default.fileExists(atPath: first) { return .file(first) }
            return .glyph(entry.files.count > 1 ? "doc.on.doc" : "doc")
        }
    }

    /// Mots et lignes, comptés une fois par contenu : la liste se recalcule à chaque frappe.
    private static var countCache: [String: (words: Int, lines: Int)] = [:]

    private static func counts(_ entry: ClipboardEntry) -> (words: Int, lines: Int) {
        if let cached = countCache[entry.signature] { return cached }
        let words = entry.text.split { $0.isWhitespace || $0.isNewline }.count
        let lines = entry.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        if countCache.count > 5_000 { countCache.removeAll() }
        countCache[entry.signature] = (words, lines)
        return (words, lines)
    }

    static func detail(_ entry: ClipboardEntry, now: Date = Date()) -> ItemDetail {
        var metadata: [(label: String, value: String)] = [("Type", entry.typeLabel)]
        var text = ""
        var image: NSImage?

        switch entry.kind {
        case .text, .email:
            text = entry.text.count > 20_000 ? String(entry.text.prefix(20_000)) + "\n…" : entry.text
            let (words, lines) = counts(entry)
            metadata.append(("Caractères", entry.characterCount.formatted()))
            metadata.append(("Mots", words.formatted()))
            if lines > 1 { metadata.append(("Lignes", lines.formatted())) }
        case .link:
            text = entry.text
            if let host = ClipboardClassifier.link(in: entry.text)?.host { metadata.append(("Domaine", host)) }
        case .color:
            // La valeur est déjà le titre et figure dans les formats : la pastille prend toute la place.
            if let color = ParsedColor(entry.text) {
                metadata.append(("HEX", color.hexString))
                metadata.append(("RGB", color.rgbString))
                metadata.append(("HSL", color.hslString))
            }
        case .image:
            image = ClipboardImageCache.preview(entry.id)
            if let info = entry.image { metadata.append(("Dimensions", "\(info.width) × \(info.height) pixels")) }
            metadata.append(("Taille", ByteCountFormatter.string(fromByteCount: Int64(entry.byteSize), countStyle: .file)))
            if let recognized = entry.recognizedText, !recognized.isEmpty {
                let words = recognized.split { $0.isWhitespace || $0.isNewline }.count
                metadata.append(("Texte reconnu", words == 1 ? "1 mot" : "\(words) mots"))
            }
            if !entry.barcodes.isEmpty {
                metadata.append(("QR code", entry.barcodes[0]))
            }
        case .files:
            text = entry.files.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n")
            if entry.files.count == 1 {
                let path = entry.files[0]
                image = ClipboardImageCache.preview(entry.id)
                if let attributes = try? FileManager.default.attributesOfItem(atPath: path) {
                    if attributes[.type] as? FileAttributeType != .typeDirectory, let size = attributes[.size] as? Int64 {
                        metadata.append(("Taille", ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
                    }
                } else {
                    metadata.append(("État", "Introuvable"))
                }
                metadata.append(("Emplacement", ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath))
            } else {
                let missing = entry.files.filter { !FileManager.default.fileExists(atPath: $0) }.count
                if missing > 0 { metadata.append(("Introuvables", "\(missing)")) }
            }
        }

        metadata.append(("Application", entry.sourceApp ?? "—"))
        let ago = entry.date > now.addingTimeInterval(-45) ? "à l’instant" : relative.localizedString(for: entry.date, relativeTo: now)
        metadata.append(("Copié", "\(fullDate.string(from: entry.date)) (\(ago))"))
        if entry.copyCount > 1 {
            metadata.append(("Nombre de copies", "\(entry.copyCount)"))
            metadata.append(("Première copie", fullDate.string(from: entry.firstCopied)))
        }
        if let name = entry.name, !name.isEmpty, entry.kind != .files {
            metadata.insert(("Nom", name), at: 0)
        }
        // L'aperçu tient dans la hauteur laissée par les informations, sans être rogné.
        if [.color, .image, .files].contains(entry.kind) {
            let lines = text.isEmpty ? 0 : min(text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count, 8)
            let canvas = ClipboardImageCache.previewCanvas(rows: metadata.count, textLines: lines)
            if entry.kind == .color, let color = ParsedColor(entry.text) {
                image = ClipboardImageCache.swatch(color, size: canvas)
            } else if let base = image {
                image = ClipboardImageCache.fitted(base, key: entry.id.uuidString, size: canvas)
            } else if entry.kind == .files {
                image = ClipboardImageCache.fileIcons(entry.files, size: canvas)
            }
        }
        return ItemDetail(text: text, metadata: metadata, image: image)
    }
}

/// Les actions d'une entrée, dans l'ordre du panneau d'actions (↵ puis ⌘↵ pour les deux premières).
@MainActor
enum ClipboardActions {
    private static var monitor: ClipboardMonitor { .shared }

    static let openShortcut = KeyShortcut(keyCode: 31, modifiers: [.command], label: "O")
    static let editContent = KeyShortcut(keyCode: 14, modifiers: [.command, .shift], label: "E")
    static let deleteRecent = KeyShortcut(keyCode: 7, modifiers: [.command, .shift], label: "X")
    static let saveSnippet = KeyShortcut(keyCode: 1, modifiers: [.command], label: "S")

    static func actions(for entry: ClipboardEntry) -> [ItemAction] {
        let settings = ClipboardSettings.shared
        let plainByDefault = settings.preferPlainText && entry.hasRichText
        let paste = pasteAction(entry, plain: plainByDefault, title: Actions.pasteTitle)
        let copy = ItemAction(title: "Copier dans le presse-papiers", symbol: "doc.on.doc") {
            monitor.write(entry, mode: plainByDefault ? .plainText : .original)
            monitor.markUsed(entry.id)
            return .hud("Copié dans le presse-papiers")
        }
        var actions = settings.primaryAction == .paste ? [paste, copy] : [copy, paste]

        if entry.hasRichText {
            actions.append(plainByDefault
                ? pasteAction(entry, plain: false, title: "Coller avec la mise en forme", shortcut: .pastePlain)
                : pasteAction(entry, plain: true, title: "Coller en texte brut", shortcut: .pastePlain))
        }
        if entry.kind == .image, entry.image?.format != "PNG" {
            actions.append(ItemAction(title: "Coller en PNG", symbol: "photo") {
                monitor.write(entry, mode: .png)
                monitor.markUsed(entry.id)
                return Paster.pasteCurrent()
            })
        }

        actions += kindActions(entry)
        actions += contentActions(entry)
        actions += entryActions(entry)
        actions += deleteActions(entry)
        return actions
    }

    private static func pasteAction(_ entry: ClipboardEntry, plain: Bool, title: String, shortcut: KeyShortcut? = nil) -> ItemAction {
        ItemAction(title: title, symbol: plain ? "doc.plaintext" : "doc.on.clipboard", shortcut: shortcut) {
            monitor.write(entry, mode: plain ? .plainText : .original)
            monitor.markUsed(entry.id)
            return Paster.pasteCurrent()
        }
    }

    /// Ouvrir le lien, écrire un e-mail, afficher les fichiers, copier une couleur dans un autre format.
    private static func kindActions(_ entry: ClipboardEntry) -> [ItemAction] {
        switch entry.kind {
        case .link:
            guard let url = ClipboardClassifier.link(in: entry.text) else { return [] }
            var actions = [ItemAction(title: "Ouvrir le lien", symbol: "safari", shortcut: openShortcut) {
                NSWorkspace.shared.open(url)
                return .close
            }]
            if let createQuicklink = AppHooks.createQuicklink {
                actions.append(ItemAction(title: "Créer un lien rapide", symbol: "link.badge.plus", section: "Contenu") {
                    createQuicklink(url.absoluteString, entry.name ?? url.host ?? "")
                })
            }
            return actions
        case .email:
            guard let address = ClipboardClassifier.email(in: entry.text),
                  let url = URL(string: "mailto:" + address) else { return [] }
            return [ItemAction(title: "Écrire un e-mail", symbol: "envelope", shortcut: openShortcut) {
                NSWorkspace.shared.open(url)
                return .close
            }]
        case .files:
            let urls = entry.files.map { URL(fileURLWithPath: $0) }
            return [
                ItemAction(title: urls.count > 1 ? "Ouvrir les fichiers" : "Ouvrir", symbol: "arrow.up.forward.app", shortcut: openShortcut) {
                    for url in urls { NSWorkspace.shared.open(url) }
                    return .close
                },
                ItemAction(title: "Afficher dans le Finder", symbol: "folder", shortcut: KeyShortcut(keyCode: 15, modifiers: [.command, .shift], label: "R")) {
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                    return .close
                },
                Actions.copy(entry.files.joined(separator: "\n"), title: urls.count > 1 ? "Copier les chemins" : "Copier le chemin", symbol: "link", shortcut: .copyPath, hud: "Chemin copié"),
            ]
        case .color:
            guard let color = ParsedColor(entry.text) else { return [] }
            return [
                Actions.copy(color.hexString, title: "Copier en HEX", symbol: "number", hud: "\(color.hexString) copié").inSection("Couleur"),
                Actions.copy(color.rgbString, title: "Copier en RGB", symbol: "slider.horizontal.3", hud: "\(color.rgbString) copié").inSection("Couleur"),
                Actions.copy(color.hslString, title: "Copier en HSL", symbol: "circle.lefthalf.filled", hud: "\(color.hslString) copié").inSection("Couleur"),
            ]
        case .text, .image:
            return []
        }
    }

    /// Texte des images, QR codes, IA, snippets, partage.
    private static func contentActions(_ entry: ClipboardEntry) -> [ItemAction] {
        var actions: [ItemAction] = []
        if entry.kind == .image {
            actions.append(ItemAction(title: "Copier le texte de l’image", symbol: "text.viewfinder", shortcut: .copyText, section: "Contenu") {
                if let text = entry.recognizedText, !text.isEmpty {
                    Pasteboard.copy(text)
                    return .hud("Texte de l’image copié")
                }
                Task { @MainActor in
                    if let text = await monitor.recognizeNow(entry), !text.isEmpty {
                        Pasteboard.copy(text)
                        HUD.shared.show("Texte de l’image copié")
                    } else {
                        HUD.shared.show("Aucun texte trouvé dans l’image", symbol: "exclamationmark.triangle.fill")
                    }
                }
                return .close
            })
            if !entry.barcodes.isEmpty {
                let content = entry.barcodes.joined(separator: "\n")
                actions.append(Actions.copy(content, title: "Copier le contenu du QR code", symbol: "qrcode.viewfinder", hud: "Contenu du QR code copié").inSection("Contenu"))
                if entry.barcodes.count == 1, let url = ClipboardClassifier.link(in: content) {
                    actions.append(ItemAction(title: "Ouvrir le lien du QR code", symbol: "safari", section: "Contenu") {
                        NSWorkspace.shared.open(url)
                        return .close
                    })
                }
            }
        }

        let aiText = entry.isTextual ? entry.text : entry.recognizedText ?? ""
        if let sendToAIChat = AppHooks.sendToAIChat, !aiText.isEmpty {
            actions.append(ItemAction(title: "Envoyer à l’IA", symbol: "sparkles", shortcut: .toAI, section: "Contenu") {
                let text = entry.isTextual ? monitor.fullText(entry) : aiText
                return sendToAIChat(text, [])
            })
        }
        if let createSnippet = AppHooks.createSnippet, entry.isTextual {
            actions.append(ItemAction(title: "Enregistrer comme snippet", symbol: "text.badge.plus", shortcut: saveSnippet, section: "Contenu") {
                createSnippet(monitor.fullText(entry))
            })
        }
        actions.append(ItemAction(title: "Partager…", symbol: "square.and.arrow.up", shortcut: .share, section: "Contenu") {
            ClipboardShare.present(entry)
        })
        return actions
    }

    /// Modifier, renommer, épingler.
    private static func entryActions(_ entry: ClipboardEntry) -> [ItemAction] {
        var actions: [ItemAction] = []
        if entry.isTextual {
            actions.append(ItemAction(title: "Modifier le contenu", symbol: "pencil", shortcut: editContent, section: "Entrée") {
                .push(editForm(entry))
            })
        }
        actions.append(ItemAction(title: "Renommer l’entrée", symbol: "character.cursor.ibeam", shortcut: .edit, section: "Entrée") {
            .push(renameForm(entry))
        })
        actions.append(ItemAction(title: entry.isPinned ? "Désépingler" : "Épingler", symbol: entry.isPinned ? "pin.slash" : "pin", shortcut: .pin, section: "Entrée") {
            monitor.togglePin(entry.id)
            return .refresh
        })
        return actions
    }

    private static func deleteActions(_ entry: ClipboardEntry) -> [ItemAction] {
        [
            ItemAction(title: "Supprimer l’entrée", symbol: "trash", shortcut: .removeEntry, isDestructive: true, section: "Suppression") {
                monitor.remove(entry.id)
                return .refresh
            },
            ItemAction(title: "Supprimer les entrées récentes…", symbol: "clock.arrow.circlepath", shortcut: deleteRecent, isDestructive: true, section: "Suppression") {
                .push(recentDeletionScreen())
            },
            ItemAction(title: "Tout supprimer…", symbol: "trash.slash", shortcut: .removeAll, isDestructive: true, section: "Suppression") {
                .push(clearForm())
            },
        ]
    }

    // MARK: - Écrans

    static func editForm(_ entry: ClipboardEntry) -> FormScreen {
        let form = FormScreen(
            id: "clipboard.edit",
            title: "Modifier l’entrée",
            icon: ClipboardFeature.icon,
            fields: [
                FormField(
                    id: "text",
                    label: "Contenu",
                    kind: .textArea(lines: 11),
                    value: monitor.fullText(entry),
                    info: entry.hasRichText ? "La mise en forme d’origine sera remplacée par le texte modifié." : nil
                ),
            ]
        ) { state in
            guard !state.trimmed("text").isEmpty else {
                state.error = "Le contenu ne peut pas être vide"
                return .stay
            }
            monitor.updateText(entry.id, to: state["text"])
            return .pop
        }
        return form
    }

    static func renameForm(_ entry: ClipboardEntry) -> FormScreen {
        FormScreen(
            id: "clipboard.rename",
            title: "Renommer l’entrée",
            icon: ClipboardFeature.icon,
            submitTitle: "Renommer",
            fields: [
                FormField(
                    id: "name",
                    label: "Nom",
                    kind: .text,
                    placeholder: entry.automaticTitle,
                    value: entry.name ?? "",
                    info: "Le nom remplace le titre dans la liste et se retrouve par la recherche. Laissez vide pour revenir au titre automatique."
                ),
            ]
        ) { state in
            monitor.rename(entry.id, to: state["name"])
            return .pop
        }
    }

    static func clearForm() -> FormScreen {
        let entries = monitor.entries
        let pinned = entries.filter(\.isPinned).count
        let unpinned = entries.count - pinned
        var fields = [
            FormField(
                id: "info",
                label: "Attention",
                kind: .info,
                value: unpinned == 0
                    ? "Aucune entrée non épinglée."
                    : "\(unpinned == 1 ? "L’entrée" : "Les \(unpinned) entrées") de l’historique, avec leurs images et leurs formats enregistrés, \(unpinned == 1 ? "sera supprimée" : "seront supprimées") définitivement."
            ),
        ]
        if pinned > 0 {
            fields.append(FormField(id: "pinned", label: "Épinglés", kind: .checkbox(label: pinned == 1 ? "Supprimer aussi l’entrée épinglée" : "Supprimer aussi les \(pinned) entrées épinglées"), value: "false"))
        }
        return FormScreen(id: "clipboard.clear", title: "Supprimer tout l’historique", icon: .symbol("trash.fill", Palette.red), submitTitle: "Tout supprimer", fields: fields) { state in
            monitor.clear(includingPinned: state.bool("pinned"))
            return .pop
        }
    }

    static func recentDeletionScreen() -> LauncherScreen {
        ListScreen(
            id: "clipboard.deleteRecent",
            title: "Supprimer les entrées récentes",
            placeholder: "Choisir une période…",
            icon: .symbol("clock.arrow.circlepath", Palette.red)
        ) { query in
            let now = Date()
            let items = ClipboardRecentRange.allCases.compactMap { range -> ResultItem? in
                let ids = range.ids(in: monitor.entries, now: now)
                guard query.isEmpty || Fuzzy.score(query.normalizedForSearch, range.title) != nil else { return nil }
                return ResultItem(
                    id: "clipboard.deleteRecent.\(range.rawValue)",
                    title: range.title,
                    icon: .tinted("clock", Palette.red),
                    accessory: ids.isEmpty ? "Aucune entrée" : ids.count == 1 ? "1 entrée" : "\(ids.count) entrées",
                    usageKey: "",
                    actions: [ItemAction(title: "Supprimer", symbol: "trash", isDestructive: true) {
                        monitor.remove(ids: range.ids(in: monitor.entries, now: Date()))
                        return .pop
                    }]
                )
            }
            return [ResultSection(id: "ranges", title: "Les entrées épinglées sont conservées", items: items)]
        }
    }
}


/// « Partager… » : le sélecteur de partage de macOS, ancré au lanceur.
@MainActor
enum ClipboardShare {
    private final class Delegate: NSObject, NSSharingServicePickerDelegate {
        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            MainActor.assumeIsolated { AppContext.launcher?.keepOpenOnResign = false }
        }
    }

    private static let delegate = Delegate()

    static func items(for entry: ClipboardEntry) -> [Any] {
        let monitor = ClipboardMonitor.shared
        switch entry.kind {
        case .files:
            return entry.files.map { URL(fileURLWithPath: $0) }
        case .image:
            if let data = monitor.imageData(entry)?.data, let image = NSImage(data: data) { return [image] }
            return []
        case .link:
            return [ClipboardClassifier.link(in: entry.text) ?? entry.text]
        default:
            return [monitor.fullText(entry)]
        }
    }

    static func present(_ entry: ClipboardEntry) -> ActionOutcome {
        let items = items(for: entry)
        guard !items.isEmpty, let launcher = AppContext.launcher, let view = launcher.window.contentView else {
            return .toast("Partage impossible pour cette entrée")
        }
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = delegate
        launcher.keepOpenOnResign = true
        // Sous le bouton « Actions » de la barre du bas.
        let anchor = NSRect(x: view.bounds.maxX - 90, y: view.isFlipped ? view.bounds.maxY - LauncherLayout.footerHeight : LauncherLayout.footerHeight, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: view.isFlipped ? .minY : .maxY)
        return .stay
    }
}
