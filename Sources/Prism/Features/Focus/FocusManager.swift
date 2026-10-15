import AppKit
import Combine
import SwiftUI

/// Les préférences de la concentration (`focus.` dans UserDefaults).
@MainActor
final class FocusSettings: ObservableObject {
    static let shared = FocusSettings()

    private let defaults = UserDefaults.standard

    /// Durée d'un report du blocage, en minutes ; 0 : report désactivé.
    @Published var snoozeMinutes: Int {
        didSet { defaults.set(snoozeMinutes, forKey: "focus.snoozeMinutes") }
    }

    /// Son à la fin d'une session et d'une pause.
    @Published var playSound: Bool {
        didSet { defaults.set(playSound, forKey: "focus.playSound") }
    }

    /// Rouvrir à la fin les apps quittées (et réafficher celles masquées) pendant la session.
    @Published var reopenApps: Bool {
        didSet { defaults.set(reopenApps, forKey: "focus.reopenApps") }
    }

    /// Mode « autoriser » : un navigateur autorisé sans site listé laisse passer tous les sites.
    @Published var allowAllSitesWithBrowser: Bool {
        didSet { defaults.set(allowAllSitesWithBrowser, forKey: "focus.allowAllSitesWithBrowser") }
    }

    /// La session s'affiche dans la barre des menus plutôt que dans la barre flottante.
    @Published var showInMenuBar: Bool {
        didSet {
            defaults.set(showInMenuBar, forKey: "focus.showInMenuBar")
            FocusPresenter.shared.update()
        }
    }

    static let snoozeOptions: [(minutes: Int, title: String)] = [(1, "1 minute"), (3, "3 minutes"), (5, "5 minutes"), (10, "10 minutes"), (0, "Désactivé")]

    private init() {
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.bool(forKey: key)
        }
        snoozeMinutes = UserDefaults.standard.object(forKey: "focus.snoozeMinutes") == nil ? 3 : UserDefaults.standard.integer(forKey: "focus.snoozeMinutes")
        playSound = bool("focus.playSound", true)
        reopenApps = bool("focus.reopenApps", true)
        allowAllSitesWithBrowser = bool("focus.allowAllSitesWithBrowser", true)
        showInMenuBar = bool("focus.showInMenuBar", false)
    }
}

/// La session de concentration en cours : démarrage, pause, prolongation, fin, et le blocage qui va avec.
/// Le temps se déduit des dates de la session ; une minuterie d'une seconde rafraîchit l'affichage,
/// surveille le navigateur et détecte la fin.
@MainActor
final class FocusManager: ObservableObject {
    static let shared = FocusManager()

    let store = JSONStore<FocusData>("focus.json", default: FocusData())

    @Published private(set) var session: FocusSession?
    /// L'heure du dernier battement, pour les vues qui affichent le minuteur.
    @Published private(set) var now = Date()
    /// Blocage suspendu jusqu'à cette date (« Reporter le blocage »).
    @Published private(set) var snoozedUntil: Date?

    /// Rendu hors écran : une session en mémoire, sans blocage ni écriture sur le disque.
    private(set) var isSimulation = false
    private var simulatedHistory: [FocusHistoryEntry]?

    /// La dernière session arrivée à son terme, pour la prolonger après coup.
    private var lastFinished: (session: FocusSession, endedAt: Date)?
    private var timer: Timer?
    /// Apps masquées par le blocage, avec l'heure : si elles reviennent, elles sont quittées.
    private var hiddenApps: [pid_t: Date] = [:]
    private var lastSiteBlock: Date?
    private var installed = false
    private var storeObserver: AnyCancellable?

    private init() {
        storeObserver = store.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }

    // MARK: - Lecture

    var categories: [FocusCategory] { FocusCategory.builtIn + store.value.categories }
    var history: [FocusHistoryEntry] { simulatedHistory ?? store.value.history }
    var lastConfiguration: FocusConfiguration? { store.value.lastConfiguration }

    func category(_ id: String) -> FocusCategory? { categories.first { $0.id == id } }

    var isSnoozed: Bool { snoozedUntil.map { $0 > Date() } ?? false }

    /// Le blocage s'applique : une session, ni en pause ni reportée.
    var isEnforcing: Bool {
        guard let session, !session.isPaused, !isSimulation else { return false }
        return !isSnoozed
    }

    var rules: FocusRules? {
        session.map { FocusRules(session: $0, categories: categories, allowAllSitesWithBrowser: FocusSettings.shared.allowAllSitesWithBrowser) }
    }

    /// « Bloque Réseaux sociaux, Actualités et 2 sites ».
    func scopeDescription(for session: FocusSession) -> String {
        let names = session.categoryIDs.compactMap { category($0)?.name }
        var parts = names
        let extras = session.extraApps.count + session.extraWebsites.count
        if extras > 0 { parts.append(extras == 1 ? "1 ajout" : "\(extras) ajouts") }
        let list: String
        switch parts.count {
        case 0: return session.mode == .block ? "Rien à bloquer" : "Tout est bloqué"
        case 1: list = parts[0]
        case 2: list = parts[0] + " et " + parts[1]
        default: list = names.count > 2 ? "\(names.count) catégories" + (extras > 0 ? " et \(parts.last ?? "")" : "") : parts.dropLast().joined(separator: ", ") + " et " + (parts.last ?? "")
        }
        return (session.mode == .block ? "Bloque " : "Autorise seulement ") + list
    }

    /// « Encore 18 min », « En pause », « 42 min écoulées ».
    func statusText(for session: FocusSession, at now: Date) -> String {
        if session.isPaused {
            if let end = session.pauseEndsAt { return "En pause jusqu’à \(FocusFormat.time(end))" }
            return "En pause"
        }
        if let remaining = session.remaining(at: now) {
            return "Encore " + FocusFormat.duration(max(remaining, 60))
        }
        return FocusFormat.duration(session.elapsed(at: now)) + " écoulées"
    }

    // MARK: - Démarrage et arrêt

    /// Au lancement de Prism : surveillance des apps et de la veille, reprise d'une session en cours.
    func install() {
        guard !installed else { return }
        installed = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    if let app { self?.enforce(on: app) }
                }
            }
        }
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        }
        restore()
    }

    /// Reprend la session enregistrée (Prism a redémarré pendant une session).
    private func restore() {
        guard var saved = store.value.session else { return }
        let now = Date()
        if saved.pausedBySleep { saved.resume(at: now) }
        if saved.isOver(at: now) {
            // La session s'est terminée pendant que Prism était fermé.
            let end = saved.startedAt.addingTimeInterval(saved.pausedTotal + (saved.duration ?? 0))
            record(saved, endedAt: end)
            store.value.session = nil
            release(saved)
            return
        }
        session = saved
        persist()
        began(applyToRunningApps: true, announce: false)
    }

    func start(_ configuration: FocusConfiguration) {
        if session != nil { complete(announce: false) }
        let now = Date()
        session = FocusSession(configuration: configuration, startedAt: now)
        lastFinished = nil
        snoozedUntil = nil
        store.value.lastConfiguration = configuration
        persist()
        began(applyToRunningApps: true, announce: true)
    }

    /// Démarre avec la dernière configuration, ou termine la session en cours.
    @discardableResult
    func toggle() -> Bool {
        if session != nil {
            complete()
            return false
        }
        start(lastConfiguration ?? .standard)
        return true
    }

    private func began(applyToRunningApps: Bool, announce: Bool) {
        hiddenApps = [:]
        FocusBlockedPage.write()
        startTimer()
        FocusPresenter.shared.update()
        guard let session else { return }
        if announce {
            let length = session.duration.map { FocusFormat.duration($0) } ?? "sans limite"
            HUD.shared.show("Concentration démarrée · \(length)", symbol: "scope")
        }
        if applyToRunningApps { applyToRunning() }
    }

    /// Termine la session et l'inscrit dans l'historique.
    func complete(timeUp: Bool = false, announce: Bool = true) {
        guard let finished = session else { return }
        let now = Date()
        record(finished, endedAt: now)
        session = nil
        snoozedUntil = nil
        persist()
        release(finished)
        stopTimer()
        FocusPresenter.shared.update()
        guard announce else { return }
        if FocusSettings.shared.playSound { NSSound(named: "Glass")?.play() }
        FocusHalo.flash(tint: Palette.green)
        if timeUp {
            lastFinished = (finished, now)
            let goal = finished.goal.isEmpty ? "Session de concentration" : finished.goal
            FocusToast.shared.show(
                title: "Session terminée",
                message: "\(goal) · \(FocusFormat.duration(finished.elapsed(at: now)))",
                symbol: "checkmark.circle.fill",
                tint: Palette.green,
                buttons: [
                    .init(title: "+5 min") { FocusManager.shared.extendFinished(by: 5) },
                    .init(title: "+15 min") { FocusManager.shared.extendFinished(by: 15) },
                ],
                duration: 12
            )
        } else {
            HUD.shared.show("Session terminée · \(FocusFormat.duration(finished.elapsed(at: now))) de concentration", symbol: "checkmark.circle.fill")
        }
    }

    /// Arrête la session sans l'inscrire dans l'historique.
    func cancel() {
        guard let cancelled = session else { return }
        session = nil
        snoozedUntil = nil
        persist()
        release(cancelled)
        stopTimer()
        FocusPresenter.shared.update()
        HUD.shared.show("Session annulée", symbol: "xmark.circle.fill")
    }

    /// Prolonge la session qui vient d'arriver à son terme (bouton de la notification de fin).
    func extendFinished(by minutes: Int) {
        guard session == nil, let (finished, endedAt) = lastFinished else { return }
        var revived = finished
        // Le temps passé depuis la fin ne compte pas comme de la concentration.
        revived.pausedTotal += Date().timeIntervalSince(endedAt)
        revived.extend(by: TimeInterval(minutes * 60))
        if !isSimulation, store.value.history.first?.id == finished.id { store.value.history.removeFirst() }
        lastFinished = nil
        session = revived
        persist()
        began(applyToRunningApps: true, announce: false)
        HUD.shared.show("Session prolongée de \(minutes) min", symbol: "plus.circle.fill")
    }

    // MARK: - Pause, prolongation, modification

    func pause(minutes: Int?) {
        guard var current = session, !current.isPaused else { return }
        current.pause(at: Date(), for: minutes.map { TimeInterval($0 * 60) })
        session = current
        persist()
        FocusPresenter.shared.update()
        HUD.shared.show(minutes.map { "Pause de \($0) min" } ?? "Session en pause", symbol: "pause.circle.fill")
    }

    func resume(automatic: Bool = false) {
        guard var current = session, current.isPaused else { return }
        current.resume(at: Date())
        session = current
        persist()
        FocusPresenter.shared.update()
        if automatic {
            if FocusSettings.shared.playSound { NSSound(named: "Purr")?.play() }
            FocusToast.shared.show(
                title: "La pause est finie",
                message: "On reprend : \(current.goal.isEmpty ? "concentration" : current.goal)",
                symbol: "play.circle.fill",
                tint: Palette.indigo,
                buttons: [.init(title: "+5 min de pause") { FocusManager.shared.pause(minutes: 5) }],
                duration: 8
            )
        } else {
            HUD.shared.show("La concentration reprend", symbol: "play.circle.fill")
        }
        enforceFrontmost()
    }

    func extend(minutes: Int) {
        guard var current = session, !current.isUnlimited else { return }
        current.extend(by: TimeInterval(minutes * 60))
        session = current
        persist()
        FocusPresenter.shared.update()
        HUD.shared.show("+\(minutes) min · \(statusText(for: current, at: Date()))", symbol: "plus.circle.fill")
    }

    /// Change l'objectif, le mode, les listes, et ajoute du temps.
    func update(goal: String, mode: FocusMode, categoryIDs: [String], extraApps: [String], extraWebsites: [String], addMinutes: Int) {
        guard var current = session else { return }
        current.goal = goal
        current.mode = mode
        current.categoryIDs = categoryIDs
        current.extraApps = extraApps
        current.extraWebsites = extraWebsites
        if addMinutes > 0 { current.extend(by: TimeInterval(addMinutes * 60)) }
        session = current
        store.value.lastConfiguration = FocusConfiguration(
            goal: goal, duration: store.value.lastConfiguration?.duration ?? current.duration, mode: mode,
            categoryIDs: categoryIDs, extraApps: extraApps, extraWebsites: extraWebsites
        )
        persist()
        FocusPresenter.shared.update()
        applyToRunning()
    }

    /// Suspend le blocage quelques minutes ; la session continue.
    func snooze(minutes: Int? = nil) {
        let length = minutes ?? FocusSettings.shared.snoozeMinutes
        guard session != nil, length > 0 else { return }
        snoozedUntil = Date().addingTimeInterval(TimeInterval(length * 60))
        FocusPresenter.shared.update()
        HUD.shared.show("Blocage reporté de \(length) min", symbol: "clock.arrow.circlepath")
    }

    // MARK: - Minuterie

    private func startTimer() {
        guard timer == nil, !isSimulation else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = Date()
        self.now = now
        guard let session else { stopTimer(); return }
        if let until = snoozedUntil, until <= now {
            snoozedUntil = nil
            HUD.shared.show("Fin du report : le blocage reprend", symbol: "hand.raised.fill")
            enforceFrontmost()
        }
        if session.isPaused {
            if let end = session.pauseEndsAt, end <= now { resume(automatic: true) }
        } else if session.isOver(at: now) {
            complete(timeUp: true)
            return
        } else if isEnforcing {
            checkBrowser()
        }
        FocusPresenter.shared.tick()
    }

    // MARK: - Veille

    private func systemWillSleep() {
        guard var current = session, !current.isPaused else { return }
        current.pause(at: Date(), for: nil, bySleep: true)
        session = current
        persist()
        store.flush()
    }

    private func systemDidWake() {
        guard var current = session, current.pausedBySleep else { return }
        current.resume(at: Date())
        session = current
        persist()
        FocusPresenter.shared.update()
    }

    // MARK: - Blocage des apps

    /// Une app passe au premier plan ou se lance : masquée la première fois, quittée si elle revient.
    private func enforce(on app: NSRunningApplication) {
        guard isEnforcing, let rules, app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let identity = FocusAppIdentity(bundleID: app.bundleIdentifier, name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "")
        guard rules.blocks(app: identity) else { return }
        let name = identity.name.isEmpty ? "Cette app" : identity.name
        let pid = app.processIdentifier
        let now = Date()

        if let hiddenAt = hiddenApps[pid], now.timeIntervalSince(hiddenAt) > 1.5 {
            // Revenue après avoir été masquée : on la quitte proprement (jamais de fermeture forcée).
            if let path = app.bundleURL?.path, var current = session, !current.closedApps.contains(path) {
                current.closedApps.append(path)
                session = current
                persist()
            }
            hiddenApps[pid] = nil
            app.terminate()
            notifyBlocked(title: "\(name) a été quittée", message: "Bloquée pendant la concentration")
            return
        }
        let firstTime = hiddenApps[pid] == nil
        hiddenApps[pid] = hiddenApps[pid] ?? now
        app.hide()
        // L'activation peut arriver juste après le masquage : on insiste une fois.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if app.isActive { app.hide() }
        }
        if firstTime { notifyBlocked(title: "\(name) est bloquée", message: "Pendant la concentration") }
    }

    /// Au démarrage : les apps bloquées déjà ouvertes sont masquées.
    private func applyToRunning() {
        guard isEnforcing, let rules else { return }
        let now = Date()
        var count = 0
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isTerminated {
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { continue }
            let identity = FocusAppIdentity(bundleID: app.bundleIdentifier, name: app.localizedName ?? "")
            guard rules.blocks(app: identity), hiddenApps[app.processIdentifier] == nil else { continue }
            app.hide()
            hiddenApps[app.processIdentifier] = now
            count += 1
        }
        if count > 0 {
            FocusToast.shared.show(
                title: count == 1 ? "1 app masquée" : "\(count) apps masquées",
                message: "Bloquées pendant la concentration",
                symbol: "eye.slash.fill",
                tint: Palette.orange,
                buttons: [],
                duration: 3.5
            )
        }
    }

    private func enforceFrontmost() {
        guard isEnforcing, let front = NSWorkspace.shared.frontmostApplication else { return }
        enforce(on: front)
    }

    // MARK: - Blocage des sites

    /// L'onglet actif du navigateur au premier plan, lu chaque seconde.
    private func checkBrowser() {
        // Sans site bloqué, on ne lit jamais l'onglet : pas de demande d'autorisation d'automatisation inutile.
        guard let rules, rules.mode == .allow || !rules.websites.isEmpty,
              let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier, FocusRules.browsers.contains(bundleID) else { return }
        if let lastSiteBlock, Date().timeIntervalSince(lastSiteBlock) < 1.5 { return }
        let identity = FocusAppIdentity(bundleID: bundleID, name: front.localizedName ?? "")
        guard !rules.blocks(app: identity), let url = FocusBrowser.activeURL(bundleID: bundleID),
              rules.blocks(url: url, browser: identity) else { return }
        lastSiteBlock = Date()
        let host = URL(string: url)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url
        let page = FocusBlockedPage.url(site: host, session: session, now: Date())
        FocusBrowser.leave(bundleID: bundleID, for: page)
        notifyBlocked(title: "\(host) est bloqué", message: "Pendant la concentration")
    }

    private func notifyBlocked(title: String, message: String) {
        FocusHalo.flash(tint: Palette.orange)
        let snooze = FocusSettings.shared.snoozeMinutes
        FocusToast.shared.show(
            title: title,
            message: message,
            symbol: "hand.raised.fill",
            tint: Palette.orange,
            buttons: snooze > 0 ? [.init(title: "Reporter \(snooze) min") { FocusManager.shared.snooze() }] : [],
            duration: 4.5
        )
    }

    // MARK: - Fin de session

    /// Rouvre les apps quittées et réaffiche celles masquées, selon le réglage.
    private func release(_ finished: FocusSession) {
        defer { hiddenApps = [:] }
        guard !isSimulation, FocusSettings.shared.reopenApps else { return }
        for pid in hiddenApps.keys {
            NSRunningApplication(processIdentifier: pid)?.unhide()
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
        for path in finished.closedApps where !running.contains(path) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration)
        }
    }

    private func record(_ finished: FocusSession, endedAt: Date) {
        guard !isSimulation else { return }
        let entry = FocusHistoryEntry(
            id: finished.id, goal: finished.goal, startedAt: finished.startedAt, endedAt: endedAt,
            focused: finished.elapsed(at: endedAt), planned: finished.duration
        )
        store.value.history = Array(([entry] + store.value.history).prefix(100))
    }

    func clearHistory() {
        guard !isSimulation else { return }
        store.value.history = []
    }

    private func persist() {
        guard !isSimulation else { return }
        if store.value.session != session { store.value.session = session }
    }

    // MARK: - Catégories personnalisées

    func save(_ category: FocusCategory) {
        guard !category.isBuiltIn, !isSimulation else { return }
        if let index = store.value.categories.firstIndex(where: { $0.id == category.id }) {
            store.value.categories[index] = category
        } else {
            store.value.categories.append(category)
        }
    }

    func deleteCategory(_ id: String) {
        guard !isSimulation else { return }
        store.value.categories.removeAll { $0.id == id }
    }

    /// Une copie modifiable d’une catégorie (intégrée ou non), enregistrée.
    func duplicate(_ category: FocusCategory) -> FocusCategory {
        let copy = draftCopy(of: category)
        save(copy)
        return copy
    }

    /// Une copie modifiable, pas encore enregistrée.
    func draftCopy(of category: FocusCategory) -> FocusCategory {
        var copy = category
        copy.id = "custom-" + UUID().uuidString.prefix(8).lowercased()
        copy.name = category.name + " (copie)"
        copy.isBuiltIn = false
        return copy
    }

    // MARK: - Rendu hors écran

    /// Une session fictive en mémoire, pour les rendus : rien n'est bloqué ni écrit.
    func simulate(_ session: FocusSession, history: [FocusHistoryEntry], now: Date) {
        isSimulation = true
        self.session = session
        simulatedHistory = history
        self.now = now
    }
}

// MARK: - Navigateurs

/// L'onglet actif d'un navigateur, par AppleScript : lecture de l'adresse, remplacement par la page de blocage.
@MainActor
enum FocusBrowser {
    private static func isSafari(_ bundleID: String) -> Bool { bundleID == "com.apple.Safari" }

    static func activeURL(bundleID: String) -> String? {
        let source = isSafari(bundleID)
            ? #"tell application id "com.apple.Safari" to return URL of current tab of front window"#
            : #"tell application id "\#(bundleID)" to return URL of active tab of front window"#
        let result = run(source)
        guard result.ok, let url = result.output, !url.isEmpty else { return nil }
        return url
    }

    /// Remplace l'onglet par la page de blocage ; à défaut, revient à la page précédente.
    static func leave(bundleID: String, for page: URL) {
        let target = page.absoluteString.replacingOccurrences(of: "\"", with: "%22")
        let replace = isSafari(bundleID)
            ? #"tell application id "com.apple.Safari" to set URL of current tab of front window to "\#(target)""#
            : #"tell application id "\#(bundleID)" to set URL of active tab of front window to "\#(target)""#
        if run(replace).ok { return }
        let back = isSafari(bundleID)
            ? #"tell application id "com.apple.Safari" to do JavaScript "history.back()" in current tab of front window"#
            : #"tell application id "\#(bundleID)" to go back active tab of front window"#
        run(back)
    }

    /// Exécute un script ; `ok` vaut vrai même si le script ne renvoie rien.
    @discardableResult
    private static func run(_ source: String) -> (ok: Bool, output: String?) {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return (false, nil) }
        let result = script.executeAndReturnError(&error)
        return (error == nil, error == nil ? result.stringValue : nil)
    }
}
