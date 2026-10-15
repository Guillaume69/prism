import AppKit

/// Les commandes qui vivent hors du lanceur, comme dans Raycast :
/// - « menu-bar » : un élément de la barre des menus de macOS, avec son menu, rafraîchi à son intervalle ;
/// - « no-view » avec un intervalle : relancée en arrière-plan quand l'utilisateur l'a activée.
/// Les commandes actives sont retenues et relancées à l'ouverture de Prism.
@MainActor
final class ExtensionBackground: NSObject, NSMenuDelegate {
    static let shared = ExtensionBackground()

    private static let storeKey = "extensions.background"

    private final class Entry {
        let key: String
        var session: ExtensionSession?
        var statusItem: NSStatusItem?
        var timer: Timer?
        var view: ExtensionNode?
        var startedAt = Date.distantPast

        init(key: String) { self.key = key }
    }

    private var entries: [String: Entry] = [:]
    private var actions: [ObjectIdentifier: () -> Void] = [:]

    private var stored: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.storeKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.storeKey) }
    }

    static func key(_ installed: InstalledExtension, _ command: ExtensionManifest.Command) -> String {
        "\(installed.id)/\(command.name)"
    }

    func isActive(_ installed: InstalledExtension, _ command: ExtensionManifest.Command) -> Bool {
        entries[Self.key(installed, command)] != nil
    }

    /// Au lancement de Prism : les commandes activées la dernière fois.
    func restore() {
        for key in stored {
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let installed = ExtensionRegistry.shared.find(parts[0]),
                  let command = installed.manifest.commands.first(where: { $0.name == parts[1] }) else { continue }
            activate(installed, command, remember: false)
        }
    }

    func toggle(_ installed: InstalledExtension, _ command: ExtensionManifest.Command) -> ActionOutcome {
        if isActive(installed, command) {
            deactivate(Self.key(installed, command))
            return .hud(command.mode == "menu-bar" ? "Retiré de la barre des menus" : "Rafraîchissement en arrière-plan désactivé")
        }
        activate(installed, command, remember: true)
        return .hud(command.mode == "menu-bar" ? "« \(command.title) » ajouté à la barre des menus" : "« \(command.title) » tourne en arrière-plan")
    }

    func activate(_ installed: InstalledExtension, _ command: ExtensionManifest.Command, remember: Bool) {
        let key = Self.key(installed, command)
        guard entries[key] == nil else { return }
        let entry = Entry(key: key)
        entries[key] = entry
        if remember, !stored.contains(key) { stored.append(key) }
        if command.mode == "menu-bar" {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = command.title
            item.button?.imagePosition = .imageLeading
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            entry.statusItem = item
        }
        run(entry, installed, command, launchType: "background")
        if let interval = command.interval {
            entry.timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let entry = self.entries[key] else { return }
                    self.run(entry, installed, command, launchType: "background")
                }
            }
        }
    }

    func deactivate(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.timer?.invalidate()
        entry.session?.terminate()
        if let item = entry.statusItem { NSStatusBar.system.removeStatusItem(item) }
        stored.removeAll { $0 == key }
    }

    /// Retire les commandes d'une extension désinstallée.
    func removeAll(for installed: InstalledExtension) {
        for key in entries.keys where key.hasPrefix(installed.id + "/") { deactivate(key) }
        stored.removeAll { $0.hasPrefix(installed.id + "/") }
    }

    /// (Re)lance la commande. Un menu garde son processus, comme Raycast tant que la commande charge ; les commandes
    /// sans vue s'arrêtent d'elles-mêmes.
    private func run(_ entry: Entry, _ installed: InstalledExtension, _ command: ExtensionManifest.Command, launchType: String) {
        guard ExtensionPreferences.shared.missing(for: installed, command: command).isEmpty else {
            entry.statusItem?.button?.title = "⚠︎ \(command.title)"
            entry.statusItem?.button?.toolTip = "Préférences obligatoires à remplir"
            return
        }
        entry.session?.terminate()
        let session = ExtensionSession(installed: installed, command: command)
        let key = entry.key
        session.onRender = { [weak self] view, _ in
            guard let self, let entry = self.entries[key] else { return }
            entry.view = view
            self.update(entry, installed: installed)
        }
        session.onError = { message, _ in
            ExtensionSession.logFile(for: installed).appendLine("[prism] erreur en arrière-plan : \(message)")
        }
        entry.session = session
        entry.startedAt = Date()
        do {
            try session.start(launchType: launchType)
        } catch {
            entry.statusItem?.button?.title = "⚠︎ \(command.title)"
            entry.statusItem?.button?.toolTip = error.localizedDescription
        }
    }

    /// Pour le pont d'essai : chaque commande active, son titre affiché, sa visibilité et ses éléments de menu.
    var debugEntries: [String] {
        entries.values.map { entry in
            let button = entry.statusItem?.button
            let items = entry.view.map { $0.all("menubar-item").count } ?? -1
            let frame = button?.window?.frame ?? .zero
            var menu = ""
            if let built = entry.statusItem?.menu {
                menuNeedsUpdate(built)
                menu = built.items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: " / ")
            }
            return "\(entry.key) | titre « \(button?.title ?? "") » | image \(button?.image != nil) | visible \(entry.statusItem?.isVisible ?? false) | éléments \(items) | cadre \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height)) | menu : \(menu)"
        }
    }

    // MARK: - Barre des menus

    private func update(_ entry: Entry, installed: InstalledExtension) {
        guard let item = entry.statusItem, let view = entry.view, view.type == "menubar" else { return }
        let title = view.string("title") ?? ""
        item.button?.title = title
        item.button?.toolTip = view.string("tooltip")
        item.button?.image = Self.image(view["icon"], installed: installed, size: 16)
        if item.button?.image == nil, title.isEmpty { item.button?.title = installed.title }
        item.isVisible = true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let (entry, installed) = entries.values.lazy.compactMap({ entry -> (Entry, InstalledExtension)? in
            guard entry.statusItem?.menu === menu, let session = entry.session else { return nil }
            return (entry, session.installed)
        }).first else { return }
        menu.removeAllItems()
        actions.removeAll()
        if let view = entry.view {
            fill(menu, with: view, entry: entry, installed: installed)
            if view.bool("isLoading") == true, menu.items.isEmpty {
                menu.addItem(withTitle: "Chargement…", action: nil, keyEquivalent: "").isEnabled = false
            }
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let session = entry.session
        addAction(menu, title: "Rafraîchir") { [weak self] in
            guard let self, let command = session?.command else { return }
            self.run(entry, installed, command, launchType: "userInitiated")
        }
        addAction(menu, title: "Préférences…") {
            guard let command = session?.command else { return }
            CommandRunner.present(.push(ExtensionsFeature.preferencesForm(installed, command: command)))
        }
        addAction(menu, title: "Retirer de la barre des menus") { [weak self] in
            self?.deactivate(entry.key)
        }
    }

    private func fill(_ menu: NSMenu, with node: ExtensionNode, entry: Entry, installed: InstalledExtension) {
        for child in node.children {
            switch child.type {
            case "menubar-item":
                let title = child.string("title") ?? ""
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                if let subtitle = child.string("subtitle"), !subtitle.isEmpty {
                    let text = NSMutableAttributedString(string: title)
                    text.append(NSAttributedString(string: "  " + subtitle, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
                    item.attributedTitle = text
                }
                item.image = Self.image(child["icon"], installed: installed, size: 16)
                item.toolTip = child.string("tooltip")
                if let handler = child.handler("onAction"), let session = entry.session {
                    register(item) { session.call(handler, [["type": "left-click"]]) }
                } else {
                    item.isEnabled = false
                }
                menu.addItem(item)
            case "menubar-section":
                if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
                if let title = child.string("title") {
                    let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    header.isEnabled = false
                    menu.addItem(header)
                }
                fill(menu, with: child, entry: entry, installed: installed)
            case "menubar-submenu":
                let item = NSMenuItem(title: child.string("title") ?? "", action: nil, keyEquivalent: "")
                item.image = Self.image(child["icon"], installed: installed, size: 16)
                let submenu = NSMenu()
                fill(submenu, with: child, entry: entry, installed: installed)
                item.submenu = submenu
                menu.addItem(item)
            default:
                fill(menu, with: child, entry: entry, installed: installed)
            }
        }
    }

    private func addAction(_ menu: NSMenu, title: String, _ action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        register(item, action)
        menu.addItem(item)
    }

    private func register(_ item: NSMenuItem, _ action: @escaping () -> Void) {
        item.target = self
        item.action = #selector(runMenuAction(_:))
        actions[ObjectIdentifier(item)] = action
    }

    @objc private func runMenuAction(_ sender: NSMenuItem) {
        actions[ObjectIdentifier(sender)]?()
    }

    /// Une icône d'extension en image de menu : symbole (modèle, teinté par le système), fichier ou ressource.
    static func image(_ value: Any?, installed: InstalledExtension, size: CGFloat) -> NSImage? {
        guard value != nil else { return nil }
        let image: NSImage?
        switch ExtensionIcon.icon(value, assets: installed.assets, fallback: .none) {
        case .glyph(let name), .tinted(let name, _), .symbol(let name, _):
            image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            image?.isTemplate = true
        case .image(let picture):
            image = picture.copy() as? NSImage
        case .file(let path):
            image = NSWorkspace.shared.icon(forFile: path)
        default:
            image = nil
        }
        image?.size = NSSize(width: size, height: size)
        return image
    }
}

extension URL {
    /// Ajoute une ligne à un fichier texte (journaux).
    func appendLine(_ line: String) {
        guard let file = try? FileHandle(forWritingTo: self) else { return }
        file.seekToEndOfFile()
        file.write(Data((line + "\n").utf8))
        try? file.close()
    }
}
