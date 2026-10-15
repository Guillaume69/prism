import AppKit
import IOKit.ps

/// Un panneau des Réglages Système (ou une section, comme Confidentialité › Micro).
struct SystemSettingsPane {
    /// Ce qui suit « x-apple.systempreferences: », ou le chemin d'un `.prefPane` tiers.
    let target: String
    let title: String
    var subtitle = "Réglages Système"
    /// Le bundle dont on montre l'icône.
    let iconPath: String
    var keywords: [String] = []
    var isThirdParty = false
    /// Symbole à la place de l'icône, pour les extensions qui n'en ont pas.
    var symbol: String?

    var url: URL? {
        isThirdParty ? URL(fileURLWithPath: target) : URL(string: "x-apple.systempreferences:" + target)
    }
}

/// Les panneaux des Réglages Système, lus dans les extensions de `/System/Library/ExtensionKit/Extensions`
/// (point d'extension `com.apple.Settings.extension.ui`), avec leur nom localisé ; plus les sections utiles
/// de Confidentialité et sécurité, et les panneaux tiers (`.prefPane`).
enum SystemSettingsCatalog {
    static let extensionsDirectory = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions", isDirectory: true)
    static let privacyExtension = "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex"

    /// Panneaux réservés à des cas particuliers (éducation, suivi interne) ou sans nom lisible.
    static let excluded: Set<String> = [
        "com.apple.FollowUpSettings.FollowUpSettingsExtension",
        "com.apple.HeadphoneSettings",
        "com.apple.ClassKit-Settings.extension",
        "com.apple.Classroom-Settings.extension",
    ]

    /// Des mots-clés pour trouver un panneau par ce qu'il règle.
    static let extraKeywords: [String: [String]] = [
        "com.apple.Appearance-Settings.extension": ["dark mode", "mode sombre", "theme", "couleur d accentuation"],
        "com.apple.Displays-Settings.extension": ["ecran", "resolution", "luminosite", "night shift", "displays"],
        "com.apple.Sound-Settings.extension": ["volume", "audio", "haut-parleurs", "micro", "sound"],
        "com.apple.Desktop-Settings.extension": ["dock", "stage manager", "mission control", "coins actifs"],
        "com.apple.Wallpaper-Settings.extension": ["wallpaper", "fond d ecran"],
        "com.apple.Battery-Settings.extension": ["battery", "energie", "economiseur d energie", "low power mode"],
        "com.apple.wifi-settings-extension": ["wifi", "wi-fi", "reseau sans fil"],
        "com.apple.Network-Settings.extension": ["network", "ethernet", "coupe-feu", "firewall"],
        "com.apple.Keyboard-Settings.extension": ["keyboard", "raccourcis clavier", "dictee", "saisie"],
        "com.apple.settings.PrivacySecurity.extension": ["privacy", "securite", "filevault", "autorisations"],
        "com.apple.Software-Update-Settings.extension": ["software update", "mise a jour", "macos"],
        "com.apple.LoginItems-Settings.extension": ["login items", "ouverture", "demarrage", "extensions"],
        "com.apple.Users-Groups-Settings.extension": ["users", "utilisateurs", "comptes"],
        "com.apple.Lock-Screen-Settings.extension": ["lock screen", "economiseur d ecran", "mot de passe"],
        "com.apple.Touch-ID-Settings.extension": ["touch id", "mot de passe", "empreinte"],
        "com.apple.Focus-Settings.extension": ["focus", "ne pas deranger", "do not disturb"],
        "com.apple.settings.Storage": ["storage", "espace disque", "stockage"],
        "com.apple.Sharing-Settings.extension": ["sharing", "airplay", "partage d ecran", "nom de l ordinateur"],
        "com.apple.Siri-Settings.extension": ["apple intelligence", "siri"],
        "com.apple.Localization-Settings.extension": ["language", "langue", "region", "format de date"],
        "com.apple.Date-Time-Settings.extension": ["date", "heure", "fuseau horaire", "time zone"],
        "com.apple.ControlCenter-Settings.extension": ["control center", "centre de controle", "menu bar"],
    ]

    /// Les sections de Confidentialité et sécurité : ancres reconnues par les Réglages Système.
    static let privacyAnchors: [(anchor: String, title: String, keywords: [String])] = [
        ("Privacy_Accessibility", "Accessibilité", ["accessibility", "accessibilite"]),
        ("Privacy_Microphone", "Micro", ["microphone", "micro"]),
        ("Privacy_Camera", "Caméra", ["camera", "webcam"]),
        ("Privacy_ScreenCapture", "Enregistrement de l’écran et de l’audio du système", ["screen recording", "capture d ecran"]),
        ("Privacy_AllFiles", "Accès complet au disque", ["full disk access", "disque"]),
        ("Privacy_FilesAndFolders", "Fichiers et dossiers", ["files and folders"]),
        ("Privacy_Automation", "Automatisation", ["automation", "applescript", "apple events"]),
        ("Privacy_ListenEvent", "Surveillance de l’entrée", ["input monitoring", "clavier"]),
        ("Privacy_LocationServices", "Service de localisation", ["location services", "localisation", "gps"]),
        ("Privacy_Contacts", "Contacts", ["contacts"]),
        ("Privacy_Calendars", "Calendriers", ["calendars", "agenda"]),
        ("Privacy_Reminders", "Rappels", ["reminders"]),
        ("Privacy_Photos", "Photos", ["photos"]),
        ("Privacy_Bluetooth", "Bluetooth", ["bluetooth"]),
        ("Privacy_SpeechRecognition", "Reconnaissance vocale", ["speech recognition", "dictee"]),
    ]

    /// Les langues à essayer pour les noms, dans l'ordre de l'utilisateur (« fr-FR » → « fr_FR », « fr »), puis le français.
    static var languages: [String] {
        var result: [String] = []
        for language in Locale.preferredLanguages + ["fr"] {
            let underscored = language.replacingOccurrences(of: "-", with: "_")
            for candidate in [underscored, String(underscored.split(separator: "_").first ?? "")] where !candidate.isEmpty && !result.contains(candidate) {
                result.append(candidate)
            }
        }
        return result
    }

    /// Les panneaux des extensions du système, triés par nom.
    static func scanExtensions(directory: URL = extensionsDirectory, languages: [String] = languages) -> [SystemSettingsPane] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        var panes: [SystemSettingsPane] = []
        for name in names where name.hasSuffix(".appex") {
            let bundle = directory.appendingPathComponent(name, isDirectory: true)
            guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
                  let attributes = info["EXAppExtensionAttributes"] as? [String: Any],
                  attributes["EXExtensionPointIdentifier"] as? String == "com.apple.Settings.extension.ui",
                  (attributes["SettingsExtensionAttributes"] as? [String: Any])?["allowsXAppleSystemPreferencesURLScheme"] as? Bool == true,
                  let identifier = info["CFBundleIdentifier"] as? String,
                  !excluded.contains(identifier) else { continue }
            let table = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Resources/InfoPlist.loctable")) as? [String: Any] ?? [:]
            func localized(_ language: String) -> String? {
                guard let strings = table[language] as? [String: Any] else { return nil }
                return strings["CFBundleDisplayName"] as? String ?? strings["CFBundleName"] as? String
            }
            let english = localized("en") ?? info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
            let title = override(for: identifier) ?? languages.lazy.compactMap(localized).first ?? english
            guard var title, !title.isEmpty else { continue }
            // Le trait d'union insécable d'Apple (« Wi‑Fi ») gênerait la recherche.
            title = title.replacingOccurrences(of: "\u{2011}", with: "-")
            var keywords = extraKeywords[identifier] ?? []
            if let english, english != title { keywords.insert(english.replacingOccurrences(of: "\u{2011}", with: "-"), at: 0) }
            var pane = SystemSettingsPane(target: identifier, title: title, iconPath: bundle.path, keywords: keywords)
            if identifier == "com.apple.Battery-Settings.extension" { pane.symbol = hasBattery ? "battery.100percent" : "bolt.fill" }
            panes.append(pane)
        }
        return panes.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Les noms qu'Apple ne localise pas dans l'extension elle-même.
    private static func override(for identifier: String) -> String? {
        switch identifier {
        case "com.apple.Battery-Settings.extension": hasBattery ? "Batterie" : "Énergie"
        default: nil
        }
    }

    private static var hasBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return !sources.isEmpty
    }

    static var privacyPanes: [SystemSettingsPane] {
        privacyAnchors.map { anchor in
            SystemSettingsPane(
                target: "com.apple.preference.security?" + anchor.anchor,
                title: anchor.title,
                subtitle: "Confidentialité et sécurité",
                iconPath: privacyExtension,
                keywords: anchor.keywords + ["confidentialite", "privacy"]
            )
        }
    }

    /// Les panneaux tiers (pilotes, outils) installés pour tous ou pour l'utilisateur.
    static func thirdPartyPanes() -> [SystemSettingsPane] {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/PreferencePanes").path
        return ["/Library/PreferencePanes", home].flatMap { folder -> [SystemSettingsPane] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            return names.filter { $0.hasSuffix(".prefPane") }.map { name in
                let path = (folder as NSString).appendingPathComponent(name)
                let bundle = Bundle(path: path)
                let title = bundle?.localizedInfoDictionary?["CFBundleName"] as? String
                    ?? bundle?.infoDictionary?["NSPrefPaneIconLabel"] as? String
                    ?? String(name.dropLast(".prefPane".count))
                return SystemSettingsPane(target: path, title: title, iconPath: path, isThirdParty: true)
            }
        }
    }
}

/// Les Réglages Système dans la recherche : chaque panneau se trouve par son nom ou ce qu'il règle.
@MainActor
enum SystemSettingsFeature: PrismFeature {
    private static var cache: [SystemSettingsPane]?

    /// Tous les panneaux, lus une fois.
    static var panes: [SystemSettingsPane] {
        if let cache { return cache }
        let all = SystemSettingsCatalog.scanExtensions() + SystemSettingsCatalog.privacyPanes + SystemSettingsCatalog.thirdPartyPanes()
        cache = all
        return all
    }

    static var commands: [ResultItem] {
        [Command.screen("system-settings", "Rechercher dans les Réglages Système", subtitle: "Réglages Système", symbol: "gearshape.fill", color: Palette.gray, keywords: ["system settings", "system preferences", "preferences systeme", "reglages"]) {
            screen()
        }]
    }

    /// Les meilleurs panneaux sous les résultats de la recherche principale.
    static func extraSections(query: String) -> [ResultSection] {
        let normalized = query.normalizedForSearch
        guard normalized.count >= 2 else { return [] }
        let scored = panes.compactMap { pane -> (SystemSettingsPane, Double)? in
            var best = Fuzzy.score(normalized, pane.title) ?? 0
            for keyword in pane.keywords {
                best = max(best, (Fuzzy.score(normalized, keyword) ?? 0) * 0.85)
            }
            // Les sous-séquences lointaines (score < 55) feraient du bruit.
            return best >= 55 ? (pane, best) : nil
        }
        let items = scored
            .sorted { $0.1 == $1.1 ? $0.0.title.count < $1.0.title.count : $0.1 > $1.1 }
            .prefix(5)
            .map { item($0.0) }
        return items.isEmpty ? [] : [ResultSection(id: "system-settings", title: "Réglages Système", items: Array(items))]
    }

    static func item(_ pane: SystemSettingsPane) -> ResultItem { item(pane, showsSubtitle: true) }

    static func item(_ pane: SystemSettingsPane, showsSubtitle: Bool) -> ResultItem {
        var actions: [ItemAction] = [
            ItemAction(title: "Ouvrir dans Réglages Système", symbol: "gearshape") {
                if let url = pane.url { NSWorkspace.shared.open(url) }
                return .close
            },
        ]
        if let url = pane.url, !pane.isThirdParty {
            actions.append(Actions.copy(url.absoluteString, title: "Copier le lien du panneau", shortcut: .copyText, hud: "Lien copié"))
        }
        return ResultItem(
            id: "system-settings:" + pane.target,
            title: pane.title,
            subtitle: showsSubtitle ? pane.subtitle : nil,
            icon: pane.symbol.map { .symbol($0, Palette.green) } ?? .file(pane.iconPath),
            accessory: "Réglages",
            keywords: pane.keywords,
            actions: actions
        )
    }

    static func screen() -> ListScreen {
        ListScreen(id: "system-settings", title: "Réglages Système", placeholder: "Rechercher un réglage…", icon: .symbol("gearshape.fill", Palette.gray)) { query in
            let normalized = query.normalizedForSearch
            func matches(_ pane: SystemSettingsPane) -> Bool {
                normalized.isEmpty || Fuzzy.score(normalized, pane.title) != nil
                    || pane.keywords.contains { (Fuzzy.score(normalized, $0) ?? 0) >= 55 }
            }
            let all = panes.filter(matches)
            return [
                ResultSection(id: "panes", title: "Panneaux", items: all.filter { !$0.isThirdParty && $0.subtitle == "Réglages Système" }.map { item($0, showsSubtitle: false) }),
                ResultSection(id: "privacy", title: "Confidentialité et sécurité", items: all.filter { $0.subtitle != "Réglages Système" }.map { item($0, showsSubtitle: false) }),
                ResultSection(id: "third-party", title: "Autres panneaux", items: all.filter(\.isThirdParty).map { item($0, showsSubtitle: false) }),
            ].filter { !$0.items.isEmpty }
        }
    }

    static func selfTest(_ check: (Bool, String) -> Void) {
        let system = SystemSettingsCatalog.scanExtensions(languages: ["fr"])
        check(system.count > 20, "\(system.count) panneaux des Réglages Système")
        check(system.contains { $0.target == "com.apple.BluetoothSettings" && $0.title == "Bluetooth" }, "panneau Bluetooth trouvé")
        check(system.contains { $0.title == "Confidentialité et sécurité" }, "noms localisés en français")
        check(system.contains { $0.title == "Wi-Fi" }, "Wi-Fi, avec un trait d'union ordinaire")
        check(SystemSettingsPane(target: "com.apple.BluetoothSettings", title: "Bluetooth", iconPath: "").url?.absoluteString
              == "x-apple.systempreferences:com.apple.BluetoothSettings", "lien x-apple.systempreferences")
        let found = extraSections(query: "micro").first?.items.map(\.title) ?? []
        check(found.contains("Micro"), "« micro » trouve Confidentialité › Micro")
    }
}
