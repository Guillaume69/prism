import AppKit
import ApplicationServices

/// `BrowserExtension` de Raycast, sans extension de navigateur : les onglets et les pages de Safari et des navigateurs
/// Chromium par AppleScript (le texte des pages demande « Autoriser JavaScript depuis les Apple Events »).
@MainActor
enum ExtensionBrowser {
    /// Les onglets de tous les navigateurs ouverts. Identifiant : « navigateur:fenêtre:onglet ».
    static func tabs() throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        var answered = false
        let open = browsers()
        /// Le navigateur de l'onglet actif : le premier (au premier plan d'abord) qui a des fenêtres.
        var activeApp: String?
        for app in open {
            let isSafari = app == "com.apple.Safari"
            // `tab` désigne un onglet dans le dictionnaire du navigateur : le séparateur est le caractère 9.
            let script = """
            set sep to character id 9
            tell application id "\(app)"
                set output to ""
                set w to 0
                repeat with aWindow in windows
                    set w to w + 1
                    set activeIndex to \(isSafari ? "index of current tab of aWindow" : "active tab index of aWindow")
                    set t to 0
                    repeat with aTab in tabs of aWindow
                        set t to t + 1
                        set output to output & w & sep & t & sep & (t = activeIndex and w = 1) & sep & (URL of aTab) & sep & (\(isSafari ? "name" : "title") of aTab) & linefeed
                    end repeat
                end repeat
                return output
            end tell
            """
            guard let output = AppleScript.run(script) else { continue }
            answered = true
            if activeApp == nil, !output.isEmpty { activeApp = app }
            for line in output.split(separator: "\n") {
                let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 5 else { continue }
                let url = fields[3]
                result.append([
                    "id": "\(app):\(fields[0]):\(fields[1])",
                    "url": url,
                    "title": fields[4],
                    "active": fields[2] == "true" && app == activeApp,
                    "favicon": URL(string: url)?.host.map { "https://\($0)/favicon.ico" } ?? NSNull(),
                ])
            }
        }
        if !open.isEmpty, !answered {
            throw ExtensionSession.RequestError("Autorisez Prism à contrôler votre navigateur : Réglages Système › Confidentialité et sécurité › Automatisation")
        }
        return result
    }

    /// Le contenu d'un onglet (l'actif par défaut) : texte, HTML ou Markdown (le texte de la page), éventuellement
    /// limité à un sélecteur CSS.
    static func content(format: String, selector: String?, tabID: String?) throws -> String {
        var target: (app: String, window: Int, tab: Int?)?
        if let tabID {
            let parts = tabID.split(separator: ":").map(String.init)
            if parts.count == 3, let window = Int(parts[1]), let tab = Int(parts[2]) { target = (parts[0], window, tab) }
        } else if let app = browsers().first {
            target = (app, 1, nil)
        }
        guard let target else { throw ExtensionSession.RequestError("Aucun navigateur ouvert (Safari, Chrome, Arc, Brave, Edge, Vivaldi)") }
        let element = selector.map { "document.querySelector(\(jsString($0)))" } ?? (format == "html" ? "document.documentElement" : "document.body")
        let property = format == "html" ? "outerHTML" : "innerText"
        let js = "(function(){var e=\(element);return e?e.\(property):''})()"
        let escaped = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script: String
        if target.app == "com.apple.Safari" {
            let tab = target.tab.map { "tab \($0) of window \(target.window)" } ?? "current tab of front window"
            script = #"tell application id "com.apple.Safari" to do JavaScript "\#(escaped)" in \#(tab)"#
        } else {
            let tab = target.tab.map { "tab \($0) of window \(target.window)" } ?? "active tab of front window"
            script = #"tell application id "\#(target.app)" to execute \#(tab) javascript "\#(escaped)""#
        }
        guard let text = AppleScript.run(script) else {
            throw ExtensionSession.RequestError("Le navigateur refuse JavaScript : activez « Autoriser JavaScript depuis les Apple Events » (menu Développement ou Affichage › Développeur)")
        }
        return text
    }

    private static func jsString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    private static func browsers() -> [String] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var ordered: [String] = []
        let front = (AppContext.previousApp ?? NSWorkspace.shared.frontmostApplication)?.bundleIdentifier
        if let front, front == "com.apple.Safari" || BrowserTab.chromiumBrowsers.contains(front) { ordered.append(front) }
        for id in ["com.apple.Safari"] + BrowserTab.chromiumBrowsers where running.contains(id) && !ordered.contains(id) { ordered.append(id) }
        return ordered
    }
}

/// `WindowManagement` de Raycast, par l'accessibilité : fenêtre active, fenêtres visibles, écrans, déplacement.
@MainActor
enum ExtensionWindows {
    /// Le cadre d'un écran dans le repère de l'accessibilité (origine en haut à gauche de l'écran principal).
    private static func axFrame(_ screen: NSScreen) -> CGRect {
        let frame = screen.frame
        return CGRect(x: frame.minX, y: WindowManager.primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    private static func requireTrust() throws {
        guard AccessibilityGate.isGranted else { throw ExtensionSession.RequestError("Autorisez Prism dans Réglages Système › Accessibilité") }
    }

    /// Identifiant d'une fenêtre : « pid-rang » parmi les fenêtres de son application.
    private static func describe(_ window: AXUIElement, app: NSRunningApplication, index: Int, active: Bool) -> [String: Any]? {
        guard let frame = AX.frame(window) else { return nil }
        let screen = NSScreen.screens.first { axFrame($0).intersects(frame) } ?? NSScreen.main
        var positionable: DarwinBoolean = false
        var resizable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &positionable)
        AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &resizable)
        return [
            "id": "\(app.processIdentifier)-\(index)",
            "active": active,
            "bounds": ["position": ["x": frame.minX, "y": frame.minY], "size": ["width": frame.width, "height": frame.height]],
            "desktopId": screen.map(desktopID) ?? "",
            "positionable": positionable.boolValue,
            "resizable": resizable.boolValue,
            "fullScreenSettable": true,
            "application": ExtensionSession.application(app.bundleURL, name: app.localizedName, bundleID: app.bundleIdentifier),
        ]
    }

    /// La fenêtre de l'app qui était au premier plan ; si elle n'en a pas (Finder sans fenêtre…),
    /// la fenêtre la plus en avant à l'écran, hors Prism.
    static func activeWindow() throws -> [String: Any] {
        try requireTrust()
        var candidates: [NSRunningApplication] = []
        if let app = AppContext.previousApp ?? NSWorkspace.shared.frontmostApplication { candidates.append(app) }
        candidates += frontmostWindowOwners().filter { owner in !candidates.contains { $0.processIdentifier == owner.processIdentifier } }
        guard let (app, focused) = candidates.lazy.compactMap({ app in AX.focusedWindow(of: app.processIdentifier).map { (app, $0) } }).first else {
            throw ExtensionSession.RequestError("Aucune fenêtre active")
        }
        let windows = AX.windows(of: app.processIdentifier)
        let index = windows.firstIndex { CFEqual($0, focused) } ?? 0
        guard let described = describe(focused, app: app, index: index, active: true) else { throw ExtensionSession.RequestError("Fenêtre illisible") }
        return described
    }

    /// Les apps des fenêtres à l'écran, de la plus en avant à la plus en arrière (Prism exclu).
    private static func frontmostWindowOwners() -> [NSRunningApplication] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var seen = Set<pid_t>()
        return list.compactMap { info -> NSRunningApplication? in
            guard (info[kCGWindowLayer as String] as? Int) == 0, let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != ProcessInfo.processInfo.processIdentifier, seen.insert(pid).inserted else { return nil }
            return NSRunningApplication(processIdentifier: pid)
        }
    }

    static func windowsOnActiveDesktop() throws -> [[String: Any]] {
        try requireTrust()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let pids = Set(list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }.compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value })
        let front = (AppContext.previousApp ?? NSWorkspace.shared.frontmostApplication)?.processIdentifier
        var result: [[String: Any]] = []
        for app in NSWorkspace.shared.runningApplications where pids.contains(app.processIdentifier) && app.activationPolicy == .regular {
            let focused = AX.focusedWindow(of: app.processIdentifier)
            for (index, window) in AX.windows(of: app.processIdentifier, timeout: 0.3).enumerated() where AX.isStandardWindow(window) {
                let active = app.processIdentifier == front && focused.map { CFEqual($0, window) } == true
                if let described = describe(window, app: app, index: index, active: active) { result.append(described) }
            }
        }
        return result
    }

    static func desktopID(_ screen: NSScreen) -> String {
        "screen-\((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0)"
    }

    static func desktops() -> [[String: Any]] {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.map { screen in
            [
                "id": desktopID(screen),
                "active": screen.frame.contains(mouse),
                "screenId": (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "",
                "size": ["width": screen.frame.width, "height": screen.frame.height],
                "type": "user",
            ]
        }
    }

    static func setBounds(_ params: [String: Any]) throws {
        try requireTrust()
        let id = params["id"] as? String ?? ""
        let parts = id.split(separator: "-").compactMap { Int32($0) }
        guard parts.count == 2, let app = NSRunningApplication(processIdentifier: parts[0]) else { throw ExtensionSession.RequestError("Fenêtre inconnue : \(id)") }
        let windows = AX.windows(of: app.processIdentifier)
        guard Int(parts[1]) < windows.count else { throw ExtensionSession.RequestError("Fenêtre fermée") }
        let window = windows[Int(parts[1])]
        if params["bounds"] as? String == "fullscreen" {
            _ = AX.set(window, "AXFullScreen", bool: true)
            return
        }
        guard let bounds = params["bounds"] as? [String: Any], var frame = AX.frame(window) else { return }
        if let position = bounds["position"] as? [String: Any] {
            if let x = (position["x"] as? NSNumber)?.doubleValue { frame.origin.x = x }
            if let y = (position["y"] as? NSNumber)?.doubleValue { frame.origin.y = y }
        }
        if let size = bounds["size"] as? [String: Any] {
            if let width = (size["width"] as? NSNumber)?.doubleValue { frame.size.width = width }
            if let height = (size["height"] as? NSNumber)?.doubleValue { frame.size.height = height }
        }
        if let desktop = params["desktopId"] as? String, let screen = NSScreen.screens.first(where: { desktopID($0) == desktop }) {
            let area = axFrame(screen)
            if !area.intersects(frame) { frame.origin = CGPoint(x: area.minX + 40, y: area.minY + 40) }
        }
        AX.setFrame(window, frame, pid: app.processIdentifier)
    }
}
