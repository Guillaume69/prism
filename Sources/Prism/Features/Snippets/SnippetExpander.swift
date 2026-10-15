import AppKit
import Carbon.HIToolbox

/// Développement des mots-clés dans toutes les applications, par une interception du clavier (CGEventTap).
/// Un tampon garde les derniers caractères tapés ; quand il se termine par un mot-clé, la touche est retenue,
/// le mot-clé effacé par des retours arrière, le texte collé (le presse-papiers est remis ensuite), le curseur placé.
@MainActor
final class SnippetExpander: ObservableObject {
    static let shared = SnippetExpander()

    enum Status {
        case off
        case running
        /// L'accessibilité n'est pas accordée : rien n'est intercepté, les réglages le signalent.
        case needsAccessibility
        case failed
    }

    @Published private(set) var status: Status = .off

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var buffer = ""
    /// Pendant un développement, les frappes sont ignorées (les nôtres, et celles tapées entre-temps).
    private var injecting = false
    private var retryTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private let bufferLimit = 80

    private init() {}

    private var settings: SnippetSettings { SnippetSettings.shared }

    /// Installe ou retire l'interception selon les réglages et l'autorisation. N'en demande aucune.
    func update() {
        guard settings.expansionEnabled else {
            uninstall()
            status = .off
            return
        }
        guard tap == nil else {
            status = .running
            return
        }
        // Sans interface (autotests, rendus), on n'intercepte jamais le clavier.
        guard !SnippetStore.isHeadless, AXIsProcessTrusted() else {
            status = .needsAccessibility
            scheduleRetry()
            return
        }
        install()
    }

    private func install() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: snippetTapCallback,
            userInfo: refcon
        ) else {
            status = .failed
            scheduleRetry()
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        retryTimer?.invalidate()
        retryTimer = nil
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SnippetExpander.shared.buffer = "" }
        }
        status = .running
    }

    private func uninstall() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        tap = nil
        source = nil
        activationObserver = nil
        buffer = ""
    }

    /// L'accessibilité peut être accordée plus tard : on revérifie sans rien demander.
    private func scheduleRetry() {
        guard retryTimer == nil, !SnippetStore.isHeadless else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { SnippetExpander.shared.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    // MARK: - Frappes

    /// `false` : l'évènement est retenu (il n'atteint pas l'application).
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            buffer = ""
            return true
        case .keyDown:
            break
        default:
            return true
        }
        // Nos propres frappes simulées (retours arrière, ⌘V, flèches).
        if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) || injecting { return true }
        // Champ de mot de passe : rien n'est lu.
        if IsSecureEventInputEnabled() {
            buffer = ""
            return true
        }
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            buffer = ""
            return true
        }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch keyCode {
        case kVK_Delete:
            if !buffer.isEmpty { buffer.removeLast() }
            return true
        case kVK_ForwardDelete, kVK_Escape, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            buffer = ""
            return true
        default:
            break
        }
        guard let character = character(of: event, keyCode: keyCode) else { return true }
        guard shouldExpandHere() else {
            buffer = ""
            return true
        }
        let keywords = SnippetStore.shared.keywords
        if !keywords.isEmpty, let match = KeywordMatcher.match(
            buffer: buffer, typed: character, keywords: keywords,
            mode: settings.mode, insideWords: settings.expandInsideWords
        ), let snippet = SnippetStore.shared.snippet(keyword: match.keyword) {
            buffer = ""
            expand(snippet, match: match)
            return false
        }
        if character == "\n" {
            buffer = ""
        } else {
            buffer.append(character)
            if buffer.count > bufferLimit { buffer.removeFirst(buffer.count - bufferLimit) }
        }
        return true
    }

    private func character(of event: CGEvent, keyCode: Int) -> Character? {
        if keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter { return "\n" }
        if keyCode == kVK_Tab { return "\t" }
        var length = 0
        var units = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
        // Touche morte (accent circonflexe en attente) : rien encore.
        guard length > 0 else { return nil }
        let string = String(utf16CodeUnits: units, count: length)
        guard string.count == 1, let character = string.first else {
            buffer = ""
            return nil
        }
        // Touches de fonction et caractères de contrôle.
        if let scalar = character.unicodeScalars.first, (0xF700...0xF8FF).contains(scalar.value) || scalar.properties.generalCategory == .control {
            buffer = ""
            return nil
        }
        return character
    }

    private func shouldExpandHere() -> Bool {
        // Le lanceur ouvert reçoit le clavier sans être l'application de premier plan.
        if AppContext.launcher?.isVisible == true { return false }
        guard let app = NSWorkspace.shared.frontmostApplication else { return true }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return false }
        if let id = app.bundleIdentifier, settings.disabledApps.contains(id) { return false }
        return true
    }

    // MARK: - Développement

    private func expand(_ snippet: Snippet, match: KeywordMatch) {
        let app = NSWorkspace.shared.frontmostApplication
        injecting = true
        SnippetStore.shared.recordUse(snippet.id)
        let delimiter = settings.keepDelimiter ? match.delimiter : nil

        // Des arguments à saisir : le mot-clé s'efface, le lanceur les demande, puis colle dans l'application d'origine.
        if !Placeholders.arguments(in: snippet.text).isEmpty {
            Task { @MainActor in
                self.deleteCharacters(match.charactersToDelete)
                try? await Task.sleep(nanoseconds: 80_000_000)
                self.injecting = false
                guard let launcher = AppContext.launcher,
                      let form = ArgumentsForm.screen(for: SnippetsFeature.item(for: snippet, delivery: .paste, countsUse: false)) else { return }
                launcher.show(reset: true)
                if let app { AppContext.previousApp = app }
                launcher.model.push(form)
            }
            return
        }

        let selection = Placeholders.needsSelection(snippet.text) ? SelectedText.viaAccessibility(app) : nil
        let expanded = SnippetsFeature.expand(snippet.text, arguments: [:], selection: selection)
        var text = expanded.text
        var cursorFromEnd = expanded.cursorFromEnd ?? 0
        var pressReturn = false
        if let delimiter {
            if delimiter == "\n", expanded.cursorFromEnd == nil {
                // Retour gardé : la touche est rejouée (envoi d'un message, validation d'un champ).
                pressReturn = true
            } else {
                text.append(delimiter)
                if expanded.cursorFromEnd != nil { cursorFromEnd += 1 }
            }
        }
        Task { @MainActor in
            await self.inject(deleting: match.charactersToDelete, text: text, cursorFromEnd: cursorFromEnd, pressReturn: pressReturn)
        }
    }

    private func deleteCharacters(_ count: Int) {
        for _ in 0..<max(count, 0) { Keystrokes.send(CGKeyCode(kVK_Delete)) }
    }

    private func inject(deleting count: Int, text: String, cursorFromEnd: Int, pressReturn: Bool) async {
        deleteCharacters(count)
        let delay = UInt64(max(settings.injectionDelay, 10))
        try? await Task.sleep(nanoseconds: delay * 1_000_000)

        let saved = Pasteboard.snapshot()
        ClipboardMonitor.shared.ignoreNextChange()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Les gestionnaires de presse-papiers (nspasteboard.org) ignorent ce contenu passager.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        Keystrokes.send(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)

        try? await Task.sleep(nanoseconds: 60_000_000)
        if pressReturn { Keystrokes.send(CGKeyCode(kVK_Return)) }
        for _ in 0..<cursorFromEnd { Keystrokes.send(CGKeyCode(kVK_LeftArrow)) }
        if settings.playSound { NSSound(named: "Pop")?.play() }

        // L'application lit le presse-papiers au collage : on attend avant de remettre l'ancien contenu.
        try? await Task.sleep(nanoseconds: 450_000_000)
        Pasteboard.write(saved)
        buffer = ""
        injecting = false
    }
}

/// Rappel C de l'interception : il tourne sur la boucle principale, où l'interception est installée.
private func snippetTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let expander = Unmanaged<SnippetExpander>.fromOpaque(refcon).takeUnretainedValue()
    let pass = MainActor.assumeIsolated { expander.handle(type: type, event: event) }
    return pass ? Unmanaged.passUnretained(event) : nil
}
