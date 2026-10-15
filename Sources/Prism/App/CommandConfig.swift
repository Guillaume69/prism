import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Un raccourci clavier global enregistré par l'utilisateur.
struct Hotkey: Codable, Equatable, Hashable {
    var keyCode: UInt32
    /// Modificateurs au format Carbon (`cmdKey`, `optionKey`…).
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        modifiers = Hotkey.carbon(from: event.modifierFlags)
    }

    static func carbon(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    /// ⌃⌥⌘ ensemble s'affichent ✦, comme la touche Hyper de Raycast.
    var symbols: [String] {
        if let tap = tapModifier { return [ModifierTap.symbol(tap), ModifierTap.symbol(tap)] }
        var result: [String] = []
        let hyper = UInt32(cmdKey | optionKey | controlKey)
        if modifiers & hyper == hyper {
            result.append("✦")
            if modifiers & UInt32(shiftKey) != 0 { result.append("⇧") }
        } else {
            if modifiers & UInt32(controlKey) != 0 { result.append("⌃") }
            if modifiers & UInt32(optionKey) != 0 { result.append("⌥") }
            if modifiers & UInt32(shiftKey) != 0 { result.append("⇧") }
            if modifiers & UInt32(cmdKey) != 0 { result.append("⌘") }
        }
        result.append(KeyNames.name(for: UInt16(keyCode)))
        return result
    }

    var label: String { symbols.joined() }

    /// Un raccourci sans modificateur n'est accepté que pour les touches de fonction.
    var isValid: Bool {
        tapModifier != nil || modifiers != 0 || KeyNames.isFunctionKey(UInt16(keyCode))
    }

    /// Double appui d'une touche de modification (⌘⌘, ⌥⌥…) : codé hors de la plage des touches.
    static func doubleTap(_ modifier: NSEvent.ModifierFlags) -> Hotkey {
        Hotkey(keyCode: ModifierTap.base + ModifierTap.code(modifier), modifiers: 0)
    }

    var tapModifier: NSEvent.ModifierFlags? {
        keyCode >= ModifierTap.base ? ModifierTap.modifier(keyCode - ModifierTap.base) : nil
    }
}

/// Le double appui qui ouvre le lanceur, s'il en est un.
enum LauncherTap {
    nonisolated(unsafe) static var key: UInt32 = 0
}

/// Raccourcis faits d'un double appui sur une touche de modification, comme dans Raycast.
/// Carbon ne sait pas les enregistrer : un moniteur d'évènements les reconnaît (accessibilité requise).
@MainActor
final class ModifierTap {
    static let shared = ModifierTap()
    nonisolated static let base: UInt32 = 0x10000

    nonisolated static func code(_ modifier: NSEvent.ModifierFlags) -> UInt32 {
        switch modifier {
        case .command: 1
        case .option: 2
        case .control: 3
        default: 4
        }
    }

    nonisolated static func modifier(_ code: UInt32) -> NSEvent.ModifierFlags? {
        switch code {
        case 1: .command
        case 2: .option
        case 3: .control
        case 4: .shift
        default: nil
        }
    }

    nonisolated static func symbol(_ modifier: NSEvent.ModifierFlags) -> String {
        switch modifier {
        case .command: "⌘"
        case .option: "⌥"
        case .control: "⌃"
        default: "⇧"
        }
    }

    /// La seule touche de modification enfoncée, s'il n'y en a qu'une.
    nonisolated static func single(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags? {
        let relevant = flags.intersection([.command, .option, .control, .shift])
        for candidate in [NSEvent.ModifierFlags.command, .option, .control, .shift] where relevant == candidate { return candidate }
        return nil
    }

    /// Les commandes par double appui, et celui qui ouvre le lanceur.
    var handlers: [UInt32: @MainActor () -> Void] = [:] {
        didSet { installIfNeeded() }
    }

    private var monitors: [Any] = []
    private var detector = Detector()

    /// La reconnaissance pure (testée sans clavier) : appui seul, relâché vite, deux fois de suite.
    struct Detector {
        var pressed: NSEvent.ModifierFlags?
        var pressedAt: TimeInterval = 0
        var lastTap: (modifier: NSEvent.ModifierFlags, at: TimeInterval)?

        /// `true` quand un double appui vient d'être reconnu.
        mutating func flagsChanged(_ flags: NSEvent.ModifierFlags, at time: TimeInterval) -> NSEvent.ModifierFlags? {
            let relevant = flags.intersection([.command, .option, .control, .shift])
            if let single = ModifierTap.single(relevant), pressed == nil {
                pressed = single
                pressedAt = time
                return nil
            }
            guard relevant.isEmpty, let modifier = pressed else {
                if !relevant.isEmpty { pressed = nil; lastTap = nil }
                return nil
            }
            pressed = nil
            guard time - pressedAt < 0.3 else { lastTap = nil; return nil }
            if let last = lastTap, last.modifier == modifier, time - last.at < 0.4 {
                lastTap = nil
                return modifier
            }
            lastTap = (modifier, time)
            return nil
        }

        /// Une touche ordinaire entre-temps annule tout (⌘C n'est pas un appui sur ⌘).
        mutating func keyDown() {
            pressed = nil
            lastTap = nil
        }
    }

    private func installIfNeeded() {
        guard monitors.isEmpty, !handlers.isEmpty else { return }
        let handle: (NSEvent) -> Void = { event in
            MainActor.assumeIsolated { ModifierTap.shared.process(event) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handle) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { event in handle(event); return event }) {
            monitors.append(local)
        }
    }

    private func process(_ event: NSEvent) {
        if event.type == .keyDown {
            detector.keyDown()
            return
        }
        guard let modifier = detector.flagsChanged(event.modifierFlags, at: event.timestamp) else { return }
        guard !GameMode.isSuspended else { return }
        handlers[Self.code(modifier)]?()
    }
}

/// Noms lisibles des touches, selon la disposition du clavier.
enum KeyNames {
    private static let special: [UInt16: String] = [
        UInt16(kVK_Space): "Espace", UInt16(kVK_Return): "↵", UInt16(kVK_Tab): "⇥", UInt16(kVK_Delete): "⌫",
        UInt16(kVK_ForwardDelete): "⌦", UInt16(kVK_Escape): "Échap", UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓", UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘",
        UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟", UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12", UInt16(kVK_F13): "F13",
        UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15", UInt16(kVK_F16): "F16", UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18",
        UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
    ]

    static func isFunctionKey(_ code: UInt16) -> Bool {
        special[code]?.hasPrefix("F") == true
    }

    static func name(for code: UInt16) -> String {
        if let name = special[code] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &characters)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

/// Réglages d'une commande : alias, raccourci, favori, masquée.
struct CommandConfig: Codable, Equatable {
    var alias: String?
    var hotkey: Hotkey?
    var disabled = false
}

@MainActor
final class CommandConfigStore: ObservableObject {
    static let shared = CommandConfigStore()

    struct Content: Codable {
        var commands: [String: CommandConfig] = [:]
        var favorites: [String] = []
        var disabledFallbacks: [String] = []
        var fallbackOrder: [String] = []
    }

    let store = JSONStore("commands.json", default: Content())
    private var registered: [String: HotKey] = [:]

    private init() {}

    var data: Content {
        get { store.value }
        set { store.value = newValue; objectWillChange.send() }
    }

    func config(for id: String) -> CommandConfig { data.commands[id] ?? CommandConfig() }

    func update(_ id: String, _ change: (inout CommandConfig) -> Void) {
        var config = config(for: id)
        change(&config)
        data.commands[id] = config == CommandConfig() ? nil : config
        registerHotkeys()
    }

    func alias(for id: String) -> String? { data.commands[id]?.alias }
    func isDisabled(_ id: String) -> Bool { data.commands[id]?.disabled ?? false }
    func isFavorite(_ id: String) -> Bool { data.favorites.contains(id) }

    func toggleFavorite(_ id: String) {
        if let index = data.favorites.firstIndex(of: id) {
            data.favorites.remove(at: index)
        } else {
            data.favorites.append(id)
        }
    }

    func moveFavorite(_ id: String, by delta: Int) {
        guard let index = data.favorites.firstIndex(of: id) else { return }
        let target = max(0, min(data.favorites.count - 1, index + delta))
        data.favorites.swapAt(index, target)
    }

    /// L'identifiant de la commande qui porte déjà ce raccourci.
    func owner(of hotkey: Hotkey) -> String? {
        data.commands.first { $0.value.hotkey == hotkey }?.key
    }

    // MARK: - Raccourcis globaux

    func registerHotkeys() {
        let wanted = data.commands.compactMapValues(\.hotkey)
        for (id, _) in registered where wanted[id] == nil || registered[id]?.binding != wanted[id] {
            registered[id] = nil
        }
        // Les doubles appuis passent par le moniteur ; le raccourci du lanceur garde sa place.
        var taps = ModifierTap.shared.handlers.filter { $0.key == LauncherTap.key }
        for (id, hotkey) in wanted {
            if let modifier = hotkey.tapModifier {
                taps[ModifierTap.code(modifier)] = { CommandRunner.run(id: id) }
            }
        }
        ModifierTap.shared.handlers = taps
        for (id, hotkey) in wanted where registered[id] == nil && hotkey.tapModifier == nil {
            // Pendant une partie (mode jeu), les raccourcis de Prism se taisent.
            let key = HotKey(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers) {
                MainActor.assumeIsolated {
                    guard !GameMode.isSuspended else { return }
                    CommandRunner.run(id: id)
                }
            }
            key.binding = hotkey
            registered[id] = key
        }
    }

    // MARK: - Actions communes

    /// Les actions de configuration ajoutées au panneau d'actions des commandes et des apps.
    func actions(for item: ResultItem) -> [ItemAction] {
        let id = item.id
        let config = config(for: id)
        let favorite = isFavorite(id)
        var actions: [ItemAction] = [
            ItemAction(title: favorite ? "Retirer des favoris" : "Ajouter aux favoris", symbol: favorite ? "star.slash" : "star", shortcut: .favorite, section: "Configurer") { [weak self] in
                self?.toggleFavorite(id)
                return .refresh
            },
        ]
        if favorite {
            actions.append(ItemAction(title: "Monter dans les favoris", symbol: "arrow.up", shortcut: .moveUp, section: "Configurer") { [weak self] in
                self?.moveFavorite(id, by: -1)
                return .refresh
            })
            actions.append(ItemAction(title: "Descendre dans les favoris", symbol: "arrow.down", shortcut: .moveDown, section: "Configurer") { [weak self] in
                self?.moveFavorite(id, by: 1)
                return .refresh
            })
        }
        actions += [
            ItemAction(title: config.alias == nil ? "Définir un alias" : "Modifier l’alias (\(config.alias ?? ""))", symbol: "textformat.abc", shortcut: .alias, section: "Configurer") {
                .push(CommandConfigStore.aliasForm(for: item))
            },
            ItemAction(title: config.hotkey == nil ? "Définir un raccourci" : "Modifier le raccourci (\(config.hotkey?.label ?? ""))", symbol: "keyboard", shortcut: .hotkey, section: "Configurer") {
                .push(CommandConfigStore.hotkeyForm(for: item))
            },
            ItemAction(title: "Copier le lien profond", symbol: "link", shortcut: .deeplink, section: "Configurer") {
                Pasteboard.copy(Deeplinks.url(forItem: id).absoluteString)
                return .hud("Lien profond copié")
            },
            ItemAction(title: "Réinitialiser le classement", symbol: "arrow.counterclockwise", section: "Configurer") {
                UsageStore.shared.reset(item.usageKey ?? id)
                return .toast("Classement réinitialisé")
            },
            ItemAction(title: "Masquer de la recherche", symbol: "eye.slash", section: "Configurer") { [weak self] in
                self?.update(id) { $0.disabled = true }
                return .refresh
            },
        ]
        return actions
    }

    static func aliasForm(for item: ResultItem) -> FormScreen {
        let current = shared.alias(for: item.id) ?? ""
        return FormScreen(
            id: "alias." + item.id,
            title: "Alias de « \(item.title) »",
            icon: item.icon,
            fields: [
                FormField(id: "alias", label: "Alias", kind: .text, placeholder: "Par exemple : cb", value: current,
                          info: "Tapez l’alias dans la recherche : la commande passe en tête. Suivi d’une espace, il remplit le premier argument."),
            ]
        ) { state in
            let alias = state.trimmed("alias").lowercased()
            if !alias.isEmpty, alias.range(of: #"^[a-z0-9 ]+$"#, options: .regularExpression) == nil {
                state.error = "Lettres minuscules, chiffres et espaces seulement"
                return .stay
            }
            shared.update(item.id) { $0.alias = alias.isEmpty ? nil : alias }
            return .then(.pop, .toast(alias.isEmpty ? "Alias retiré" : "Alias « \(alias) » enregistré"))
        }
    }

    static func hotkeyForm(for item: ResultItem) -> FormScreen {
        let current = shared.config(for: item.id).hotkey
        return FormScreen(
            id: "hotkey." + item.id,
            title: "Raccourci de « \(item.title) »",
            icon: item.icon,
            fields: [
                FormField(id: "hotkey", label: "Raccourci", kind: .hotkey, value: current.map(HotkeyCoding.encode) ?? "",
                          info: "Cliquez dans le champ puis appuyez sur la combinaison. Le raccourci marche partout, même Prism fermé."),
            ]
        ) { state in
            let value = state["hotkey"]
            guard !value.isEmpty else {
                shared.update(item.id) { $0.hotkey = nil }
                return .then(.pop, .toast("Raccourci retiré"))
            }
            guard let hotkey = HotkeyCoding.decode(value), hotkey.isValid else {
                state.error = "Ajoutez au moins un modificateur (⌘, ⌥, ⌃ ou ⇧)"
                return .stay
            }
            if hotkey == Preferences.shared.launcherHotkey {
                state.error = "Ce raccourci ouvre déjà Prism"
                return .stay
            }
            if let owner = shared.owner(of: hotkey), owner != item.id {
                shared.update(owner) { $0.hotkey = nil }
            }
            shared.update(item.id) { $0.hotkey = hotkey }
            return .then(.pop, .toast("Raccourci \(hotkey.label) enregistré"))
        }
    }
}

/// Raccourci ⇄ texte, pour les champs de formulaire.
enum HotkeyCoding {
    static func encode(_ hotkey: Hotkey) -> String { "\(hotkey.keyCode):\(hotkey.modifiers)" }

    static func decode(_ text: String) -> Hotkey? {
        let parts = text.split(separator: ":").compactMap { UInt32($0) }
        guard parts.count == 2 else { return nil }
        return Hotkey(keyCode: parts[0], modifiers: parts[1])
    }
}

/// Exécute une commande hors du lanceur : raccourci global, lien profond, menu.
@MainActor
enum CommandRunner {
    static func run(id: String, arguments: [String] = []) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            AppContext.previousApp = frontmost
        }
        guard let item = RootScreen.candidates().first(where: { $0.id == id }) else {
            HUD.shared.show("Commande introuvable", symbol: "exclamationmark.triangle.fill")
            return
        }
        // Le raccourci d'une app la masque si elle est déjà devant, comme dans Raycast (réglable).
        if id.hasPrefix("app:"), AppCatalog.hotkeyTogglesVisibility, let frontmost, frontmost.bundleURL?.path == String(id.dropFirst(4)) {
            frontmost.hide()
            return
        }
        UsageStore.shared.record(item.usageKey ?? item.id)
        let outcome: ActionOutcome
        if !item.arguments.isEmpty, let run = item.runWithArguments {
            if arguments.count >= item.arguments.filter({ !$0.isOptional }).count {
                outcome = run(arguments)
            } else if let form = ArgumentsForm.screen(for: item, prefilled: arguments) {
                outcome = .push(form)
            } else {
                return
            }
        } else if let primary = item.actions.first {
            outcome = primary.run()
        } else {
            return
        }
        present(outcome)
    }

    /// Montre le résultat d'une action lancée hors du lanceur.
    static func present(_ outcome: ActionOutcome) {
        switch outcome {
        case .close, .stay, .refresh:
            break
        case .hud(let message), .toast(let message):
            HUD.shared.show(message)
        case .then(let first, let second):
            present(first)
            present(second)
        case .pop, .popToRoot:
            break
        case .push, .replace, .setQuery:
            guard let launcher = AppContext.launcher else { return }
            launcher.show(reset: true)
            launcher.model.apply(outcome)
        }
    }
}
