import AppKit
import ApplicationServices

/// Un élément de la barre des menus, lu par l'accessibilité (ou fabriqué par les autotests).
struct MenuNode {
    var title: String
    var isEnabled = true
    var shortcut: String? = nil
    var children: [MenuNode] = []
    var element: AXUIElement? = nil
}

/// Un élément de menu cliquable, avec son chemin : « Fichier › Exporter › PDF ».
struct MenuEntry {
    var path: [String]
    var shortcut: String?
    var isEnabled: Bool
    var element: AXUIElement?

    var title: String { path.last ?? "" }
    /// Le chemin des menus parents : « Fichier › Exporter ».
    var parentPath: String { MenuPath.join(path.dropLast()) }
    var fullPath: String { MenuPath.join(path) }
}

/// Chemins de menus : « Fichier › Exporter › PDF ».
enum MenuPath {
    static let separator = " › "

    static func join<S: Sequence>(_ components: S) -> String where S.Element == String {
        components.joined(separator: separator)
    }

    /// Lit « Fichier › Exporter › PDF », « Fichier > Exporter > PDF » ou « Fichier/Exporter/PDF ».
    static func parse(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "›>/"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Aplatit la barre des menus : le menu Pomme (le premier), les séparateurs et les titres vides sont ignorés ;
    /// un élément qui ouvre un sous-menu n'est pas un résultat, ses éléments le sont.
    static func flatten(_ menuBar: [MenuNode], limit: Int = 4000) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        func walk(_ node: MenuNode, path: [String], depth: Int) {
            guard entries.count < limit, depth < 8 else { return }
            let title = node.title.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return }
            let current = path + [title]
            if node.children.isEmpty {
                entries.append(MenuEntry(path: current, shortcut: node.shortcut, isEnabled: node.isEnabled, element: node.element))
            } else {
                for child in node.children { walk(child, path: current, depth: depth + 1) }
            }
        }
        for (index, top) in menuBar.enumerated() where index > 0 && top.title != "Apple" {
            for child in top.children { walk(child, path: [top.title], depth: 1) }
        }
        return entries
    }
}

/// Le libellé d'un raccourci de menu, d'après les attributs AXMenuItemCmd* : « ⇧⌘S », « ⌥⌘← ».
enum MenuShortcut {
    /// Bits de `AXMenuItemCmdModifiers` : sans bit, ⌘ seul.
    static let shiftBit = 1, optionBit = 2, controlBit = 4, noCommandBit = 8

    /// Les glyphes de touches spéciales (`kMenu…Glyph` de Carbon).
    static let glyphs: [Int: String] = [
        0x02: "⇥", 0x03: "⇤", 0x04: "⌤", 0x09: "Espace", 0x0A: "⌦", 0x0B: "↩", 0x0D: "↩", 0x10: "↓",
        0x17: "⌫", 0x18: "←", 0x19: "↑", 0x1A: "→", 0x1B: "⎋", 0x1C: "⌧",
        0x62: "⇞", 0x63: "⇪", 0x64: "←", 0x65: "→", 0x66: "↖", 0x68: "↑", 0x69: "↘", 0x6A: "↓", 0x6B: "⇟",
        0x6F: "F1", 0x70: "F2", 0x71: "F3", 0x72: "F4", 0x73: "F5", 0x74: "F6", 0x75: "F7", 0x76: "F8",
        0x77: "F9", 0x78: "F10", 0x79: "F11", 0x7A: "F12", 0x87: "F13", 0x88: "F14", 0x89: "F15",
        0x8C: "⏏", 0x90: "F16", 0x91: "F17", 0x92: "F18", 0x93: "F19",
    ]

    /// Caractères de commande et caractères privés de `NSEvent` (flèches, touches de fonction).
    static func keyName(_ character: String) -> String {
        guard let scalar = character.unicodeScalars.first else { return character }
        switch scalar.value {
        case 0x08, 0x7F: return "⌫"
        case 0x09: return "⇥"
        case 0x0D, 0x03: return "↩"
        case 0x1B: return "⎋"
        case 0x20: return "Espace"
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF704...0xF71B: return "F\(scalar.value - 0xF704 + 1)"
        case 0xF728: return "⌦"
        case 0xF729: return "↖"
        case 0xF72B: return "↘"
        case 0xF72C: return "⇞"
        case 0xF72D: return "⇟"
        default: return character.uppercased()
        }
    }

    /// Le libellé complet, ou `nil` sans raccourci. Ordre des modificateurs de macOS : ⌃⌥⇧⌘.
    static func label(character: String?, glyph: Int?, virtualKeyName: String? = nil, modifiers: Int?) -> String? {
        let key: String
        if let character, !character.isEmpty {
            key = keyName(character)
        } else if let glyph, let name = glyphs[glyph] {
            key = name
        } else if let virtualKeyName, !virtualKeyName.isEmpty {
            key = virtualKeyName
        } else {
            return nil
        }
        let flags = modifiers ?? 0
        var result = ""
        if flags & controlBit != 0 { result += "⌃" }
        if flags & optionBit != 0 { result += "⌥" }
        if flags & shiftBit != 0 { result += "⇧" }
        if flags & noCommandBit == 0 { result += "⌘" }
        return result + key
    }
}

/// Lit la barre des menus d'une application par l'accessibilité. À appeler hors du fil principal : jusqu'à une seconde.
enum MenuReader {
    private static let attributes = [
        kAXTitleAttribute, kAXEnabledAttribute, kAXChildrenAttribute, kAXRoleAttribute,
        kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute, kAXMenuItemCmdGlyphAttribute, kAXMenuItemCmdVirtualKeyAttribute,
    ] as CFArray

    static func read(pid: pid_t) -> [MenuNode] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let menuBar = AX.element(app, kAXMenuBarAttribute) else { return [] }
        var budget = 6000
        return AX.elements(menuBar, kAXChildrenAttribute).map { node($0, depth: 0, budget: &budget) }
    }

    private static func node(_ element: AXUIElement, depth: Int, budget: inout Int) -> MenuNode {
        budget -= 1
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let list = values as? [AnyObject], list.count == 8 else {
            return MenuNode(title: "")
        }
        func value<T>(_ index: Int, _ type: T.Type) -> T? { list[index] as? T }
        let title = value(0, String.self) ?? ""
        let enabled = value(1, NSNumber.self)?.boolValue ?? true
        let role = value(3, String.self)
        var node = MenuNode(title: title, isEnabled: enabled, element: element)
        if role == kAXMenuItemRole {
            let virtualKey = value(7, NSNumber.self)?.intValue
            node.shortcut = MenuShortcut.label(
                character: value(4, String.self),
                glyph: value(6, NSNumber.self)?.intValue,
                virtualKeyName: virtualKey.flatMap { $0 > 0 ? specialKeyName($0) : nil },
                modifiers: value(5, NSNumber.self)?.intValue
            )
        }
        // Barre → menu → éléments ; un élément à sous-menu porte un AXMenu.
        guard depth < 7, budget > 0, let children = value(2, NSArray.self) as? [AnyObject] else { return node }
        let elements = children.compactMap { item -> AXUIElement? in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? unsafeBitCast(item, to: AXUIElement.self) : nil
        }
        for child in elements {
            if AX.string(child, kAXRoleAttribute) == kAXMenuRole {
                node.children += AX.elements(child, kAXChildrenAttribute).map { self.node($0, depth: depth + 1, budget: &budget) }
            } else {
                node.children.append(self.node(child, depth: depth + 1, budget: &budget))
            }
        }
        return node
    }

    /// Touches sans caractère (codes virtuels) : flèches, touches de fonction, retour arrière.
    private static func specialKeyName(_ code: Int) -> String? {
        let names: [Int: String] = [
            36: "↩", 48: "⇥", 49: "Espace", 51: "⌫", 53: "⎋", 117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        return names[code]
    }
}

/// « Rechercher dans les menus » : tous les éléments des menus de l'app au premier plan.
@MainActor
final class MenuSearchScreen: LauncherScreen {
    private let app: NSRunningApplication?
    private var entries: [MenuEntry] = []
    private var loaded = false

    init() {
        app = AppContext.previousApp
        let name = app?.localizedName
        super.init(
            id: "navigation.menus", title: "Rechercher dans les menus",
            placeholder: name.map { "Rechercher dans les menus de \($0)…" } ?? "Rechercher dans les menus…",
            icon: .symbol("filemenu.and.selection", NavigationFeature.color)
        )
    }

    override var footerTitle: String? { app?.localizedName.map { "Menus de \($0)" } }

    override func didAppear() {
        guard AccessibilityGate.isGranted, let app, !loaded, !isLoading else { return }
        isLoading = true
        let pid = app.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            let entries = MenuPath.flatten(MenuReader.read(pid: pid))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.entries = entries
                    self.loaded = true
                    self.isLoading = false
                    self.reload()
                }
            }
        }
    }

    override func sections(query: String) -> [ResultSection] {
        guard AccessibilityGate.isGranted, let app else { return [] }
        let icon: ItemIcon = app.bundleURL.map { .file($0.path) } ?? .symbol("filemenu.and.selection", NavigationFeature.color)
        let normalized = query.normalizedForSearch
        if normalized.isEmpty {
            // Dans l'ordre des menus, une section par menu de la barre.
            var order: [String] = []
            var groups: [String: [ResultItem]] = [:]
            for (index, entry) in entries.enumerated() {
                let menu = entry.path.first ?? ""
                if groups[menu] == nil { order.append(menu) }
                groups[menu, default: []].append(item(entry, index: index, icon: icon))
            }
            return order.map { ResultSection(id: "menu." + $0, title: $0, items: groups[$0] ?? []) }
        }
        let scored: [(index: Int, score: Double)] = entries.enumerated().compactMap { index, entry in
            var best = Fuzzy.score(normalized, entry.title)
            if let score = Fuzzy.score(normalized, entry.fullPath).map({ $0 * 0.7 }), score > (best ?? 0) { best = score }
            guard let best else { return nil }
            return (index, best + (entry.isEnabled ? 0 : -30))
        }
        let items = scored.sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
            .prefix(200)
            .map { item(entries[$0.index], index: $0.index, icon: icon) }
        return items.isEmpty ? [] : [ResultSection(id: "results", title: "Résultats", items: items)]
    }

    private func item(_ entry: MenuEntry, index: Int, icon: ItemIcon) -> ResultItem {
        let app = app
        return ResultItem(
            id: "menu.\(index)",
            title: entry.title,
            subtitle: entry.parentPath,
            icon: icon,
            accessory: entry.isEnabled ? nil : "Désactivé",
            tags: entry.shortcut.map { [$0] } ?? [],
            usageKey: "",
            actions: [
                ItemAction(title: "Choisir « \(entry.title) »", symbol: "cursorarrow.click") {
                    guard entry.isEnabled else { return .toast("« \(entry.title) » est désactivé") }
                    guard let element = entry.element else { return .close }
                    app?.activate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { AX.perform(element, kAXPressAction) }
                    return .close
                },
                Actions.copy(entry.fullPath, title: "Copier le chemin du menu", symbol: "doc.on.doc", shortcut: .copyText, hud: "Chemin copié"),
                ItemAction(title: "Relire les menus", symbol: "arrow.clockwise", shortcut: .refresh) { [weak self] in
                    self?.loaded = false
                    self?.didAppear()
                    return .stay
                },
            ],
            isDimmed: !entry.isEnabled
        )
    }

    override func emptyState(query: String) -> (symbol: String, message: String) {
        guard AccessibilityGate.isGranted else { return ("lock.shield", "Prism doit être autorisé à lire les menus des autres applications.\n" + AccessibilityGate.explanation) }
        guard let app else { return ("menubar.rectangle", "Aucune application au premier plan") }
        let name = app.localizedName ?? "l’application"
        if isLoading || !loaded { return ("hourglass", "Lecture des menus de \(name)…") }
        if entries.isEmpty { return ("menubar.rectangle", "\(name) n’a aucun menu lisible") }
        return ("magnifyingglass", "Aucun élément de menu pour « \(query) »")
    }

    override var screenActions: [ItemAction] {
        AccessibilityGate.isGranted ? [] : [AccessibilityGate.requestAction]
    }
}
