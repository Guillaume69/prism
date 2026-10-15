import AppKit

/// Pont d'essai, actif seulement si l'app est lancée avec `PRISM_DEBUG=1` :
/// `Prism --debug type <texte>`, `--debug key <code> [cmd,shift,…]`, `--debug dump <fichier>`.
/// Les frappes sont injectées dans la file d'événements de Prism, comme si elles venaient du clavier.
@MainActor
enum DebugBridge {
    nonisolated static let notification = Notification.Name("app.prism.launcher.debug")

    static func install(launcher: LauncherPanelController) {
        guard ProcessInfo.processInfo.environment["PRISM_DEBUG"] == "1" else { return }
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { handle(command, launcher: launcher) }
        }
        NSLog("Prism : pont de débogage actif")
    }

    private static func handle(_ command: String, launcher: LauncherPanelController) {
        let parts = command.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
        guard let verb = parts.first else { return }
        switch verb {
        case "type":
            for character in parts.dropFirst().joined() {
                post(keyCode: 0xFFFF, characters: String(character), modifiers: [])
            }
        case "key":
            let code = UInt16(parts.count > 1 ? parts[1] : "") ?? 0
            var flags: NSEvent.ModifierFlags = []
            let names = parts.count > 2 ? parts[2] : ""
            if names.contains("cmd") { flags.insert(.command) }
            if names.contains("shift") { flags.insert(.shift) }
            if names.contains("ctrl") { flags.insert(.control) }
            if names.contains("opt") { flags.insert(.option) }
            let characters: [UInt16: String] = [
                0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 6: "z", 7: "x", 8: "c", 9: "v", 12: "q", 13: "w", 14: "e", 15: "r",
                16: "y", 17: "t", 31: "o", 35: "p", 37: "l", 38: "j", 40: "k", 43: ",", 45: "n", 47: ".", 36: "\r", 48: "\t", 53: "\u{1B}",
                18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0", 51: "\u{7F}",
            ]
            post(keyCode: code, characters: characters[code] ?? "", modifiers: flags)
        case "systype":
            // Frappes système, vues par toutes les apps et par les interceptions de Prism (snippets, Hyper, doubles frappes).
            SystemKeys.type(parts.dropFirst().joined())
        case "syskey":
            // syskey <code> [cmd,shift,ctrl,opt] [down|up|press]
            let code = CGKeyCode(parts.count > 1 ? parts[1] : "") ?? 0
            SystemKeys.key(code, flags: SystemKeys.flags(parts.count > 2 ? parts[2] : ""), phase: parts.count > 3 ? parts[3] : "press")
        case "sysflags":
            // sysflags <code de la touche de modification> [cmd,shift,ctrl,opt] : appui (avec les drapeaux) ou relâchement (sans).
            let code = CGKeyCode(parts.count > 1 ? parts[1] : "") ?? 0
            SystemKeys.flagsChanged(code, flags: SystemKeys.flags(parts.count > 2 ? parts[2] : ""))
        case "request-trust":
            Paster.requestTrust()
        case "hotkey":
            let status = AppContext.simulateHotKey?() ?? -1
            NSLog("Prism : raccourci simulé, statut \(status)")
        case "fullscreen-test":
            guard parts.count > 1 else { return }
            fullScreenTest(output: parts[1], launcher: launcher)
        case "dump":
            guard parts.count > 1 else { return }
            dump(to: parts[1], launcher: launcher)
        case "run":
            // Lance une commande par son identifiant, comme un raccourci global.
            guard parts.count > 1 else { return }
            CommandRunner.run(id: parts[1], arguments: Array(parts.dropFirst(2)))
        case "url":
            guard parts.count > 1, let url = URL(string: parts[1]) else { return }
            Deeplinks.handle(url)
        case "show":
            launcher.show(reset: true)
        case "render":
            guard parts.count > 1 else { return }
            launcher.renderPanel(to: parts[1])
        default:
            break
        }
    }

    private static func post(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) {
        let window = NSApp.keyWindow
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window?.windowNumber ?? 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    private static func dump(to path: String, launcher: LauncherPanelController) {
        let model = launcher.model
        let keyWindow = NSApp.keyWindow
        let state: [String: Any] = [
            "visible": launcher.isVisible,
            "appActive": NSApp.isActive,
            "keyWindow": keyWindow.map { String(describing: type(of: $0)) } ?? "aucune",
            "firstResponder": keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "aucun",
            "frontmostApp": NSWorkspace.shared.frontmostApplication?.localizedName ?? "?",
            "previousApp": AppContext.previousApp?.localizedName ?? "?",
            "mode": model.screen.title,
            "screen": model.screen.id,
            "stackDepth": model.stack.count,
            "panelSize": "\(Int(launcher.window.frame.width))×\(Int(launcher.window.frame.height))",
            "menuBarExtensions": ExtensionBackground.shared.debugEntries,
            "inlineArguments": model.inlineArguments,
            "argumentFocus": model.argumentFocus.map { "\($0)" } ?? "aucun",
            "query": model.query,
            "selected": model.selectedItem?.title ?? "",
            "sections": model.sections.map { "\($0.title ?? "—") (\($0.items.count))" },
            "actionPanelOpen": model.isActionPanelOpen,
            "actionIndex": model.actionIndex,
            "actions": model.currentActions.map(\.title),
            "items": model.allItems.prefix(30).map(\.title),
            "toast": model.toast ?? "",
            "hotKey": Preferences.shared.launcherHotkey.label,
            "hotKeyRegistered": AppContext.hotKeyRegistered,
            "accessibilityTrusted": Paster.isTrusted,
            "settingsWindowVisible": NSApp.windows.contains { $0.title == "Réglages de Prism" && $0.isVisible },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Ouvre une fenêtre d'essai en plein écran, y affiche le lanceur, et note s'il passe bien devant.
    private static func fullScreenTest(output: String, launcher: LauncherPanelController) {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 640, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Prism – essai plein écran"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        launcher.hide()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        var report: [String: Any] = [:]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            window.toggleFullScreen(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            report["testWindowFullScreen"] = window.styleMask.contains(.fullScreen)
            report["testWindowOnActiveSpace"] = window.isOnActiveSpace
            _ = AppContext.simulateHotKey?()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.8) {
            let panel = launcher.window
            report["launcherVisible"] = launcher.isVisible
            report["launcherOnActiveSpace"] = panel.isOnActiveSpace
            report["launcherIsKey"] = panel.isKeyWindow
            let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                .compactMap { $0[kCGWindowNumber as String] as? Int }
            let panelIndex = onScreen.firstIndex(of: panel.windowNumber)
            let windowIndex = onScreen.firstIndex(of: window.windowNumber)
            report["launcherOnScreen"] = panelIndex != nil
            report["testWindowOnScreen"] = windowIndex != nil
            if let panelIndex, let windowIndex {
                report["launcherInFront"] = panelIndex < windowIndex
            }
            launcher.hide()
            window.toggleFullScreen(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) {
            window.close()
            NSApp.hide(nil)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: output))
            }
        }
    }
}

/// Les frappes système du pont d'essai, envoyées au niveau du matériel : toutes les apps et les interceptions les voient.
@MainActor
enum SystemKeys {
    private static let codes: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49, ";": 41, ",": 43, ".": 47, "/": 44, "-": 27, "=": 24,
    ]

    static func flags(_ names: String) -> CGEventFlags {
        var flags: CGEventFlags = []
        if names.contains("cmd") { flags.insert(.maskCommand) }
        if names.contains("shift") { flags.insert(.maskShift) }
        if names.contains("ctrl") { flags.insert(.maskControl) }
        if names.contains("opt") { flags.insert(.maskAlternate) }
        return flags
    }

    /// Les caractères sont envoyés par un processus enfant (`Prism --post-keys`) : macOS marque une frappe du numéro
    /// du processus qui l'envoie, et l'expansion des snippets ignore celles de Prism. L'enfant hérite de l'autorisation.
    static func type(_ text: String) {
        guard let executable = Bundle.main.executablePath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--post-keys", text]
        try? process.run()
    }

    static func post(text: String) {
        for character in text {
            let code = codes[Character(character.lowercased())] ?? 0
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
                var units = Array(String(character).utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                if character.isUppercase { event.flags = .maskShift }
                post(event)
            }
            usleep(12_000)
        }
    }

    static func key(_ code: CGKeyCode, flags: CGEventFlags, phase: String) {
        for down in [true, false] where phase == "press" || (phase == "down") == down {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            post(event)
        }
    }

    static func flagsChanged(_ code: CGKeyCode, flags: CGEventFlags) {
        guard let event = CGEvent(source: nil) else { return }
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
        event.flags = flags
        post(event)
    }

    private static func post(_ event: CGEvent) {
        event.post(tap: .cghidEventTap)
    }
}
