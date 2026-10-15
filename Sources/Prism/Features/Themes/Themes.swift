import AppKit
import SwiftUI

/// Un thème du lanceur : fond, textes, sélection, accent. Les couleurs absentes suivent le système.
struct PrismTheme: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// « dark » ou « light » : l'apparence forcée du lanceur.
    var appearance: String
    var background: String?
    var backgroundOpacity: Double = 0.92
    var text: String?
    var secondaryText: String?
    var selection: String?
    var accent: String
    var isBuiltIn = false

    var isDark: Bool { appearance == "dark" }

    static let prismDark = PrismTheme(id: "prism-dark", name: "Prism sombre", appearance: "dark", background: nil, text: nil, secondaryText: nil, selection: nil, accent: "#FF6161", isBuiltIn: true)
    static let prismLight = PrismTheme(id: "prism-light", name: "Prism clair", appearance: "light", background: nil, text: nil, secondaryText: nil, selection: nil, accent: "#FF6161", isBuiltIn: true)

    static let builtIn: [PrismTheme] = [
        prismDark,
        prismLight,
        PrismTheme(id: "midnight", name: "Minuit", appearance: "dark", background: "#0F1222", text: "#E6E9F5", secondaryText: "#8A90AD", selection: "#262B47", accent: "#7C8CFF", isBuiltIn: true),
        PrismTheme(id: "dracula", name: "Dracula", appearance: "dark", background: "#282A36", text: "#F8F8F2", secondaryText: "#9AA3C9", selection: "#44475A", accent: "#FF79C6", isBuiltIn: true),
        PrismTheme(id: "nord", name: "Nord", appearance: "dark", background: "#2E3440", text: "#ECEFF4", secondaryText: "#A3ABBA", selection: "#434C5E", accent: "#88C0D0", isBuiltIn: true),
        PrismTheme(id: "tokyo-night", name: "Tokyo Night", appearance: "dark", background: "#1A1B26", text: "#C0CAF5", secondaryText: "#7A82A8", selection: "#2F334D", accent: "#7AA2F7", isBuiltIn: true),
        PrismTheme(id: "catppuccin", name: "Catppuccin Mocha", appearance: "dark", background: "#1E1E2E", text: "#CDD6F4", secondaryText: "#9399B2", selection: "#313244", accent: "#CBA6F7", isBuiltIn: true),
        PrismTheme(id: "gruvbox", name: "Gruvbox", appearance: "dark", background: "#282828", text: "#EBDBB2", secondaryText: "#A89984", selection: "#3C3836", accent: "#FE8019", isBuiltIn: true),
        PrismTheme(id: "solarized-dark", name: "Solarized sombre", appearance: "dark", background: "#002B36", text: "#EEE8D5", secondaryText: "#93A1A1", selection: "#073642", accent: "#B58900", isBuiltIn: true),
        PrismTheme(id: "forest", name: "Forêt", appearance: "dark", background: "#14201A", text: "#E3EFE6", secondaryText: "#8FA897", selection: "#22352B", accent: "#4CC38A", isBuiltIn: true),
        PrismTheme(id: "solarized-light", name: "Solarized clair", appearance: "light", background: "#FDF6E3", text: "#073642", secondaryText: "#657B83", selection: "#EEE8D5", accent: "#CB4B16", isBuiltIn: true),
        PrismTheme(id: "rose-pine-dawn", name: "Rosé Pine Dawn", appearance: "light", background: "#FAF4ED", text: "#575279", secondaryText: "#9893A5", selection: "#F2E9E1", accent: "#D7827E", isBuiltIn: true),
        PrismTheme(id: "paper", name: "Papier", appearance: "light", background: "#FFFFFF", text: "#1D1D1F", secondaryText: "#86868B", selection: "#F0F0F2", accent: "#0A84FF", isBuiltIn: true),
        PrismTheme(id: "sakura", name: "Sakura", appearance: "light", background: "#FFF5F8", text: "#4A2C3A", secondaryText: "#A07C8C", selection: "#FCE4EC", accent: "#E5508E", isBuiltIn: true),
    ]
}

@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    struct Content: Codable {
        var custom: [PrismTheme] = []
        var darkTheme = PrismTheme.prismDark.id
        var lightTheme = PrismTheme.prismLight.id
        /// Suivre l'apparence du système (sinon : toujours le thème sombre).
        var followSystem = true
    }

    let store = JSONStore("themes.json", default: Content())

    private init() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ThemeStore.shared.changed() }
        }
    }

    var data: Content {
        get { store.value }
        set { store.value = newValue; changed() }
    }

    var all: [PrismTheme] { PrismTheme.builtIn + data.custom }

    func theme(_ id: String) -> PrismTheme? { all.first { $0.id == id } }

    var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            || UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// Le thème en vigueur, selon l'apparence du système.
    var current: PrismTheme {
        let dark = !data.followSystem || systemIsDark
        return theme(dark ? data.darkTheme : data.lightTheme) ?? (dark ? .prismDark : .prismLight)
    }

    func apply(_ theme: PrismTheme) {
        if theme.isDark { data.darkTheme = theme.id } else { data.lightTheme = theme.id }
    }

    func save(_ theme: PrismTheme) {
        var theme = theme
        theme.isBuiltIn = false
        if let index = data.custom.firstIndex(where: { $0.id == theme.id }) {
            data.custom[index] = theme
        } else {
            data.custom.append(theme)
        }
    }

    func delete(_ id: String) {
        data.custom.removeAll { $0.id == id }
        if data.darkTheme == id { data.darkTheme = PrismTheme.prismDark.id }
        if data.lightTheme == id { data.lightTheme = PrismTheme.prismLight.id }
    }

    func changed() {
        objectWillChange.send()
        NotificationCenter.default.post(name: .prismThemeDidChange, object: nil)
    }

    /// Le thème en JSON, à partager ou à coller dans « Importer un thème ».
    func json(for theme: PrismTheme) -> String {
        var exported = theme
        exported.isBuiltIn = false
        guard let data = try? JSONEncoder.prism.encode(exported) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func importTheme(_ json: String) -> PrismTheme? {
        guard var theme = try? JSONDecoder.prism.decode(PrismTheme.self, from: Data(json.utf8)) else { return nil }
        theme.id = "custom-" + UUID().uuidString.prefix(8).lowercased()
        theme.isBuiltIn = false
        save(theme)
        return theme
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let red = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var hexString: String {
        guard let color = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(round(color.redComponent * 255)), Int(round(color.greenComponent * 255)), Int(round(color.blueComponent * 255)))
    }
}

@MainActor
enum ThemesFeature: PrismFeature {
    static func screen() -> LauncherScreen {
        ListScreen(id: "themes", title: "Thèmes", placeholder: "Rechercher un thème…", icon: .symbol("paintpalette.fill", Palette.pink)) { query in
            let store = ThemeStore.shared
            let normalized = query.normalizedForSearch
            @MainActor func items(_ dark: Bool) -> [ResultItem] {
                store.all.filter { $0.isDark == dark && (normalized.isEmpty || Fuzzy.score(normalized, $0.name) != nil) }.map { theme in
                    let active = (dark ? store.data.darkTheme : store.data.lightTheme) == theme.id
                    var actions = [
                        ItemAction(title: "Appliquer le thème", symbol: "paintbrush") {
                            store.apply(theme)
                            return .refresh
                        },
                        ItemAction(title: "Copier en JSON", symbol: "curlybraces", shortcut: .copyText) {
                            Pasteboard.copy(store.json(for: theme))
                            return .toast("Thème copié en JSON")
                        },
                        ItemAction(title: "Dupliquer et modifier", symbol: "plus.square.on.square", shortcut: .duplicate) {
                            var copy = theme
                            copy.id = "custom-" + UUID().uuidString.prefix(8).lowercased()
                            copy.name = theme.name + " (copie)"
                            if copy.background == nil { copy.background = theme.isDark ? "#1C1C1F" : "#F7F7F8" }
                            store.save(copy)
                            NotificationCenter.default.post(name: .prismOpenSettings, object: "themes")
                            return .close
                        },
                    ]
                    if !theme.isBuiltIn {
                        actions.append(ItemAction(title: "Supprimer le thème", symbol: "trash", shortcut: .removeEntry, isDestructive: true) {
                            store.delete(theme.id)
                            return .refresh
                        })
                    }
                    return ResultItem(
                        id: "theme:" + theme.id,
                        title: theme.name,
                        subtitle: theme.isBuiltIn ? "Intégré" : "Personnalisé",
                        icon: .color(NSColor(hex: theme.accent) ?? .systemRed),
                        accessory: active ? "Actif" : nil,
                        usageKey: "",
                        actions: actions
                    )
                }
            }
            return [
                ResultSection(id: "dark", title: "Thèmes sombres", items: items(true)),
                ResultSection(id: "light", title: "Thèmes clairs", items: items(false)),
            ].filter { !$0.items.isEmpty }
        }
    }

    static var commands: [ResultItem] {
        [Command.screen("themes", "Changer de thème", subtitle: "Thèmes", symbol: "paintpalette.fill", color: Palette.pink, keywords: ["switch theme", "theme", "couleurs", "apparence"], screen: screen)]
    }

    static var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "themes", title: "Thèmes", symbol: "paintpalette.fill", color: Palette.pink, order: 20) { AnyView(ThemeSettingsView()) }]
    }
}

/// Réglages des thèmes : choix pour le mode clair et le mode sombre, éditeur de thème personnalisé.
struct ThemeSettingsView: View {
    @ObservedObject private var store = ThemeStore.shared
    @State private var editing: PrismTheme?
    @State private var importText = ""

    var body: some View {
        Form {
            Section {
                Toggle("Suivre l’apparence du système", isOn: Binding(
                    get: { store.data.followSystem },
                    set: { store.data.followSystem = $0 }
                ))
                Picker("Thème sombre", selection: Binding(get: { store.data.darkTheme }, set: { store.data.darkTheme = $0 })) {
                    ForEach(store.all.filter(\.isDark)) { Text($0.name).tag($0.id) }
                }
                Picker("Thème clair", selection: Binding(get: { store.data.lightTheme }, set: { store.data.lightTheme = $0 })) {
                    ForEach(store.all.filter { !$0.isDark }) { Text($0.name).tag($0.id) }
                }
            }
            Section("Galerie") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(store.all) { theme in
                        ThemeSwatch(theme: theme, isActive: store.current.id == theme.id)
                            .onTapGesture { store.apply(theme) }
                            .contextMenu {
                                Button("Modifier une copie") { editing = copy(of: theme) }
                                Button("Copier en JSON") { Pasteboard.copy(store.json(for: theme)) }
                                if !theme.isBuiltIn {
                                    Button("Modifier") { editing = theme }
                                    Button("Supprimer", role: .destructive) { store.delete(theme.id) }
                                }
                            }
                    }
                }
                .padding(.vertical, 4)
                HStack {
                    Button("Nouveau thème…") { editing = copy(of: store.current) }
                    Spacer()
                    TextField("Coller un thème JSON", text: $importText)
                        .frame(width: 200)
                    Button("Importer") {
                        if store.importTheme(importText) != nil { importText = "" }
                    }
                    .disabled(importText.isEmpty)
                }
            }
            if let editing {
                Section("Éditeur") {
                    ThemeEditor(theme: Binding(get: { self.editing ?? editing }, set: { self.editing = $0 }))
                    HStack {
                        Button("Annuler") { self.editing = nil }
                        Spacer()
                        Button("Enregistrer et appliquer") {
                            if let theme = self.editing {
                                store.save(theme)
                                store.apply(theme)
                            }
                            self.editing = nil
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func copy(of theme: PrismTheme) -> PrismTheme {
        var copy = theme
        copy.id = "custom-" + UUID().uuidString.prefix(8).lowercased()
        copy.name = theme.name + " (personnalisé)"
        copy.background = copy.background ?? (theme.isDark ? "#1C1C1F" : "#F7F7F8")
        copy.text = copy.text ?? (theme.isDark ? "#F2F2F4" : "#1D1D1F")
        copy.secondaryText = copy.secondaryText ?? (theme.isDark ? "#9B9BA3" : "#7A7A80")
        copy.selection = copy.selection ?? (theme.isDark ? "#2E2E33" : "#E9E9EC")
        copy.isBuiltIn = false
        return copy
    }
}

private struct ThemeEditor: View {
    @Binding var theme: PrismTheme

    var body: some View {
        TextField("Nom", text: $theme.name)
        Picker("Apparence", selection: $theme.appearance) {
            Text("Sombre").tag("dark")
            Text("Claire").tag("light")
        }
        colorRow("Fond", \.background, fallback: theme.isDark ? "#1C1C1F" : "#F7F7F8")
        Slider(value: $theme.backgroundOpacity, in: 0.5...1) { Text("Opacité du fond") }
        colorRow("Texte", \.text, fallback: theme.isDark ? "#F2F2F4" : "#1D1D1F")
        colorRow("Texte secondaire", \.secondaryText, fallback: "#8E8E93")
        colorRow("Sélection", \.selection, fallback: theme.isDark ? "#2E2E33" : "#E9E9EC")
        ColorPicker("Accent", selection: Binding(
            get: { Color(nsColor: NSColor(hex: theme.accent) ?? .systemRed) },
            set: { theme.accent = NSColor($0).hexString }
        ), supportsOpacity: false)
        ThemeSwatch(theme: theme, isActive: false)
            .frame(width: 180)
    }

    private func colorRow(_ label: String, _ path: WritableKeyPath<PrismTheme, String?>, fallback: String) -> some View {
        ColorPicker(label, selection: Binding(
            get: { Color(nsColor: NSColor(hex: theme[keyPath: path] ?? fallback) ?? .gray) },
            set: { theme[keyPath: path] = NSColor($0).hexString }
        ), supportsOpacity: false)
    }
}

/// Aperçu d'un thème : un mini lanceur.
struct ThemeSwatch: View {
    let theme: PrismTheme
    let isActive: Bool

    var body: some View {
        let background = theme.background.flatMap(NSColor.init(hex:)).map(Color.init(nsColor:)) ?? (theme.isDark ? Color(white: 0.13) : Color(white: 0.96))
        let text = theme.text.flatMap(NSColor.init(hex:)).map(Color.init(nsColor:)) ?? (theme.isDark ? .white : .black)
        let secondary = theme.secondaryText.flatMap(NSColor.init(hex:)).map(Color.init(nsColor:)) ?? .gray
        let selection = theme.selection.flatMap(NSColor.init(hex:)).map(Color.init(nsColor:)) ?? (theme.isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.07))
        let accent = Color(nsColor: NSColor(hex: theme.accent) ?? .systemRed)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Capsule().fill(accent).frame(width: 2, height: 10)
                Capsule().fill(secondary.opacity(0.6)).frame(width: 46, height: 5)
            }
            RoundedRectangle(cornerRadius: 4).fill(selection).frame(height: 12)
                .overlay(alignment: .leading) {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 7, height: 7)
                        Capsule().fill(text.opacity(0.85)).frame(width: 40, height: 4)
                    }
                    .padding(.leading, 4)
                }
            Capsule().fill(text.opacity(0.4)).frame(width: 60, height: 4).padding(.leading, 4)
            Text(theme.name)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(text)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isActive ? accent : Color.primary.opacity(0.12), lineWidth: isActive ? 2 : 1)
        )
    }
}
