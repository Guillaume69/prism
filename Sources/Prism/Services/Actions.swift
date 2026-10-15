import AppKit
import ApplicationServices

enum Pasteboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func copy(image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    static func copy(files: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(files as [NSURL])
    }

    /// Recopie tels quels des éléments (tous leurs formats : texte riche, HTML, image…).
    static func write(_ items: [[NSPasteboard.PasteboardType: Data]]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let objects = items.map { formats -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in formats { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(objects)
    }

    /// Une copie de tout le contenu, pour le remettre après un collage.
    static func snapshot() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var formats: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { formats[type] = data }
            }
            return formats
        }
    }
}

/// Coller dans l'application de premier plan : copie, réactivation de l'application, puis ⌘V simulé.
@MainActor
enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Colle du texte ; `cursorFromEnd` recule ensuite le curseur (placeholder `{cursor}`).
    static func paste(_ text: String, cursorFromEnd: Int? = nil, restoreClipboard: Bool = false) -> ActionOutcome {
        let previous = restoreClipboard ? Pasteboard.snapshot() : []
        Pasteboard.copy(text)
        return pasteCurrent(after: cursorFromEnd, restoring: restoreClipboard ? previous : nil)
    }

    /// Colle des éléments de presse-papiers complets (images, fichiers, texte riche).
    static func paste(items: [[NSPasteboard.PasteboardType: Data]]) -> ActionOutcome {
        Pasteboard.write(items)
        return pasteCurrent(after: nil, restoring: nil)
    }

    /// Colle ce qui est déjà dans le presse-papiers.
    static func pasteCurrent(after cursorFromEnd: Int? = nil, restoring previous: [[NSPasteboard.PasteboardType: Data]]? = nil) -> ActionOutcome {
        guard isTrusted else {
            requestTrust()
            return .hud("Copié — autorisez Prism dans Accessibilité pour coller")
        }
        let target = AppContext.previousApp
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            target?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                Keystrokes.send(9, flags: .maskCommand)
                if let cursorFromEnd, cursorFromEnd > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        for _ in 0..<cursorFromEnd { Keystrokes.send(123) }
                    }
                }
                if let previous {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Pasteboard.write(previous) }
                }
            }
        }
        return .close
    }
}

/// Frappes clavier simulées (demandent l'accessibilité).
enum Keystrokes {
    static func send(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Tape du texte caractère par caractère, sans passer par le presse-papiers.
    static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for scalar in text.utf16 {
            var character = scalar
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }
}

/// Le texte sélectionné dans l'application de premier plan : par l'accessibilité, sinon par un ⌘C simulé
/// (le presse-papiers est remis ensuite).
@MainActor
enum SelectedText {
    static func read(from target: NSRunningApplication? = nil) async -> String? {
        let app = target ?? AppContext.previousApp
        if let text = viaAccessibility(app), !text.isEmpty { return text }
        return await viaCopy(app)
    }

    static func viaAccessibility(_ app: NSRunningApplication?) -> String? {
        guard Paster.isTrusted, let app else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(unsafeBitCast(focused, to: AXUIElement.self), kAXSelectedTextAttribute as CFString, &selected) == .success else {
            return nil
        }
        return selected as? String
    }

    private static func viaCopy(_ app: NSRunningApplication?) async -> String? {
        guard Paster.isTrusted else { return nil }
        let pasteboard = NSPasteboard.general
        let saved = Pasteboard.snapshot()
        let before = pasteboard.changeCount
        if let app, !app.isActive {
            app.activate()
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        ClipboardMonitor.shared.ignoreNextChange()
        Keystrokes.send(8, flags: .maskCommand)
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 40_000_000)
            if pasteboard.changeCount != before { break }
        }
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)
        Pasteboard.write(saved)
        return text
    }
}

/// Actions communes aux résultats.
@MainActor
enum Actions {
    static func copy(
        _ text: String,
        title: String = "Copier dans le presse-papiers",
        symbol: String = "doc.on.doc",
        shortcut: KeyShortcut? = nil,
        hud: String = "Copié dans le presse-papiers"
    ) -> ItemAction {
        ItemAction(title: title, symbol: symbol, shortcut: shortcut) {
            Pasteboard.copy(text)
            return .hud(hud)
        }
    }

    static func paste(_ text: String, title: String? = nil, shortcut: KeyShortcut? = nil) -> ItemAction {
        ItemAction(title: title ?? pasteTitle, symbol: "doc.on.clipboard", shortcut: shortcut) {
            Paster.paste(text)
        }
    }

    /// « Coller dans Notes », selon l'application qui était devant.
    static var pasteTitle: String {
        AppContext.previousApp?.localizedName.map { "Coller dans \($0)" } ?? "Coller"
    }

    static func open(_ path: String, title: String = "Ouvrir") -> ItemAction {
        ItemAction(title: title, symbol: "arrow.up.forward.app") {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return .close
        }
    }

    static func reveal(_ path: String) -> ItemAction {
        ItemAction(title: "Afficher dans le Finder", symbol: "folder", shortcut: KeyShortcut(keyCode: 15, modifiers: [.command, .shift], label: "R")) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return .close
        }
    }

    static func copyPath(_ path: String) -> ItemAction {
        copy(path, title: "Copier le chemin", symbol: "link", shortcut: .copyPath, hud: "Chemin copié")
    }

    static func openURL(_ url: URL, title: String) -> ItemAction {
        ItemAction(title: title, symbol: "safari") {
            NSWorkspace.shared.open(url)
            return .close
        }
    }

    /// Ouvre une adresse avec une application choisie.
    static func open(_ url: URL, withApp appPath: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: appPath), configuration: configuration)
    }
}
