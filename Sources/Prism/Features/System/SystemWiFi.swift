import AppKit
import CoreLocation
import CoreWLAN

/// Le Wi-Fi : interface et alimentation par CoreWLAN et `networksetup`, réseaux connus et à portée.
enum WiFi {
    // MARK: - Lecture des sorties de networksetup (pures, vérifiées par les autotests)

    /// L'interface Wi-Fi (« en0 ») dans la sortie de `networksetup -listallhardwareports`.
    static func interfaceName(fromHardwarePorts text: String) -> String? {
        var isWiFiPort = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Hardware Port:") {
                let port = trimmed.dropFirst("Hardware Port:".count).trimmingCharacters(in: .whitespaces).lowercased()
                isWiFiPort = port == "wi-fi" || port == "airport" || port == "wifi"
            } else if trimmed.hasPrefix("Device:"), isWiFiPort {
                let device = trimmed.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)
                return device.isEmpty ? nil : device
            }
        }
        return nil
    }

    /// « Wi-Fi Power (en0): On » → `true`.
    static func power(fromOutput text: String) -> Bool? {
        guard let colon = text.lastIndex(of: ":") else { return nil }
        switch text[text.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }

    /// Les réseaux de `networksetup -listpreferredwirelessnetworks`, une ligne indentée par réseau.
    static func preferredNetworks(fromOutput text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("\t") || $0.hasPrefix("  ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `networksetup -setairportnetwork` répond toujours 0 : l'erreur se lit dans le texte.
    static func joinError(fromOutput text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.contains("could not find") { return "Réseau introuvable" }
        if lower.contains("failed") || lower.contains("error") || lower.contains("-3900") { return "Connexion impossible" }
        return nil
    }

    // MARK: - État du système

    /// L'interface Wi-Fi : CoreWLAN, sinon la liste des ports matériels.
    static func interfaceName() -> String? {
        if let name = CWWiFiClient.shared().interface()?.interfaceName { return name }
        return interfaceName(fromHardwarePorts: SystemShell.output("/usr/sbin/networksetup", ["-listallhardwareports"]) ?? "")
    }

    static func isPowered() -> Bool? {
        if let interface = CWWiFiClient.shared().interface() { return interface.powerOn() }
        guard let name = interfaceName() else { return nil }
        return power(fromOutput: SystemShell.output("/usr/sbin/networksetup", ["-getairportpower", name]) ?? "")
    }

    /// Allume ou éteint le Wi-Fi (`networksetup -setairportpower`). En arrière-plan.
    static func setPower(_ on: Bool) -> Bool {
        guard let name = interfaceName() else { return false }
        return SystemShell.status("/usr/sbin/networksetup", ["-setairportpower", name, on ? "on" : "off"]) == 0
    }

    static func preferredNetworks() -> [String] {
        guard let name = interfaceName() else { return [] }
        return preferredNetworks(fromOutput: SystemShell.output("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", name]) ?? "")
    }

    /// Rejoint un réseau enregistré : le mot de passe vient du trousseau.
    static func join(_ ssid: String) -> String? {
        guard let name = interfaceName() else { return "Aucune interface Wi-Fi" }
        guard let output = SystemShell.output("/usr/sbin/networksetup", ["-setairportnetwork", name, ssid], includeErrors: true) else {
            return "Connexion impossible"
        }
        return joinError(fromOutput: output)
    }
}

/// Un réseau Wi-Fi vu par l'écran des réseaux.
struct WiFiNetwork {
    let ssid: String
    /// En dBm ; `nil` pour un réseau connu hors de portée.
    var rssi: Int?
    var isSecure = true
    var isKnown = false
    var isCurrent = false

    /// Barres de signal, de 1 à 3.
    var bars: Int {
        guard let rssi else { return 0 }
        if rssi >= -60 { return 3 }
        if rssi >= -72 { return 2 }
        return 1
    }
}

/// L'écran « Réseaux Wi-Fi » : réseau actuel, réseaux à portée et réseaux connus.
@MainActor
final class WiFiScreen: LauncherScreen {
    private var powered: Bool?
    private var networks: [WiFiNetwork] = []
    private var hasScanned = false
    private var locationManager: CLLocationManager?

    init() {
        super.init(id: "system.wifi-networks", title: "Réseaux Wi-Fi", placeholder: "Rechercher un réseau…", icon: .symbol("wifi", Palette.blue))
    }

    override func didAppear() {
        requestLocationIfNeeded()
        load()
    }

    /// Depuis macOS 14, le nom des réseaux n'est donné qu'aux apps autorisées à utiliser la localisation.
    private func requestLocationIfNeeded() {
        guard !SystemFeature.isHeadless else { return }
        let manager = CLLocationManager()
        if manager.authorizationStatus == .notDetermined {
            locationManager = manager
            manager.requestWhenInUseAuthorization()
        }
    }

    private func load() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let interface = CWWiFiClient.shared().interface()
            let powered = WiFi.isPowered()
            let current = interface?.ssid()
            let known = WiFi.preferredNetworks()
            var found: [WiFiNetwork] = []
            if powered == true, let scanned = try? interface?.scanForNetworks(withSSID: nil) {
                var best: [String: CWNetwork] = [:]
                for network in scanned {
                    guard let ssid = network.ssid, !ssid.isEmpty else { continue }
                    if let existing = best[ssid], existing.rssiValue >= network.rssiValue { continue }
                    best[ssid] = network
                }
                found = best.values.map { network in
                    WiFiNetwork(
                        ssid: network.ssid ?? "",
                        rssi: network.rssiValue,
                        isSecure: !network.supportsSecurity(.none),
                        isKnown: known.contains(network.ssid ?? ""),
                        isCurrent: network.ssid == current
                    )
                }
            }
            let inRange = Set(found.map(\.ssid))
            for ssid in known where !inRange.contains(ssid) {
                found.append(WiFiNetwork(ssid: ssid, rssi: nil, isKnown: true, isCurrent: ssid == current))
            }
            if let current, !found.contains(where: { $0.ssid == current }) {
                found.append(WiFiNetwork(ssid: current, rssi: interface?.rssiValue(), isKnown: true, isCurrent: true))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.powered = powered
                    self.networks = found
                    self.hasScanned = true
                    self.isLoading = false
                    self.reload()
                }
            }
        }
    }

    override func sections(query: String) -> [ResultSection] {
        let normalized = query.normalizedForSearch
        let matches = networks.filter { normalized.isEmpty || Fuzzy.score(normalized, $0.ssid) != nil }
        var sections: [ResultSection] = []
        if normalized.isEmpty, let powered {
            sections.append(ResultSection(id: "power", title: nil, items: [powerItem(powered)]))
        }
        let current = matches.filter(\.isCurrent)
        let inRange = matches.filter { !$0.isCurrent && $0.rssi != nil }.sorted { ($0.rssi ?? -200) > ($1.rssi ?? -200) }
        let known = matches.filter { !$0.isCurrent && $0.rssi == nil }.sorted { $0.ssid.localizedStandardCompare($1.ssid) == .orderedAscending }
        if !current.isEmpty { sections.append(ResultSection(id: "current", title: "Réseau actuel", items: current.map(item))) }
        if !inRange.isEmpty { sections.append(ResultSection(id: "range", title: "Réseaux à portée", items: inRange.map(item))) }
        if !known.isEmpty { sections.append(ResultSection(id: "known", title: "Réseaux connus", items: known.map(item))) }
        if hasScanned, powered == true, inRange.isEmpty, normalized.isEmpty {
            sections.append(ResultSection(id: "hint", title: nil, items: [locationHint()]))
        }
        return sections
    }

    override func emptyState(query: String) -> (symbol: String, message: String) {
        if isLoading { return ("wifi", "Recherche des réseaux…") }
        return super.emptyState(query: query)
    }

    private func powerItem(_ powered: Bool) -> ResultItem {
        ResultItem(
            id: "wifi.power",
            title: powered ? "Wi-Fi activé" : "Wi-Fi désactivé",
            subtitle: WiFi.interfaceName(),
            icon: .symbol(powered ? "wifi" : "wifi.slash", powered ? Palette.blue : Palette.gray),
            accessory: powered ? "Activé" : "Désactivé",
            usageKey: "",
            actions: [
                ItemAction(title: powered ? "Désactiver le Wi-Fi" : "Activer le Wi-Fi", symbol: "power") { [weak self] in
                    self?.isLoading = true
                    DispatchQueue.global(qos: .userInitiated).async {
                        _ = WiFi.setPower(!powered)
                        DispatchQueue.main.asyncAfter(deadline: .now() + (powered ? 0.2 : 2.5)) {
                            MainActor.assumeIsolated { self?.load() }
                        }
                    }
                    return .stay
                },
                SystemSettingsLink.action(title: "Ouvrir les réglages Wi-Fi", pane: "com.apple.wifi-settings-extension"),
            ]
        )
    }

    private func item(_ network: WiFiNetwork) -> ResultItem {
        var tags: [String] = []
        if network.isKnown, !network.isCurrent, network.rssi != nil { tags.append("Connu") }
        var actions: [ItemAction] = []
        if !network.isCurrent, network.isKnown || !network.isSecure {
            actions.append(ItemAction(title: "Se connecter", symbol: "wifi") {
                HUD.shared.show("Connexion à « \(network.ssid) »…", symbol: "wifi")
                DispatchQueue.global(qos: .userInitiated).async {
                    let error = WiFi.join(network.ssid)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if let error {
                                HUD.shared.show("\(error) : \(network.ssid)", symbol: "exclamationmark.triangle.fill")
                            } else {
                                HUD.shared.show("Connecté à « \(network.ssid) »", symbol: "wifi")
                            }
                        }
                    }
                }
                return .close
            })
        }
        if !network.isCurrent, !network.isKnown, network.isSecure {
            actions.append(SystemSettingsLink.action(title: "Se connecter dans les réglages Wi-Fi", pane: "com.apple.wifi-settings-extension"))
        }
        actions.append(Actions.copy(network.ssid, title: "Copier le nom du réseau", shortcut: .copyText, hud: "Nom du réseau copié"))
        actions.append(ItemAction(title: "Actualiser", symbol: "arrow.clockwise", shortcut: .refresh) { [weak self] in
            self?.load()
            return .stay
        })
        let symbol = network.rssi == nil ? "wifi.exclamationmark" : ["wifi.exclamationmark", "wifi", "wifi", "wifi"][network.bars]
        let subtitle: String
        if network.isCurrent {
            subtitle = "Connecté"
        } else if network.rssi == nil {
            subtitle = "Hors de portée"
        } else {
            subtitle = network.isSecure ? "Sécurisé" : "Ouvert"
        }
        return ResultItem(
            id: "wifi.network." + network.ssid,
            title: network.ssid,
            subtitle: subtitle,
            icon: .symbol(symbol, network.isCurrent ? Palette.blue : (network.rssi == nil ? Palette.gray : Palette.teal)),
            accessory: network.rssi.map { _ in String(repeating: "●", count: network.bars) + String(repeating: "○", count: 3 - network.bars) },
            tags: tags,
            usageKey: "",
            actions: actions
        )
    }

    private func locationHint() -> ResultItem {
        ResultItem(
            id: "wifi.location",
            title: "Autoriser la localisation pour voir les réseaux à portée",
            subtitle: "macOS ne donne le nom des réseaux qu’aux apps autorisées",
            icon: .symbol("location.fill", Palette.gray),
            usageKey: "",
            actions: [SystemSettingsLink.action(title: "Ouvrir Service de localisation", pane: "com.apple.preference.security?Privacy_LocationServices")]
        )
    }
}

/// Ouvre un panneau des Réglages Système (`x-apple.systempreferences:`).
@MainActor
enum SystemSettingsLink {
    static func url(_ pane: String) -> URL? { URL(string: "x-apple.systempreferences:" + pane) }

    static func open(_ pane: String) {
        if let url = url(pane) { NSWorkspace.shared.open(url) }
    }

    static func action(title: String, pane: String) -> ItemAction {
        ItemAction(title: title, symbol: "gearshape") {
            open(pane)
            return .close
        }
    }
}
