import AppKit
import SwiftUI

enum LauncherLayout {
    static let width: CGFloat = 760
    static let height: CGFloat = 476
    static let cornerRadius: CGFloat = 14
    static let searchHeight: CGFloat = 58
    static let footerHeight: CGFloat = 42
    static let rowHeight: CGFloat = 42
}

/// Couleurs du lanceur, tirées du thème en vigueur (celles du système pour les thèmes Prism).
@MainActor
enum Theme {
    static var current: PrismTheme { ThemeStore.shared.current }

    private static func hex(_ value: String?) -> NSColor? { value.flatMap(NSColor.init(hex:)) }

    static var accent: Color { Color(nsColor: hex(current.accent) ?? NSColor(srgbRed: 1, green: 0.38, blue: 0.38, alpha: 1)) }

    static var windowTint: Color {
        if let background = hex(current.background) {
            return Color(nsColor: background.withAlphaComponent(current.backgroundOpacity))
        }
        return dynamic(
            light: NSColor(white: 0.98, alpha: 0.62),
            dark: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 0.70)
        )
    }

    /// Couleur du texte du thème, pour les nuances des séparateurs et des pastilles.
    private static var ink: NSColor? { hex(current.text) }

    static var text: Color? { ink.map { Color(nsColor: $0) } }
    static var secondaryText: Color? { hex(current.secondaryText).map { Color(nsColor: $0) } }

    static var border: Color { tone(light: 0.12, dark: 0.13) }
    static var separator: Color { tone(light: 0.07, dark: 0.07) }
    static var selection: Color {
        if let selection = hex(current.selection) { return Color(nsColor: selection) }
        return tone(light: 0.07, dark: 0.09)
    }
    static var subtleFill: Color { tone(light: 0.03, dark: 0.035) }
    static var keycap: Color { tone(light: 0.06, dark: 0.08) }
    static var footer: Color { tone(light: 0.025, dark: 0.025) }
    static var popover: Color {
        if let background = hex(current.background) {
            return Color(nsColor: background.blended(withFraction: 0.06, of: ink ?? .white) ?? background)
        }
        return dynamic(
            light: NSColor(white: 0.985, alpha: 0.98),
            dark: NSColor(srgbRed: 0.15, green: 0.15, blue: 0.16, alpha: 0.98)
        )
    }

    /// Une nuance du texte : noir sur fond clair, blanc sur fond sombre, ou la couleur du thème.
    private static func tone(light: CGFloat, dark: CGFloat) -> Color {
        if let ink {
            return Color(nsColor: ink.withAlphaComponent(current.isDark ? dark : light))
        }
        return dynamic(light: NSColor(white: 0, alpha: light), dark: NSColor(white: 1, alpha: dark))
    }

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// L'apparence imposée au lanceur par le thème.
    static var appearance: NSAppearance? {
        NSAppearance(named: current.isDark ? .darkAqua : .aqua)
    }
}

extension View {
    /// Les couleurs de texte du thème, si elles sont définies.
    @ViewBuilder
    func themedText() -> some View {
        if let text = Theme.text {
            foregroundStyle(text, Theme.secondaryText ?? text.opacity(0.6), (Theme.secondaryText ?? text).opacity(0.6))
        } else {
            self
        }
    }
}

struct ItemIconView: View {
    let icon: ItemIcon
    var size: CGFloat = 22

    var body: some View {
        switch icon {
        case .file(let path):
            Image(nsImage: IconCache.icon(for: path))
                .resizable()
                .interpolation(.high)
                .frame(width: size + 4, height: size + 4)
        case .symbol(let name, let color):
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(color.gradient)
                .overlay(
                    Image(systemName: name)
                        .font(.system(size: size * 0.52, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .frame(width: size, height: size)
                .padding(2)
        case .glyph(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.6, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size + 4, height: size + 4)
        case .tinted(let name, let color):
            Image(systemName: name)
                .font(.system(size: size * 0.62, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: size + 4, height: size + 4)
        case .emoji(let character):
            Text(character)
                .font(.system(size: size * 0.9))
                .frame(width: size + 4, height: size + 4)
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size + 2, height: size + 2)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
                .padding(1)
        case .color(let color):
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color(nsColor: color))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
                )
                .frame(width: size, height: size)
                .padding(2)
        case .favicon(let url):
            FaviconView(url: url, size: size)
        case .remote(let url, let fallback):
            RemoteImageView(url: url, fallback: fallback, size: size)
        case .none:
            Color.clear.frame(width: size, height: size)
        }
    }
}

/// Favicon d'un site, demandée au site lui-même (`/favicon.ico`), puis gardée en mémoire.
private struct FaviconView: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size * 0.8, height: size * 0.8)
                    .frame(width: size + 4, height: size + 4)
            } else {
                ItemIconView(icon: .symbol("globe", Palette.blue), size: size)
            }
        }
        .task(id: url.host) {
            image = await FaviconCache.shared.icon(for: url)
        }
    }
}

/// Image distante gardée en mémoire (icônes du Store).
private struct RemoteImageView: View {
    let url: URL
    let fallback: String
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .frame(width: size + 4, height: size + 4)
            } else {
                ItemIconView(icon: .symbol(fallback, Palette.gray), size: size)
            }
        }
        .task(id: url) {
            image = await FaviconCache.shared.image(at: url)
        }
    }
}

@MainActor
final class FaviconCache {
    static let shared = FaviconCache()
    private var cache: [String: NSImage] = [:]
    private var failed = Set<String>()

    func icon(for url: URL) async -> NSImage? {
        guard let host = url.host else { return nil }
        if let cached = cache[host] { return cached }
        if failed.contains(host) { return nil }
        let scheme = url.scheme ?? "https"
        // Fournisseur choisi dans les réglages : le site lui-même par défaut, DuckDuckGo, Google, ou aucun.
        let address: String
        switch Preferences.shared.faviconProvider {
        case "none": return nil
        case "duckduckgo": address = "https://icons.duckduckgo.com/ip3/\(host).ico"
        case "google": address = "https://www.google.com/s2/favicons?domain=\(host)&sz=64"
        default: address = "\(scheme)://\(host)/favicon.ico"
        }
        guard let iconURL = URL(string: address) else { return nil }
        var request = URLRequest(url: iconURL)
        request.timeoutInterval = 4
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let image = NSImage(data: data), image.isValid {
            cache[host] = image
            return image
        }
        failed.insert(host)
        return nil
    }

    func image(at url: URL) async -> NSImage? {
        let key = url.absoluteString
        if let cached = cache[key] { return cached }
        if failed.contains(key) { return nil }
        if let (data, response) = try? await URLSession.shared.data(from: url),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let image = NSImage(data: data), image.isValid {
            cache[key] = image
            return image
        }
        failed.insert(key)
        return nil
    }
}

struct Keycap: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, symbol.count > 1 ? 5 : 0)
            .frame(minWidth: 20, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.keycap))
    }
}

struct KeycapRow: View {
    let symbols: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                Keycap(symbol: symbol)
            }
        }
    }
}

/// Étiquette arrondie : alias, raccourci, mot-clé.
struct TagView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.keycap))
            .fixedSize()
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Le logo de Prism, dessiné par le même code que l'icône de l'application.
struct PrismMark: View {
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: IconRenderer.image(size: size * 2))
            .resizable()
            .frame(width: size * 1.25, height: size * 1.25)
    }
}

/// Le champ de recherche, en AppKit pour maîtriser le focus et la sélection à chaque ouverture.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onCreate: (NSTextField) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = CaretTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.stringValue = text
        applyStyle(field)
        onCreate(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        applyStyle(field)
    }

    private func applyStyle(_ field: NSTextField) {
        let theme = ThemeStore.shared.current
        field.textColor = theme.text.flatMap(NSColor.init(hex:)) ?? .labelColor
        let placeholderColor = theme.secondaryText.flatMap(NSColor.init(hex:))?.withAlphaComponent(0.7) ?? .tertiaryLabelColor
        let current = field.placeholderAttributedString
        let currentColor = (current?.length ?? 0) > 0 ? current?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil
        if current?.string != placeholder || currentColor != placeholderColor {
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .foregroundColor: placeholderColor,
                .font: NSFont.systemFont(ofSize: 20, weight: .regular),
            ])
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField

        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}

private final class CaretTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = NSColor(hex: ThemeStore.shared.current.accent) ?? .systemRed
        }
        return result
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
