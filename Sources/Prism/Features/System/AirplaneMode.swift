import AppKit

/// Le mode avion de Prism : macOS n'en a pas, on coupe donc le Wi-Fi et le Bluetooth ensemble,
/// et on rétablit ensuite exactement ce qui était allumé.
@MainActor
enum AirplaneMode {
    private static let key = "system.airplane.restore"

    /// Ce qu'il faudra rallumer (« wifi », « bluetooth ») ; `nil` : le mode n'est pas actif.
    static var restore: [String]? {
        get { UserDefaults.standard.stringArray(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var isOn: Bool { restore != nil }

    static func toggle() -> ActionOutcome {
        if let restore {
            self.restore = nil
            DispatchQueue.global(qos: .userInitiated).async {
                if restore.contains("wifi") { _ = WiFi.setPower(true) }
                if restore.contains("bluetooth") { Bluetooth.setPower(true) }
            }
            return .hud("Mode avion désactivé")
        }
        var wasOn: [String] = []
        if WiFi.isPowered() == true { wasOn.append("wifi") }
        if Bluetooth.isPowered == true { wasOn.append("bluetooth") }
        restore = wasOn
        DispatchQueue.global(qos: .userInitiated).async {
            if wasOn.contains("wifi") { _ = WiFi.setPower(false) }
            if wasOn.contains("bluetooth") { Bluetooth.setPower(false) }
        }
        return .hud("Mode avion : Wi-Fi et Bluetooth coupés")
    }

    static var commands: [ResultItem] {
        [Command.run("system.airplane", "Mode avion", subtitle: "Système", symbol: "airplane", color: Palette.orange,
                     keywords: ["airplane mode", "avion", "hors ligne", "offline", "wifi", "bluetooth"]) { toggle() }]
    }
}
