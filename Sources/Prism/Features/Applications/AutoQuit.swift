import AppKit

/// Fermeture automatique, comme l'« Auto Quit » de Raycast : une app choisie est quittée après un délai
/// sans être au premier plan. Jamais l'app de devant, ni Prism ni le Finder, ni pendant un appel ou un
/// enregistrement (micro ou caméra allumés), ni Spotify ou Musique en pleine lecture.
@MainActor
final class AutoQuit {
    static let shared = AutoQuit()

    /// Dernier moment où chaque app (par processus) a quitté le premier plan.
    private var lastActive: [pid_t: Date] = [:]
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// Apps de musique : on demande leur état de lecture avant de les quitter.
    nonisolated static let mediaPlayers: [String: String] = ["com.spotify.client": "Spotify", "com.apple.Music": "Music"]

    // MARK: - Réglages

    static func isEnabled(for bundleID: String) -> Bool { ApplicationsPreferences.autoQuitApps[bundleID] != nil }

    static func setEnabled(_ enabled: Bool, for bundleID: String) {
        var apps = ApplicationsPreferences.autoQuitApps
        apps[bundleID] = enabled ? (apps[bundleID] ?? 0) : nil
        ApplicationsPreferences.autoQuitApps = apps
        NotificationCenter.default.post(name: .prismDataDidChange, object: nil)
    }

    /// Délai propre à l'app (minutes), 0 pour le délai par défaut.
    static func setDelay(_ minutes: Int, for bundleID: String) {
        var apps = ApplicationsPreferences.autoQuitApps
        apps[bundleID] = minutes
        ApplicationsPreferences.autoQuitApps = apps
        NotificationCenter.default.post(name: .prismDataDidChange, object: nil)
    }

    /// Le délai effectif d'une app, en minutes ; `nil` si elle n'est pas concernée.
    static func delay(for bundleID: String, apps: [String: Int], defaultDelay: Int) -> Int? {
        guard let own = apps[bundleID] else { return nil }
        return own > 0 ? own : defaultDelay
    }

    /// L'app est-elle inactive depuis assez longtemps ?
    static func isDue(lastActive: Date, now: Date, delayMinutes: Int) -> Bool {
        now.timeIntervalSince(lastActive) >= Double(delayMinutes) * 60
    }

    /// « après 5 min (par défaut) ».
    static func describe(_ own: Int, defaultDelay: Int) -> String {
        own > 0 ? "après \(own) min" : "après \(defaultDelay) min (par défaut)"
    }

    // MARK: - Surveillance

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        let now = Date()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            lastActive[app.processIdentifier] = now
        }
        observers.append(center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { self?.lastActive[pid] = Date() } }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { self?.lastActive[pid] = Date() } }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { self?.lastActive[pid] = Date() } }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { self?.lastActive[pid] = nil } }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        let apps = ApplicationsPreferences.autoQuitApps
        guard !apps.isEmpty else { return }
        let defaultDelay = ApplicationsPreferences.autoQuitDelay
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let now = Date()
        let due = NSWorkspace.shared.runningApplications.filter { app in
            guard let bundleID = app.bundleIdentifier, !app.isTerminated, app.processIdentifier != frontmost,
                  !SystemActions.protectedBundleIDs.contains(bundleID),
                  let minutes = AutoQuit.delay(for: bundleID, apps: apps, defaultDelay: defaultDelay) else { return false }
            guard let last = lastActive[app.processIdentifier] else {
                lastActive[app.processIdentifier] = now
                return false
            }
            return AutoQuit.isDue(lastActive: last, now: now, delayMinutes: minutes)
        }
        guard !due.isEmpty else { return }
        // Micro, caméra et lecture se vérifient hors du fil principal (AppleScript pour la musique).
        let candidates = due
        DispatchQueue.global(qos: .utility).async {
            guard !SystemAudio.isMicrophoneInUse(), !SystemAudio.isCameraInUse() else { return }
            let quittable = candidates.filter { app in
                guard let name = app.bundleIdentifier.flatMap({ AutoQuit.mediaPlayers[$0] }) else { return true }
                return !AutoQuit.isPlaying(name)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for app in quittable where app.processIdentifier != NSWorkspace.shared.frontmostApplication?.processIdentifier {
                        app.terminate()
                    }
                }
            }
        }
    }

    /// L'app de musique (déjà ouverte) est-elle en lecture ?
    nonisolated static func isPlaying(_ appName: String) -> Bool {
        let script = "if application \"\(appName)\" is running then tell application \"\(appName)\" to return player state as string"
        let output = SystemShell.output("/usr/bin/osascript", ["-e", script]) ?? ""
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "playing"
    }
}
