import AppKit

/// Le HDR des écrans qui le gèrent (« Toggle HDR » de Raycast). macOS n'a pas d'API publique pour le basculer :
/// on passe par les fonctions de SkyLight qu'utilise Réglages Système, chargées à l'exécution
/// pour que Prism reste utilisable si elles disparaissent.
@MainActor
enum HDR {
    private typealias Check = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias SetMode = @convention(c) (CGDirectDisplayID, Bool, Int32, Int32) -> Int32

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    private static func function<T>(_ name: String, as type: T.Type) -> T? {
        guard let skyLight, let symbol = dlsym(skyLight, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    private static let supports = function("SLSDisplaySupportsHDRMode", as: Check.self)
    private static let isEnabled = function("SLSDisplayIsHDRModeEnabled", as: Check.self)
    private static let setEnabled = function("SLSDisplaySetHDRModeEnabled", as: SetMode.self)

    /// Les écrans branchés qui savent passer en HDR.
    static var displays: [CGDirectDisplayID] {
        guard let supports else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { supports($0) }
    }

    static func enabled(_ display: CGDirectDisplayID) -> Bool { isEnabled?(display) ?? false }

    static func name(of display: CGDirectDisplayID) -> String {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display }?.localizedName ?? "Écran"
    }

    /// Bascule les écrans HDR ensemble, d'après l'état du premier.
    static func toggle() -> ActionOutcome {
        let targets = displays
        guard let first = targets.first, let setEnabled else { return .toast("Aucun écran branché ne gère le HDR") }
        let wanted = !enabled(first)
        let failures = targets.filter { setEnabled($0, wanted, 0, 0) != 0 }
        guard failures.isEmpty else { return .toast("Le HDR n’a pas pu être basculé sur \(failures.map(name(of:)).joined(separator: ", "))") }
        let names = targets.map(name(of:)).joined(separator: ", ")
        return .hud(wanted ? "HDR activé : \(names)" : "HDR désactivé : \(names)")
    }

    static var commands: [ResultItem] {
        let targets = displays
        guard let first = targets.first else { return [] }
        return [Command.run("system.hdr", "Basculer le HDR", subtitle: "Système · \(enabled(first) ? "activé" : "désactivé") sur \(targets.map(name(of:)).joined(separator: ", "))",
                            symbol: "sun.max.trianglebadge.exclamationmark", color: Palette.orange,
                            keywords: ["hdr", "toggle hdr", "high dynamic range", "écran", "display", "luminosité"]) { toggle() }]
    }

    static func selfTest(_ check: (Bool, String) -> Void) {
        check(supports != nil && isEnabled != nil && setEnabled != nil, "HDR : fonctions de SkyLight trouvées")
    }
}
