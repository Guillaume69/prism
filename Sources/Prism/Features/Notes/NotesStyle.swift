import AppKit
import SwiftUI

/// Les réglages des notes, dans UserDefaults sous des clés « notes.* ».
@MainActor
final class NotesPreferences: ObservableObject {
    static let shared = NotesPreferences()

    enum FontChoice: String, CaseIterable, Identifiable {
        case system, mono, serif
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: "Système"
            case .mono: "Chasse fixe"
            case .serif: "Serif"
            }
        }
    }

    static let zoomRange: ClosedRange<Double> = 0.7...2.0
    private let defaults = UserDefaults.standard

    /// Bouton dans la barre des menus qui affiche ou masque la fenêtre.
    @Published var showInMenuBar: Bool {
        didSet { defaults.set(showInMenuBar, forKey: "notes.menuBar"); changed() }
    }

    /// Échap retire le focus de l'éditeur au lieu de fermer la fenêtre.
    @Published var escapeUnfocuses: Bool {
        didSet { defaults.set(escapeUnfocuses, forKey: "notes.escapeUnfocuses") }
    }

    @Published var zoom: Double {
        didSet {
            let clamped = min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
            if clamped != zoom { zoom = clamped; return }
            defaults.set(zoom, forKey: "notes.zoom")
            changed()
        }
    }

    @Published var font: FontChoice {
        didSet { defaults.set(font.rawValue, forKey: "notes.font"); changed() }
    }

    @Published var showFormatBar: Bool {
        didSet { defaults.set(showFormatBar, forKey: "notes.formatBar") }
    }

    /// Le cadre de la fenêtre, gardé d'une ouverture à l'autre.
    var windowFrame: NSRect? {
        get { defaults.string(forKey: "notes.frame").map(NSRectFromString).flatMap { $0.width > 100 ? $0 : nil } }
        set { defaults.set(newValue.map(NSStringFromRect), forKey: "notes.frame") }
    }

    private init() {
        showInMenuBar = defaults.bool(forKey: "notes.menuBar")
        escapeUnfocuses = defaults.bool(forKey: "notes.escapeUnfocuses")
        zoom = defaults.object(forKey: "notes.zoom") as? Double ?? 1
        font = FontChoice(rawValue: defaults.string(forKey: "notes.font") ?? "") ?? .system
        showFormatBar = defaults.object(forKey: "notes.formatBar") as? Bool ?? true
    }

    private func changed() {
        NotificationCenter.default.post(name: .notesPreferencesDidChange, object: nil)
    }

    func zoomIn() { zoom = (zoom * 10 + 1).rounded() / 10 }
    func zoomOut() { zoom = (zoom * 10 - 1).rounded() / 10 }
    func resetZoom() { zoom = 1 }
}

extension Notification.Name {
    static let notesPreferencesDidChange = Notification.Name("PrismNotesPreferencesDidChange")
}

/// Polices et couleurs de la fenêtre des notes, tirées du thème de Prism.
struct NotesStyle {
    var dark: Bool
    var font: NotesPreferences.FontChoice
    var zoom: CGFloat

    var background: NSColor
    var text: NSColor
    var secondary: NSColor
    var tertiary: NSColor
    var accent: NSColor
    var fill: NSColor
    var separator: NSColor
    var chrome: NSColor

    @MainActor
    static func current(theme: PrismTheme? = nil) -> NotesStyle {
        let preferences = NotesPreferences.shared
        let theme = theme ?? ThemeStore.shared.current
        let dark = theme.isDark
        let ink = theme.text.flatMap(NSColor.init(hex:)) ?? (dark ? NSColor(white: 0.93, alpha: 1) : NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1))
        let background = theme.background.flatMap(NSColor.init(hex:))
            ?? (dark ? NSColor(srgbRed: 0.118, green: 0.118, blue: 0.129, alpha: 1) : NSColor(srgbRed: 0.992, green: 0.992, blue: 0.988, alpha: 1))
        let secondary = theme.secondaryText.flatMap(NSColor.init(hex:)) ?? ink.withAlphaComponent(dark ? 0.58 : 0.55)
        return NotesStyle(
            dark: dark,
            font: preferences.font,
            zoom: CGFloat(preferences.zoom),
            background: background,
            text: ink,
            secondary: secondary,
            tertiary: ink.withAlphaComponent(dark ? 0.32 : 0.30),
            accent: NSColor(hex: theme.accent) ?? .systemRed,
            fill: ink.withAlphaComponent(dark ? 0.07 : 0.05),
            separator: ink.withAlphaComponent(dark ? 0.10 : 0.09),
            chrome: background.blended(withFraction: dark ? 0.035 : 0.02, of: dark ? .white : .black) ?? background
        )
    }

    var baseSize: CGFloat { (font == .mono ? 13.5 : 14.5) * zoom }

    /// La police du corps du texte, avec une graisse et une taille relative.
    func bodyFont(scale: CGFloat = 1, weight: NSFont.Weight = .regular) -> NSFont {
        let size = (baseSize * scale).rounded(.toNearestOrEven)
        switch font {
        case .system:
            return .systemFont(ofSize: size, weight: weight)
        case .mono:
            return .monospacedSystemFont(ofSize: size * 0.97, weight: weight)
        case .serif:
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            if let descriptor = base.fontDescriptor.withDesign(.serif), let serif = NSFont(descriptor: descriptor, size: size) {
                return serif
            }
            return base
        }
    }

    func codeFont(scale: CGFloat = 0.9) -> NSFont {
        .monospacedSystemFont(ofSize: (baseSize * scale).rounded(.toNearestOrEven), weight: .regular)
    }

    var swiftBackground: Color { Color(nsColor: background) }
    var swiftText: Color { Color(nsColor: text) }
    var swiftSecondary: Color { Color(nsColor: secondary) }
    var swiftTertiary: Color { Color(nsColor: tertiary) }
    var swiftAccent: Color { Color(nsColor: accent) }
    var swiftFill: Color { Color(nsColor: fill) }
    var swiftSeparator: Color { Color(nsColor: separator) }
    var swiftChrome: Color { Color(nsColor: chrome) }
}

extension NSFont {
    /// La même police avec des traits ajoutés (gras, italique), synthétisés au besoin.
    func adding(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
