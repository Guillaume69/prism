import AppKit
import Combine
import SwiftUI

/// Fenêtre flottante sans bordure qui prend le clavier sans activer l'application,
/// pour que l'app de premier plan le reste (coller, ranger les fenêtres).
final class LauncherPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class LauncherPanelController: NSObject, NSWindowDelegate {
    let model: LauncherModel
    private let panel: LauncherPanel
    private let effect = NSVisualEffectView()
    private var keyMonitor: Any?
    private weak var searchField: NSTextField?
    private var lastHidden = Date.distantPast
    private var hideGeneration = 0
    private var subscriptions: Set<AnyCancellable> = []
    /// Garde le lanceur ouvert quand une autre fenêtre de Prism passe devant (aperçu, menu).
    var keepOpenOnResign = false

    var isVisible: Bool { panel.isVisible && panel.alphaValue > 0 }
    var window: NSWindow { panel }

    init(model: LauncherModel) {
        self.model = model
        panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: LauncherLayout.width, height: LauncherLayout.height))
        super.init()
        panel.delegate = self

        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: LauncherLayout.cornerRadius)

        let root = ScaledLauncherView(model: model) { [weak self] field in
            self?.searchField = field
        }
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        applyTheme()

        model.onClose = { [weak self] in self?.hide() }
        model.focusSearch = { [weak self] in self?.focusSearchField() }
        model.moveCaretToEnd = { [weak self] in
            DispatchQueue.main.async {
                guard let field = self?.searchField, let editor = field.currentEditor() else { return }
                editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
            }
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.panel else { return event }
                return self.handleKey(event) ? nil : event
            }
        }

        // Le mode compact change la hauteur de la fenêtre au fil de la saisie.
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateHeight(animated: true) } }
            .store(in: &subscriptions)
        NotificationCenter.default.addObserver(forName: .prismThemeDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        }
        AppContext.launcher = self
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show(reset forceReset: Bool = false) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            AppContext.previousApp = frontmost
        }
        hideGeneration += 1
        let wasVisible = isVisible
        model.prepareForShow(reset: forceReset || Date().timeIntervalSince(lastHidden) > Preferences.shared.resetDelay)
        if !wasVisible {
            applyTheme()
            updateHeight(animated: false)
            position()
            panel.alphaValue = 0
        }
        panel.makeKeyAndOrderFront(nil)
        focusSearchField()
        if !wasVisible { InputSourceSwitcher.activate(Preferences.shared.inputSource) }
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        panel.invalidateShadow()
    }

    func hide() {
        guard panel.isVisible else { return }
        InputSourceSwitcher.restore()
        if !model.query.trimmingCharacters(in: .whitespaces).isEmpty, model.isRoot {
            var history = Preferences.shared.searchHistory
            history.removeAll { $0 == model.query }
            history.insert(model.query, at: 0)
            Preferences.shared.searchHistory = history
        }
        lastHidden = Date()
        NotificationCenter.default.post(name: .prismLauncherDidHide, object: nil)
        model.closeActionPanel()
        hideGeneration += 1
        let generation = hideGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.09
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hideGeneration == generation else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !keepOpenOnResign else { return }
        hide()
    }

    private func focusSearchField() {
        guard let searchField else { return }
        if model.screen.hidesSearchField { return }
        panel.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    private func applyTheme() {
        updateHeight(animated: false)
        let theme = ThemeStore.shared.current
        panel.appearance = Theme.appearance
        effect.material = theme.background == nil ? .popover : .hudWindow
    }

    /// Hauteur de la fenêtre : la barre seule en mode compact, la fenêtre entière sinon. Le haut ne bouge pas.
    /// Hauteur de la fenêtre : la barre seule en mode compact, la fenêtre entière sinon. Le haut ne bouge pas.
    /// La taille de l'interface agrandit la fenêtre ; son contenu garde ses dimensions de base,
    /// agrandies par SwiftUI (`ScaledLauncherView`).
    private func updateHeight(animated: Bool) {
        let scale = CGFloat(Preferences.shared.interfaceScale)
        let baseHeight = model.isCompact ? LauncherLayout.searchHeight + (model.compactFavorites.isEmpty ? 0 : 62) : LauncherLayout.height
        let size = NSSize(width: LauncherLayout.width * scale, height: baseHeight * scale)
        if abs(panel.frame.height - size.height) > 0.5 || abs(panel.frame.width - size.width) > 0.5 {
            var frame = panel.frame
            frame.origin.y += frame.height - size.height
            frame.origin.x += (frame.width - size.width) / 2
            frame.size = size
            panel.setFrame(frame, display: true, animate: false)
            panel.invalidateShadow()
        }
    }

    /// Le contenu réel de la fenêtre en PNG (pont de débogage) : vérifie la mise en page, taille comprise.
    func renderPanel(to path: String) {
        guard let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Centré horizontalement, dans le tiers haut de l'écran où se trouve la souris.
    private func position() {
        let screen: NSScreen?
        switch Preferences.shared.showOnScreen {
        case "main":
            screen = NSScreen.screens.first
        case "window":
            // L'écran de la fenêtre active (liste des fenêtres, sans autorisation).
            let pid = AppContext.previousApp?.processIdentifier
            let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
            let frontWindow = windows.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            if let bounds = frontWindow?[kCGWindowBounds as String] as? [String: CGFloat], let primary = NSScreen.screens.first {
                let center = CGPoint(x: (bounds["X"] ?? 0) + (bounds["Width"] ?? 0) / 2, y: primary.frame.height - (bounds["Y"] ?? 0) - (bounds["Height"] ?? 0) / 2)
                screen = NSScreen.screens.first { NSPointInRect(center, $0.frame) } ?? NSScreen.main
            } else {
                screen = NSScreen.main
            }
        default:
            let mouse = NSEvent.mouseLocation
            screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        }
        guard let area = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let top = area.maxY - area.height * 0.18
        panel.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(), y: (top - size.height).rounded()))
    }

    // MARK: - Clavier

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

        // Panneau d'actions ouvert : la frappe filtre les actions.
        if model.isActionPanelOpen {
            switch event.keyCode {
            case 53: model.closeActionPanel(); return true
            case 126: model.moveSelection(-1); return true
            case 125: model.moveSelection(1); return true
            case 36, 76: model.activate(); return true
            case 51: model.deleteInActionPanel(); return true
            case 40 where modifiers == .command: model.toggleActionPanel(); return true
            default:
                if modifiers.isDisjoint(with: [.command, .control]), let characters = event.characters, !characters.isEmpty,
                   characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                    model.typeInActionPanel(characters)
                    return true
                }
                return model.performShortcut(keyCode: event.keyCode, modifiers: modifiers)
            }
        }

        if model.screen.handleKey(event, modifiers: modifiers) { return true }

        // Formulaires et vues propres : seules Échap, ⌘K, ⌘W et ⌘, restent au lanceur.
        if model.screen.customViewHandlesNavigation {
            switch (event.keyCode, modifiers) {
            case (53, _): model.escape(); return true
            case (40, .command): model.toggleActionPanel(); return true
            case (13, .command): hide(); return true
            case (43, .command): NotificationCenter.default.post(name: .prismOpenSettings, object: nil); return true
            default: return model.performShortcut(keyCode: event.keyCode, modifiers: modifiers)
            }
        }

        switch event.keyCode {
        case 53 where modifiers == .command: // ⌘Échap : retour à la recherche principale
            model.popToRoot(clearQuery: true)
            return true
        case 53: // Échap
            model.escape()
            return true
        case 126 where modifiers == .command, 125 where modifiers == .command: // ⌘↑ ⌘↓ : section précédente ou suivante
            model.jumpSection(event.keyCode == 126 ? -1 : 1)
            return true
        case 126 where modifiers == .option, 125 where modifiers == .option: // ⌥↑ ⌥↓ : page précédente ou suivante
            model.step(event.keyCode == 126 ? -8 : 8)
            return true
        case 126: // ↑ (sur une recherche vide, en haut : historique des recherches)
            if model.isRoot, model.query.isEmpty, model.selectedID == model.allItems.first?.id, model.recallSearchHistory() { return true }
            model.moveSelection(-1)
            return true
        case 125: // ↓
            model.moveSelection(1)
            return true
        case 123, 124: // ← →
            if modifiers.isEmpty, model.isGridSelection {
                model.step(event.keyCode == 123 ? -1 : 1)
                return true
            }
            return false
        case 36, 76: // Entrée
            if modifiers == .command {
                model.activateSecondary()
            } else if modifiers.isEmpty {
                model.activate()
            } else {
                return model.performShortcut(keyCode: event.keyCode, modifiers: modifiers)
            }
            return true
        case 48: // Tab : les champs d'arguments de la commande, sinon descend dans la liste
            if model.showsInlineArguments {
                model.focusNextArgument(backwards: modifiers == .shift)
            } else {
                model.moveSelection(modifiers == .shift ? -1 : 1)
            }
            return true
        case 51 where modifiers.isEmpty && model.query.isEmpty && !model.isRoot: // ⌫ sur un champ vide
            model.pop()
            return true
        default:
            break
        }

        if modifiers == .control {
            if Preferences.shared.navigationBindings == "vim" {
                if event.keyCode == 38 { model.moveSelection(1); return true }  // ⌃J
                if event.keyCode == 40 { model.moveSelection(-1); return true } // ⌃K
            } else {
                if event.keyCode == 45 { model.moveSelection(1); return true }  // ⌃N
                if event.keyCode == 35 { model.moveSelection(-1); return true } // ⌃P
            }
        }
        // ⌥↵ : l'action tertiaire.
        if modifiers == .option, event.keyCode == 36 || event.keyCode == 76 {
            model.activateTertiary()
            return true
        }

        if modifiers == .command {
            switch event.keyCode {
            case 40: // ⌘K
                model.toggleActionPanel()
                return true
            case 35 where model.screen.filter != nil: // ⌘P
                model.cycleFilter()
                return true
            case 43: // ⌘,
                NotificationCenter.default.post(name: .prismOpenSettings, object: nil)
                return true
            case 13: // ⌘W
                hide()
                return true
            case 18...26 where model.isRoot: // ⌘1 à ⌘9 : favoris
                if model.performShortcut(keyCode: event.keyCode, modifiers: modifiers) { return true }
                let index = [18, 19, 20, 21, 23, 22, 26, 28, 25].firstIndex(of: Int(event.keyCode)) ?? 0
                let favorites = model.sections.first { $0.id == "favorites" }?.items ?? []
                if favorites.indices.contains(index) {
                    model.select(favorites[index].id)
                    model.activate()
                    return true
                }
                return false
            case 0: return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            case 8 where model.performShortcut(keyCode: 8, modifiers: modifiers): return true
            case 8: return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            case 9: return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            case 7: return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
            case 6: return NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
            default: break
            }
        }
        if modifiers == [.command, .shift], event.keyCode == 6 {
            return NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        }
        if modifiers == [.command, .shift], event.keyCode == 35, model.screen.filter != nil {
            model.cycleFilter(-1)
            return true
        }

        return model.performShortcut(keyCode: event.keyCode, modifiers: modifiers)
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}


import Carbon.HIToolbox

/// Change de source de saisie à l'ouverture du lanceur et remet la précédente à la fermeture.
@MainActor
enum InputSourceSwitcher {
    private static var previous: TISInputSource?

    /// Les dispositions de clavier activées : (identifiant, nom).
    static var available: [(id: String, name: String)] {
        let filter = [kTISPropertyInputSourceIsSelectCapable as String: true, kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return list.compactMap { source in
            guard let id = property(source, kTISPropertyInputSourceID), let name = property(source, kTISPropertyLocalizedName) else { return nil }
            return (id, name)
        }
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    static func activate(_ id: String) {
        guard !id.isEmpty else { return }
        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        guard let current, property(current, kTISPropertyInputSourceID) != id else { return }
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let target = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource])?.first else { return }
        previous = current
        TISSelectInputSource(target)
    }

    static func restore() {
        guard let previous else { return }
        TISSelectInputSource(previous)
        self.previous = nil
    }
}


/// Le lanceur à la taille d'interface choisie : mis en page à sa taille de base, puis agrandi.
struct ScaledLauncherView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject private var preferences = Preferences.shared
    let onSearchFieldCreated: (NSTextField) -> Void

    var body: some View {
        let scale = CGFloat(preferences.interfaceScale)
        GeometryReader { proxy in
            LauncherView(model: model, onSearchFieldCreated: onSearchFieldCreated)
                .frame(width: proxy.size.width / scale, height: proxy.size.height / scale)
                .scaleEffect(scale, anchor: .topLeading)
        }
    }
}
