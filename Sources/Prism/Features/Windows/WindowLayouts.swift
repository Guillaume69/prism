import AppKit
import ApplicationServices

/// Dispositions : enregistrer les fenêtres visibles, puis les remettre en place (en lançant les apps manquantes).
@MainActor
enum LayoutEngine {
    /// Au plus huit fenêtres par écran, comme Raycast.
    nonisolated static let maxWindowsPerScreen = 8

    // MARK: - Parties pures

    /// Garde les `limit` premières fenêtres de chaque écran, dans l'ordre reçu (de l'avant vers l'arrière).
    static func limitPerScreen(_ windows: [SavedWindow], limit: Int = maxWindowsPerScreen) -> [SavedWindow] {
        var counts: [Int: Int] = [:]
        return windows.filter { window in
            counts[window.screenIndex, default: 0] += 1
            return counts[window.screenIndex, default: 0] <= limit
        }
    }

    /// L'écran actuel d'une fenêtre enregistrée : même nom, sinon même rang, sinon l'écran principal.
    static func screenIndex(for window: SavedWindow, screenNames: [String]) -> Int {
        if let name = window.screenName, let index = screenNames.firstIndex(of: name) {
            // Deux écrans du même modèle : le rang départage.
            if screenNames.filter({ $0 == name }).count > 1, screenNames.indices.contains(window.screenIndex), screenNames[window.screenIndex] == name {
                return window.screenIndex
            }
            return index
        }
        return screenNames.indices.contains(window.screenIndex) ? window.screenIndex : 0
    }

    /// Associe les fenêtres enregistrées aux fenêtres ouvertes d'une app : même titre d'abord, puis dans l'ordre.
    static func match(saved: [String], open: [String]) -> [Int?] {
        var used = Set<Int>()
        var result: [Int?] = Array(repeating: nil, count: saved.count)
        for (index, title) in saved.enumerated() {
            if let found = open.indices.first(where: { !used.contains($0) && open[$0] == title && !title.isEmpty }) {
                result[index] = found
                used.insert(found)
            }
        }
        for index in saved.indices where result[index] == nil {
            if let found = open.indices.first(where: { !used.contains($0) }) {
                result[index] = found
                used.insert(found)
            }
        }
        return result
    }

    // MARK: - Enregistrer

    /// Les fenêtres visibles, de l'avant vers l'arrière (ordre de la pile de WindowServer).
    static func captureWindows() -> [SavedWindow] {
        let screens = NSScreen.screens
        let axScreens = WindowGeometry.axScreens(screens.map { ($0.frame, $0.visibleFrame) }, primaryHeight: WindowManager.primaryHeight)
        let order = stackingOrder()
        var captured: [(window: SavedWindow, rank: Int)] = []
        for app in WindowManager.regularApps() where !app.isHidden {
            for window in AX.windows(of: app.processIdentifier) {
                guard AX.isStandardWindow(window), AX.bool(window, kAXMinimizedAttribute) != true,
                      AX.bool(window, "AXFullScreen") != true, let frame = AX.frame(window), frame.width > 40, frame.height > 40,
                      let screen = WindowGeometry.screenIndex(for: frame, in: axScreens) else { continue }
                let saved = SavedWindow(
                    appName: app.localizedName ?? "App",
                    bundleID: app.bundleIdentifier,
                    appPath: app.bundleURL?.path,
                    title: AX.string(window, kAXTitleAttribute) ?? "",
                    relative: WindowGeometry.relativeFrame(frame, in: axScreens[screen].visible),
                    screenIndex: screen,
                    screenName: screens[screen].localizedName
                )
                let rank = order.firstIndex { $0.pid == app.processIdentifier && WindowGeometry.matches($0.bounds, frame) } ?? Int.max
                captured.append((saved, rank))
            }
        }
        return limitPerScreen(captured.sorted { $0.rank < $1.rank }.map(\.window))
    }

    /// La pile des fenêtres à l'écran (sans titre : pas besoin de l'enregistrement de l'écran).
    private static func stackingOrder() -> [(pid: pid_t, bounds: CGRect)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
            return (pid, bounds)
        }
    }

    static func saveCurrent(name: String, otherWindows: OtherWindowsBehavior, replacing id: String? = nil) -> ActionOutcome {
        guard AccessibilityGate.isGranted else { return WindowManager.withTarget { _ in .close } }
        let windows = captureWindows()
        guard !windows.isEmpty else { return .toast("Aucune fenêtre visible à enregistrer") }
        let layout = SavedWindowLayout(id: id ?? WindowStore.newID(), name: name, created: Date(), otherWindows: otherWindows, windows: windows)
        WindowStore.shared.save(layout)
        return .then(.popToRoot, .hud("Disposition « \(name) » enregistrée (\(windows.count) fenêtre\(windows.count > 1 ? "s" : ""))"))
    }

    // MARK: - Appliquer

    static func apply(_ layout: SavedWindowLayout) -> ActionOutcome {
        guard AccessibilityGate.isGranted else { return WindowManager.withTarget { _ in .close } }
        Task { @MainActor in await run(layout) }
        return .hud("Disposition « \(layout.name) »")
    }

    private static func runningApp(for window: SavedWindow) -> NSRunningApplication? {
        let apps = WindowManager.regularApps()
        if let bundleID = window.bundleID, let app = apps.first(where: { $0.bundleIdentifier == bundleID }) { return app }
        return apps.first { $0.localizedName == window.appName }
    }

    private static func run(_ layout: SavedWindowLayout) async {
        // 1. Lancer les apps absentes, sans les mettre devant.
        var launched = false
        for window in layout.windows where runningApp(for: window) == nil {
            let url = window.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                ?? window.appPath.map { URL(fileURLWithPath: $0) }
            guard let url, FileManager.default.fileExists(atPath: url.path) else { continue }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            launched = true
        }
        // 2. Attendre que leurs fenêtres apparaissent (six secondes au plus).
        if launched {
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                let ready = layout.windows.allSatisfy { window in
                    guard let app = runningApp(for: window) else { return true }
                    return !AX.windows(of: app.processIdentifier).isEmpty
                }
                if ready { break }
            }
        }

        // 3. Placer chaque fenêtre sur son écran.
        let screens = NSScreen.screens
        let axScreens = WindowGeometry.axScreens(screens.map { ($0.frame, $0.visibleFrame) }, primaryHeight: WindowManager.primaryHeight)
        let names = screens.map(\.localizedName)
        var placed: [(window: AXUIElement, app: NSRunningApplication)] = []
        let byApp = Dictionary(grouping: limitPerScreen(layout.windows).enumerated(), by: { runningApp(for: $0.element)?.processIdentifier ?? -1 })
        for (pid, entries) in byApp where pid != -1 {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            if app.isHidden { app.unhide() }
            let open = AX.windows(of: pid).filter(AX.isStandardWindow)
            let matches = match(saved: entries.map(\.element.title), open: open.map { AX.string($0, kAXTitleAttribute) ?? "" })
            for (entry, found) in zip(entries, matches) {
                guard let found else { continue }
                let window = open[found]
                if AX.bool(window, kAXMinimizedAttribute) == true { AX.set(window, kAXMinimizedAttribute, bool: false) }
                let screen = screenIndex(for: entry.element, screenNames: names)
                let frame = WindowGeometry.absoluteFrame(entry.element.relative, in: axScreens[screen].visible)
                AX.setFrame(window, frame, pid: pid)
                placed.append((window, app))
            }
        }

        // 4. Les autres fenêtres.
        let placedPIDs = Set(placed.map(\.app.processIdentifier))
        switch layout.otherWindows {
        case .keep:
            break
        case .hide:
            for app in WindowManager.regularApps() where !placedPIDs.contains(app.processIdentifier) { app.hide() }
        case .minimize:
            for app in WindowManager.regularApps() where !app.isHidden {
                for window in AX.windows(of: app.processIdentifier) where AX.isStandardWindow(window) {
                    guard !placed.contains(where: { CFEqual($0.window, window) }) else { continue }
                    AX.set(window, kAXMinimizedAttribute, bool: true)
                }
            }
        }

        // 5. Remettre la pile : de l'arrière vers l'avant, la première fenêtre enregistrée finit devant.
        let ordered = layout.windows.enumerated().compactMap { index, saved -> (Int, AXUIElement, NSRunningApplication)? in
            guard let app = runningApp(for: saved), let element = placed.first(where: { $0.app == app && AX.string($0.window, kAXTitleAttribute) == saved.title })?.window else { return nil }
            return (index, element, app)
        }
        for (_, window, _) in ordered.reversed() { AX.perform(window, kAXRaiseAction) }
        if let front = ordered.first { WindowManager.focus(front.1, of: front.2) }
    }
}
