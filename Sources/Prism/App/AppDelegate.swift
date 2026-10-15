import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    nonisolated static let toggleNotification = Notification.Name("app.prism.launcher.toggle")

    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var settingsWindow: NSWindow?
    private lazy var launcher = LauncherPanelController(model: LauncherModel())

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            // Une seule instance : on demande à celle qui tourne de s'ouvrir.
            DistributedNotificationCenter.default().postNotificationName(Self.toggleNotification, object: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        Deeplinks.install()
        AppContext.launcher = launcher
        updateStatusItem()
        AppCatalog.shared.reload()
        registerHotKey()
        Features.startAll()
        CommandConfigStore.shared.registerHotkeys()

        let center = NotificationCenter.default
        center.addObserver(forName: .prismHotKeyChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotKey() }
        }
        center.addObserver(forName: .prismOpenSettings, object: nil, queue: .main) { [weak self] notification in
            let pane = notification.object as? String
            MainActor.assumeIsolated {
                if let pane { SettingsNavigation.shared.selection = pane }
                self?.openSettings()
            }
        }
        center.addObserver(forName: .prismMenuBarChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusItem() }
        }
        DistributedNotificationCenter.default().addObserver(forName: Self.toggleNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.launcher.toggle() }
        }

        DebugBridge.install(launcher: launcher)

        if !Preferences.shared.hasLaunchedBefore {
            Preferences.shared.hasLaunchedBefore = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.launcher.show()
                HUD.shared.show("Prism est prêt : \(Preferences.shared.launcherHotkey.label) pour l’ouvrir", symbol: "sparkles")
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launcher.show()
        return false
    }

    // MARK: - Raccourci global

    private func registerHotKey() {
        hotKey = nil
        let hotkey = Preferences.shared.launcherHotkey
        var taps = ModifierTap.shared.handlers
        if LauncherTap.key != 0 { taps[LauncherTap.key] = nil }
        if let modifier = hotkey.tapModifier {
            // Double appui (⌘⌘…) : reconnu par le moniteur d'évènements, accessibilité requise.
            LauncherTap.key = ModifierTap.code(modifier)
            taps[LauncherTap.key] = { [weak self] in self?.launcher.toggle() }
            ModifierTap.shared.handlers = taps
            AppContext.hotKeyRegistered = Paster.isTrusted
            AppContext.simulateHotKey = { [weak self] in self?.launcher.toggle(); return 0 }
        } else {
            LauncherTap.key = 0
            ModifierTap.shared.handlers = taps
            hotKey = HotKey(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers) { [weak self] in
                MainActor.assumeIsolated {
                    guard !GameMode.isSuspended else { return }
                    self?.launcher.toggle()
                }
            }
            AppContext.hotKeyRegistered = hotKey?.isRegistered ?? false
            AppContext.simulateHotKey = { [weak self] in self?.hotKey?.simulatePress() ?? -1 }
        }
        statusItem?.menu?.item(withTag: 1)?.title = "Ouvrir Prism (\(hotkey.label))"
    }

    // MARK: - Barre des menus

    private func updateStatusItem() {
        if Preferences.shared.showMenuBarIcon {
            if statusItem == nil { installStatusItem() }
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = IconRenderer.menuBarImage()
        item.button?.toolTip = "Prism"

        let menu = NSMenu()
        let open = NSMenuItem(title: "Ouvrir Prism (\(Preferences.shared.launcherHotkey.label))", action: #selector(openLauncher), keyEquivalent: "")
        open.tag = 1
        open.target = self
        menu.addItem(open)
        let clipboard = NSMenuItem(title: "Historique du presse-papiers", action: #selector(openClipboard), keyEquivalent: "")
        clipboard.target = self
        menu.addItem(clipboard)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Réglages…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quitter Prism", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func openLauncher() {
        launcher.show()
    }

    @objc private func openClipboard() {
        launcher.show(reset: true)
        launcher.model.push(ClipboardFeature.screen())
    }

    @objc private func openSettingsFromMenu() {
        openSettings()
    }

    // MARK: - Réglages

    func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
                styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Réglages de Prism"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView { [weak self] in
                self?.hotKey?.isRegistered ?? false
            })
            window.center()
            window.delegate = self
            settingsWindow = window
            // Échap ferme les réglages, comme dans Raycast (hors édition d'un champ).
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
                guard event.keyCode == 53, let window, event.window === window,
                      !(window.firstResponder is NSTextView) else { return event }
                window.performClose(nil)
                return nil
            }
        }
        // L'activation est coopérative depuis macOS 14 : on la demande tant que le lanceur
        // détient encore l'interaction, et on ne le masque qu'ensuite.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
        launcher.hide()
    }

    /// Réglages fermés : Prism redevient discret et rend la main à l'application d'avant.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        DispatchQueue.main.async { NSApp.hide(nil) }
    }

    // MARK: - Menu principal

    /// Sans menu Édition, ⌘C, ⌘V et ⌘A ne marchent pas dans les champs des réglages.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Réglages…", action: #selector(openSettingsFromMenu), keyEquivalent: ","))
        appMenu.items.last?.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quitter Prism", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Édition")
        editMenu.addItem(NSMenuItem(title: "Annuler", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Rétablir", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Fenêtre")
        windowMenu.addItem(NSMenuItem(title: "Fermer", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}
