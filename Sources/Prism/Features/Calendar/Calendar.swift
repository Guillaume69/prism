import AppKit
import SwiftUI

// MARK: - Éléments de l'agenda

@MainActor
enum AgendaItems {
    static func icon(_ event: AgendaEvent) -> ItemIcon {
        let color = Color(nsColor: event.calendarColor)
        if event.isDeclined { return .tinted("circle.slash", color) }
        if event.isAllDay { return .tinted("sun.max.fill", color) }
        return .tinted(event.meeting != nil ? "video.fill" : "circle.fill", color)
    }

    static func item(_ event: AgendaEvent, now: Date, idPrefix: String = "event:") -> ResultItem {
        let accessory: String
        if event.isOngoing(at: now) {
            accessory = "En cours"
        } else if event.isAllDay {
            accessory = "Journée"
        } else {
            accessory = AgendaFormat.range(event.start, event.end)
        }
        return ResultItem(
            id: idPrefix + event.id,
            title: event.title,
            subtitle: event.calendarTitle,
            icon: icon(event),
            accessory: accessory,
            detail: detail(event, now: now),
            usageKey: "",
            actions: actions(event, now: now)
        )
    }

    // MARK: Détail

    static func detail(_ event: AgendaEvent, now: Date) -> ItemDetail {
        var lines = ["## \(event.title)", "**\(AgendaFormat.when(event, now: now))**"]
        let countdown = event.isAllDay ? "" : AgendaFormat.countdown(to: event, now: now)
        if !countdown.isEmpty { lines.append(countdown) }
        if let meeting = event.meeting {
            lines.append("")
            lines.append("[Rejoindre avec \(meeting.service.title)](\(meeting.url.absoluteString))")
        }
        if !event.attendees.isEmpty {
            lines.append("")
            lines.append("**Participants (\(event.attendees.count))**")
            for attendee in event.attendees {
                lines.append("- \(attendee.name)\(attendee.isMe ? " (vous)" : "") — \(status(attendee))")
            }
        }
        if let notes = event.notes.map(cleanNotes), !notes.isEmpty {
            lines.append("")
            lines.append("**Notes**")
            lines.append(notes)
        }
        var metadata: [(label: String, value: String)] = [("Calendrier", event.calendarTitle)]
        metadata.append(("Durée", event.isAllDay ? "Toute la journée" : AgendaFormat.duration(event.duration)))
        if let location = event.location, MeetingLink.find(in: location) == nil {
            metadata.append(("Lieu", location))
        }
        if let meeting = event.meeting { metadata.append(("Visio", meeting.service.title)) }
        if let response = event.myResponse, !event.isOrganizer { metadata.append(("Ma réponse", response.label)) }
        if event.isRecurring { metadata.append(("Répétition", "Évènement récurrent")) }
        return ItemDetail(text: lines.joined(separator: "\n"), metadata: metadata, isMarkdown: true)
    }

    private static func status(_ attendee: AgendaEvent.Attendee) -> String {
        if attendee.isOrganizer { return "organise" }
        switch attendee.response {
        case .accepted: return "a accepté"
        case .declined: return "a refusé"
        case .tentative: return "peut-être"
        case .pending, .unknown: return "pas encore répondu"
        }
    }

    /// Les notes des invitations : sans HTML, sans les longues lignes de séparation, raccourcies.
    static func cleanNotes(_ notes: String) -> String {
        var text = notes.replacingOccurrences(of: #"(?i)<br\s*/?>|</p>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, value) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "’"] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.replacingOccurrences(of: #"(?m)^\s*[-_=~*]{5,}\s*$"#, with: "---", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 1_500 ? String(text.prefix(1_500)) + "…" : text
    }

    /// Le texte de « Copier les détails ».
    static func detailsText(_ event: AgendaEvent, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMMyyyy")
        var lines = [event.title]
        lines.append(event.isAllDay
            ? formatter.string(from: event.start) + ", toute la journée"
            : formatter.string(from: event.start) + ", " + AgendaFormat.range(event.start, event.end))
        if let location = event.location { lines.append("Lieu : \(location)") }
        if let meeting = event.meeting { lines.append("\(meeting.service.title) : \(meeting.url.absoluteString)") }
        if !event.attendees.isEmpty { lines.append("Participants : " + event.attendees.map(\.name).joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    // MARK: Actions

    static func joinAction(_ meeting: MeetingLink, title: String? = nil) -> ItemAction {
        ItemAction(title: title ?? "Rejoindre la visio (\(meeting.service.title))", symbol: "video.fill", shortcut: KeyShortcut(keyCode: 36, modifiers: [.command], label: "↵")) {
            CalendarService.shared.join(meeting)
            return .close
        }
    }

    static func openAction(_ event: AgendaEvent) -> ItemAction {
        ItemAction(title: "Ouvrir dans Calendrier", symbol: "calendar") {
            CalendarService.shared.openInCalendar(event)
            return .close
        }
    }

    static func actions(_ event: AgendaEvent, now: Date) -> [ItemAction] {
        var actions = [openAction(event)]
        let meeting = event.meeting
        if let meeting { actions.append(joinAction(meeting)) }
        if !event.isOrganizer, event.myResponse != nil {
            // EventKit ne sait pas répondre à une invitation : Calendrier s'en charge.
            for (title, symbol) in [("Accepter l’invitation", "checkmark.circle"), ("Refuser l’invitation", "xmark.circle")] {
                actions.append(ItemAction(title: title, symbol: symbol, section: "Répondre") {
                    CalendarService.shared.openInCalendar(event)
                    return .hud("Répondez à l’invitation dans Calendrier")
                })
            }
        }
        let emails = event.attendees.filter { !$0.isMe }.compactMap(\.email)
        if !emails.isEmpty {
            actions.append(ItemAction(title: "Envoyer un e-mail aux participants", symbol: "envelope", shortcut: KeyShortcut(keyCode: 14, modifiers: [.command, .shift], label: "E"), section: "Répondre") {
                var components = URLComponents()
                components.scheme = "mailto"
                components.path = emails.joined(separator: ",")
                components.queryItems = [URLQueryItem(name: "subject", value: event.title)]
                if let url = components.url { NSWorkspace.shared.open(url) }
                return .close
            })
        }
        var copies: [ItemAction] = []
        if let meeting {
            copies.append(Actions.copy(meeting.url.absoluteString, title: "Copier le lien de la visio", symbol: "link", shortcut: KeyShortcut(keyCode: 37, modifiers: [.command, .shift], label: "L"), hud: "Lien copié"))
        }
        copies += [
            Actions.copy(detailsText(event, now: now), title: "Copier les détails", symbol: "doc.on.doc", shortcut: .copyText, hud: "Détails copiés"),
            Actions.copy(event.title, title: "Copier le titre", symbol: "textformat", shortcut: .copyName, hud: "Titre copié"),
        ]
        if !event.attendees.isEmpty {
            let list = event.attendees.map { attendee in attendee.email.map { "\(attendee.name) <\($0)>" } ?? attendee.name }
            copies.append(Actions.copy(list.joined(separator: ", "), title: "Copier les participants", symbol: "person.2", hud: "Participants copiés"))
        }
        copies.append(ItemAction(title: "Copier mes disponibilités du jour", symbol: "clock.badge.checkmark") {
            Pasteboard.copy(availability(on: event.start, now: now))
            return .hud("Disponibilités copiées")
        })
        actions += copies.map { var action = $0; action.section = "Copier"; return action }

        actions.append(ItemAction(title: "Créer un évènement", symbol: "calendar.badge.plus", shortcut: .create, section: "Agenda") {
            .push(CalendarFeature.createForm())
        })
        actions.append(ItemAction(title: "Bloquer du temps", symbol: "hourglass", section: "Agenda") {
            .push(CalendarFeature.blockTimeScreen())
        })
        actions.append(ItemAction(title: "Actualiser", symbol: "arrow.clockwise", shortcut: .refresh, section: "Agenda") {
            CalendarService.shared.refresh()
            return .refresh
        })
        if event.canEdit {
            actions.append(ItemAction(title: "Supprimer l’évènement", symbol: "trash", shortcut: .removeEntry, isDestructive: true, section: "Agenda") {
                .push(DestructiveConfirmScreen(
                    title: "Supprimer l’évènement ?",
                    message: "« \(event.title) » sera supprimé de « \(event.calendarTitle) »\(event.isRecurring ? " (cette occurrence seulement)" : "")\(event.attendees.count > 1 ? ". Les participants ne seront pas prévenus par Prism." : ".")",
                    confirmTitle: "Supprimer"
                ) {
                    do {
                        try CalendarService.shared.delete(event)
                        HUD.shared.show("Évènement supprimé", symbol: "trash.fill")
                        return .refresh
                    } catch {
                        return .toast(error.localizedDescription)
                    }
                })
            })
        }
        return actions
    }

    /// Les créneaux libres du jour, d'après les évènements affichés (occupés, non refusés).
    static func availability(on day: Date, now: Date) -> String {
        let calendar = Calendar.current
        let settings = CalendarSettings.shared
        let busy = CalendarService.shared.visibleEvents
            .filter { !$0.isAllDay && !$0.isFree && !$0.isDeclined && calendar.isDate($0.start, inSameDayAs: day) }
            .map { DateInterval(start: $0.start, end: max($0.end, $0.start)) }
        let slots = FreeSlots.compute(busy: busy, day: day, workStart: settings.workStart, workEnd: settings.workEnd, now: now)
        return FreeSlots.text(slots, day: day)
    }

    /// L'élément qui demande l'accès au calendrier.
    static func accessItem(onGranted: @escaping @MainActor () -> Void) -> ResultItem {
        let denied = CalendarService.status == .denied || CalendarService.status == .restricted
        return ResultItem(
            id: "calendar.access",
            title: denied ? "Ouvrir les réglages de confidentialité" : "Autoriser l’accès au calendrier…",
            icon: .symbol("lock.fill", Palette.gray),
            detail: ItemDetail(
                text: denied
                    ? "## Accès refusé\nPrism n’a pas accès à vos calendriers. Autorisez-le dans **Réglages Système › Confidentialité et sécurité › Calendriers**."
                    : "## Votre agenda dans Prism\nPrism affiche vos prochains évènements, rejoint vos réunions en un geste et crée des évènements.\n\nVos données restent sur votre Mac.",
                metadata: [("État", CalendarService.shared.statusDescription)],
                isMarkdown: true
            ),
            usageKey: "",
            actions: [ItemAction(title: denied ? "Ouvrir les réglages" : "Autoriser l’accès…", symbol: "lock.open") {
                CalendarService.shared.requestAccess { granted in if granted { onGranted() } }
                return .stay
            }]
        )
    }
}

// MARK: - Mon agenda

/// « Mon agenda » : les évènements à venir, groupés par jour, la prochaine réunion en tête ; ⌘P filtre par calendrier.
@MainActor
final class AgendaScreen: LauncherScreen {
    init() {
        super.init(id: "calendar", title: "Mon agenda", placeholder: "Rechercher des évènements…", icon: .symbol("calendar", Palette.red))
        layout = .split(listWidth: 340)
        filter = Self.makeFilter(selected: "all")
    }

    private static func makeFilter(selected: String) -> ScreenFilter? {
        let hidden = Set(CalendarSettings.shared.hiddenCalendars)
        let calendars = CalendarService.shared.isAuthorized ? CalendarService.shared.calendars.filter { !hidden.contains($0.id) } : []
        guard calendars.count > 1 else { return nil }
        let options = [ScreenFilter.Option(id: "all", title: "Tous les calendriers")] + calendars.map { .init(id: $0.id, title: $0.title) }
        return ScreenFilter(options: options, selected: options.contains { $0.id == selected } ? selected : "all")
    }

    override func didAppear() {
        CalendarService.shared.onChange["agenda"] = { [weak self] in
            guard let self else { return }
            self.isLoading = false
            self.filter = Self.makeFilter(selected: self.filter?.selected ?? "all")
            self.reload()
        }
        let service = CalendarService.shared
        if service.isAuthorized {
            isLoading = service.lastFetch == nil
            service.refresh()
        }
    }

    override func didDisappear() {
        CalendarService.shared.onChange["agenda"] = nil
    }

    override func sections(query: String) -> [ResultSection] {
        let service = CalendarService.shared
        guard service.isAuthorized else {
            return [ResultSection(id: "access", title: "Calendrier", items: [AgendaItems.accessItem { [weak self] in
                guard let self else { return }
                self.filter = Self.makeFilter(selected: "all")
                self.reload()
            }])]
        }
        let now = Date()
        let horizon = now.addingTimeInterval(14 * 86_400)
        let selected = filter?.selected ?? "all"
        let normalized = query.normalizedForSearch
        var events = service.visibleEvents.filter { event in
            guard event.end > now, event.start < horizon else { return false }
            guard selected == "all" || event.calendarID == selected else { return false }
            guard !normalized.isEmpty else { return true }
            let fields = [event.title, event.location ?? "", event.calendarTitle] + event.attendees.map(\.name)
            return fields.contains { Fuzzy.score(normalized, $0) ?? 0 >= 60 }
        }
        var sections: [ResultSection] = []
        if normalized.isEmpty, let next = AgendaGrouping.nextMeeting(events, now: now, within: 12 * 3600) {
            let title = next.isOngoing(at: now) ? "En cours" : "Prochaine réunion · " + AgendaFormat.countdown(to: next, now: now).lowercased()
            sections.append(ResultSection(id: "next", title: title, items: [AgendaItems.item(next, now: now)]))
            events.removeAll { $0.id == next.id }
        }
        for group in AgendaGrouping.group(events, now: now) {
            sections.append(ResultSection(
                id: "day-\(Int(group.day.timeIntervalSince1970))",
                title: group.title,
                items: group.events.map { AgendaItems.item($0, now: now) }
            ))
        }
        return sections
    }

    override func emptyState(query: String) -> (symbol: String, message: String) {
        if isLoading { return ("hourglass", "Chargement de l’agenda…") }
        return query.isEmpty
            ? ("calendar", "Rien de prévu dans les deux prochaines semaines.")
            : ("magnifyingglass", "Aucun évènement pour « \(query) »")
    }

    override var screenActions: [ItemAction] {
        [ItemAction(title: "Créer un évènement", symbol: "calendar.badge.plus", shortcut: .create) { .push(CalendarFeature.createForm()) }]
    }
}

// MARK: - Fonctionnalité

@MainActor
enum CalendarFeature: PrismFeature {
    static func start() {
        CalendarService.shared.onChange["root"] = {
            guard let model = AppContext.launcher?.model, model.isRoot else { return }
            model.root.reload()
        }
        // Sans autorisation, rien n'est lu : l'accès se demande depuis « Mon agenda » ou les réglages.
        if CalendarService.shared.isAuthorized { CalendarService.shared.start() }
        CalendarMenuBar.shared.start()
    }

    static var commands: [ResultItem] {
        [
            Command.screen("calendar", "Mon agenda", subtitle: "Calendrier", symbol: "calendar", color: Palette.red, keywords: ["my schedule", "calendar", "agenda", "evenements", "reunions", "planning"]) { AgendaScreen() },
            Command.screen("calendar.new", "Créer un évènement", subtitle: "Calendrier", symbol: "calendar.badge.plus", color: Palette.red, keywords: ["create event", "nouvel evenement", "rendez-vous", "reunion"]) { createForm() },
            Command.screen("calendar.block", "Bloquer du temps", subtitle: "Calendrier", symbol: "hourglass", color: Palette.red, keywords: ["block time", "focus", "concentration", "creneau"]) { blockTimeScreen() },
        ]
    }

    /// La réunion en cours ou imminente, en tête de la recherche principale : ↵ la rejoint.
    static func topSections(query: String) -> [ResultSection] {
        let settings = CalendarSettings.shared
        let service = CalendarService.shared
        guard settings.showInRoot, service.isAuthorized else { return [] }
        service.refreshIfStale()
        let now = Date()
        guard let event = AgendaGrouping.nextMeeting(service.visibleEvents, now: now, within: TimeInterval(settings.rootLeadMinutes * 60)) else { return [] }
        if !query.isEmpty {
            let normalized = query.normalizedForSearch
            let words = [event.title, "rejoindre", "join", "reunion", "meeting", "visio", "agenda", event.meeting?.service.title ?? ""]
            guard words.contains(where: { Fuzzy.score(normalized, $0) ?? 0 >= 74 }) else { return [] }
        }
        let meeting = event.meeting
        var actions: [ItemAction] = []
        if let meeting { actions.append(AgendaItems.joinAction(meeting, title: "Rejoindre la visio")) }
        actions.append(AgendaItems.openAction(event))
        if let meeting {
            actions.append(Actions.copy(meeting.url.absoluteString, title: "Copier le lien de la visio", symbol: "link", hud: "Lien copié"))
        }
        actions.append(ItemAction(title: "Ouvrir Mon agenda", symbol: "calendar") { .push(AgendaScreen()) })
        let item = ResultItem(
            id: "calendar.next",
            title: event.title,
            subtitle: AgendaFormat.countdown(to: event, now: now) + " · " + AgendaFormat.range(event.start, event.end),
            icon: .symbol(meeting != nil ? "video.fill" : "calendar", Color(nsColor: event.calendarColor)),
            accessory: meeting?.service.title ?? event.calendarTitle,
            usageKey: "",
            actions: actions
        )
        return [ResultSection(id: "calendar-next", title: event.isOngoing(at: now) ? "Réunion en cours" : "Prochaine réunion", items: [item])]
    }

    // MARK: Créer un évènement

    static func createForm(title: String = "", start: Date? = nil) -> LauncherScreen {
        let service = CalendarService.shared
        let calendar = Calendar.current
        let now = Date()
        let start = start ?? Date(timeIntervalSinceReferenceDate: ceil(now.timeIntervalSinceReferenceDate / 1_800) * 1_800)
        let iso = ISO8601DateFormatter()
        let calendars = service.calendars.filter(\.isWritable)
        let defaultCalendar = service.defaultCalendarID ?? calendars.first?.id ?? ""
        let alerts: [(value: String, title: String)] = [
            ("none", "Aucune"), ("0", "À l’heure de l’évènement"), ("5", "5 minutes avant"), ("10", "10 minutes avant"),
            ("15", "15 minutes avant"), ("30", "30 minutes avant"), ("60", "1 heure avant"), ("1440", "1 jour avant"),
        ]
        let fields: [FormField] = [
            FormField(id: "title", label: "Titre", kind: .text, placeholder: "Réunion d’équipe", value: title),
            FormField(id: "start", label: "Début", kind: .date(includesTime: true), value: iso.string(from: start)),
            FormField(id: "end", label: "Fin", kind: .date(includesTime: true), value: iso.string(from: start.addingTimeInterval(3_600))),
            FormField(id: "allDay", label: "", kind: .checkbox(label: "Toute la journée"), value: "false"),
            FormField(id: "calendar", label: "Calendrier", kind: .dropdown(calendars.map { ($0.id, $0.title) }), value: defaultCalendar),
            FormField(id: "location", label: "Lieu", kind: .text, placeholder: "Salle, adresse…"),
            FormField(id: "url", label: "Lien", kind: .text, placeholder: "https://meet.google.com/…"),
            FormField(id: "attendees", label: "Participants", kind: .text, placeholder: "lea@exemple.fr, hugo@exemple.fr",
                      info: "Une invitation (fichier .ics) leur est préparée dans Mail ; ils sont aussi ajoutés aux notes."),
            FormField(id: "notes", label: "Notes", kind: .textArea(lines: 3)),
            FormField(id: "alert", label: "Alerte", kind: .dropdown(alerts), value: "10"),
        ]
        return FormScreen(id: "calendar.new", title: "Créer un évènement", icon: .symbol("calendar.badge.plus", Palette.red), submitTitle: "Créer l’évènement", fields: fields) { state in
            guard service.canWrite else {
                state.error = FeatureDemo.isActive ? "Démonstration : rien n’est enregistré." : "Autorisez d’abord l’accès au calendrier (Réglages › Calendrier)."
                return .stay
            }
            let title = state.trimmed("title")
            guard !title.isEmpty else { state.error = "Donnez un titre à l’évènement"; return .stay }
            let allDay = state.bool("allDay")
            guard var begin = iso.date(from: state["start"]), var end = iso.date(from: state["end"]) else {
                state.error = "Dates invalides"
                return .stay
            }
            if allDay {
                begin = calendar.startOfDay(for: begin)
                end = max(calendar.startOfDay(for: end), begin)
            } else if end <= begin {
                state.error = "La fin doit suivre le début"
                return .stay
            }
            var link: URL?
            let rawLink = state.trimmed("url")
            if !rawLink.isEmpty {
                link = URL(string: rawLink.contains("://") ? rawLink : "https://" + rawLink)
                guard link?.host != nil else { state.error = "Lien invalide"; return .stay }
            }
            var notes = state.trimmed("notes")
            let attendees = state.trimmed("attendees")
            if !attendees.isEmpty { notes += (notes.isEmpty ? "" : "\n\n") + "Participants : " + attendees }
            let alert = state["alert"]
            let draft = CalendarService.Draft(
                title: title, start: begin, end: end, isAllDay: allDay,
                calendarID: state["calendar"].isEmpty ? nil : state["calendar"],
                location: state.trimmed("location").isEmpty ? nil : state.trimmed("location"),
                url: link, notes: notes.isEmpty ? nil : notes,
                alertMinutes: alert == "none" ? nil : Int(alert)
            )
            do {
                try service.create(draft)
                // EventKit n'invite personne : on prépare l'invitation dans Mail, avec le fichier .ics.
                let emails = CalendarInvitation.emails(in: attendees)
                if !emails.isEmpty { return CalendarInvitation.compose(draft: draft, attendees: emails) }
                return .hud("Évènement « \(title) » créé")
            } catch {
                state.error = error.localizedDescription
                return .stay
            }
        }
    }

    // MARK: Bloquer du temps

    /// Bloque un créneau à partir de maintenant ; la saisie devient le titre. ⌘↵ : au prochain créneau libre.
    static func blockTimeScreen() -> LauncherScreen {
        let durations: [(minutes: Int, title: String)] = [(15, "15 minutes"), (30, "30 minutes"), (45, "45 minutes"), (60, "1 heure"), (90, "1 h 30"), (120, "2 heures"), (180, "3 heures")]
        return ListScreen(
            id: "calendar.block",
            title: "Bloquer du temps",
            placeholder: "Titre du créneau (facultatif)…",
            icon: .symbol("hourglass", Palette.red)
        ) { query in
            let service = CalendarService.shared
            guard service.canWrite || FeatureDemo.isActive else {
                return [ResultSection(id: "access", title: "Calendrier", items: [AgendaItems.accessItem {}])]
            }
            let now = Date()
            let start = Date(timeIntervalSinceReferenceDate: ceil(now.timeIntervalSinceReferenceDate / 300) * 300)
            let title = query.isEmpty ? "Temps bloqué" : query
            let items = durations.map { duration -> ResultItem in
                let end = start.addingTimeInterval(TimeInterval(duration.minutes * 60))
                return ResultItem(
                    id: "block.\(duration.minutes)",
                    title: "Bloquer \(duration.title)",
                    subtitle: "« \(title) » · \(AgendaFormat.range(start, end))",
                    icon: .symbol("hourglass", Palette.red),
                    accessory: AgendaFormat.range(start, end),
                    usageKey: "",
                    actions: [
                        ItemAction(title: "Bloquer maintenant", symbol: "hourglass") {
                            block(title: title, start: start, minutes: duration.minutes)
                        },
                        ItemAction(title: "Bloquer au prochain créneau libre", symbol: "calendar.badge.clock") {
                            let slot = FreeSlots.compute(
                                busy: service.visibleEvents.filter { !$0.isAllDay && !$0.isFree && !$0.isDeclined }.map { DateInterval(start: $0.start, end: max($0.end, $0.start)) },
                                day: now, workStart: CalendarSettings.shared.workStart, workEnd: CalendarSettings.shared.workEnd, now: now,
                                minimum: TimeInterval(duration.minutes * 60)
                            ).first
                            guard let slot else { return .toast("Aucun créneau libre assez long aujourd’hui") }
                            return block(title: title, start: slot.start, minutes: duration.minutes)
                        },
                    ]
                )
            }
            return [ResultSection(id: "durations", title: "Durée", items: items)]
        }
    }

    private static func block(title: String, start: Date, minutes: Int) -> ActionOutcome {
        let end = start.addingTimeInterval(TimeInterval(minutes * 60))
        do {
            try CalendarService.shared.create(.init(title: title, start: start, end: end, calendarID: nil, location: nil, url: nil, notes: nil, alertMinutes: nil))
            return .hud("Créneau bloqué de \(AgendaFormat.range(start, end))")
        } catch {
            return .toast(error.localizedDescription)
        }
    }

    // MARK: Réglages, liens profonds, autotests

    static var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "calendar", title: "Calendrier", symbol: "calendar", color: Palette.red, order: 45) { AnyView(CalendarSettingsView()) }]
    }

    /// `prism://calendar` (agenda), `prism://calendar/new`, `prism://calendar/block`, `prism://calendar/join` (prochaine réunion).
    static func handle(url: URL) -> Bool {
        guard url.host == "calendar", let launcher = AppContext.launcher else { return false }
        switch url.path {
        case "/join":
            let next = AgendaGrouping.nextMeeting(CalendarService.shared.visibleEvents, now: Date(), within: 30 * 60)
            if let meeting = next?.meeting {
                CalendarService.shared.join(meeting)
            } else {
                HUD.shared.show("Aucune réunion avec visio dans les 30 minutes", symbol: "video.slash.fill")
            }
        case "/new":
            launcher.show(reset: true)
            launcher.model.push(createForm())
        case "/block":
            launcher.show(reset: true)
            launcher.model.push(blockTimeScreen())
        default:
            launcher.show(reset: true)
            launcher.model.push(AgendaScreen())
        }
        return true
    }

    static func selfTest(_ check: (Bool, String) -> Void) {
        // Invitations
        check(CalendarInvitation.emails(in: "Léa <lea@exemple.fr>, hugo@exemple.fr ; LEA@exemple.fr") == ["lea@exemple.fr", "hugo@exemple.fr"], "invitation : adresses extraites, sans doublon")
        let invitation = CalendarInvitation.ics(title: "Point, hebdo", start: Date(timeIntervalSince1970: 1_800_000_000), end: Date(timeIntervalSince1970: 1_800_001_800), isAllDay: false,
                                                location: "Salle 2", url: nil, notes: "Ordre du jour\nPoint 1", attendees: ["lea@exemple.fr"], uid: "u1", now: Date(timeIntervalSince1970: 1_799_000_000))
        check(invitation.contains("DTSTART:20270115T080000Z") && invitation.contains("SUMMARY:Point\\, hebdo") && invitation.contains("ATTENDEE;ROLE=REQ-PARTICIPANT;RSVP=TRUE:mailto:lea@exemple.fr") && invitation.contains("\r\n"), "invitation : fichier iCalendar conforme")
        let mailto = CalendarInvitation.mailtoURL(to: ["lea@exemple.fr", "hugo@exemple.fr"], subject: "Invitation : Point & café", body: "Bonjour,\nÀ demain ?")?.absoluteString ?? ""
        check(mailto == "mailto:lea@exemple.fr,hugo@exemple.fr?subject=Invitation%20%3A%20Point%20%26%20caf%C3%A9&body=Bonjour%2C%0D%0A%C3%80%20demain%20%3F", "invitation : lien mailto encodé")
        let gmail = CalendarInvitation.gmailComposeURL(to: ["lea@exemple.fr"], subject: "Point & café", body: "Bonjour")
        check(gmail.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "su" }?.value } == "Point & café" && gmail?.host == "mail.google.com", "invitation : rédaction Gmail pré-remplie")

        // Barre des menus et connexion automatique.
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ id: String, start minutes: Double, length: Double = 30, link: Bool = true) -> AgendaEvent {
            AgendaEvent(id: id, title: "Réunion \(id)", start: base.addingTimeInterval(minutes * 60), end: base.addingTimeInterval((minutes + length) * 60),
                        calendarID: "c", calendarTitle: "Travail", calendarColor: .systemRed,
                        url: link ? URL(string: "https://meet.google.com/abc-defg-hij") : nil)
        }
        let menuEvents = [event("a", start: -10), event("b", start: 20), event("c", start: 90, link: false)]
        check(CalendarMenuBar.featured(in: menuEvents, now: base, leadMinutes: 60, conferenceOnly: false, dismissed: [])?.id == "a", "barre des menus : la réunion en cours d’abord")
        check(CalendarMenuBar.featured(in: menuEvents, now: base, leadMinutes: 60, conferenceOnly: false, dismissed: ["a"])?.id == "b", "barre des menus : évènement masqué ignoré")
        check(CalendarMenuBar.featured(in: [menuEvents[2]], now: base, leadMinutes: 120, conferenceOnly: true, dismissed: []) == nil, "barre des menus : seulement avec visio")
        check(CalendarMenuBar.title(for: menuEvents[1], now: base) == "Réunion b · dans 20 min", "barre des menus : titre « dans 20 min »")
        check(CalendarMenuBar.dueForAutoJoin(menuEvents, now: base.addingTimeInterval(19 * 60), leadMinutes: 1, joined: [])?.id == "b", "connexion automatique : 1 min avant")
        check(CalendarMenuBar.dueForAutoJoin(menuEvents, now: base.addingTimeInterval(19 * 60), leadMinutes: 1, joined: ["b"]) == nil, "connexion automatique : une seule fois")
        check(CalendarMenuBar.dueForAutoJoin(menuEvents, now: base, leadMinutes: 1, joined: []) == nil, "connexion automatique : pas une réunion commencée depuis 10 min")

        func service(_ text: String) -> MeetingService? { MeetingLink.find(in: text)?.service }
        let zoom = MeetingLink.find(in: "Lien : https://us02web.zoom.us/j/81234567890?pwd=abc123.")
        check(zoom?.service == .zoom && zoom?.url.absoluteString == "https://us02web.zoom.us/j/81234567890?pwd=abc123", "visio : Zoom, ponctuation finale retirée")
        check(zoom?.nativeURL?.absoluteString == "zoommtg://us02web.zoom.us/join?action=join&confno=81234567890&pwd=abc123", "visio : Zoom dans l’application")
        check(service("Rejoindre avec Google Meet : https://meet.google.com/abc-defg-hij") == .googleMeet, "visio : Google Meet")
        let teams = MeetingLink.find(in: "Click here <https://teams.microsoft.com/l/meetup-join/19%3ameeting_YmFj%40thread.v2/0?context=%7b%7d>")
        check(teams?.service == .teams && teams?.nativeURL?.absoluteString.hasPrefix("msteams:/l/meetup-join/") == true, "visio : Teams et son application")
        check(service("https://acme.webex.com/acme/j.php?MTID=m8b2f") == .webex, "visio : Webex")
        check(service("https://app.slack.com/huddle/T01ABCDEF/C02GHIJKL") == .slack, "visio : Slack Huddle")
        check(service("https://facetime.apple.com/join#v=1&p=AbC&k=dEf") == .faceTime, "visio : FaceTime")
        check(service("https://join.skype.com/AbCdEf123") == .skype, "visio : Skype")
        check(service("https://whereby.com/equipe-produit") == .whereby, "visio : Whereby")
        check(service("https://around.co/r/abc") == .around, "visio : Around")
        check(service("https://meet.jit.si/PrismStandup") == .jitsi, "visio : Jitsi")
        check(service("https://global.gotomeeting.com/join/123456789") == .goToMeeting, "visio : GoTo Meeting")
        check(service("https://bluejeans.com/123456789") == .blueJeans, "visio : BlueJeans")
        check(service("https://chime.aws/1234567890") == .chime, "visio : Amazon Chime")
        let wrapped = MeetingLink.find(in: "https://eur01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fzoom.us%2Fj%2F999888777&data=05%7C01")
        check(wrapped?.service == .zoom && wrapped?.url.absoluteString == "https://zoom.us/j/999888777", "visio : lien Outlook déballé")
        check(MeetingLink.find(in: "Agenda : https://example.com/ordre-du-jour") == nil, "visio : lien ordinaire ignoré")
        let first = MeetingLink.detect(url: URL(string: "https://meet.jit.si/Equipe"), location: "https://zoom.us/j/1", notes: nil)
        check(first?.service == .jitsi, "visio : le lien de l’évènement passe avant le lieu")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .current
        calendar.locale = Locale(identifier: "fr_FR")
        calendar.firstWeekday = 2
        func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)) ?? Date()
        }
        let now = date(14, 10, 2) // mercredi 14 octobre 2026, 10 h 02
        check(RelativeDay.title(for: date(14, 18), now: now, calendar: calendar) == "Aujourd’hui", "jour : aujourd’hui")
        check(RelativeDay.title(for: date(15, 9), now: now, calendar: calendar) == "Demain", "jour : demain")
        check(RelativeDay.title(for: date(16, 9), now: now, calendar: calendar) == "Vendredi", "jour : nom du jour cette semaine")
        check(RelativeDay.title(for: date(22, 9), now: now, calendar: calendar) == "Jeudi 22 octobre", "jour : date au-delà d’une semaine")
        check(RelativeDay.title(for: date(13, 9), now: now, calendar: calendar) == "Hier", "jour : hier")

        func event(_ id: String, _ start: Date, _ minutes: Int, allDay: Bool = false, declined: Bool = false) -> AgendaEvent {
            AgendaEvent(
                id: id, title: id, start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)), isAllDay: allDay,
                calendarID: "c", calendarTitle: "Travail", calendarColor: .systemBlue,
                attendees: declined ? [AgendaEvent.Attendee(name: "Moi", response: .declined, isMe: true)] : []
            )
        }
        let events = [
            event("fini", date(14, 8), 30),
            event("revue", date(14, 15), 60),
            event("conf", date(13, 0), 3 * 24 * 60, allDay: true),
            event("standup", date(15, 9, 30), 15),
            event("ferie", date(15, 0), 24 * 60, allDay: true),
            event("atelier", date(20, 10), 120),
        ]
        let groups = AgendaGrouping.group(events, now: now, calendar: calendar)
        check(groups.map(\.title) == ["Aujourd’hui", "Demain", "Mardi"], "regroupement : un groupe par jour")
        check(groups.first?.events.map(\.id) == ["conf", "revue"], "regroupement : évènements finis retirés, journée entière en tête")
        check(groups.dropFirst().first?.events.map(\.id) == ["ferie", "standup"], "regroupement : ordre dans la journée")

        let soon = [event("bientot", date(14, 10, 10), 30), event("refusee", date(14, 10, 5), 30, declined: true)]
        check(AgendaGrouping.nextMeeting(soon, now: now, within: 10 * 60)?.id == "bientot", "prochaine réunion : refusée ignorée")
        check(AgendaGrouping.nextMeeting(soon, now: now, within: 5 * 60) == nil, "prochaine réunion : hors du délai")
        let ongoing = [event("encours", date(14, 9, 45), 60), event("apres", date(14, 11), 30)]
        check(AgendaGrouping.nextMeeting(ongoing, now: now, within: 30 * 60)?.id == "encours", "prochaine réunion : la réunion en cours")

        let busy = [
            DateInterval(start: date(14, 10, 30), end: date(14, 11)),
            DateInterval(start: date(14, 10, 45), end: date(14, 12)),
            DateInterval(start: date(14, 14), end: date(14, 15)),
            DateInterval(start: date(14, 17, 50), end: date(14, 18, 30)),
        ]
        let slots = FreeSlots.compute(busy: busy, day: now, workStart: 9, workEnd: 18, now: now, calendar: calendar)
        let expected = [
            DateInterval(start: date(14, 10, 5), end: date(14, 10, 30)),
            DateInterval(start: date(14, 12), end: date(14, 14)),
            DateInterval(start: date(14, 15), end: date(14, 17, 50)),
        ]
        check(slots == expected, "créneaux libres : chevauchements fusionnés, départ arrondi à l’heure actuelle")
        let tomorrow = FreeSlots.compute(busy: [], day: date(15, 12), workStart: 9, workEnd: 18, now: now, calendar: calendar)
        check(tomorrow == [DateInterval(start: date(15, 9), end: date(15, 18))], "créneaux libres : journée entière le lendemain")
        check(FreeSlots.text(expected, day: now, calendar: calendar).hasPrefix("Mes disponibilités le mercredi 14 octobre :\n• 10:05 – 10:30"), "créneaux libres : texte copié")
        check(AgendaFormat.duration(5_400) == "1 h 30" && AgendaFormat.duration(2_700) == "45 min" && AgendaFormat.duration(3_600) == "1 h", "durées")
        check(AgendaItems.cleanNotes("Bonjour<br>à tous&nbsp;!\n________________\nFin") == "Bonjour\nà tous !\n---\nFin", "notes d’invitation nettoyées")
    }
}

// MARK: - Réglages

struct CalendarSettingsView: View {
    @ObservedObject private var settings = CalendarSettings.shared
    @State private var status = CalendarService.shared.statusDescription
    @State private var authorized = CalendarService.shared.isAuthorized

    var body: some View {
        let calendars = authorized ? CalendarService.shared.calendars : []
        Form {
            Section {
                LabeledContent("Accès au calendrier") {
                    HStack(spacing: 10) {
                        if authorized {
                            Label(status, systemImage: "checkmark.circle.fill").foregroundStyle(Palette.green)
                        } else {
                            Text(status).foregroundStyle(.secondary)
                            Button("Autoriser l’accès…") {
                                CalendarService.shared.requestAccess { _ in
                                    status = CalendarService.shared.statusDescription
                                    authorized = CalendarService.shared.isAuthorized
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Autorisation")
            } footer: {
                Text("Prism lit vos évènements sur votre Mac, sans rien envoyer sur le réseau.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("Calendriers affichés") {
                if calendars.isEmpty {
                    Text("Autorisez l’accès pour choisir les calendriers.").foregroundStyle(.secondary)
                }
                ForEach(calendars) { item in
                    Toggle(isOn: Binding(
                        get: { !settings.hiddenCalendars.contains(item.id) },
                        set: { shown in
                            settings.hiddenCalendars.removeAll { $0 == item.id }
                            if !shown { settings.hiddenCalendars.append(item.id) }
                        }
                    )) {
                        HStack(spacing: 8) {
                            Circle().fill(Color(nsColor: item.color)).frame(width: 10, height: 10)
                            Text(item.title)
                            Text(item.source).foregroundStyle(.secondary).font(.system(size: 11.5))
                        }
                    }
                }
            }

            Section("Recherche principale") {
                Toggle("Afficher la réunion en cours ou à venir", isOn: $settings.showInRoot)
                Picker("Apparaît", selection: $settings.rootLeadMinutes) {
                    ForEach([2, 5, 10, 15, 20, 30], id: \.self) { minutes in
                        Text("\(minutes) minutes avant").tag(minutes)
                    }
                }
                .disabled(!settings.showInRoot)
            }

            Section {
                Picker("Ouvrir Google Meet dans", selection: $settings.meetBrowser) {
                    Text("Le navigateur par défaut").tag("")
                    ForEach(MeetBrowsers.installed, id: \.id) { browser in
                        Text(browser.name).tag(browser.id)
                    }
                }
            } header: {
                Text("Visioconférence")
            } footer: {
                Text("Zoom et Microsoft Teams s’ouvrent dans leur application quand elle est installée, les autres services dans le navigateur.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            CalendarMenuBarSettingsSection()

            Section("Disponibilités") {
                Picker("Début de journée", selection: $settings.workStart) {
                    ForEach(5...12, id: \.self) { Text("\($0) h").tag($0) }
                }
                Picker("Fin de journée", selection: $settings.workEnd) {
                    ForEach(14...23, id: \.self) { Text("\($0) h").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
