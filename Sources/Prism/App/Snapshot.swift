import AppKit
import SwiftUI

/// Rendu hors écran du lanceur en PNG, pour vérifier le design sans autorisation d'enregistrement de l'écran :
/// `Prism --snapshot sortie.png [--mode <commande>] [--query texte] [--light] [--actions] [--down N]`,
/// `Prism --snapshot reglages.png --settings [--pane <onglet>]`.
@MainActor
enum Snapshot {
    static func run(arguments: [String]) -> Int32 {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let output = value("--snapshot") else { return 1 }
        let dark = !arguments.contains("--light")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        AppCatalog.shared.loadSynchronously()

        if arguments.contains("--settings") {
            if let pane = value("--pane") { SettingsNavigation.shared.selection = pane }
            return render(NSHostingView(rootView: SettingsView { true }), size: NSSize(width: 880, height: 640), to: output, dark: dark)
        }

        let model = LauncherModel()
        model.prepareForShow(reset: true)
        let query = value("--query") ?? ""
        // `--mode <id>` ouvre la commande « command:<id> » comme si on l'avait lancée.
        if let mode = value("--mode"), let item = RootScreen.candidates().first(where: { $0.id == "command:" + mode }) {
            if let form = ArgumentsForm.screen(for: item), !item.arguments.isEmpty {
                model.push(form)
            } else if let action = item.actions.first {
                model.apply(action.run())
            }
            if !query.isEmpty { model.query = query }
        } else {
            model.query = query
        }
        RunLoop.main.run(until: Date().addingTimeInterval(Double(value("--wait") ?? "") ?? (value("--mode") == "files" ? 2.0 : 0.4)))
        if let down = value("--down").flatMap(Int.init) {
            for _ in 0..<down { model.moveSelection(1) }
        }
        if arguments.contains("--actions") { model.toggleActionPanel() }

        let margin: CGFloat = 60
        let size = NSSize(width: LauncherLayout.width + margin * 2, height: LauncherLayout.height + margin * 2)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        let wallpaper = CAGradientLayer()
        wallpaper.frame = container.bounds
        wallpaper.colors = dark
            ? [NSColor(srgbRed: 0.16, green: 0.20, blue: 0.33, alpha: 1).cgColor, NSColor(srgbRed: 0.36, green: 0.18, blue: 0.30, alpha: 1).cgColor]
            : [NSColor(srgbRed: 0.62, green: 0.74, blue: 0.92, alpha: 1).cgColor, NSColor(srgbRed: 0.93, green: 0.78, blue: 0.84, alpha: 1).cgColor]
        wallpaper.startPoint = CGPoint(x: 0, y: 1)
        wallpaper.endPoint = CGPoint(x: 1, y: 0)
        container.layer?.addSublayer(wallpaper)

        // Le flou de NSVisualEffectView ne se capture pas : un voile uni le remplace.
        let veil = NSView(frame: NSRect(x: margin, y: margin, width: LauncherLayout.width, height: LauncherLayout.height))
        veil.wantsLayer = true
        veil.layer?.cornerRadius = LauncherLayout.cornerRadius
        veil.layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 0.85) : NSColor(white: 0.95, alpha: 0.85)).cgColor
        container.addSubview(veil)

        let hosting = NSHostingView(rootView: LauncherView(model: model) { _ in })
        hosting.frame = veil.frame
        container.addSubview(hosting)
        window.contentView = container
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        guard let bitmap = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return 1 }
        container.cacheDisplay(in: container.bounds, to: bitmap)
        do {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        } catch {
            print("Écriture impossible : \(error)")
            return 1
        }
        print("✓ \(output)")
        return 0
    }

    private static func render(_ view: NSView, size: NSSize, to output: String, dark: Bool) -> Int32 {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 1 }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        print("✓ \(output)")
        return 0
    }
}
