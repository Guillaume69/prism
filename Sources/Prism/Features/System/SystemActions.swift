import AppKit
import ApplicationServices

/// Commandes système : session, veille, énergie, apparence, Finder, disques, applications, notifications.
enum SystemActions {
    // MARK: - Session et veille

    static func lockScreen() {
        typealias LockFunction = @convention(c) () -> Int32
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        if let handle = dlopen(path, RTLD_NOW), let symbol = dlsym(handle, "SACLockScreenImmediate") {
            _ = unsafeBitCast(symbol, to: LockFunction.self)()
        } else {
            run("/usr/bin/pmset", ["displaysleepnow"])
        }
    }

    static func sleep() { run("/usr/bin/pmset", ["sleepnow"]) }
    static func sleepDisplays() { run("/usr/bin/pmset", ["displaysleepnow"]) }
    // La fenêtre de confirmation du système (avec « Rouvrir les fenêtres ») tient lieu de confirmation.
    static func restart() { osascript(#"tell application "loginwindow" to «event aevtrrst»"#) }
    static func shutDown() { osascript(#"tell application "loginwindow" to «event aevtrsdn»"#) }
    static func logOut() { osascript(#"tell application "loginwindow" to «event aevtlogo»"#) }

    static func startScreenSaver() {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Énergie (pmset)

    /// La valeur d'un réglage dans la sortie de `pmset -g` (« hibernatemode 3 » → « 3 »).
    static func pmsetValue(_ key: String, in output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2, parts[0] == key { return String(parts[1]) }
        }
        return nil
    }

    static var isLowPowerModeEnabled: Bool {
        if let value = pmsetValue("lowpowermode", in: SystemShell.output("/usr/bin/pmset", ["-g"]) ?? "") { return value == "1" }
        return ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Hibernation : la mémoire est écrite sur le disque, puis le Mac s'éteint complètement.
    /// Le mode d'origine est remis au réveil. Demande le mot de passe administrateur.
    static func hibernate(completion: @escaping @Sendable (Bool) -> Void) {
        let script = "previous=$(/usr/bin/pmset -g | /usr/bin/awk '/hibernatemode/ {print $2}'); "
            + "/usr/bin/pmset -a hibernatemode 25 && /usr/bin/pmset sleepnow; "
            + "/bin/sleep 20; /usr/bin/pmset -a hibernatemode ${previous:-3}"
        runAsAdministrator(script, completion: completion)
    }

    /// Active ou désactive l'économiseur d'énergie (Low Power Mode). Demande le mot de passe administrateur.
    static func setLowPowerMode(_ enabled: Bool, completion: @escaping @Sendable (Bool) -> Void) {
        runAsAdministrator("/usr/bin/pmset -a lowpowermode \(enabled ? 1 : 0)", completion: completion)
    }

    /// `do shell script … with administrator privileges` : la fenêtre d'authentification de macOS.
    static func runAsAdministrator(_ shell: String, completion: @escaping @Sendable (Bool) -> Void) {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in completion(finished.terminationStatus == 0) }
        do { try process.run() } catch { completion(false) }
    }

    // MARK: - Apparence et bureau

    static var isDarkMode: Bool {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String == "Dark"
    }

    /// Bascule clair / sombre : SkyLight (privé, sans autorisation), sinon System Events. Rend le nouvel état.
    static func toggleDarkMode() -> Bool {
        let dark = !isDarkMode
        typealias SetTheme = @convention(c) (Bool) -> Void
        if let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
           let symbol = dlsym(handle, "SLSSetAppearanceThemeLegacy") {
            unsafeBitCast(symbol, to: SetTheme.self)(dark)
        } else {
            osascript(#"tell application "System Events" to tell appearance preferences to set dark mode to not dark mode"#)
        }
        return dark
    }

    /// Afficher le bureau, comme le geste du trackpad : notification privée du Dock, F11 en secours.
    static func showDesktop() {
        typealias SendNotification = @convention(c) (CFString, Int32) -> Void
        if let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW),
           let symbol = dlsym(handle, "CoreDockSendNotification") {
            unsafeBitCast(symbol, to: SendNotification.self)("com.apple.showdesktop.awake" as CFString, 0)
        } else {
            Keystrokes.send(103)
        }
    }

    static var isStageManagerEnabled: Bool {
        CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString) as? Bool ?? false
    }

    /// Stage Manager : le réglage du gestionnaire de fenêtres, qui le relit en général aussitôt (au mieux).
    static func setStageManager(_ enabled: Bool) {
        CFPreferencesSetAppValue("GloballyEnabled" as CFString, enabled as CFBoolean, "com.apple.WindowManager" as CFString)
        CFPreferencesAppSynchronize("com.apple.WindowManager" as CFString)
        run("/usr/bin/defaults", ["write", "com.apple.WindowManager", "GloballyEnabled", "-bool", enabled ? "true" : "false"])
    }

    // MARK: - Finder

    static var trashURL: URL {
        FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
    }

    static func openTrash() {
        osascript("tell application \"Finder\"\nopen trash\nactivate\nend tell")
    }

    /// Le nombre d'éléments de la corbeille, s'il est lisible sans autorisation (accès complet au disque).
    static var trashItemCount: Int? {
        (try? FileManager.default.contentsOfDirectory(atPath: trashURL.path))?.filter { $0 != ".DS_Store" }.count
    }

    static func emptyTrash() { osascript(#"tell application "Finder" to empty trash"#) }

    static var showsHiddenFiles: Bool {
        CFPreferencesCopyAppValue("AppleShowAllFiles" as CFString, "com.apple.finder" as CFString) as? Bool ?? false
    }

    /// Montre ou cache les fichiers cachés dans le Finder, puis le relance. Rend le nouvel état.
    static func toggleHiddenFiles() -> Bool {
        let show = !showsHiddenFiles
        run("/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", show ? "true" : "false"])
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { run("/usr/bin/killall", ["Finder"]) }
        return show
    }

    // MARK: - Disques

    /// Un volume monté, réduit à ce qui décide s'il s'éjecte.
    struct MountedVolume {
        let url: URL
        let name: String
        let isEjectable: Bool
        let isRemovable: Bool
        let isInternal: Bool
        let isLocal: Bool
    }

    /// Les volumes à éjecter : disques externes, clés, cartes, images disque. Jamais le disque de démarrage.
    static func ejectable(_ volumes: [MountedVolume]) -> [MountedVolume] {
        volumes.filter { volume in
            volume.url.path != "/" && volume.url.path.hasPrefix("/Volumes/") && volume.isLocal
                && (volume.isEjectable || volume.isRemovable || !volume.isInternal)
        }
    }

    static func mountedVolumes() -> [MountedVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return MountedVolume(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                isEjectable: values.volumeIsEjectable ?? false,
                isRemovable: values.volumeIsRemovable ?? false,
                isInternal: values.volumeIsInternal ?? true,
                isLocal: values.volumeIsLocal ?? true
            )
        }
    }

    /// Éjecte tout ce qui peut l'être, hors du fil principal : nombre éjecté et volumes refusés.
    static func ejectAll(completion: @escaping @MainActor (Int, [String]) -> Void) {
        let urls = ejectable(mountedVolumes()).map { ($0.url, $0.name) }
        DispatchQueue.global(qos: .userInitiated).async {
            var ejected = 0
            var failed: [String] = []
            for (url, name) in urls {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                    ejected += 1
                } catch {
                    failed.append(name)
                }
            }
            let count = ejected
            let refused = failed
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(count, refused) } }
        }
    }

    // MARK: - Applications

    /// Ce que Prism ne quitte jamais en bloc : lui-même et le Finder.
    static let protectedBundleIDs: Set<String> = ["com.apple.finder", Bundle.main.bundleIdentifier ?? "app.prism"]

    /// Les applications à fenêtres, sans Prism.
    static func regularApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier && !$0.isTerminated
        }
    }

    /// Les indices des apps que « Quitter toutes les applications » fermerait : ni Prism, ni le Finder,
    /// ni les exclues, ni celle qu'on garde (l'app au premier plan).
    static func quitCandidates(bundleIDs: [String?], excluded: Set<String>, keeping kept: String?) -> [Int] {
        bundleIDs.enumerated().compactMap { index, bundleID in
            guard let bundleID else { return index }
            if protectedBundleIDs.contains(bundleID) || excluded.contains(bundleID) || bundleID == kept { return nil }
            return index
        }
    }

    // MARK: - Notifications

    /// Le nom d'une action d'accessibilité : les actions propres s'écrivent « Name:Fermer\nTarget:0x0\nSelector:(null) ».
    private static func actionName(_ raw: String) -> String {
        let line = raw.components(separatedBy: .newlines).first { $0.hasPrefix("Name:") }
        return (line.map { String($0.dropFirst("Name:".count)) } ?? raw).trimmingCharacters(in: .whitespaces).normalizedForSearch
    }

    /// Les actions qui ferment une notification ou un groupe (« Close », « Fermer », « Tout effacer »).
    static func isDismissAction(_ raw: String) -> Bool {
        ["close", "clear all", "clear", "fermer", "effacer", "tout effacer", "effacer tout"].contains(actionName(raw))
    }

    private static func isClearAll(_ raw: String) -> Bool {
        ["clear all", "tout effacer", "effacer tout"].contains(actionName(raw))
    }

    /// Ferme les notifications affichées, par l'accessibilité du centre de notifications. Rend le nombre fermé.
    static func clearNotifications() -> Int {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else { return 0 }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var cleared = 0
        // Chaque fermeture redessine l'arbre : on recommence tant qu'on trouve quelque chose.
        for _ in 0..<40 {
            guard let (element, action) = firstDismissAction(in: root, depth: 0) else { break }
            guard AXUIElementPerformAction(element, action as CFString) == .success else { break }
            cleared += 1
            usleep(150_000)
        }
        return cleared
    }

    private static func firstDismissAction(in element: AXUIElement, depth: Int) -> (AXUIElement, String)? {
        guard depth < 14 else { return nil }
        var names: CFArray?
        if AXUIElementCopyActionNames(element, &names) == .success, let names = names as? [String] {
            // « Tout effacer » d'un groupe d'abord, sinon « Fermer ».
            if let action = names.first(where: isClearAll) ?? names.first(where: isDismissAction) { return (element, action) }
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return nil }
        for child in list {
            if let found = firstDismissAction(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    // MARK: - Outils

    static func osascript(_ source: String) {
        run("/usr/bin/osascript", ["-e", source])
    }

    static func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

/// Night Shift par CoreBrightness (privé) : `CBBlueLightClient`, chargé à la demande.
enum NightShift {
    nonisolated(unsafe) private static let client: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
              let type = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
        return type.init()
    }()

    static var isAvailable: Bool {
        guard let client else { return false }
        return client.responds(to: NSSelectorFromString("setEnabled:")) && client.responds(to: NSSelectorFromString("getBlueLightStatus:"))
    }

    /// L'état : la structure renvoyée commence par deux booléens, « actif » puis « activé ».
    static var isEnabled: Bool? {
        guard let client, isAvailable else { return nil }
        typealias GetStatus = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        let selector = NSSelectorFromString("getBlueLightStatus:")
        let function = unsafeBitCast(client.method(for: selector), to: GetStatus.self)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 128)
        guard function(client, selector, buffer) else { return nil }
        return buffer.load(fromByteOffset: 1, as: Bool.self)
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard let client, isAvailable else { return false }
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Bool
        let selector = NSSelectorFromString("setEnabled:")
        return unsafeBitCast(client.method(for: selector), to: SetEnabled.self)(client, selector, enabled)
    }
}

/// Lancer un outil en ligne de commande et lire sa sortie (hors du fil principal de préférence).
enum SystemShell {
    static func output(_ path: String, _ arguments: [String], includeErrors: Bool = false) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = includeErrors ? pipe : FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    static func status(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
