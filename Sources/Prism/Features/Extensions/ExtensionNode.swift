import AppKit
import SwiftUI

/// Un nœud de l'interface rendue par une extension : type (« list », « list-item », « action »…), props, enfants.
/// Les fonctions de l'extension arrivent comme `{"$fn": id}` et les dates comme `{"$date": "…"}`.
struct ExtensionNode {
    let type: String
    let props: [String: Any]
    let children: [ExtensionNode]

    init?(_ json: Any?) {
        guard let object = json as? [String: Any], let type = object["type"] as? String else { return nil }
        self.type = type
        props = object["props"] as? [String: Any] ?? [:]
        children = (object["children"] as? [Any] ?? []).compactMap { ExtensionNode($0) }
    }

    subscript(_ key: String) -> Any? { props[key] }

    func string(_ key: String) -> String? { ExtensionValue.text(props[key]) }

    func bool(_ key: String) -> Bool? { props[key] as? Bool }

    func number(_ key: String) -> Double? { (props[key] as? NSNumber)?.doubleValue }

    func handler(_ key: String) -> String? { ExtensionValue.handler(props[key]) }

    /// Les enfants d'un type, à toute profondeur (sans entrer dans les emplacements).
    func all(_ wanted: String) -> [ExtensionNode] {
        children.flatMap { child -> [ExtensionNode] in
            if child.type == wanted { return [child] }
            if child.type == "slot" { return [] }
            return child.all(wanted)
        }
    }

    /// L'emplacement nommé (« actions », « detail », « searchBarAccessory », « metadata »).
    func slot(_ name: String) -> ExtensionNode? {
        children.first { $0.type == "slot" && $0.string("name") == name }?.children.first
    }

    /// Les enfants directs, sans les emplacements.
    var content: [ExtensionNode] { children.filter { $0.type != "slot" } }
}

enum ExtensionValue {
    /// L'identifiant d'une fonction de l'extension : sa place dans l'interface, ou un numéro pour les requêtes.
    static func handler(_ value: Any?) -> String? {
        switch (value as? [String: Any])?["$fn"] {
        case let id as String: return id
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    static func date(_ value: Any?) -> Date? {
        guard let raw = (value as? [String: Any])?["$date"] as? String else { return nil }
        return ISO8601DateFormatter.extensions.date(from: raw)
    }

    /// Un texte : chaîne, nombre, ou `{ value }` (titres avec infobulle).
    static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        case let object as [String: Any]:
            if let date = date(object) { return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short) }
            return text(object["value"])
        default: return nil
        }
    }

    /// Une date d'accessoire, dite comme Raycast : « il y a 5 min », « dans 2 j ».
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

extension ISO8601DateFormatter {
    static let extensions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - Couleurs

@MainActor
enum ExtensionColor {
    static func color(_ value: Any?, dark: Bool? = nil) -> Color? {
        nsColor(value, dark: dark).map(Color.init(nsColor:))
    }

    static func nsColor(_ value: Any?, dark: Bool? = nil) -> NSColor? {
        let dark = dark ?? ExtensionIcon.isDark
        switch value {
        case let name as String:
            return named(name)
        case let object as [String: Any]:
            if let light = object["light"], let darkValue = object["dark"] { return nsColor(dark ? darkValue : light, dark: dark) }
            return nil
        default:
            return nil
        }
    }

    private static func named(_ name: String) -> NSColor? {
        switch name {
        case "raycast-blue": return NSColor(Palette.blue)
        case "raycast-green": return NSColor(Palette.green)
        case "raycast-magenta": return NSColor(Palette.pink)
        case "raycast-orange": return NSColor(Palette.orange)
        case "raycast-purple": return NSColor(Palette.violet)
        case "raycast-red": return NSColor(Palette.red)
        case "raycast-yellow": return NSColor(Palette.yellow)
        case "raycast-primary-text": return .labelColor
        case "raycast-secondary-text": return .secondaryLabelColor
        default: break
        }
        if name.hasPrefix("#") { return hex(String(name.dropFirst())) }
        let css: [String: NSColor] = [
            "red": .systemRed, "green": .systemGreen, "blue": .systemBlue, "orange": .systemOrange, "yellow": .systemYellow,
            "purple": .systemPurple, "pink": .systemPink, "gray": .systemGray, "grey": .systemGray, "black": .black, "white": .white,
            "brown": .systemBrown, "teal": .systemTeal, "indigo": .systemIndigo, "cyan": .cyan, "magenta": .magenta,
        ]
        return css[name.lowercased()]
    }

    static func hex(_ raw: String) -> NSColor? {
        var text = raw
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let red = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

// MARK: - Icônes

@MainActor
enum ExtensionIcon {
    static var isDark: Bool {
        // `NSApp` est nul hors de l'app (autotests) : l'apparence du système alors.
        let app: NSApplication? = NSApp
        let appearance = app?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Une source d'image Raycast (icône intégrée, URL, chemin, ressource, emoji, `{ source, tintColor }`, `{ fileIcon }`)
    /// en icône de Prism. `assets` : le dossier des ressources de l'extension.
    static func icon(_ value: Any?, assets: URL?, fallback: ItemIcon = .glyph("circle.dashed")) -> ItemIcon {
        switch value {
        case let string as String:
            return icon(source: string, tint: nil, assets: assets) ?? fallback
        case let object as [String: Any]:
            if let file = object["fileIcon"] as? String { return .file(expand(file)) }
            if let light = object["light"], let dark = object["dark"], object["source"] == nil {
                return icon(isDark ? dark : light, assets: assets, fallback: fallback)
            }
            if let color = object["color"] { return ExtensionColor.nsColor(color).map(ItemIcon.color) ?? fallback }
            if let inner = object["value"] { return icon(inner, assets: assets, fallback: fallback) }
            let tint = ExtensionColor.color(object["tintColor"])
            var source = object["source"]
            if let pair = source as? [String: Any], let light = pair["light"], let dark = pair["dark"] { source = isDark ? dark : light }
            if let string = source as? String, let resolved = icon(source: string, tint: tint, assets: assets) { return resolved }
            if let fallbackSource = object["fallback"] as? String, let resolved = icon(source: fallbackSource, tint: tint, assets: assets) { return resolved }
            return fallback
        default:
            return fallback
        }
    }

    private static func icon(source: String, tint: Color?, assets: URL?) -> ItemIcon? {
        if let symbol = symbol(forRaycastIcon: source) {
            return tint.map { .tinted(symbol, $0) } ?? .glyph(symbol)
        }
        if source.hasPrefix("http://") || source.hasPrefix("https://"), let url = URL(string: source) {
            return .remote(url, fallback: "photo")
        }
        if source.hasPrefix("data:"), let comma = source.firstIndex(of: ","),
           let data = Data(base64Encoded: String(source[source.index(after: comma)...])), let image = NSImage(data: data) {
            return .image(image)
        }
        if source.hasPrefix("/") || source.hasPrefix("~") {
            let path = expand(source)
            if let image = cachedImage(path) { return .image(image) }
            return FileManager.default.fileExists(atPath: path) ? .file(path) : nil
        }
        if source.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) && source.count <= 2 {
            return .emoji(source)
        }
        if let assets {
            let base = assets.appendingPathComponent(source)
            let dark = base.deletingPathExtension().path + "@dark." + base.pathExtension
            if isDark, let image = cachedImage(dark) { return .image(image) }
            if let image = cachedImage(base.path) { return .image(image) }
        }
        return nil
    }

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    private static var cache: [String: NSImage] = [:]

    private static func cachedImage(_ path: String) -> NSImage? {
        if let image = cache[path] { return image }
        guard FileManager.default.fileExists(atPath: path), !path.hasSuffix(".app"),
              let image = NSImage(contentsOfFile: path) else { return nil }
        if cache.count > 400 { cache.removeAll() }
        cache[path] = image
        return image
    }

    // MARK: Icônes de Raycast → symboles SF

    /// Les noms qui ne se déduisent pas du nom Raycast.
    private static let explicit: [String: String] = [
        "magnifying-glass": "magnifyingglass", "copy-clipboard": "doc.on.clipboard", "clipboard": "doc.on.clipboard",
        "blank-document": "doc", "document": "doc", "text-document": "doc.text", "finder": "folder", "gear": "gearshape",
        "cog": "gearshape", "x-mark-circle": "xmark.circle", "x-mark-circle-filled": "xmark.circle.fill", "xmark-circle": "xmark.circle",
        "x-mark-top-right-square": "xmark.square", "exclamation-mark": "exclamationmark", "info-circle": "info.circle",
        "question-mark-circle": "questionmark.circle", "question-mark": "questionmark", "code": "chevron.left.forwardslash.chevron.right",
        "code-block": "curlybraces", "terminal": "terminal", "download": "arrow.down.circle", "upload": "arrow.up.circle",
        "image": "photo", "images": "photo.on.rectangle", "music": "music.note", "rocket": "paperplane", "text": "textformat",
        "text-cursor": "character.cursor.ibeam", "two-people": "person.2", "person-circle": "person.crop.circle",
        "add-person": "person.badge.plus", "remove-person": "person.badge.minus", "globe": "globe", "globe-01": "globe",
        "link": "link", "lock-unlocked": "lock.open", "lock-disabled": "lock.slash", "app-window": "macwindow",
        "app-window-list": "rectangle.stack", "app-window-grid-2x2": "square.grid.2x2", "app-window-grid-3x3": "square.grid.3x3",
        "app-window-sidebar-left": "sidebar.left", "app-window-sidebar-right": "sidebar.right", "window": "macwindow",
        "sidebar": "sidebar.left", "list": "list.bullet", "bullet-points": "list.bullet", "number-list": "list.number",
        "check-list": "checklist", "checkmark": "checkmark", "check-circle": "checkmark.circle", "checkmark-circle": "checkmark.circle",
        "circle-progress": "circle.dotted", "circle-progress-25": "circle.lefthalf.filled", "circle-progress-50": "circle.lefthalf.filled",
        "circle-progress-75": "circle.lefthalf.filled", "circle-progress-100": "circle.fill", "circle-ellipsis": "ellipsis.circle",
        "ellipsis": "ellipsis", "ellipsis-vertical": "ellipsis", "dot": "circle.fill", "star-circle": "star.circle", "star-disabled": "star.slash",
        "heart-disabled": "heart.slash", "bell-disabled": "bell.slash", "eye-disabled": "eye.slash", "eye-slash": "eye.slash",
        "speaker-on": "speaker.wave.2", "speaker-off": "speaker.slash", "speaker-down": "speaker.wave.1", "speaker-up": "speaker.wave.3",
        "speech-bubble": "bubble.left", "speech-bubble-active": "bubble.left.and.text.bubble.right", "speech-bubble-important": "exclamationmark.bubble",
        "message": "message", "envelope": "envelope", "envelope-open": "envelope.open", "new-document": "doc.badge.plus",
        "new-folder": "folder.badge.plus", "folder": "folder", "hard-drive": "internaldrive", "computer-chip": "cpu",
        "desktop": "desktopcomputer", "monitor": "display", "mobile": "iphone", "mobile-phone": "iphone", "keyboard": "keyboard",
        "mouse": "computermouse", "wifi": "wifi", "wifi-disabled": "wifi.slash", "bluetooth": "antenna.radiowaves.left.and.right",
        "battery": "battery.75", "battery-charging": "battery.100.bolt", "battery-disabled": "battery.0", "power": "power",
        "house": "house", "building": "building.2", "map": "map", "pin": "pin", "pin-disabled": "pin.slash", "airplane": "airplane",
        "car": "car", "train": "tram", "bike": "bicycle", "calendar": "calendar", "clock": "clock", "alarm": "alarm",
        "stopwatch": "stopwatch", "hourglass": "hourglass", "repeat": "repeat", "shuffle": "shuffle", "play": "play.fill",
        "pause": "pause.fill", "stop": "stop.fill", "forward": "forward.fill", "rewind": "backward.fill", "next": "forward.end.fill",
        "previous": "backward.end.fill", "plus": "plus", "plus-circle": "plus.circle", "plus-square": "plus.square", "minus": "minus",
        "minus-circle": "minus.circle", "trash": "trash", "pencil": "pencil", "edit": "pencil", "eraser": "eraser",
        "bookmark": "bookmark", "book": "book", "tag": "tag", "hashtag": "number", "at-symbol": "at", "key": "key",
        "lock": "lock", "shield": "shield", "bug": "ant", "bolt": "bolt", "bolt-disabled": "bolt.slash", "cloud": "cloud",
        "sun": "sun.max", "moon": "moon", "cloud-rain": "cloud.rain", "snowflake": "snowflake", "temperature": "thermometer",
        "lightbulb": "lightbulb", "light-bulb": "lightbulb", "light-bulb-off": "lightbulb.slash", "wand": "wand.and.stars",
        "stars": "sparkles", "raycast-logo-neg": "sparkles", "raycast-logo-pos": "sparkles", "sparkles": "sparkles",
        "filter": "line.3.horizontal.decrease", "sort": "arrow.up.arrow.down", "arrow-clockwise": "arrow.clockwise",
        "arrow-counter-clockwise": "arrow.counterclockwise", "arrow-ne": "arrow.up.right", "arrow-right-circle": "arrow.right.circle",
        "chevron-right": "chevron.right", "chevron-left": "chevron.left", "chevron-up": "chevron.up", "chevron-down": "chevron.down",
        "chevron-up-down": "chevron.up.chevron.down", "maximize": "arrow.up.left.and.arrow.down.right", "minimize": "arrow.down.right.and.arrow.up.left",
        "fullscreen": "arrow.up.left.and.arrow.down.right", "sidebar-left": "sidebar.left", "layers": "square.3.layers.3d",
        "box": "shippingbox", "gift": "gift", "cart": "cart", "coins": "dollarsign.circle", "credit-card": "creditcard",
        "bank-note": "banknote", "dollar": "dollarsign", "euro": "eurosign", "bar-chart": "chart.bar", "bar-code": "barcode",
        "line-chart": "chart.xyaxis.line", "pie-chart": "chart.pie", "qr-code": "qrcode", "camera": "camera", "video": "video",
        "microphone": "mic", "microphone-disabled": "mic.slash", "headphones": "headphones", "brush": "paintbrush",
        "eye-dropper": "eyedropper", "swatch": "swatchpalette", "crop": "crop", "ruler": "ruler", "compass": "safari",
        "gauge": "gauge", "flag": "flag", "trophy": "trophy", "crown": "crown", "person": "person", "phone": "phone",
        "phone-ringing": "phone.arrow.up.right", "network": "network", "receipt": "doc.plaintext", "store": "storefront",
        "switch": "switch.2", "toggle": "switch.2", "paperclip": "paperclip", "printer": "printer", "save-document": "square.and.arrow.down",
        "sidebar-right": "sidebar.right", "window-sidebar": "sidebar.left", "emoji": "face.smiling", "emoji-sad": "face.dashed",
        "warning": "exclamationmark.triangle", "important": "exclamationmark.circle", "binoculars": "binoculars",
        "anchor": "link", "atom": "atom", "beaker": "flask", "brand-github": "chevron.left.forwardslash.chevron.right",
        "github": "chevron.left.forwardslash.chevron.right", "fingerprint": "touchid", "shortcut": "command", "command-symbol": "command",
        "option-symbol": "option", "shift-symbol": "shift", "ctrl-symbol": "control", "return": "return", "delete": "delete.left",
        "undo": "arrow.uturn.backward", "redo": "arrow.uturn.forward", "reply": "arrowshape.turn.up.left", "share": "square.and.arrow.up",
        "upload-cloud": "icloud.and.arrow.up", "download-cloud": "icloud.and.arrow.down", "lock-locked": "lock",
    ]

    static func symbol(forRaycastIcon raw: String) -> String? {
        guard raw.hasSuffix("-16") || raw.hasSuffix("-24"), !raw.contains("/"), !raw.contains(".") else { return nil }
        let name = String(raw.dropLast(3))
        var candidates: [String] = []
        if let mapped = explicit[name] { candidates.append(mapped) }
        let filled = name.hasSuffix("-filled")
        let base = filled ? String(name.dropLast(7)) : name
        if filled, let mapped = explicit[base] { candidates.append(mapped + ".fill") }
        let dotted = base.replacingOccurrences(of: "-", with: ".")
        candidates.append(filled ? dotted + ".fill" : dotted)
        candidates.append(dotted)
        candidates.append(base.replacingOccurrences(of: "-", with: ""))
        if let first = base.split(separator: "-").first { candidates.append(String(first)) }
        return candidates.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? "circle.dashed"
    }

    /// Un symbole SF pour une action (le panneau d'actions n'affiche que des symboles).
    static func actionSymbol(_ value: Any?) -> String {
        if let string = value as? String, let symbol = symbol(forRaycastIcon: string) { return symbol }
        if let object = value as? [String: Any], let source = object["source"] as? String, let symbol = symbol(forRaycastIcon: source) { return symbol }
        return "circle"
    }
}

// MARK: - Raccourcis

enum ExtensionShortcut {
    private static let codes: [String: (UInt16, String)] = [
        "a": (0, "A"), "s": (1, "S"), "d": (2, "D"), "f": (3, "F"), "h": (4, "H"), "g": (5, "G"), "z": (6, "Z"), "x": (7, "X"),
        "c": (8, "C"), "v": (9, "V"), "b": (11, "B"), "q": (12, "Q"), "w": (13, "W"), "e": (14, "E"), "r": (15, "R"), "y": (16, "Y"),
        "t": (17, "T"), "1": (18, "1"), "2": (19, "2"), "3": (20, "3"), "4": (21, "4"), "6": (22, "6"), "5": (23, "5"), "=": (24, "="),
        "9": (25, "9"), "7": (26, "7"), "-": (27, "-"), "8": (28, "8"), "0": (29, "0"), "]": (30, "]"), "o": (31, "O"), "u": (32, "U"),
        "[": (33, "["), "i": (34, "I"), "p": (35, "P"), "l": (37, "L"), "j": (38, "J"), "'": (39, "'"), "k": (40, "K"), ";": (41, ";"),
        "\\": (42, "\\"), ",": (43, ","), "/": (44, "/"), "n": (45, "N"), "m": (46, "M"), ".": (47, "."), "`": (50, "`"),
        "return": (36, "↵"), "enter": (36, "↵"), "tab": (48, "⇥"), "space": (49, "Espace"), "delete": (51, "⌫"), "backspace": (51, "⌫"),
        "escape": (53, "Échap"), "deleteForward": (117, "⌦"), "arrowLeft": (123, "←"), "arrowRight": (124, "→"),
        "arrowDown": (125, "↓"), "arrowUp": (126, "↑"), "home": (115, "↖"), "end": (119, "↘"), "pageUp": (116, "⇞"), "pageDown": (121, "⇟"),
    ]

    static func shortcut(_ value: Any?) -> KeyShortcut? {
        guard var object = value as? [String: Any] else { return nil }
        if let mac = object["macOS"] as? [String: Any] { object = mac }
        guard let key = object["key"] as? String, let code = codes[key] ?? codes[key.lowercased()] else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for name in object["modifiers"] as? [String] ?? [] {
            switch name {
            case "cmd": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "opt", "option", "alt": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            default: break
            }
        }
        return KeyShortcut(keyCode: code.0, modifiers: modifiers, label: code.1)
    }
}
