import AppKit
import ApplicationServices

/// Une fenêtre ouverte, trouvée par l'accessibilité.
struct OpenWindow {
    let element: AXUIElement
    let pid: pid_t
    let appName: String
    let appPath: String?
    let title: String
    let isMinimized: Bool
    let isAppHidden: Bool
    /// Rang dans la pile des fenêtres à l'écran (0 : devant) ; `Int.max` hors écran.
    let rank: Int
}

/// Les fenêtres de toutes les applications régulières. Hors du fil principal : une app lente ne bloque pas le lanceur.
enum WindowLister {
    struct AppInfo: Sendable {
        let pid: pid_t
        let name: String
        let path: String?
        let isHidden: Bool
    }

    static func list(_ apps: [AppInfo]) -> [OpenWindow] {
        let stack = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { info -> (pid: pid_t, bounds: CGRect)? in
                guard (info[kCGWindowLayer as String] as? Int) == 0, let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                      let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: dictionary) else { return nil }
                return (pid, bounds)
            }
        var result: [OpenWindow] = []
        for app in apps {
            for window in AX.windows(of: app.pid, timeout: 0.3) where AX.isStandardWindow(window) {
                let title = AX.string(window, kAXTitleAttribute) ?? ""
                let frame = AX.frame(window) ?? .zero
                let rank = stack.firstIndex { $0.pid == app.pid && WindowGeometry.matches($0.bounds, frame) } ?? Int.max
                result.append(OpenWindow(
                    element: window, pid: app.pid, appName: app.name, appPath: app.path, title: title,
                    isMinimized: AX.bool(window, kAXMinimizedAttribute) == true, isAppHidden: app.isHidden, rank: rank
                ))
            }
        }
        return result.sorted { $0.rank == $1.rank ? ($0.appName, $0.title) < ($1.appName, $1.title) : $0.rank < $1.rank }
    }
}

/// « Changer de fenêtre » : toutes les fenêtres ouvertes, la plus récente devant.
@MainActor
final class WindowSwitcherScreen: LauncherScreen {
    private var windows: [OpenWindow] = []
    private var loaded = false

    init() {
        super.init(id: "navigation.windows", title: "Changer de fenêtre", placeholder: "Rechercher une fenêtre ou une application…",
                   icon: .symbol("macwindow.on.rectangle", NavigationFeature.color))
    }

    override func didAppear() {
        guard AccessibilityGate.isGranted, !isLoading else { return }
        isLoading = true
        let apps = WindowManager.regularApps().map {
            WindowLister.AppInfo(pid: $0.processIdentifier, name: $0.localizedName ?? "App", path: $0.bundleURL?.path, isHidden: $0.isHidden)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let windows = WindowLister.list(apps)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.windows = windows
                    self.loaded = true
                    self.isLoading = false
                    self.reload()
                }
            }
        }
    }

    override func sections(query: String) -> [ResultSection] {
        guard AccessibilityGate.isGranted else { return [] }
        let normalized = query.normalizedForSearch
        let matching: [(window: OpenWindow, index: Int, score: Double)] = windows.enumerated().compactMap { index, window in
            guard !normalized.isEmpty else { return (window, index, 0) }
            var best = Fuzzy.score(normalized, window.title)
            if let score = Fuzzy.score(normalized, window.appName).map({ $0 * 0.9 }), score > (best ?? 0) { best = score }
            if let score = Fuzzy.score(normalized, window.appName + " " + window.title).map({ $0 * 0.8 }), score > (best ?? 0) { best = score }
            return best.map { (window, index, $0) }
        }
        let sorted = normalized.isEmpty ? matching : matching.sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
        let items = sorted.map { item($0.window, index: $0.index) }
        return items.isEmpty ? [] : [ResultSection(id: "windows", title: "Fenêtres ouvertes", items: items)]
    }

    private func item(_ window: OpenWindow, index: Int) -> ResultItem {
        let element = window.element
        let app = NSRunningApplication(processIdentifier: window.pid)
        let state = window.isAppHidden ? "Masquée" : window.isMinimized ? "Réduite" : nil
        return ResultItem(
            id: "window.\(window.pid).\(index)",
            title: window.title.isEmpty ? window.appName : window.title,
            subtitle: window.title.isEmpty ? nil : window.appName,
            icon: window.appPath.map { .file($0) } ?? .symbol("macwindow", NavigationFeature.color),
            accessory: state,
            keywords: [window.appName],
            usageKey: "",
            actions: [
                ItemAction(title: "Amener devant", symbol: "macwindow") {
                    guard let app else { return .toast("L’application n’est plus ouverte") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { WindowManager.focus(element, of: app) }
                    return .close
                },
                ItemAction(title: "Réduire la fenêtre", symbol: "minus.rectangle", shortcut: KeyShortcut(keyCode: 46, modifiers: [.command], label: "M"), section: "Fenêtre") { [weak self] in
                    AX.set(element, kAXMinimizedAttribute, bool: true)
                    self?.didAppear()
                    return .toast("Fenêtre réduite")
                },
                ItemAction(title: "Fermer la fenêtre", symbol: "xmark.square", shortcut: KeyShortcut(keyCode: 13, modifiers: [.command, .shift], label: "W"), isDestructive: true, section: "Fenêtre") { [weak self] in
                    guard let button = AX.element(element, kAXCloseButtonAttribute), AX.perform(button, kAXPressAction) else {
                        return .toast("Cette fenêtre ne se ferme pas ainsi")
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.didAppear() }
                    return .toast("Fenêtre fermée")
                },
                ItemAction(title: "Basculer le plein écran", symbol: "arrow.up.left.and.arrow.down.right", shortcut: KeyShortcut(keyCode: 3, modifiers: [.command, .control], label: "F"), section: "Fenêtre") {
                    guard let app else { return .close }
                    let isFull = AX.bool(element, "AXFullScreen") ?? false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        WindowManager.focus(element, of: app)
                        AX.set(element, "AXFullScreen", bool: !isFull)
                    }
                    return .close
                },
                ItemAction(title: "Masquer \(window.appName)", symbol: "eye.slash", shortcut: KeyShortcut(keyCode: 4, modifiers: [.command, .shift], label: "H"), section: "Application") { [weak self] in
                    app?.hide()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.didAppear() }
                    return .toast("\(window.appName) masquée")
                },
                ItemAction(title: "Quitter \(window.appName)", symbol: "xmark.circle", shortcut: .quitApp, isDestructive: true, section: "Application") { [weak self] in
                    app?.terminate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.didAppear() }
                    return .toast("\(window.appName) quittée")
                },
            ]
        )
    }

    override func emptyState(query: String) -> (symbol: String, message: String) {
        guard AccessibilityGate.isGranted else { return ("lock.shield", "Prism doit être autorisé à voir les fenêtres des autres applications.\n" + AccessibilityGate.explanation) }
        if isLoading || !loaded { return ("hourglass", "Recherche des fenêtres…") }
        return query.isEmpty ? ("macwindow", "Aucune fenêtre ouverte") : ("magnifyingglass", "Aucune fenêtre pour « \(query) »")
    }

    override var screenActions: [ItemAction] {
        AccessibilityGate.isGranted ? [] : [AccessibilityGate.requestAction]
    }
}
