import AppKit
import IOBluetooth

/// Le Bluetooth : alimentation par les fonctions privées d'IOBluetooth (celles qu'utilise `blueutil`),
/// appareils appairés par `IOBluetoothDevice`. Toute lecture déclenche l'autorisation Bluetooth de macOS :
/// rien n'est lu tant que l'utilisateur n'a pas lancé une commande.
enum Bluetooth {
    private typealias GetPower = @convention(c) () -> Int32
    private typealias SetPower = @convention(c) (Int32) -> Void

    private static let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW)

    private static var getter: GetPower? {
        dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState").map { unsafeBitCast($0, to: GetPower.self) }
    }

    private static var setter: SetPower? {
        dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState").map { unsafeBitCast($0, to: SetPower.self) }
    }

    /// Les fonctions privées existent-elles sur ce système ? (Sans les appeler.)
    static var isControllable: Bool { getter != nil && setter != nil }

    static var isPowered: Bool? { getter.map { $0() != 0 } }

    /// Allume ou éteint le Bluetooth, puis attend que l'état suive (jusqu'à 3 secondes).
    @discardableResult
    static func setPower(_ on: Bool) -> Bool {
        guard let setter, let getter else { return false }
        setter(on ? 1 : 0)
        for _ in 0..<30 {
            if (getter() != 0) == on { return true }
            usleep(100_000)
        }
        return (getter() != 0) == on
    }

    /// Le symbole d'un appareil selon sa classe (casque, clavier, souris…).
    static func symbol(major: UInt32, minor: UInt32, name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if lower.contains("mouse") || lower.contains("souris") { return "magicmouse.fill" }
        if lower.contains("keyboard") || lower.contains("clavier") { return "keyboard.fill" }
        switch major {
        case 0x04: return "headphones" // audio/vidéo
        case 0x05:
            // Périphérique : bit 6 clavier, bit 7 pointage.
            if minor & 0x10 != 0 { return "keyboard.fill" }
            if minor & 0x20 != 0 { return "computermouse.fill" }
            return "gamecontroller.fill"
        case 0x02: return "iphone"
        case 0x01: return "laptopcomputer"
        case 0x06: return "printer.fill"
        default: return "dot.radiowaves.left.and.right"
        }
    }
}

/// L'écran « Appareils Bluetooth » : appareils appairés, connectés en tête ; se connecter ou se déconnecter.
@MainActor
final class BluetoothScreen: LauncherScreen {
    private var devices: [IOBluetoothDevice] = []
    private var powered: Bool?
    private var busy = Set<String>()

    init() {
        super.init(id: "system.bluetooth-devices", title: "Appareils Bluetooth", placeholder: "Rechercher un appareil…", icon: .symbol("dot.radiowaves.left.and.right", Palette.blue))
    }

    override func didAppear() { load() }

    private func load() {
        // En rendu ou en autotest, rien n'est lu : la liste des appareils demande l'autorisation Bluetooth.
        guard !SystemFeature.isHeadless else {
            powered = true
            reload()
            return
        }
        powered = Bluetooth.isPowered
        devices = (IOBluetoothDevice.pairedDevices() ?? []).compactMap { $0 as? IOBluetoothDevice }
        reload()
    }

    override func sections(query: String) -> [ResultSection] {
        let normalized = query.normalizedForSearch
        let matches = devices.filter { normalized.isEmpty || Fuzzy.score(normalized, $0.name ?? "") != nil }
        var sections: [ResultSection] = []
        if normalized.isEmpty, let powered {
            sections.append(ResultSection(id: "power", title: nil, items: [powerItem(powered)]))
        }
        let connected = matches.filter { $0.isConnected() }
        let others = matches.filter { !$0.isConnected() }
        if !connected.isEmpty { sections.append(ResultSection(id: "connected", title: "Connectés", items: connected.map(item))) }
        if !others.isEmpty { sections.append(ResultSection(id: "paired", title: "Appareils appairés", items: others.map(item))) }
        return sections
    }

    override func emptyState(query: String) -> (symbol: String, message: String) {
        query.isEmpty ? ("dot.radiowaves.left.and.right", "Aucun appareil appairé") : super.emptyState(query: query)
    }

    private func powerItem(_ powered: Bool) -> ResultItem {
        ResultItem(
            id: "bluetooth.power",
            title: powered ? "Bluetooth activé" : "Bluetooth désactivé",
            icon: .symbol("dot.radiowaves.left.and.right", powered ? Palette.blue : Palette.gray),
            accessory: powered ? "Activé" : "Désactivé",
            usageKey: "",
            actions: [
                ItemAction(title: powered ? "Désactiver le Bluetooth" : "Activer le Bluetooth", symbol: "power") { [weak self] in
                    self?.isLoading = true
                    DispatchQueue.global(qos: .userInitiated).async {
                        Bluetooth.setPower(!powered)
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                self?.isLoading = false
                                self?.load()
                            }
                        }
                    }
                    return .stay
                },
                SystemSettingsLink.action(title: "Ouvrir les réglages Bluetooth", pane: "com.apple.BluetoothSettings"),
            ]
        )
    }

    private func item(_ device: IOBluetoothDevice) -> ResultItem {
        let name = device.name ?? device.addressString ?? "Appareil"
        let address = device.addressString ?? ""
        let connected = device.isConnected()
        let symbol = Bluetooth.symbol(major: device.deviceClassMajor, minor: device.deviceClassMinor, name: name)
        let isBusy = busy.contains(address)
        var actions: [ItemAction] = []
        if connected {
            actions.append(ItemAction(title: "Se déconnecter", symbol: "bolt.horizontal.circle") { [weak self] in
                self?.toggle(device, connect: false)
                return .stay
            })
        } else {
            actions.append(ItemAction(title: "Se connecter", symbol: "bolt.horizontal.circle.fill") { [weak self] in
                self?.toggle(device, connect: true)
                return .stay
            })
        }
        actions.append(Actions.copy(address, title: "Copier l’adresse", shortcut: .copyText, hud: "Adresse copiée"))
        actions.append(Actions.copy(name, title: "Copier le nom", shortcut: .copyName, hud: "Nom copié"))
        actions.append(ItemAction(title: "Actualiser", symbol: "arrow.clockwise", shortcut: .refresh) { [weak self] in
            self?.load()
            return .stay
        })
        return ResultItem(
            id: "bluetooth.device." + address,
            title: name,
            subtitle: isBusy ? (connected ? "Déconnexion…" : "Connexion…") : (connected ? "Connecté" : nil),
            icon: .symbol(symbol, connected ? Palette.blue : Palette.gray),
            accessory: address,
            usageKey: "",
            actions: actions
        )
    }

    /// La connexion peut prendre plusieurs secondes : elle se fait hors du fil principal.
    private func toggle(_ device: IOBluetoothDevice, connect: Bool) {
        let address = device.addressString ?? ""
        let name = device.name ?? address
        busy.insert(address)
        reload()
        nonisolated(unsafe) let target = device
        DispatchQueue.global(qos: .userInitiated).async {
            let result = connect ? target.openConnection() : target.closeConnection()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy.remove(address)
                    if result == kIOReturnSuccess {
                        self.host?.showToast(connect ? "Connecté à \(name)" : "\(name) déconnecté", isError: false)
                    } else {
                        self.host?.showToast(connect ? "Connexion à \(name) impossible" : "Déconnexion impossible")
                    }
                    self.load()
                }
            }
        }
    }
}
