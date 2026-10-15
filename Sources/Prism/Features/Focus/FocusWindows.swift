import AppKit
import SwiftUI

// Ce que la concentration affiche hors du lanceur : la barre flottante ou l'élément de la barre des menus,
// le halo sur les bords de l'écran, les notifications avec boutons, la page de blocage des sites.

// MARK: - Barre de concentration et barre des menus

/// Montre la session : barre flottante en pilule, ou élément de la barre des menus (réglage).
@MainActor
final class FocusPresenter: NSObject, NSMenuDelegate {
    static let shared = FocusPresenter()

    private var panel: NSPanel?
    private var statusItem: NSStatusItem?
    private var dragOrigin: (mouse: NSPoint, frame: NSPoint)?

    /// Barre ou barre des menus selon la session et le réglage.
    func update() {
        let manager = FocusManager.shared
        guard !manager.isSimulation, manager.session != nil else {
            hidePanel()
            removeStatusItem()
            return
        }
        if FocusSettings.shared.showInMenuBar {
            hidePanel()
            installStatusItem()
            refreshStatusItem()
        } else {
            removeStatusItem()
            showPanel()
        }
    }

    /// Chaque seconde : le titre de la barre des menus (la barre flottante observe le modèle).
    func tick() {
        refreshStatusItem()
    }

    // MARK: Barre flottante

    private func showPanel() {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        if !panel.isVisible {
            panel.setFrameOrigin(savedOrigin(for: panel.frame.size))
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 1
            }
        }
    }

    private func hidePanel() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(rootView: FocusBarHost())
        let size = NSSize(width: FocusBarView.width + 24, height: FocusBarView.height + 24)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        return panel
    }

    /// Position enregistrée, sinon en haut au centre de l'écran principal.
    private func savedOrigin(for size: NSSize) -> NSPoint {
        if let text = UserDefaults.standard.string(forKey: "focus.barOrigin") {
            let point = NSPointFromString(text)
            if NSScreen.screens.contains(where: { $0.frame.intersects(NSRect(origin: point, size: size)) }) { return point }
        }
        let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - 6)
    }

    /// Glisser la barre : appelé par le geste de la vue, en coordonnées de l'écran.
    func dragChanged() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragOrigin == nil { dragOrigin = (mouse, panel.frame.origin) }
        guard let origin = dragOrigin else { return }
        panel.setFrameOrigin(NSPoint(x: origin.frame.x + mouse.x - origin.mouse.x, y: origin.frame.y + mouse.y - origin.mouse.y))
    }

    func dragEnded() {
        dragOrigin = nil
        if let panel { UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "focus.barOrigin") }
    }

    // MARK: Barre des menus

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "scope", accessibilityDescription: "Concentration")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button, let session = FocusManager.shared.session else { return }
        let now = Date()
        let text: String
        if session.isPaused {
            text = "En pause"
        } else {
            text = FocusFormat.clock(session.remaining(at: now) ?? session.elapsed(at: now))
        }
        button.attributedTitle = NSAttributedString(string: " " + text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
        ])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let manager = FocusManager.shared
        guard let session = manager.session else { return }
        let now = Date()
        let header = NSMenuItem(title: session.goal.isEmpty ? "Session de concentration" : session.goal, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let status = NSMenuItem(title: manager.statusText(for: session, at: now), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        if session.isPaused {
            menu.addItem(item("Reprendre", "play.fill") { FocusManager.shared.resume() })
        } else {
            let pause = NSMenuItem(title: "Faire une pause", action: nil, keyEquivalent: "")
            pause.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)
            let submenu = NSMenu()
            for minutes in [5, 10, 15] {
                submenu.addItem(item("\(minutes) minutes", nil) { FocusManager.shared.pause(minutes: minutes) })
            }
            submenu.addItem(item("Jusqu’à la reprise", nil) { FocusManager.shared.pause(minutes: nil) })
            pause.submenu = submenu
            menu.addItem(pause)
        }
        if !session.isUnlimited {
            menu.addItem(item("Ajouter 5 minutes", "plus") { FocusManager.shared.extend(minutes: 5) })
            menu.addItem(item("Ajouter 15 minutes", "plus") { FocusManager.shared.extend(minutes: 15) })
        }
        if FocusSettings.shared.snoozeMinutes > 0, !session.isPaused {
            menu.addItem(item("Reporter le blocage (\(FocusSettings.shared.snoozeMinutes) min)", "clock.arrow.circlepath") { FocusManager.shared.snooze() })
        }
        menu.addItem(.separator())
        menu.addItem(item("Modifier la session…", "slider.horizontal.3") { FocusFeature.openInLauncher(FocusFeature.editForm()) })
        menu.addItem(item("Afficher la barre de concentration", "capsule") { FocusSettings.shared.showInMenuBar = false })
        menu.addItem(.separator())
        menu.addItem(item("Terminer la session", "checkmark.circle") { FocusManager.shared.complete() })
        menu.addItem(item("Annuler la session", "xmark.circle") { FocusManager.shared.cancel() })
    }

    private func item(_ title: String, _ symbol: String?, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: action)
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }
}

/// Élément de menu qui exécute une fermeture.
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, action handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(runHandler), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) non pris en charge") }

    @objc private func runHandler() {
        MainActor.assumeIsolated { handler() }
    }
}

/// La barre, branchée sur le modèle en direct.
struct FocusBarHost: View {
    @ObservedObject private var manager = FocusManager.shared

    var body: some View {
        if let session = manager.session {
            FocusBarView(
                session: session,
                now: manager.now,
                isSnoozed: manager.isSnoozed,
                onDragChanged: { FocusPresenter.shared.dragChanged() },
                onDragEnded: { FocusPresenter.shared.dragEnded() }
            )
            .padding(12)
        }
    }
}

/// La barre de concentration : une pilule sombre avec l'objectif, le minuteur, pause et fin.
struct FocusBarView: View {
    static let width: CGFloat = 380
    static let height: CGFloat = 46

    let session: FocusSession
    let now: Date
    var isSnoozed = false
    var onDragChanged: () -> Void = {}
    var onDragEnded: () -> Void = {}

    private var tint: Color {
        if session.isPaused { return Palette.yellow }
        return isSnoozed ? Palette.gray : Palette.orange
    }

    private var subtitle: String {
        if session.isPaused {
            if let end = session.pauseEndsAt { return "En pause jusqu’à \(FocusFormat.time(end))" }
            return "En pause"
        }
        if isSnoozed { return "Blocage reporté" }
        if let end = session.endDate(at: now) { return "Fin à \(FocusFormat.time(end))" }
        return "Sans limite"
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                ring
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.goal.isEmpty ? "Concentration" : session.goal)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(FocusFormat.clock(session.remaining(at: now) ?? session.elapsed(at: now)))
                    .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(session.isPaused ? .white.opacity(0.5) : .white)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { _ in onDragChanged() }
                .onEnded { _ in onDragEnded() })

            HStack(spacing: 4) {
                FocusBarButton(symbol: session.isPaused ? "play.fill" : "pause.fill", help: session.isPaused ? "Reprendre" : "Pause de 5 minutes") {
                    if session.isPaused { FocusManager.shared.resume() } else { FocusManager.shared.pause(minutes: 5) }
                }
                FocusBarButton(symbol: "stop.fill", help: "Terminer la session") {
                    FocusManager.shared.complete()
                }
                Menu {
                    if !session.isUnlimited {
                        Button("Ajouter 5 minutes") { FocusManager.shared.extend(minutes: 5) }
                        Button("Ajouter 15 minutes") { FocusManager.shared.extend(minutes: 15) }
                    }
                    if !session.isPaused {
                        Menu("Faire une pause") {
                            ForEach([5, 10, 15], id: \.self) { minutes in
                                Button("\(minutes) minutes") { FocusManager.shared.pause(minutes: minutes) }
                            }
                            Button("Jusqu’à la reprise") { FocusManager.shared.pause(minutes: nil) }
                        }
                    }
                    if FocusSettings.shared.snoozeMinutes > 0, !session.isPaused {
                        Button("Reporter le blocage (\(FocusSettings.shared.snoozeMinutes) min)") { FocusManager.shared.snooze() }
                    }
                    Divider()
                    Button("Modifier la session…") { FocusFeature.openInLauncher(FocusFeature.editForm()) }
                    Button("Déplacer dans la barre des menus") { FocusSettings.shared.showInMenuBar = true }
                    Divider()
                    Button("Annuler la session") { FocusManager.shared.cancel() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Plus d’actions")
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 9)
        .frame(width: Self.width, height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: 999, style: .circular)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.10).opacity(0.94))
                .overlay(RoundedRectangle(cornerRadius: 999, style: .circular).inset(by: 0.5).stroke(Color.white.opacity(0.12), lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .environment(\.colorScheme, .dark)
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 3)
            if session.isUnlimited {
                Circle().stroke(tint, lineWidth: 3)
            } else {
                Circle()
                    .trim(from: 0, to: max(0.02, 1 - session.progress(at: now)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: session.isPaused ? "pause.fill" : "scope")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: 28, height: 28)
    }
}

private struct FocusBarButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.2 : 0.1)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Halo

/// Une lueur colorée sur les bords de chaque écran, qui s'estompe : orange au blocage, verte à la fin.
@MainActor
enum FocusHalo {
    private static var windows: [NSWindow] = []

    static func flash(tint: Color) {
        for window in windows { window.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.contentView = NSHostingView(rootView: FocusHaloView(tint: tint))
            window.setFrame(screen.frame, display: false)
            return window
        }
        let shown = windows
        for window in shown {
            window.alphaValue = 0
            window.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            for window in shown { window.animator().alphaValue = 1 }
        }, completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 1.3
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    for window in shown { window.animator().alphaValue = 0 }
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        for window in shown { window.orderOut(nil) }
                        windows.removeAll { shown.contains($0) }
                    }
                })
            }
        })
    }
}

/// Bords lumineux : un dégradé vers l'intérieur et un liseré net.
struct FocusHaloView: View {
    let tint: Color
    var depth: CGFloat = 90

    var body: some View {
        ZStack {
            edge(.top, .bottom)
            edge(.bottom, .top)
            edge(.leading, .trailing)
            edge(.trailing, .leading)
            Rectangle()
                .strokeBorder(tint.opacity(0.95), lineWidth: 3)
                .blur(radius: 2)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func edge(_ from: UnitPoint, _ to: UnitPoint) -> some View {
        let horizontal = from == .top || from == .bottom
        let alignment: Alignment = from == .top ? .top : from == .bottom ? .bottom : from == .leading ? .leading : .trailing
        return LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.18), .clear], startPoint: from, endPoint: to)
            .frame(width: horizontal ? nil : depth, height: horizontal ? depth : nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

// MARK: - Notifications

/// Une notification en bas de l'écran, avec des boutons (« Reporter 3 min », « +5 min ») : le HUD, en interactif.
@MainActor
final class FocusToast {
    static let shared = FocusToast()

    struct Button {
        let title: String
        let action: @MainActor () -> Void
    }

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(title: String, message: String, symbol: String, tint: Color, buttons: [Button], duration: TimeInterval) {
        guard !FocusManager.shared.isSimulation else { return }
        let view = FocusToastView(title: title, message: message, symbol: symbol, tint: tint, buttons: buttons.map { button in
            FocusToastView.Action(title: button.title) { [weak self] in
                self?.dismiss()
                button.action()
            }
        })
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = hosting
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.minY + area.height * 0.12, width: size.width, height: size.height), display: true)
        }
        hideWork?.cancel()
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func dismiss() {
        hideWork?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }
}

struct FocusToastView: View {
    struct Action: Identifiable {
        let id = UUID()
        let title: String
        let run: @MainActor () -> Void
    }

    let title: String
    let message: String
    let symbol: String
    let tint: Color
    let actions: [Action]

    init(title: String, message: String, symbol: String, tint: Color, buttons: [Action]) {
        self.title = title
        self.message = message
        self.symbol = symbol
        self.tint = tint
        actions = buttons
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(tint.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            ForEach(actions) { action in
                SwiftUI.Button(action: action.run) {
                    Text(action.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 999, style: .circular).fill(tint.opacity(0.35)))
                        .overlay(RoundedRectangle(cornerRadius: 999, style: .circular).inset(by: 0.5).stroke(tint.opacity(0.7), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, actions.isEmpty ? 16 : 7)
        .frame(height: 42)
        .background(
            RoundedRectangle(cornerRadius: 999, style: .circular)
                .fill(Color.black.opacity(0.85))
                .overlay(RoundedRectangle(cornerRadius: 999, style: .circular).inset(by: 0.5).stroke(tint.opacity(0.45), lineWidth: 1))
        )
        .shadow(color: tint.opacity(0.35), radius: 14, y: 2)
        .padding(16)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Page de blocage

/// La page locale qui remplace un site bloqué : `Application Support/Prism/Focus/blocked.html`.
/// Le site, l'objectif et l'heure de fin passent dans l'adresse ; la page décompte le temps elle-même.
@MainActor
enum FocusBlockedPage {
    static var fileURL: URL { StoreLocation.subdirectory("Focus").appendingPathComponent("blocked.html") }

    static func write() {
        guard !FocusManager.shared.isSimulation else { return }
        let url = fileURL
        if (try? String(contentsOf: url, encoding: .utf8)) == html { return }
        try? html.write(to: url, atomically: true, encoding: .utf8)
    }

    static func url(site: String, session: FocusSession?, now: Date) -> URL {
        write()
        var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "site", value: site)]
        if let session {
            if !session.goal.isEmpty { items.append(URLQueryItem(name: "goal", value: session.goal)) }
            if let end = session.endDate(at: now), !session.isPaused {
                items.append(URLQueryItem(name: "end", value: String(Int(end.timeIntervalSince1970 * 1000))))
            }
        }
        components?.queryItems = items
        return components?.url ?? fileURL
    }

    static let html = """
    <!doctype html>
    <html lang="fr">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Bloqué pendant la concentration</title>
    <style>
      :root { color-scheme: dark; --orange: #ff9440; }
      * { box-sizing: border-box; margin: 0; }
      body {
        min-height: 100vh; display: grid; place-items: center; padding: 32px;
        font: 15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
        color: #f2f2f4;
        background:
          radial-gradient(1200px 600px at 50% -10%, rgba(255,148,64,.22), transparent 60%),
          radial-gradient(900px 500px at 100% 110%, rgba(102,107,242,.18), transparent 60%),
          #111113;
      }
      main { width: min(520px, 100%); text-align: center; }
      .ring {
        width: 92px; height: 92px; margin: 0 auto 28px; border-radius: 50%;
        display: grid; place-items: center;
        background: radial-gradient(circle, rgba(255,148,64,.25), rgba(255,148,64,.05) 70%);
        box-shadow: 0 0 0 1px rgba(255,148,64,.45), 0 0 60px rgba(255,148,64,.35);
      }
      .ring svg { width: 40px; height: 40px; }
      h1 { font-size: 28px; font-weight: 700; letter-spacing: -.02em; }
      .site { margin-top: 6px; color: rgba(242,242,244,.55); font-size: 15px; }
      .site b { color: var(--orange); font-weight: 600; }
      .card {
        margin-top: 32px; padding: 20px 22px; border-radius: 16px; text-align: left;
        background: rgba(255,255,255,.05); border: 1px solid rgba(255,255,255,.09);
      }
      .label { font-size: 11px; font-weight: 600; letter-spacing: .08em; text-transform: uppercase; color: rgba(242,242,244,.45); }
      .goal { margin-top: 4px; font-size: 18px; font-weight: 600; }
      .timer { margin-top: 18px; display: flex; align-items: baseline; justify-content: space-between; gap: 12px; }
      .clock { font: 600 34px/1 ui-rounded, -apple-system, sans-serif; font-variant-numeric: tabular-nums; }
      .hint { margin-top: 26px; font-size: 13px; color: rgba(242,242,244,.45); }
      kbd { font: 500 12px -apple-system, sans-serif; padding: 2px 6px; border-radius: 5px; background: rgba(255,255,255,.1); }
    </style>
    </head>
    <body>
    <main>
      <div class="ring">
        <svg viewBox="0 0 24 24" fill="none" stroke="#ff9440" stroke-width="2" stroke-linecap="round">
          <circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="4.5"/><circle cx="12" cy="12" r="0.6" fill="#ff9440"/>
        </svg>
      </div>
      <h1>Bloqué pendant la concentration</h1>
      <p class="site" id="site"></p>
      <section class="card">
        <div class="label">Objectif</div>
        <div class="goal" id="goal">Rester concentré</div>
        <div class="timer" id="timer" hidden>
          <div><div class="label">Temps restant</div><div class="clock" id="clock">--:--</div></div>
          <div class="label" id="end"></div>
        </div>
      </section>
      <p class="hint">Le site sera de nouveau accessible à la fin de la session. Pour un instant de répit, reportez le blocage depuis Prism.</p>
    </main>
    <script>
      const params = new URLSearchParams(location.search);
      const site = params.get("site");
      const goal = params.get("goal");
      const end = Number(params.get("end"));
      if (site) {
        const b = document.createElement("b");
        b.textContent = site;
        const p = document.getElementById("site");
        p.append(b, document.createTextNode(" attendra la fin de votre session."));
      }
      if (goal) document.getElementById("goal").textContent = goal;
      if (end) {
        document.getElementById("timer").hidden = false;
        const endDate = new Date(end);
        document.getElementById("end").textContent = "Fin à " + endDate.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });
        const pad = (n) => String(n).padStart(2, "0");
        const tick = () => {
          const left = Math.max(0, Math.ceil((end - Date.now()) / 1000));
          const h = Math.floor(left / 3600), m = Math.floor(left % 3600 / 60), s = left % 60;
          document.getElementById("clock").textContent = h ? `${h}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
          if (left === 0) { document.querySelector("h1").textContent = "Session terminée"; }
        };
        tick();
        setInterval(tick, 1000);
      }
    </script>
    </body>
    </html>
    """
}
