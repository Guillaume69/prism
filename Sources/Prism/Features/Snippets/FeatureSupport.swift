import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Outils partagés par les snippets et les liens rapides : contexte réel des placeholders,
/// confirmation dans le lanceur, choix d'un fichier JSON.

extension Placeholders.Context {
    /// Le contexte réel : historique du presse-papiers pour `{clipboard offset=…}`, snippets pour `{snippet name=…}`.
    @MainActor
    static func live(usage: Placeholders.Usage) -> Placeholders.Context {
        var context = Placeholders.Context()
        context.usage = usage
        let current = NSPasteboard.general.string(forType: .string)
        let history = ClipboardMonitor.shared.entries.map(\.text)
        context.clipboard = { offset in
            if offset <= 0 { return current ?? history.first }
            // L'historique commence par l'entrée actuelle quand elle y figure.
            let shift = history.first == current ? 0 : -1
            let index = offset + shift
            return history.indices.contains(index) ? history[index] : nil
        }
        let snippets = SnippetStore.shared.snippets
        context.snippet = { name in snippets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.text }
        return context
    }
}

/// Confirmation d'une action destructrice, dans le lanceur : ↵ confirme, Échap annule.
@MainActor
enum Confirmation {
    static func screen(title: String, question: String, confirmTitle: String, icon: ItemIcon, perform: @escaping @MainActor () -> ActionOutcome) -> LauncherScreen {
        ListScreen(id: "confirm." + title, title: title, placeholder: question, icon: icon) { _ in
            [ResultSection(id: "confirm", title: question, items: [
                ResultItem(
                    id: "confirm.yes",
                    title: confirmTitle,
                    icon: .symbol("trash.fill", Palette.red),
                    accessory: "Irréversible",
                    usageKey: "",
                    actions: [ItemAction(title: confirmTitle, symbol: "trash", isDestructive: true, run: perform)]
                ),
                ResultItem(
                    id: "confirm.no",
                    title: "Annuler",
                    icon: .symbol("xmark", Palette.gray),
                    usageKey: "",
                    actions: [ItemAction(title: "Annuler", symbol: "xmark") { .pop }]
                ),
            ])]
        }
    }
}

/// Fenêtres d'ouverture et d'enregistrement : le lanceur est un panneau non activant, on active donc
/// l'application et on masque le lanceur avant la fenêtre modale.
@MainActor
enum JSONFilePanel {
    static func open(title: String) -> URL? {
        let fromLauncher = prepare()
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Importer"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let url = panel.runModal() == .OK ? panel.url : nil
        if fromLauncher { AppContext.previousApp?.activate() }
        return url
    }

    static func save(title: String, fileName: String) -> URL? {
        let fromLauncher = prepare()
        let panel = NSSavePanel()
        panel.title = title
        panel.prompt = "Exporter"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = fileName
        panel.canCreateDirectories = true
        let url = panel.runModal() == .OK ? panel.url : nil
        if fromLauncher { AppContext.previousApp?.activate() }
        return url
    }

    /// `true` si la demande vient du lanceur (et non des réglages) : on rend ensuite la main à l'application d'avant.
    private static func prepare() -> Bool {
        let fromLauncher = !NSApp.isActive || AppContext.launcher?.isVisible == true
        AppContext.launcher?.hide()
        NSApp.activate(ignoringOtherApps: true)
        return fromLauncher
    }
}

/// Le nom affiché d'une application, sans « .app ».
enum AppName {
    static func of(_ path: String) -> String {
        let name = FileManager.default.displayName(atPath: path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
