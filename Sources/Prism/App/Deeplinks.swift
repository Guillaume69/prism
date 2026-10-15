import AppKit

/// Liens profonds, comme ceux de Raycast (`raycast://…`) :
/// - `prism://commands/<identifiant>?arguments=a&arguments=b` lance une commande ;
/// - `prism://open` ouvre le lanceur, `prism://search?q=texte` avec une recherche ;
/// - les fonctionnalités prennent leurs propres chemins (`prism://focus/start`, `prism://notes/new`…).
@MainActor
enum Deeplinks {
    static let scheme = "prism"

    static func url(forItem id: String, arguments: [String] = []) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "commands"
        components.path = "/" + (id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id)
        if !arguments.isEmpty {
            components.queryItems = arguments.map { URLQueryItem(name: "arguments", value: $0) }
        }
        return components.url ?? URL(string: "prism://open")!
    }

    static func handle(_ url: URL) {
        guard url.scheme == scheme else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems ?? []
        switch url.host {
        case "commands":
            let encoded = String(url.path.dropFirst())
            let id = encoded.removingPercentEncoding ?? encoded
            let arguments = query.filter { $0.name == "arguments" }.compactMap(\.value)
            CommandRunner.run(id: id, arguments: arguments)
        case "open", nil:
            AppContext.launcher?.show(reset: true)
        case "search":
            guard let launcher = AppContext.launcher else { return }
            launcher.show(reset: true)
            launcher.model.query = query.first { $0.name == "q" }?.value ?? ""
        default:
            if !Features.handle(url: url) {
                HUD.shared.show("Lien inconnu : \(url.absoluteString)", symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    /// Branche les liens reçus par Launch Services (`open prism://…`).
    static func install() {
        NSAppleEventManager.shared().setEventHandler(
            DeeplinkReceiver.shared,
            andSelector: #selector(DeeplinkReceiver.handle(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }
}

final class DeeplinkReceiver: NSObject {
    static let shared = DeeplinkReceiver()

    @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text) else { return }
        MainActor.assumeIsolated { Deeplinks.handle(url) }
    }
}
