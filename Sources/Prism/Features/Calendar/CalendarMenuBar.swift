import AppKit
import SwiftUI

/// Réglages de l'agenda dans la barre des menus et de la connexion automatique aux réunions (« calendar.* »).
@MainActor
final class CalendarMenuBarSettings: ObservableObject {
    static let shared = CalendarMenuBarSettings()
    private let defaults = UserDefaults.standard

    /// Affiche la réunion en cours ou la prochaine dans la barre des menus.
    @Published var showInMenuBar: Bool { didSet { save(showInMenuBar, "calendar.menuBar") } }
    /// Seulement les évènements qui ont un lien de visio.
    @Published var menuBarConferenceOnly: Bool { didSet { save(menuBarConferenceOnly, "calendar.menuBarConferenceOnly") } }
    /// L'évènement à venir apparaît ce nombre de minutes avant son début.
    @Published var menuBarLeadMinutes: Int { didSet { save(menuBarLeadMinutes, "calendar.menuBarLeadMinutes") } }
    /// Rejoint les réunions toutes seules à leur début.
    @Published var autoJoin: Bool { didSet { save(autoJoin, "calendar.autoJoin") } }
    /// Demande confirmation avant de rejoindre.
    @Published var autoJoinConfirm: Bool { didSet { save(autoJoinConfirm, "calendar.autoJoinConfirm") } }
    /// Minutes d'avance pour rejoindre (0 : à l'heure pile).
    @Published var autoJoinLead: Int { didSet { save(autoJoinLead, "calendar.autoJoinLead") } }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        CalendarMenuBar.shared.update()
    }

    private init() {
        showInMenuBar = defaults.bool(forKey: "calendar.menuBar")
        menuBarConferenceOnly = defaults.bool(forKey: "calendar.menuBarConferenceOnly")
        menuBarLeadMinutes = defaults.object(forKey: "calendar.menuBarLeadMinutes") as? Int ?? 60
        autoJoin = defaults.bool(forKey: "calendar.autoJoin")
        autoJoinConfirm = defaults.object(forKey: "calendar.autoJoinConfirm") as? Bool ?? true
        autoJoinLead = defaults.object(forKey: "calendar.autoJoinLead") as? Int ?? 1
    }
}

/// L'agenda dans la barre des menus (« Point hebdo · dans 7 min ») et la connexion automatique aux réunions.
@MainActor
final class CalendarMenuBar: NSObject, NSMenuDelegate {
    static let shared = CalendarMenuBar()

    private var item: NSStatusItem?
    private var timer: Timer?
    private var dismissed = Set<String>()
    private var joined = Set<String>()
    private var asking = false

    func start() {
        guard !SystemFeature.isHeadless else { return }
        CalendarService.shared.onChange["menubar"] = { CalendarMenuBar.shared.update() }
        let timer = Timer(timeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated { CalendarMenuBar.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        update()
    }

    // MARK: - Choix de l'évènement

    /// L'évènement à montrer : en cours, sinon le prochain dans le délai choisi.
    static func featured(in events: [AgendaEvent], now: Date, leadMinutes: Int, conferenceOnly: Bool, dismissed: Set<String>) -> AgendaEvent? {
        let candidates = events.filter { event in
            !event.isAllDay && !event.isDeclined && event.end > now && !dismissed.contains(event.id)
                && (!conferenceOnly || event.meeting != nil)
        }
        if let ongoing = candidates.filter({ $0.isOngoing(at: now) }).min(by: { $0.start < $1.start }) { return ongoing }
        return candidates
            .filter { $0.start > now && $0.start.timeIntervalSince(now) <= Double(leadMinutes) * 60 }
            .min { $0.start < $1.start }
    }

    /// Le titre court de la barre des menus : « Point hebdo · dans 7 min », « Point hebdo · encore 20 min ».
    static func title(for event: AgendaEvent, now: Date) -> String {
        let name = event.title.count > 26 ? String(event.title.prefix(25)) + "…" : event.title
        if event.isOngoing(at: now) {
            let left = max(1, Int(event.end.timeIntervalSince(now) / 60))
            return "\(name) · encore \(left) min"
        }
        let minutes = max(1, Int(ceil(event.start.timeIntervalSince(now) / 60)))
        return minutes < 60 ? "\(name) · dans \(minutes) min" : "\(name) · \(AgendaFormat.time(event.start))"
    }

    // MARK: - Barre des menus

    func update() {
        let settings = CalendarMenuBarSettings.shared
        guard settings.showInMenuBar, CalendarService.shared.isAuthorized else {
            removeItem()
            return
        }
        let now = Date()
        let events = CalendarService.shared.visibleEvents
        guard let event = Self.featured(in: events, now: now, leadMinutes: settings.menuBarLeadMinutes,
                                        conferenceOnly: settings.menuBarConferenceOnly, dismissed: dismissed) else {
            removeItem()
            return
        }
        let item = item ?? makeItem()
        item.button?.title = " " + Self.title(for: event, now: now)
        item.button?.image = NSImage(systemSymbolName: event.meeting == nil ? "calendar" : "video.fill", accessibilityDescription: "Agenda")
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = "\(event.title) — \(AgendaFormat.range(event.start, event.end))"
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
        return item
    }

    private func removeItem() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    /// Le menu se construit à l'ouverture : la réunion, ses actions, puis le reste de la journée.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()
        let settings = CalendarMenuBarSettings.shared
        let events = CalendarService.shared.visibleEvents
        if let event = Self.featured(in: events, now: now, leadMinutes: settings.menuBarLeadMinutes,
                                     conferenceOnly: settings.menuBarConferenceOnly, dismissed: dismissed) {
            let header = NSMenuItem(title: event.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            let when = NSMenuItem(title: AgendaFormat.when(event, now: now), action: nil, keyEquivalent: "")
            when.isEnabled = false
            menu.addItem(when)
            if let meeting = event.meeting {
                menu.addItem(action("Rejoindre avec \(meeting.service.title)", symbol: "video.fill") { CalendarService.shared.join(meeting) })
            }
            menu.addItem(action("Ouvrir dans Calendrier", symbol: "calendar") { CalendarService.shared.openInCalendar(event) })
            menu.addItem(action("Masquer cet évènement", symbol: "eye.slash") { [weak self] in
                self?.dismissed.insert(event.id)
                self?.update()
            })
            menu.addItem(.separator())
        }
        let calendar = Calendar.current
        let rest = events.filter { !$0.isAllDay && $0.start > now && calendar.isDateInToday($0.start) }.prefix(6)
        if !rest.isEmpty {
            let title = NSMenuItem(title: "Plus tard aujourd’hui", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            for event in rest {
                menu.addItem(action("\(AgendaFormat.time(event.start))  \(event.title)", symbol: event.meeting == nil ? "circle.fill" : "video") {
                    if let meeting = event.meeting { CalendarService.shared.join(meeting) } else { CalendarService.shared.openInCalendar(event) }
                })
            }
            menu.addItem(.separator())
        }
        menu.addItem(action("Mon agenda…", symbol: "list.bullet.rectangle") { CommandRunner.run(id: "command:calendar") })
        menu.addItem(action("Réglages du calendrier…", symbol: "gearshape") {
            NotificationCenter.default.post(name: .prismOpenSettings, object: "calendar")
        })
    }

    private var handlers: [ObjectIdentifier: () -> Void] = [:]

    private func action(_ title: String, symbol: String, run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.representedObject = MenuAction(run: run)
        return item
    }

    @objc private func runMenuAction(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }

    private final class MenuAction {
        let run: @MainActor () -> Void
        init(run: @escaping @MainActor () -> Void) { self.run = run }
    }

    // MARK: - Connexion automatique

    private func tick() {
        update()
        let settings = CalendarMenuBarSettings.shared
        guard settings.autoJoin, !asking, CalendarService.shared.isAuthorized else { return }
        let now = Date()
        guard let event = Self.dueForAutoJoin(CalendarService.shared.visibleEvents, now: now, leadMinutes: settings.autoJoinLead, joined: joined),
              let meeting = event.meeting else { return }
        joined.insert(event.id)
        guard settings.autoJoinConfirm else {
            CalendarService.shared.join(meeting)
            HUD.shared.show("Connexion à « \(event.title) »", symbol: "video.fill")
            return
        }
        asking = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "« \(event.title) » commence"
        alert.informativeText = "\(AgendaFormat.range(event.start, event.end)) · \(meeting.service.title)"
        alert.addButton(withTitle: "Rejoindre")
        alert.addButton(withTitle: "Plus tard")
        let answer = alert.runModal()
        asking = false
        if answer == .alertFirstButtonReturn { CalendarService.shared.join(meeting) }
    }

    /// La réunion à rejoindre maintenant : avec un lien de visio, commencée depuis moins de 5 min
    /// ou qui commence dans le délai d'avance, pas encore rejointe.
    static func dueForAutoJoin(_ events: [AgendaEvent], now: Date, leadMinutes: Int, joined: Set<String>) -> AgendaEvent? {
        events.filter { event in
            guard event.meeting != nil, !event.isAllDay, !event.isDeclined, !joined.contains(event.id) else { return false }
            let delta = event.start.timeIntervalSince(now)
            return delta <= Double(leadMinutes) * 60 && delta > -5 * 60
        }.min { $0.start < $1.start }
    }
}

/// La section des réglages du calendrier pour la barre des menus et la connexion automatique.
struct CalendarMenuBarSettingsSection: View {
    @ObservedObject private var settings = CalendarMenuBarSettings.shared

    var body: some View {
        Section {
            Toggle("Afficher la prochaine réunion dans la barre des menus", isOn: $settings.showInMenuBar)
            Toggle("Seulement les évènements avec visio", isOn: $settings.menuBarConferenceOnly)
                .disabled(!settings.showInMenuBar)
            Picker("Apparaît", selection: $settings.menuBarLeadMinutes) {
                ForEach([15, 30, 60, 120, 240], id: \.self) { Text($0 < 60 ? "\($0) min avant" : "\($0 / 60) h avant").tag($0) }
            }
            .disabled(!settings.showInMenuBar)
            Toggle("Rejoindre automatiquement les réunions", isOn: $settings.autoJoin)
            Toggle("Demander avant de rejoindre", isOn: $settings.autoJoinConfirm)
                .disabled(!settings.autoJoin)
            Picker("Rejoindre", selection: $settings.autoJoinLead) {
                Text("à l’heure pile").tag(0)
                Text("1 min avant").tag(1)
                Text("2 min avant").tag(2)
                Text("5 min avant").tag(5)
            }
            .disabled(!settings.autoJoin)
        } header: {
            Text("Barre des menus et connexion automatique")
        } footer: {
            Text("Sur macOS 26, l’icône peut devoir être autorisée dans Réglages Système › Barre des menus.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
