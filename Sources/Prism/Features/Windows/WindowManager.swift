import AppKit
import ApplicationServices

/// Range la fenêtre active de l'application qui était au premier plan, par l'API d'accessibilité.
@MainActor
enum WindowManager {
    /// Une fenêtre trouvée : son élément, son application, son cadre (repère de l'accessibilité).
    struct Target {
        let window: AXUIElement
        let app: NSRunningApplication
        let frame: CGRect
    }

    enum WindowError: Error {
        case notTrusted, noApp, noWindow(String), unreadable

        var message: String {
            switch self {
            case .notTrusted: "Autorisez Prism dans Réglages Système › Accessibilité"
            case .noApp: "Aucune fenêtre au premier plan"
            case .noWindow(let app): "Aucune fenêtre à ranger dans \(app)"
            case .unreadable: "Impossible de lire la fenêtre"
            }
        }
    }

    // MARK: - Fenêtre visée

    /// La fenêtre active de `AppContext.previousApp`. Sans autorisation, la demande (action de l'utilisateur).
    static func target() -> Result<Target, WindowError> {
        guard AccessibilityGate.isGranted else {
            if !AccessibilityGate.isHeadless { Paster.requestTrust() }
            return .failure(.notTrusted)
        }
        guard let app = AppContext.previousApp else { return .failure(.noApp) }
        guard let window = AX.focusedWindow(of: app.processIdentifier) else {
            return .failure(.noWindow(app.localizedName ?? "l’application"))
        }
        guard let frame = AX.frame(window) else { return .failure(.unreadable) }
        return .success(Target(window: window, app: app, frame: frame))
    }

    /// Exécute une opération sur la fenêtre visée ; en cas d'échec, un message dans le lanceur.
    static func withTarget(_ body: (Target) -> ActionOutcome) -> ActionOutcome {
        switch target() {
        case .success(let target): body(target)
        case .failure(let error): .toast(error.message)
        }
    }

    /// Les écrans en repère Cocoa, et la hauteur de l'écran principal pour passer à l'accessibilité.
    static var screens: [WindowGeometry.Screen] {
        NSScreen.screens.map { screen in
            (screen.frame, MenuBarInsets.usable(frame: screen.frame, visible: screen.visibleFrame))
        }
    }
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    // MARK: - Rangements

    static func apply(_ layout: WindowLayout) -> ActionOutcome {
        withTarget { target in
            let compute = { targetFrame(layout, current: target.frame, screens: screens, primaryHeight: primaryHeight, options: WindowPreferences.shared.options) }
            place(target, compute(), recompute: compute)
            return .close
        }
    }

    static func apply(_ spec: CustomWindowSpec) -> ActionOutcome {
        withTarget { target in
            let compute = { WindowGeometry.customFrame(spec, current: target.frame, screens: screens, primaryHeight: primaryHeight, options: WindowPreferences.shared.options) }
            place(target, compute(), recompute: compute)
            return .close
        }
    }

    /// Cadre cible dans le repère de l'accessibilité (origine en haut à gauche de l'écran principal),
    /// sur l'écran qui contient la plus grande part de la fenêtre. Pure, pour être testée.
    static func targetFrame(
        _ layout: WindowLayout,
        current: CGRect,
        screens: [(frame: CGRect, visible: CGRect)],
        primaryHeight: CGFloat,
        options: WindowOptions = WindowOptions()
    ) -> CGRect {
        WindowGeometry.targetFrame(layout, current: current, screens: screens, primaryHeight: primaryHeight, options: options)
    }

    /// Place la fenêtre en retenant son cadre d'avant, pour « Restaurer ».
    /// `recompute` : si macOS a repoussé la fenêtre sous une barre des menus que l'écran ne déclare pas,
    /// la barre est retenue pour cet écran et le cadre recalculé, pour que les moitiés se touchent sans se chevaucher.
    static func place(_ target: Target, _ frame: CGRect, recompute: (() -> CGRect)? = nil) {
        RestoreMemory.remember(target.window, frame: target.frame)
        AX.setFrame(target.window, frame, pid: target.app.processIdentifier)
        guard let recompute, let origin = AX.point(target.window) else { return }
        let learned = NSScreen.screens.contains { screen in
            MenuBarInsets.learn(frame: screen.frame, visible: screen.visibleFrame, primaryHeight: primaryHeight, wanted: frame, actualTop: origin.y)
        }
        if learned { AX.setFrame(target.window, recompute(), pid: target.app.processIdentifier) }
    }

    /// Redimensionner (formulaire) : largeur et hauteur en points ou en % de la zone utile de l'écran.
    static func resize(width: WindowDimension, height: WindowDimension) -> ActionOutcome {
        withTarget { target in
            let area = visibleArea(containing: target.frame)
            var frame = target.frame
            frame.size = CGSize(width: max(width.resolve(area.width), 40).rounded(), height: max(height.resolve(area.height), 40).rounded())
            place(target, frame)
            return .close
        }
    }

    /// Déplacer (formulaire) : le coin haut gauche, compté depuis celui de la zone utile de l'écran.
    static func move(x: WindowDimension, y: WindowDimension) -> ActionOutcome {
        withTarget { target in
            let area = visibleArea(containing: target.frame)
            var frame = target.frame
            frame.origin = CGPoint(x: (area.minX + x.resolve(area.width)).rounded(), y: (area.minY + y.resolve(area.height)).rounded())
            place(target, frame)
            return .close
        }
    }

    /// La zone utile de l'écran de la fenêtre, dans le repère de l'accessibilité.
    static func visibleArea(containing frame: CGRect) -> CGRect {
        let axScreens = WindowGeometry.axScreens(screens, primaryHeight: primaryHeight)
        guard let index = WindowGeometry.screenIndex(for: frame, in: axScreens) else { return frame }
        return axScreens[index].visible
    }

    /// Remet la taille et la position d'avant la dernière commande de Prism.
    static func restore() -> ActionOutcome {
        withTarget { target in
            guard let previous = RestoreMemory.take(target.window) else { return .toast("Rien à restaurer pour cette fenêtre") }
            AX.setFrame(target.window, previous, pid: target.app.processIdentifier)
            return .close
        }
    }

    // MARK: - États de la fenêtre

    static func toggleFullScreen() -> ActionOutcome {
        withTarget { target in
            let isFull = AX.bool(target.window, "AXFullScreen") ?? false
            return AX.set(target.window, "AXFullScreen", bool: !isFull) ? .close : .toast("Cette fenêtre ne passe pas en plein écran")
        }
    }

    static func minimize() -> ActionOutcome {
        withTarget { target in
            AX.set(target.window, kAXMinimizedAttribute, bool: true)
            return .close
        }
    }

    /// Réduit dans le Dock toutes les fenêtres de l'écran de la fenêtre active (sinon de l'écran sous la souris).
    static func minimizeAllOnScreen() -> ActionOutcome {
        guard AccessibilityGate.isGranted else { return withTarget { _ in .close } }
        let axScreens = WindowGeometry.axScreens(screens, primaryHeight: primaryHeight)
        let reference: CGRect
        if case .success(let target) = target() {
            reference = target.frame
        } else {
            let mouse = NSEvent.mouseLocation
            reference = WindowGeometry.flip(CGRect(x: mouse.x, y: mouse.y, width: 1, height: 1), primaryHeight: primaryHeight)
        }
        guard let screen = WindowGeometry.screenIndex(for: reference, in: axScreens) else { return .close }
        var count = 0
        for app in regularApps() where !app.isHidden {
            for window in AX.windows(of: app.processIdentifier) where AX.isStandardWindow(window) && AX.bool(window, kAXMinimizedAttribute) != true {
                guard let frame = AX.frame(window), WindowGeometry.screenIndex(for: frame, in: axScreens) == screen else { continue }
                if AX.set(window, kAXMinimizedAttribute, bool: true) { count += 1 }
            }
        }
        return .hud(count == 0 ? "Aucune fenêtre sur cet écran" : count == 1 ? "1 fenêtre réduite" : "\(count) fenêtres réduites")
    }

    /// Passe à la fenêtre suivante (ou précédente) de la même application, dans un ordre stable
    /// (l'ordre de l'accessibilité suit la pile des fenêtres et ne permettrait pas d'en faire le tour).
    static func focusSibling(_ step: Int) -> ActionOutcome {
        withTarget { target in
            let windows = AX.windows(of: target.app.processIdentifier)
                .filter { AX.isStandardWindow($0) && AX.bool($0, kAXMinimizedAttribute) != true }
                .map { (element: $0, key: sortKey($0)) }
                .sorted { $0.key < $1.key }
            guard windows.count > 1, let index = windows.firstIndex(where: { CFEqual($0.element, target.window) }) else {
                return .toast("\(target.app.localizedName ?? "L’application") n’a pas d’autre fenêtre")
            }
            let next = windows[(index + step + windows.count) % windows.count].element
            focus(next, of: target.app)
            return .close
        }
    }

    private static func sortKey(_ window: AXUIElement) -> String {
        let frame = AX.frame(window) ?? .zero
        return (AX.string(window, kAXTitleAttribute) ?? "") + String(format: "|%08.0f|%08.0f", frame.minX + 50_000, frame.minY + 50_000)
    }

    /// Amène une fenêtre devant : l'app d'abord, puis la fenêtre (AXRaise, AXMain).
    static func focus(_ window: AXUIElement, of app: NSRunningApplication) {
        if AX.bool(window, kAXMinimizedAttribute) == true { AX.set(window, kAXMinimizedAttribute, bool: false) }
        if app.isHidden { app.unhide() }
        app.activate()
        AX.perform(window, kAXRaiseAction)
        AX.set(window, kAXMainAttribute, bool: true)
        AX.set(window, kAXFocusedAttribute, bool: true)
    }

    static func regularApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier && !$0.isTerminated
        }
    }
}

/// Le cadre de chaque fenêtre avant la dernière commande de Prism, pour « Restaurer ».
@MainActor
enum RestoreMemory {
    private static var entries: [(window: AXUIElement, frame: CGRect)] = []

    static func remember(_ window: AXUIElement, frame: CGRect) {
        entries.removeAll { CFEqual($0.window, window) }
        entries.append((window, frame))
        if entries.count > 60 { entries.removeFirst(entries.count - 60) }
    }

    static func take(_ window: AXUIElement) -> CGRect? {
        guard let index = entries.firstIndex(where: { CFEqual($0.window, window) }) else { return nil }
        return entries.remove(at: index).frame
    }
}

/// Bureaux (Spaces) : par les raccourcis de Mission Control, simulés ; macOS n'offre pas d'API publique.
@MainActor
enum Spaces {
    /// Codes des touches 1 à 9.
    static let digitKeyCodes: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    /// Identifiants des raccourcis de Mission Control dans `com.apple.symbolichotkeys`.
    enum Hotkey {
        static let previousSpace = 79
        static let nextSpace = 81
        static func desktop(_ number: Int) -> Int { 117 + number }
    }

    /// Le raccourci est-il actif ? `nil` s'il n'est pas déclaré (macOS le règle alors lui-même).
    static func isEnabled(_ hotkey: Int) -> Bool? {
        guard let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys"),
              let entry = all[String(hotkey)] as? [String: Any] else { return nil }
        return (entry["enabled"] as? NSNumber)?.boolValue
    }

    private static func disabledMessage(_ name: String) -> ActionOutcome {
        .toast("Activez « \(name) » : Réglages Système › Clavier › Raccourcis › Mission Control")
    }

    static func goToDesktop(_ number: Int) -> ActionOutcome {
        guard AccessibilityGate.isGranted else { return WindowManager.withTarget { _ in .close } }
        guard isEnabled(Hotkey.desktop(number)) != false else { return disabledMessage("Passer au bureau \(number)") }
        send(digitKeyCodes[number - 1], flags: .maskControl)
        return .close
    }

    static func switchSpace(next: Bool) -> ActionOutcome {
        guard AccessibilityGate.isGranted else { return WindowManager.withTarget { _ in .close } }
        guard isEnabled(next ? Hotkey.nextSpace : Hotkey.previousSpace) != false else {
            return disabledMessage(next ? "Un bureau vers la droite" : "Un bureau vers la gauche")
        }
        send(next ? 124 : 123, flags: [.maskControl, .maskSecondaryFn])
        return .close
    }

    /// Envoie la fenêtre active au bureau voisin : on saisit sa barre de titre par un clic maintenu,
    /// on change de bureau (⌃→ ou ⌃←), puis on relâche, comme Amethyst. Au mieux : macOS peut l'ignorer.
    static func moveWindow(next: Bool) -> ActionOutcome {
        WindowManager.withTarget { target in
            guard isEnabled(next ? Hotkey.nextSpace : Hotkey.previousSpace) != false else {
                return disabledMessage(next ? "Un bureau vers la droite" : "Un bureau vers la gauche")
            }
            let grab = grabPoint(of: target.window, frame: target.frame)
            let app = target.app
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                app.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    let source = CGEventSource(stateID: .combinedSessionState)
                    let saved = CGEvent(source: nil)?.location
                    CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: grab, mouseButton: .left)?.post(tap: .cghidEventTap)
                    CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: grab, mouseButton: .left)?.post(tap: .cghidEventTap)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        Keystrokes.send(next ? 124 : 123, flags: [.maskControl, .maskSecondaryFn])
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: grab, mouseButton: .left)?.post(tap: .cghidEventTap)
                            if let saved { CGWarpMouseCursorPosition(saved) }
                        }
                    }
                }
            }
            return .hud("Fenêtre envoyée au bureau \(next ? "suivant" : "précédent")")
        }
    }

    /// Un point de la barre de titre sans bouton : juste après le bouton vert, sinon en haut, à 80 pt du bord.
    private static func grabPoint(of window: AXUIElement, frame: CGRect) -> CGPoint {
        if let zoom = AX.element(window, kAXZoomButtonAttribute), let zoomFrame = AX.frame(zoom), zoomFrame.width > 0 {
            return CGPoint(x: zoomFrame.maxX + 6, y: zoomFrame.midY)
        }
        return CGPoint(x: frame.minX + 80, y: frame.minY + 12)
    }

    /// Le lanceur se ferme d'abord : la frappe part ensuite.
    private static func send(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Keystrokes.send(keyCode, flags: flags) }
    }
}

/// La barre des menus des écrans secondaires (« Les écrans disposent de Spaces distincts ») :
/// `visibleFrame` ne la retire pas toujours, mais macOS n'y laisse pas monter les fenêtres.
/// Sa hauteur, apprise au premier rangement repoussé, est ensuite retirée de la zone utile de l'écran.
@MainActor
enum MenuBarInsets {
    private static var insets: [String: CGFloat] = [:]

    private static func key(_ frame: CGRect) -> String { "\(frame.origin.x),\(frame.origin.y),\(frame.width),\(frame.height)" }

    /// La zone utile, sans la barre apprise si l'écran la déclare jusqu'en haut.
    static func usable(frame: CGRect, visible: CGRect) -> CGRect {
        guard let inset = insets[key(frame)], visible.maxY >= frame.maxY - 0.5 else { return visible }
        return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height - inset)
    }

    /// Retient la barre si la fenêtre visait le haut de cet écran et que macOS l'a repoussée de quelques dizaines de points.
    static func learn(frame: CGRect, visible: CGRect, primaryHeight: CGFloat, wanted: CGRect, actualTop: CGFloat) -> Bool {
        let top = primaryHeight - frame.maxY
        guard insets[key(frame)] == nil, visible.maxY >= frame.maxY - 0.5,
              abs(wanted.minY - top) < 1, wanted.midX >= frame.minX, wanted.midX <= frame.maxX else { return false }
        let pushed = actualTop - top
        guard pushed > 1, pushed <= 60 else { return false }
        insets[key(frame)] = pushed.rounded()
        return true
    }

    static func reset() { insets = [:] }
}
