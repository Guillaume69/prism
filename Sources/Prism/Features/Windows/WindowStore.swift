import AppKit

/// Les réglages de la gestion des fenêtres, dans UserDefaults (« windows.… »).
@MainActor
final class WindowPreferences: ObservableObject {
    static let shared = WindowPreferences()

    private let defaults = UserDefaults.standard

    /// Écart entre les fenêtres et avec les bords, de 0 à 32 pt.
    @Published var gap: Double {
        didSet { defaults.set(gap, forKey: "windows.gap") }
    }

    @Published var repeatHalf: RepeatHalfBehavior {
        didSet { defaults.set(repeatHalf.rawValue, forKey: "windows.repeatHalf") }
    }

    /// Laisser la place à la bande de Stage Manager quand il est actif.
    @Published var respectStageManager: Bool {
        didSet { defaults.set(respectStageManager, forKey: "windows.stageManager") }
    }

    @Published var stageManagerWidth: Double {
        didSet { defaults.set(stageManagerWidth, forKey: "windows.stageManagerWidth") }
    }

    private init() {
        gap = defaults.object(forKey: "windows.gap") as? Double ?? 0
        repeatHalf = defaults.string(forKey: "windows.repeatHalf").flatMap(RepeatHalfBehavior.init(rawValue:)) ?? .cycle
        respectStageManager = defaults.object(forKey: "windows.stageManager") as? Bool ?? true
        stageManagerWidth = defaults.object(forKey: "windows.stageManagerWidth") as? Double ?? 190
    }

    /// Stage Manager est-il actif, avec sa bande visible ?
    static var stageManagerIsActive: Bool {
        guard let settings = UserDefaults(suiteName: "com.apple.WindowManager") else { return false }
        return settings.bool(forKey: "GloballyEnabled") && !settings.bool(forKey: "AutoHide")
    }

    var options: WindowOptions {
        WindowOptions(
            gap: CGFloat(min(max(gap, 0), 32)),
            repeatHalf: repeatHalf,
            stageManagerMargin: respectStageManager && Self.stageManagerIsActive ? CGFloat(stageManagerWidth) : 0
        )
    }
}

/// Une commande de fenêtre créée par l'utilisateur.
struct CustomWindowCommand: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var spec: CustomWindowSpec

    var commandID: String { "command:window.custom." + id }
}

/// Une fenêtre retenue dans une disposition.
struct SavedWindow: Codable, Equatable {
    var appName: String
    var bundleID: String?
    var appPath: String?
    var title: String
    /// Cadre en fractions de la zone utile de l'écran (y compté depuis le haut).
    var relative: CGRect
    /// Rang de l'écran dans `NSScreen.screens` au moment de l'enregistrement, et son nom.
    var screenIndex: Int
    var screenName: String?
}

/// Que faire des fenêtres qui ne sont pas dans la disposition.
enum OtherWindowsBehavior: String, Codable, CaseIterable {
    case keep, minimize, hide

    var title: String {
        switch self {
        case .keep: "Les laisser"
        case .minimize: "Les réduire dans le Dock"
        case .hide: "Masquer leurs applications"
        }
    }
}

/// Une disposition de fenêtres enregistrée.
struct SavedWindowLayout: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var created: Date
    var otherWindows: OtherWindowsBehavior
    var windows: [SavedWindow]

    var commandID: String { "command:window.layout." + id }

    /// « 5 fenêtres · Safari, Mail, Terminal ».
    var summary: String {
        var apps: [String] = []
        for window in windows where !apps.contains(window.appName) { apps.append(window.appName) }
        let count = windows.count == 1 ? "1 fenêtre" : "\(windows.count) fenêtres"
        return apps.isEmpty ? count : count + " · " + apps.prefix(4).joined(separator: ", ") + (apps.count > 4 ? "…" : "")
    }
}

/// Commandes personnalisées et dispositions : `windows.json` dans Application Support.
@MainActor
final class WindowStore: ObservableObject {
    static let shared = WindowStore()

    struct Content: Codable {
        var commands: [CustomWindowCommand] = []
        var layouts: [SavedWindowLayout] = []
    }

    let store = JSONStore("windows.json", default: Content())

    private init() {}

    var data: Content {
        get { store.value }
        set { store.value = newValue; objectWillChange.send() }
    }

    func save(_ command: CustomWindowCommand) {
        if let index = data.commands.firstIndex(where: { $0.id == command.id }) {
            data.commands[index] = command
        } else {
            data.commands.append(command)
        }
    }

    func deleteCommand(_ id: String) {
        data.commands.removeAll { $0.id == id }
    }

    func command(named name: String) -> CustomWindowCommand? {
        let key = name.normalizedForSearch
        return data.commands.first { $0.name.normalizedForSearch == key }
    }

    func save(_ layout: SavedWindowLayout) {
        if let index = data.layouts.firstIndex(where: { $0.id == layout.id }) {
            data.layouts[index] = layout
        } else {
            data.layouts.append(layout)
        }
    }

    func deleteLayout(_ id: String) {
        data.layouts.removeAll { $0.id == id }
    }

    func layout(named name: String) -> SavedWindowLayout? {
        let key = name.normalizedForSearch
        return data.layouts.first { $0.name.normalizedForSearch == key }
    }

    static func newID() -> String { UUID().uuidString.prefix(8).lowercased() }
}
