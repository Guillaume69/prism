import AppKit
import SwiftUI

/// « Coller en séquence » : chaque appel colle l'entrée suivante, de la plus récente à la plus ancienne.
/// La séquence repart du début après un délai sans collage ou à une nouvelle copie.
@MainActor
final class PasteSequence {
    static let shared = PasteSequence()

    private var previous: Int?
    private var lastPaste: Date?

    /// L'indice à coller : le suivant si la séquence est en cours, sinon 0.
    nonisolated static func nextIndex(previous: Int?, lastPaste: Date?, lastCopy: Date, now: Date, timeout: TimeInterval) -> Int {
        guard let previous, let lastPaste, now.timeIntervalSince(lastPaste) < timeout, lastCopy <= lastPaste else { return 0 }
        return previous + 1
    }

    func pasteNext() -> ActionOutcome {
        let monitor = ClipboardMonitor.shared
        let settings = ClipboardSettings.shared
        let entries = monitor.entries
        guard !entries.isEmpty else { return .hud("L’historique du presse-papiers est vide") }
        let now = Date()
        let index = Self.nextIndex(previous: previous, lastPaste: lastPaste, lastCopy: monitor.lastExternalChange, now: now, timeout: settings.sequenceTimeout)
        guard index < entries.count else {
            reset()
            return .hud("Fin de l’historique : la séquence repart de l’entrée la plus récente")
        }
        previous = index
        lastPaste = now
        monitor.write(entries[index], appendingNewline: settings.sequenceAppendsNewline)
        return Paster.pasteCurrent()
    }

    func reset() {
        previous = nil
        lastPaste = nil
    }
}

@MainActor
enum ClipboardFeature: PrismFeature {
    static let icon = ItemIcon.symbol("doc.on.clipboard.fill", Palette.violet)

    static func start() {
        ClipboardMonitor.shared.start()
    }

    static func screen() -> LauncherScreen {
        ClipboardScreen()
    }

    static var commands: [ResultItem] {
        [
            Command.screen("clipboard", "Historique du presse-papiers", subtitle: "Presse-papiers", symbol: "doc.on.clipboard.fill", color: Palette.violet, keywords: ["clipboard history", "copier", "coller", "historique"], screen: screen),
            Command.run("clipboard.pasteSequentially", "Coller en séquence", subtitle: "Presse-papiers", symbol: "list.number", color: Palette.violet, keywords: ["paste sequentially", "coller à la suite", "séquence"]) {
                PasteSequence.shared.pasteNext()
            },
            Command.run("clipboard.resetSequence", "Réinitialiser la séquence de collage", subtitle: "Presse-papiers", symbol: "arrow.counterclockwise", color: Palette.violet, keywords: ["reset paste sequence", "recommencer"]) {
                PasteSequence.shared.reset()
                return .hud("Séquence de collage réinitialisée")
            },
        ]
    }

    static func fallbacks(query: String) -> [ResultItem] {
        [ResultItem(
            id: "fallback.clipboard",
            title: "Rechercher dans le presse-papiers",
            subtitle: query,
            icon: icon,
            accessory: "Commande",
            actions: [ItemAction(title: "Rechercher dans l’historique", symbol: "doc.on.clipboard") { .push(screen(), query: query) }]
        )]
    }

    static var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "clipboard", title: "Presse-papiers", symbol: "doc.on.clipboard.fill", color: Palette.violet, order: 30) {
            AnyView(ClipboardSettingsView())
        }]
    }

    /// `prism://clipboard[?type=images]`, `prism://clipboard/paste-sequentially`, `prism://clipboard/reset-sequence`.
    static func handle(url: URL) -> Bool {
        guard url.host == "clipboard" else { return false }
        switch url.path {
        case "/paste-sequentially":
            CommandRunner.run(id: "command:clipboard.pasteSequentially")
        case "/reset-sequence":
            PasteSequence.shared.reset()
            HUD.shared.show("Séquence de collage réinitialisée")
        default:
            guard let launcher = AppContext.launcher else { return true }
            let type = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "type" }?.value
                .flatMap(ClipboardTypeFilter.init(rawValue:)) ?? .all
            launcher.show(reset: true)
            launcher.model.push(ClipboardScreen(type: type))
        }
        return true
    }

    // MARK: - Autotests

    static func selfTest(_ check: (Bool, String) -> Void) {
        let kind = ClipboardClassifier.kind(forText:)
        check(kind("https://www.apple.com/fr/") == .link, "lien")
        check(kind("www.exemple.fr") == .link, "lien sans protocole")
        check(kind("slack://channel?id=42") == .link, "lien d’application")
        check(kind("https://exemple.fr et du texte") == .text, "phrase avec un lien : texte")
        check(kind("camille.martin@exemple.fr") == .email, "e-mail")
        check(kind("mailto:contact@exemple.fr") == .email, "e-mail avec mailto:")
        check(kind("#5E5CE6") == .color && kind("#fff") == .color && kind("#11223344") == .color, "couleurs hexadécimales")
        check(kind("rgb(255, 149, 0)") == .color && kind("rgba(0 0 0 / 50%)") == .color && kind("hsl(210, 50%, 40%)") == .color, "couleurs rgb() et hsl()")
        check(kind("#hashtag") == .text && kind("rgb(300, 0, 0)") == .text && kind("abc") == .text, "faux amis des couleurs")
        check(kind("Bonjour à tous,\nvoici le compte rendu.") == .text, "texte")

        let types = ClipboardClassifier.kind(types:plainText:)
        check(types([["public.file-url", "public.utf8-plain-text"]], "rapport.pdf") == .files, "fichiers")
        check(types([["public.png"]], nil) == .image, "image")
        check(types([["public.tiff", "public.utf8-plain-text"]], "https://exemple.fr/photo.jpg") == .image, "image copiée d’un navigateur")
        check(types([["public.rtf", "public.tiff", "public.utf8-plain-text"]], "Un tableau de Pages") == .text, "texte riche avec un aperçu en image")
        check(types([["com.exemple.prive"]], nil) == nil, "format inconnu ignoré")

        check(ParsedColor("rgb(255, 128, 0)")?.hexString == "#FF8000", "rgb() vers HEX")
        check(ParsedColor("#FF0000")?.hslString == "hsl(0, 100%, 50%)", "HEX vers HSL")
        check(ParsedColor("hsl(240, 100%, 50%)")?.rgbString == "rgb(0, 0, 255)", "HSL vers RGB")
        check(ParsedColor("#0000FF80")?.rgbString == "rgba(0, 0, 255, 0.5)", "transparence")

        // Filtre et recherche.
        let now = Date()
        func sample(_ text: String, _ kind: ClipboardEntry.Kind, minutes: Double, pinned: Bool = false) -> ClipboardEntry {
            var entry = ClipboardEntry(kind: kind, text: text, date: now.addingTimeInterval(-minutes * 60), sourceApp: "Notes", signature: ClipboardSignature.text(text))
            if pinned { entry.pinnedAt = now }
            return entry
        }
        var invoice = sample("", .image, minutes: 3)
        invoice.recognizedText = "Facture n° 2026-118"
        var renamed = sample("FR76 3000 6000", .text, minutes: 60 * 24 * 200, pinned: true)
        renamed.name = "IBAN du compte"
        let entries = [
            sample("Réunion à 14 h", .text, minutes: 1),
            sample("https://exemple.fr", .link, minutes: 4),
            invoice,
            sample("#FF9500", .color, minutes: 20),
            sample("contact@exemple.fr", .email, minutes: 120),
            sample("Vieux texte", .text, minutes: 60 * 24 * 40),
            renamed,
        ]
        check(ClipboardSearch.filter(entries, type: .images, query: "").count == 1, "filtre Images")
        check(ClipboardSearch.filter(entries, type: .text, query: "").count == 3, "filtre Texte")
        check(ClipboardSearch.filter(entries, type: .all, query: "facture").first?.kind == .image, "recherche dans le texte reconnu")
        check(ClipboardSearch.filter(entries, type: .all, query: "iban compte").count == 1, "recherche dans le nom donné")
        check(ClipboardSearch.filter(entries, type: .all, query: "reunion").count == 1, "recherche sans accents")
        check(ClipboardSearch.filter(entries, type: .links, query: "reunion").isEmpty, "filtre et recherche combinés")

        // Rétention.
        let expired = ClipboardRetention.expired(entries, now: now, retention: .month, maxCount: 1_000)
        check(expired == [entries[5].id], "rétention d’un mois : l’entrée de 40 jours part, l’épinglée reste")
        check(ClipboardRetention.expired(entries, now: now, retention: .unlimited, maxCount: 3).count == 3, "nombre maximal d’entrées")
        check(ClipboardRetention.expired(entries, now: now, retention: .unlimited, maxCount: 1_000).isEmpty, "conservation sans limite")
        check(ClipboardRecentRange.fiveMinutes.ids(in: entries, now: now).count == 3, "entrées des 5 dernières minutes")

        // Migration de l'ancien format (texte seul, dates par défaut de JSONEncoder).
        struct Legacy: Encodable { let id: UUID; let text: String; let date: Date; let sourceApp: String? }
        let legacyDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let legacy = [
            Legacy(id: UUID(), text: "Bonjour", date: legacyDate, sourceApp: "Notes"),
            Legacy(id: UUID(), text: "https://exemple.fr", date: legacyDate.addingTimeInterval(-60), sourceApp: nil),
            Legacy(id: UUID(), text: "Bonjour", date: legacyDate.addingTimeInterval(-120), sourceApp: "Mail"),
        ]
        let migrated = (try? JSONEncoder().encode(legacy)).flatMap(ClipboardMigration.entries(fromLegacy:)) ?? []
        check(migrated.count == 2, "migration : doublons fusionnés")
        check(migrated.first?.id == legacy[0].id && migrated.first?.date == legacyDate && migrated.first?.sourceApp == "Notes", "migration : identifiant, date et application gardés")
        check(migrated.last?.kind == .link, "migration : liens reconnus")
        check(ClipboardMigration.entries(fromLegacy: Data("pas du JSON".utf8)) == nil, "migration : fichier illisible refusé")
        let roundTrip = (try? JSONEncoder.prism.encode(entries)).flatMap { try? JSONDecoder.prism.decode([ClipboardEntry].self, from: $0) }
        check(roundTrip?.count == entries.count && roundTrip?[2].recognizedText == invoice.recognizedText && roundTrip?[6].isPinned == true, "index enregistré puis relu")

        // Coller en séquence.
        let next = PasteSequence.nextIndex
        check(next(nil, nil, .distantPast, now, 30) == 0, "séquence : départ de la plus récente")
        check(next(2, now.addingTimeInterval(-5), .distantPast, now, 30) == 3, "séquence : entrée suivante")
        check(next(2, now.addingTimeInterval(-40), .distantPast, now, 30) == 0, "séquence : délai dépassé")
        check(next(2, now.addingTimeInterval(-5), now.addingTimeInterval(-2), now, 30) == 0, "séquence : nouvelle copie")

        // Lecture d'un presse-papiers privé (jamais le presse-papiers général).
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.prism.selftest.\(UUID().uuidString)"))
        pasteboard.clearContents()
        let rich = NSPasteboardItem()
        rich.setString("Texte en gras", forType: .string)
        rich.setData(Data(#"{\rtf1\ansi {\b Texte en gras}}"#.utf8), forType: .rtf)
        pasteboard.writeObjects([rich])
        let textCapture = ClipboardMonitor.read(pasteboard)
        check(textCapture?.kind == .text && textCapture?.items.first?.keys.contains("public.rtf") == true, "copie de texte riche : tous les formats lus")
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/Applications") as NSURL, URL(fileURLWithPath: "/System") as NSURL])
        let filesCapture = ClipboardMonitor.read(pasteboard)
        check(filesCapture?.kind == .files && filesCapture?.filePaths.count == 2 && filesCapture?.items.count == 2, "copie de deux fichiers : une seule entrée")
        let picture = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { rect in
            NSColor.systemPink.setFill()
            rect.fill()
            return true
        }
        let bitmap = picture.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        let png = bitmap?.representation(using: .png, properties: [:]) ?? Data()
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        check(ClipboardMonitor.read(pasteboard)?.kind == .image, "copie d’une image")
        pasteboard.releaseGlobally()

        // Écriture sur disque, dans un dossier temporaire.
        let previousRoot = ClipboardStorage.root
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("prism-clipboard-selftest-\(UUID().uuidString)", isDirectory: true)
        ClipboardStorage.root = temporary
        let id = UUID()
        let items: [[String: Data]] = [["public.png": png, "public.utf8-plain-text": Data("légende".utf8)]]
        check(ClipboardStorage.writeContent(items, id: id) && ClipboardStorage.readContent(id) == items, "formats d’origine écrits puis relus")
        let size = ClipboardStorage.processImage(png, id: id)
        let thumbnailWritten = ClipboardStorage.thumbnailURL(id).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        check(size != nil && size?.width == bitmap?.pixelsWide && thumbnailWritten, "dimensions et vignette de l’image")
        check(ClipboardStorage.capped(items) == items, "formats sous la taille maximale gardés")
        try? FileManager.default.removeItem(at: temporary)
        ClipboardStorage.root = previousRoot
    }
}
