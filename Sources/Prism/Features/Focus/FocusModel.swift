import AppKit
import SwiftUI

// Le modèle de la concentration, sans interface ni effet de bord : catégories, session, minuterie,
// durées saisies, correspondance des apps et des sites. Tout ce qui est ici se vérifie dans `--selftest`.

/// Bloquer les apps et les sites listés, ou n'autoriser qu'eux.
enum FocusMode: String, Codable, CaseIterable {
    case block
    case allow

    var title: String {
        switch self {
        case .block: "Bloquer les apps et sites listés"
        case .allow: "N’autoriser que les apps et sites listés"
        }
    }
}

/// Une liste d'apps et de sites à bloquer ou à autoriser ensemble.
struct FocusCategory: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var symbol: String
    /// Nom d'une couleur de `FocusCategory.colors`.
    var color: String
    /// Identifiants d'apps (`com.hnc.Discord`) ou noms d'apps (« Discord »).
    var apps: [String]
    /// Domaines, sous-domaines compris (`reddit.com`), éventuellement suivis d'un chemin (`youtube.com/shorts`).
    var websites: [String]
    var isBuiltIn = false

    static let colors: [(id: String, title: String, color: Color)] = [
        ("red", "Rouge", Palette.red), ("orange", "Orange", Palette.orange), ("yellow", "Jaune", Palette.yellow),
        ("green", "Vert", Palette.green), ("teal", "Turquoise", Palette.teal), ("blue", "Bleu", Palette.blue),
        ("indigo", "Indigo", Palette.indigo), ("violet", "Violet", Palette.violet), ("pink", "Rose", Palette.pink),
        ("gray", "Gris", Palette.gray),
    ]

    var tint: Color { Self.colors.first { $0.id == color }?.color ?? Palette.gray }

    /// « 4 apps · 12 sites ».
    var summary: String {
        var parts: [String] = []
        if !apps.isEmpty { parts.append(apps.count == 1 ? "1 app" : "\(apps.count) apps") }
        if !websites.isEmpty { parts.append(websites.count == 1 ? "1 site" : "\(websites.count) sites") }
        return parts.isEmpty ? "Vide" : parts.joined(separator: " · ")
    }

    /// Les catégories fournies avec Prism : non modifiables, mais duplicables.
    static let builtIn: [FocusCategory] = [
        FocusCategory(
            id: "social", name: "Réseaux sociaux", symbol: "person.2.fill", color: "pink",
            apps: ["maccatalyst.com.atebits.Tweetie2", "com.tapbots.Ivory", "com.tapbots.TweetbotMac", "com.linkedin.LinkedIn"],
            websites: [
                "facebook.com", "instagram.com", "x.com", "twitter.com", "tiktok.com", "reddit.com", "linkedin.com",
                "threads.net", "bsky.app", "mastodon.social", "pinterest.com", "snapchat.com", "tumblr.com",
            ],
            isBuiltIn: true
        ),
        FocusCategory(
            id: "news", name: "Actualités", symbol: "newspaper.fill", color: "blue",
            apps: ["com.apple.news", "com.apple.stocks"],
            websites: [
                "lemonde.fr", "lefigaro.fr", "liberation.fr", "francetvinfo.fr", "bfmtv.com", "20minutes.fr",
                "leparisien.fr", "ouest-france.fr", "mediapart.fr", "lequipe.fr", "news.google.com", "nytimes.com",
                "theguardian.com", "bbc.com", "cnn.com", "news.ycombinator.com",
            ],
            isBuiltIn: true
        ),
        FocusCategory(
            id: "entertainment", name: "Divertissement et vidéo", symbol: "play.tv.fill", color: "red",
            apps: ["com.apple.TV", "com.spotify.client", "com.apple.Music", "com.apple.podcasts", "com.colliderli.iina", "org.videolan.vlc", "com.deezer.deezer-desktop"],
            websites: [
                "youtube.com", "netflix.com", "twitch.tv", "primevideo.com", "disneyplus.com", "canalplus.com",
                "molotov.tv", "dailymotion.com", "vimeo.com", "crunchyroll.com", "open.spotify.com", "deezer.com", "9gag.com",
            ],
            isBuiltIn: true
        ),
        FocusCategory(
            id: "games", name: "Jeux", symbol: "gamecontroller.fill", color: "green",
            apps: ["com.valvesoftware.steam", "com.epicgames.EpicGamesLauncher", "com.gog.galaxy", "com.apple.Chess", "net.battle.app"],
            websites: ["chess.com", "lichess.org", "poki.com", "crazygames.com", "miniclip.com", "roblox.com", "steampowered.com", "epicgames.com"],
            isBuiltIn: true
        ),
        FocusCategory(
            id: "messaging", name: "Messagerie", symbol: "bubble.left.and.bubble.right.fill", color: "teal",
            apps: [
                "com.tinyspeck.slackmacgap", "com.hnc.Discord", "ru.keepcoder.Telegram", "org.telegram.desktop",
                "net.whatsapp.WhatsApp", "com.apple.MobileSMS", "com.facebook.archon", "org.whispersystems.signal-desktop",
                "com.microsoft.teams2",
            ],
            websites: ["web.whatsapp.com", "messenger.com", "discord.com", "web.telegram.org", "app.slack.com", "teams.microsoft.com"],
            isBuiltIn: true
        ),
        FocusCategory(
            id: "shopping", name: "Shopping", symbol: "cart.fill", color: "orange",
            apps: [],
            websites: [
                "amazon.fr", "amazon.com", "ebay.fr", "ebay.com", "leboncoin.fr", "vinted.fr", "aliexpress.com",
                "temu.com", "shein.com", "cdiscount.com", "fnac.com", "zalando.fr", "etsy.com",
            ],
            isBuiltIn: true
        ),
    ]
}

/// Ce qu'on choisit en démarrant une session ; gardé pour « Basculer la session ».
struct FocusConfiguration: Codable, Equatable {
    var goal: String
    /// Durée prévue en secondes ; `nil` : sans limite.
    var duration: TimeInterval?
    var mode: FocusMode
    var categoryIDs: [String]
    var extraApps: [String]
    var extraWebsites: [String]

    static let standard = FocusConfiguration(
        goal: "", duration: 25 * 60, mode: .block,
        categoryIDs: ["social", "news", "entertainment"], extraApps: [], extraWebsites: []
    )
}

/// Une session de concentration. Le temps se calcule à partir des dates : rien à mettre à jour chaque seconde,
/// et une session survit au redémarrage de Prism.
struct FocusSession: Codable, Equatable {
    var id = UUID()
    var goal: String
    var mode: FocusMode
    var categoryIDs: [String]
    var extraApps: [String]
    var extraWebsites: [String]
    var startedAt: Date
    /// Durée de concentration prévue, prolongations comprises ; `nil` : sans limite.
    var duration: TimeInterval?
    /// Début de la pause en cours.
    var pausedAt: Date?
    /// Fin prévue de la pause en cours ; `nil` : jusqu'à la reprise.
    var pauseEndsAt: Date?
    /// Temps passé en pause, pauses terminées seulement.
    var pausedTotal: TimeInterval = 0
    /// La pause en cours vient de la mise en veille : elle se lève au réveil.
    var pausedBySleep = false
    /// Chemins des apps quittées par le blocage, rouvertes à la fin.
    var closedApps: [String] = []

    init(configuration: FocusConfiguration, startedAt: Date) {
        goal = configuration.goal
        mode = configuration.mode
        categoryIDs = configuration.categoryIDs
        extraApps = configuration.extraApps
        extraWebsites = configuration.extraWebsites
        duration = configuration.duration
        self.startedAt = startedAt
    }

    var configuration: FocusConfiguration {
        FocusConfiguration(goal: goal, duration: duration, mode: mode, categoryIDs: categoryIDs, extraApps: extraApps, extraWebsites: extraWebsites)
    }

    var isPaused: Bool { pausedAt != nil }
    var isUnlimited: Bool { duration == nil }

    /// Temps de concentration écoulé, pauses déduites.
    func elapsed(at now: Date) -> TimeInterval {
        max(0, (pausedAt ?? now).timeIntervalSince(startedAt) - pausedTotal)
    }

    /// Temps restant ; `nil` pour une session sans limite.
    func remaining(at now: Date) -> TimeInterval? {
        duration.map { max(0, $0 - elapsed(at: now)) }
    }

    func isOver(at now: Date) -> Bool { remaining(at: now) == 0 }

    /// Avancement de 0 à 1 (0 pour une session sans limite).
    func progress(at now: Date) -> Double {
        guard let duration, duration > 0 else { return 0 }
        return min(1, elapsed(at: now) / duration)
    }

    /// Heure de fin si la session continue sans pause.
    func endDate(at now: Date) -> Date? {
        remaining(at: now).map { now.addingTimeInterval($0) }
    }

    mutating func pause(at now: Date, for length: TimeInterval?, bySleep: Bool = false) {
        guard pausedAt == nil else { return }
        pausedAt = now
        pauseEndsAt = length.map { now.addingTimeInterval($0) }
        pausedBySleep = bySleep
    }

    mutating func resume(at now: Date) {
        guard let pausedAt else { return }
        pausedTotal += max(0, now.timeIntervalSince(pausedAt))
        self.pausedAt = nil
        pauseEndsAt = nil
        pausedBySleep = false
    }

    /// Ajoute du temps ; sans effet sur une session sans limite.
    mutating func extend(by seconds: TimeInterval) {
        guard let duration else { return }
        self.duration = duration + seconds
    }
}

/// Une session passée, pour l'historique des réglages.
struct FocusHistoryEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var goal: String
    var startedAt: Date
    var endedAt: Date
    /// Temps de concentration effectif, pauses déduites.
    var focused: TimeInterval
    var planned: TimeInterval?
}

/// Ce que Prism garde sur le disque : catégories personnalisées, historique, session en cours, dernière configuration.
struct FocusData: Codable {
    var categories: [FocusCategory] = []
    var history: [FocusHistoryEntry] = []
    var session: FocusSession?
    var lastConfiguration: FocusConfiguration?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        categories = try container.decodeIfPresent([FocusCategory].self, forKey: .categories) ?? []
        history = try container.decodeIfPresent([FocusHistoryEntry].self, forKey: .history) ?? []
        session = try container.decodeIfPresent(FocusSession.self, forKey: .session)
        lastConfiguration = try container.decodeIfPresent(FocusConfiguration.self, forKey: .lastConfiguration)
    }
}

// MARK: - Durées

/// Une durée de session : limitée (en secondes) ou sans limite.
enum FocusDuration: Equatable {
    case limited(TimeInterval)
    case unlimited

    static let maximum: TimeInterval = 24 * 3600

    var seconds: TimeInterval? {
        if case .limited(let value) = self { return value }
        return nil
    }

    /// Les durées proposées par la liste déroulante.
    static let presets: [(value: String, title: String)] = [
        ("5", "5 min"), ("10", "10 min"), ("15", "15 min"), ("25", "25 min"), ("30", "30 min"), ("45", "45 min"),
        ("60", "1 h"), ("90", "1 h 30"), ("120", "2 h"), ("180", "3 h"), ("240", "4 h"),
        ("day", "Jusqu’à la fin de la journée"), ("unlimited", "Sans limite"),
    ]

    /// Une valeur de la liste déroulante, ou un texte libre.
    static func preset(_ value: String, now: Date, calendar: Calendar = .current) -> FocusDuration? {
        switch value {
        case "unlimited": return .unlimited
        case "day": return parse("journée", now: now, calendar: calendar)
        default: return Double(value).map { .limited($0 * 60) }
        }
    }

    /// « 45 », « 45 min », « 1h30 », « 1 h 30 », « 1,5 h », « 2 heures », « 90 minutes », « jusqu’à 16h30 »,
    /// « à 9:15 », « journée », « sans limite ». `nil` si le texte n'est pas compris.
    static func parse(_ raw: String, now: Date, calendar: Calendar = .current) -> FocusDuration? {
        let text = raw.normalizedForSearch
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if ["sans limite", "illimite", "illimitee", "aucune limite", "infini", "∞", "unlimited", "no limit"].contains(text) {
            return .unlimited
        }
        if ["journee", "la journee", "toute la journee", "fin de journee", "jusqu'a la fin de la journee", "jusqu'a ce soir", "day", "all day"].contains(text) {
            guard let midnight = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime) else { return nil }
            return .limited(midnight.timeIntervalSince(now))
        }
        for prefix in ["jusqu'a ", "jusqu'au ", "jusqu a ", "jusqua ", "until ", "till ", "a ", "-> ", "→ "] where text.hasPrefix(prefix) {
            return clockTime(String(text.dropFirst(prefix.count)), now: now, calendar: calendar)
        }
        return length(text)
    }

    /// « 16h30 », « 16:30 », « 9h », « 4pm » : la prochaine fois que l'horloge affichera cette heure.
    private static func clockTime(_ text: String, now: Date, calendar: Calendar) -> FocusDuration? {
        let pattern = #"^(\d{1,2})\s*(?:h|:)?\s*(\d{2})?\s*(am|pm)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text.trimmingCharacters(in: .whitespaces) as NSString
        guard let match = regex.firstMatch(in: ns as String, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ index: Int) -> String? {
            match.range(at: index).location == NSNotFound ? nil : ns.substring(with: match.range(at: index))
        }
        guard var hour = group(1).flatMap(Int.init) else { return nil }
        let minute = group(2).flatMap(Int.init) ?? 0
        if let suffix = group(3) {
            guard (1...12).contains(hour) else { return nil }
            if suffix == "pm", hour < 12 { hour += 12 }
            if suffix == "am", hour == 12 { hour = 0 }
        }
        guard (0...23).contains(hour), (0...59).contains(minute),
              let target = calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0), matchingPolicy: .nextTime)
        else { return nil }
        return .limited(target.timeIntervalSince(now))
    }

    /// Une longueur : nombres suivis d'une unité d'heures ou de minutes ; un nombre seul compte en minutes.
    private static func length(_ text: String) -> FocusDuration? {
        let pattern = #"(\d+(?:[.,]\d+)?)\s*(heures?|hours?|hrs?|h|minutes?|mins?|mn|m)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        // Rien d'autre que des nombres, des unités, des espaces et « et ».
        var rest = text
        for match in matches.reversed() {
            if let range = Range(match.range, in: rest) { rest.replaceSubrange(range, with: " ") }
        }
        let leftover = rest.split(separator: " ").filter { $0 != "et" && $0 != "and" }
        guard leftover.isEmpty else { return nil }

        var total: TimeInterval = 0
        var previousWasHours = false
        for match in matches {
            guard let number = Double(ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: ".")) else { return nil }
            let unit = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2))
            if unit.hasPrefix("h") {
                total += number * 3600
                previousWasHours = true
            } else {
                // « 1h30 » : le nombre après les heures compte en minutes, comme un nombre seul.
                guard !unit.isEmpty || previousWasHours || matches.count == 1 else { return nil }
                total += number * 60
                previousWasHours = false
            }
        }
        return total > 0 ? .limited(total.rounded()) : nil
    }
}

// MARK: - Mise en forme

enum FocusFormat {
    /// « 24:59 », « 1:05:12 » : le minuteur.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.up))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// « 25 min », « 1 h », « 1 h 30 », « moins d’une minute ».
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "moins d’une minute" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : String(format: "%d h %02d", hours, rest)
    }

    /// « 16:30 ».
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Règles de blocage

/// Une app vue par les règles : son identifiant et son nom.
struct FocusAppIdentity: Equatable {
    var bundleID: String?
    var name: String
}

/// Ce que bloque une session : la réunion de ses catégories et de ses ajouts, selon le mode.
struct FocusRules: Equatable {
    var mode: FocusMode
    var apps: [String]
    var websites: [String]
    /// Mode « autoriser » : un navigateur autorisé sans aucun site listé laisse passer tous les sites.
    var allowAllSitesWithBrowser = true

    /// Navigateurs surveillés (onglet actif lu par AppleScript).
    static let browsers = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi"]

    /// Jamais bloquées, même en mode « autoriser seulement » : Prism, le Finder et ce dont macOS a besoin.
    static let essentialApps: Set<String> = [
        "com.apple.finder", "com.apple.systempreferences", "com.apple.Settings", "com.apple.ActivityMonitor",
        "com.apple.loginwindow", "com.apple.dock", "com.apple.SecurityAgent", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.Spotlight", "com.apple.coreservices.uiagent",
        "com.apple.UserNotificationCenter", "com.apple.screencaptureui", "com.apple.ScreenSaver.Engine",
        "com.apple.LocalAuthentication.UIAgent", "com.apple.PIPAgent", "com.apple.CoreServicesUIAgent",
        "com.apple.WindowManager", "com.apple.accessibility.universalAccessAuthWarn", "com.apple.Passwords",
        "com.apple.keychainaccess", "app.prism.launcher",
    ]

    init(mode: FocusMode, apps: [String], websites: [String], allowAllSitesWithBrowser: Bool = true) {
        self.mode = mode
        self.apps = apps
        self.websites = websites.compactMap(Self.normalizeDomain)
        self.allowAllSitesWithBrowser = allowAllSitesWithBrowser
    }

    init(session: FocusSession, categories: [FocusCategory], allowAllSitesWithBrowser: Bool) {
        let chosen = categories.filter { session.categoryIDs.contains($0.id) }
        self.init(
            mode: session.mode,
            apps: Self.unique(chosen.flatMap(\.apps) + session.extraApps),
            websites: Self.unique(chosen.flatMap(\.websites) + session.extraWebsites),
            allowAllSitesWithBrowser: allowAllSitesWithBrowser
        )
    }

    static func isEssential(_ app: FocusAppIdentity) -> Bool {
        if let id = app.bundleID {
            if essentialApps.contains(id) || id == Bundle.main.bundleIdentifier { return true }
        }
        return app.name == "Prism" || app.name == "Finder"
    }

    static func isBrowser(_ app: FocusAppIdentity) -> Bool {
        app.bundleID.map(browsers.contains) ?? false
    }

    private func isListed(_ app: FocusAppIdentity) -> Bool {
        apps.contains { Self.app(app, matches: $0) }
    }

    /// L'app doit-elle être masquée ?
    func blocks(app: FocusAppIdentity) -> Bool {
        guard !Self.isEssential(app) else { return false }
        switch mode {
        case .block:
            return isListed(app)
        case .allow:
            if isListed(app) { return false }
            // Des sites autorisés impliquent un navigateur pour les ouvrir.
            return !(Self.isBrowser(app) && !websites.isEmpty)
        }
    }

    /// L'adresse doit-elle être remplacée par la page de blocage ? Seules les pages web sont concernées.
    func blocks(url string: String, browser: FocusAppIdentity) -> Bool {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        let matched = websites.contains { Self.host(host, path: url.path, matches: $0) }
        switch mode {
        case .block:
            return matched
        case .allow:
            if matched { return false }
            if websites.isEmpty, allowAllSitesWithBrowser, isListed(browser) { return false }
            return true
        }
    }

    // MARK: Correspondances

    /// Une entrée désigne l'app par son identifiant (`com.hnc.Discord`) ou par son nom (« Discord », « discord.app »).
    static func app(_ app: FocusAppIdentity, matches entry: String) -> Bool {
        var cleaned = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        if let id = app.bundleID, id.caseInsensitiveCompare(cleaned) == .orderedSame { return true }
        if cleaned.lowercased().hasSuffix(".app") { cleaned.removeLast(4) }
        return cleaned.normalizedForSearch == app.name.normalizedForSearch
    }

    /// `www.Reddit.com/` → `reddit.com` ; `https://youtube.com/shorts/` → `youtube.com/shorts`. `nil` si ce n'est pas un domaine.
    static func normalizeDomain(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if let query = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = String(text[..<query]) }
        while text.hasSuffix("/") { text.removeLast() }
        let parts = text.split(separator: "/", maxSplits: 1).map(String.init)
        guard var host = parts.first else { return nil }
        if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."),
              host.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return parts.count > 1 ? host + "/" + parts[1] : host
    }

    /// Le domaine et ses sous-domaines ; avec un chemin, les pages sous ce chemin.
    static func host(_ host: String, path: String, matches entry: String) -> Bool {
        let parts = entry.split(separator: "/", maxSplits: 1).map(String.init)
        guard let domain = parts.first else { return false }
        var host = host.lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard host == domain || host.hasSuffix("." + domain) else { return false }
        guard parts.count > 1 else { return true }
        let prefix = "/" + parts[1]
        let lowered = path.lowercased()
        return lowered == prefix || lowered.hasPrefix(prefix + "/")
    }

    /// Une liste saisie : une entrée par ligne, ou séparées par des virgules ; sans doublon.
    static func parseList(_ text: String) -> [String] {
        unique(text.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    /// Les sites saisis, normalisés ; les entrées qui ne sont pas des domaines sont renvoyées à part.
    static func parseWebsites(_ text: String) -> (valid: [String], invalid: [String]) {
        var valid: [String] = []
        var invalid: [String] = []
        for entry in parseList(text) {
            if let domain = normalizeDomain(entry) { valid.append(domain) } else { invalid.append(entry) }
        }
        return (unique(valid), invalid)
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }
}
