import AppKit
import EventKit
import SwiftUI

/// Réglages de l'agenda, dans les préférences de l'utilisateur (« calendar.* »).
@MainActor
final class CalendarSettings: ObservableObject {
    static let shared = CalendarSettings()

    private let defaults = UserDefaults.standard

    /// Calendriers masqués (identifiants EventKit).
    @Published var hiddenCalendars: [String] {
        didSet { defaults.set(hiddenCalendars, forKey: "calendar.hiddenCalendars") }
    }

    /// Montre la réunion en cours ou à venir en tête de la recherche principale.
    @Published var showInRoot: Bool {
        didSet { defaults.set(showInRoot, forKey: "calendar.showInRoot") }
    }

    /// Combien de minutes avant son début une réunion apparaît dans la recherche principale (2 à 30).
    @Published var rootLeadMinutes: Int {
        didSet { defaults.set(rootLeadMinutes, forKey: "calendar.rootLeadMinutes") }
    }

    /// Navigateur des liens Google Meet (identifiant d'application ; vide : le navigateur par défaut).
    @Published var meetBrowser: String {
        didSet { defaults.set(meetBrowser, forKey: "calendar.meetBrowser") }
    }

    /// Heures de travail, pour « Copier mes disponibilités ».
    @Published var workStart: Int {
        didSet { defaults.set(workStart, forKey: "calendar.workStart") }
    }

    @Published var workEnd: Int {
        didSet { defaults.set(workEnd, forKey: "calendar.workEnd") }
    }

    private init() {
        hiddenCalendars = defaults.stringArray(forKey: "calendar.hiddenCalendars") ?? []
        showInRoot = defaults.object(forKey: "calendar.showInRoot") as? Bool ?? true
        rootLeadMinutes = min(30, max(2, defaults.object(forKey: "calendar.rootLeadMinutes") as? Int ?? 10))
        meetBrowser = defaults.string(forKey: "calendar.meetBrowser") ?? ""
        workStart = defaults.object(forKey: "calendar.workStart") as? Int ?? 9
        workEnd = defaults.object(forKey: "calendar.workEnd") as? Int ?? 18
    }
}

/// Un calendrier, pour les filtres et les réglages.
struct AgendaCalendar: Identifiable {
    let id: String
    let title: String
    let color: NSColor
    let source: String
    let isWritable: Bool
}

/// Accès à EventKit : autorisation, évènements des 30 prochains jours en cache, création et suppression.
/// Aucune demande d'autorisation sans geste de l'utilisateur (`requestAccess`).
@MainActor
final class CalendarService {
    static let shared = CalendarService()

    private(set) var events: [AgendaEvent] = []
    private(set) var lastFetch: Date?
    private var fetching = false
    private var originals: [String: EKEvent] = [:]
    private var started = false
    private var timer: Timer?
    /// Appelé quand les évènements ont changé (écran affiché, recherche principale).
    var onChange: [String: @MainActor () -> Void] = [:]

    /// Le magasin n'est créé qu'une fois l'accès accordé.
    private lazy var store = EKEventStore()

    nonisolated static var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    var isAuthorized: Bool {
        if FeatureDemo.isActive { return true }
        return Self.status == .fullAccess
    }

    var canWrite: Bool {
        guard !FeatureDemo.isActive else { return false }
        return isAuthorized || Self.status == .writeOnly
    }

    var statusDescription: String {
        if FeatureDemo.isActive { return "Démonstration" }
        switch Self.status {
        case .fullAccess: return "Autorisé"
        case .writeOnly: return "Écriture seule : Prism ne peut pas lire vos évènements"
        case .denied: return "Refusé"
        case .restricted: return "Restreint par le système"
        case .notDetermined: return "Pas encore demandé"
        @unknown default: return "Inconnu"
        }
    }

    // MARK: Cycle de vie

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CalendarService.shared.refresh() }
        }
        // Les réunions « à venir » glissent avec l'heure : on relit régulièrement.
        let timer = Timer(timeInterval: 120, repeats: true) { _ in
            MainActor.assumeIsolated { CalendarService.shared.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    /// Demande l'accès complet (action explicite de l'utilisateur), puis charge les évènements.
    func requestAccess(completion: @escaping @MainActor (Bool) -> Void) {
        let status = Self.status
        guard status == .notDetermined || status == .writeOnly else {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
            completion(isAuthorized)
            return
        }
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let service = CalendarService.shared
                    if granted {
                        service.store = EKEventStore()
                        service.start()
                        service.refresh()
                    }
                    completion(granted)
                }
            }
        }
    }

    func refreshIfStale() {
        if let lastFetch, Date().timeIntervalSince(lastFetch) < 60 { return }
        refresh()
    }

    /// Relit les évènements en arrière-plan.
    func refresh() {
        if FeatureDemo.isActive {
            if events.isEmpty { events = CalendarDemo.events(now: Date()) }
            lastFetch = Date()
            return
        }
        guard isAuthorized, !fetching else { return }
        fetching = true
        let store = store
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 30, to: start) ?? start.addingTimeInterval(30 * 86_400)
        Task.detached(priority: .userInitiated) {
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let fetched = store.events(matching: predicate)
            let mapped = fetched.map(CalendarService.agendaEvent)
            await MainActor.run {
                let service = CalendarService.shared
                service.fetching = false
                service.lastFetch = Date()
                service.originals = Dictionary(zip(mapped.map(\.id), fetched), uniquingKeysWith: { first, _ in first })
                service.events = mapped
                service.onChange.values.forEach { $0() }
            }
        }
    }

    /// Recopie un évènement d'EventKit.
    nonisolated static func agendaEvent(_ event: EKEvent) -> AgendaEvent {
        let start = event.startDate ?? Date()
        let attendees = (event.attendees ?? []).map { participant -> AgendaEvent.Attendee in
            let address = participant.url.absoluteString
            let email = address.lowercased().hasPrefix("mailto:") ? String(address.dropFirst(7)) : nil
            return AgendaEvent.Attendee(
                name: participant.name ?? email ?? "Participant",
                email: email,
                response: response(participant.participantStatus),
                isMe: participant.isCurrentUser,
                isOrganizer: participant.participantRole == .chair || (event.organizer.map { $0.url == participant.url } ?? false)
            )
        }
        var all = attendees
        if let organizer = event.organizer, !attendees.contains(where: { $0.isOrganizer }) {
            let address = organizer.url.absoluteString
            all.insert(AgendaEvent.Attendee(
                name: organizer.name ?? "Organisateur",
                email: address.lowercased().hasPrefix("mailto:") ? String(address.dropFirst(7)) : nil,
                response: .accepted,
                isMe: organizer.isCurrentUser,
                isOrganizer: true
            ), at: 0)
        }
        return AgendaEvent(
            id: (event.eventIdentifier ?? event.calendarItemIdentifier) + "@" + String(Int(start.timeIntervalSince1970)),
            eventIdentifier: event.eventIdentifier,
            externalIdentifier: event.calendarItemExternalIdentifier,
            title: event.title?.isEmpty == false ? event.title : "Sans titre",
            start: start,
            end: event.endDate ?? start,
            isAllDay: event.isAllDay,
            calendarID: event.calendar?.calendarIdentifier ?? "",
            calendarTitle: event.calendar?.title ?? "",
            calendarColor: event.calendar?.color ?? .systemBlue,
            location: event.location?.isEmpty == false ? event.location : nil,
            notes: event.notes?.isEmpty == false ? event.notes : nil,
            url: event.url,
            attendees: all,
            canEdit: event.calendar?.allowsContentModifications ?? false,
            isRecurring: event.hasRecurrenceRules,
            isFree: event.availability == .free
        )
    }

    nonisolated private static func response(_ status: EKParticipantStatus) -> AgendaEvent.Response {
        switch status {
        case .accepted, .completed, .delegated: .accepted
        case .declined: .declined
        case .tentative: .tentative
        case .pending, .inProcess: .pending
        default: .unknown
        }
    }

    // MARK: Lecture

    var calendars: [AgendaCalendar] {
        if FeatureDemo.isActive { return CalendarDemo.calendars }
        guard isAuthorized || canWrite else { return [] }
        return store.calendars(for: .event)
            .map { AgendaCalendar(id: $0.calendarIdentifier, title: $0.title, color: $0.color ?? .systemBlue, source: $0.source?.title ?? "", isWritable: $0.allowsContentModifications) }
            .sorted { $0.source == $1.source ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.source < $1.source }
    }

    var defaultCalendarID: String? {
        guard canWrite else { return nil }
        return store.defaultCalendarForNewEvents?.calendarIdentifier
    }

    /// Les évènements des calendriers affichés.
    var visibleEvents: [AgendaEvent] {
        let hidden = Set(CalendarSettings.shared.hiddenCalendars)
        return events.filter { !hidden.contains($0.calendarID) }
    }

    // MARK: Écriture

    enum Failure: LocalizedError {
        case notAuthorized, notFound, readOnly

        var errorDescription: String? {
            switch self {
            case .notAuthorized: "Prism n’a pas accès à votre calendrier."
            case .notFound: "Évènement introuvable."
            case .readOnly: "Ce calendrier est en lecture seule."
            }
        }
    }

    func delete(_ event: AgendaEvent) throws {
        guard canWrite else { throw Failure.notAuthorized }
        guard let original = originals[event.id] else { throw Failure.notFound }
        guard original.calendar?.allowsContentModifications == true else { throw Failure.readOnly }
        try store.remove(original, span: .thisEvent, commit: true)
        events.removeAll { $0.id == event.id }
        refresh()
    }

    struct Draft {
        var title: String
        var start: Date
        var end: Date
        var isAllDay = false
        var calendarID: String?
        var location: String?
        var url: URL?
        var notes: String?
        /// Minutes avant le début ; `nil` : pas d'alerte.
        var alertMinutes: Int?
        var isBusy = true
    }

    @discardableResult
    func create(_ draft: Draft) throws -> AgendaEvent {
        guard canWrite else { throw Failure.notAuthorized }
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.isAllDay = draft.isAllDay
        event.calendar = draft.calendarID.flatMap { store.calendar(withIdentifier: $0) } ?? store.defaultCalendarForNewEvents
        event.location = draft.location
        event.url = draft.url
        event.notes = draft.notes
        event.availability = draft.isBusy ? .busy : .free
        if let minutes = draft.alertMinutes {
            event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-minutes * 60)))
        }
        try store.save(event, span: .thisEvent, commit: true)
        refresh()
        return Self.agendaEvent(event)
    }

    /// Montre l'évènement dans Calendrier (ou ouvre Calendrier à défaut).
    func openInCalendar(_ event: AgendaEvent) {
        let identifier = event.eventIdentifier ?? event.externalIdentifier
        if let identifier, let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more") {
            NSWorkspace.shared.open(url)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Rejoint la visio : l'application native si elle est installée, sinon le navigateur.
    func join(_ link: MeetingLink) {
        if let native = link.nativeURL, NSWorkspace.shared.urlForApplication(toOpen: native) != nil {
            NSWorkspace.shared.open(native)
            return
        }
        let browser = CalendarSettings.shared.meetBrowser
        if link.service == .googleMeet, !browser.isEmpty, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser) {
            NSWorkspace.shared.open([link.url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        NSWorkspace.shared.open(link.url)
    }
}

/// Les navigateurs proposés pour Google Meet (seulement ceux qui sont installés).
enum MeetBrowsers {
    static let candidates: [(id: String, name: String)] = [
        ("com.apple.Safari", "Safari"),
        ("com.google.Chrome", "Google Chrome"),
        ("company.thebrowser.Browser", "Arc"),
        ("com.brave.Browser", "Brave"),
        ("com.microsoft.edgemac", "Microsoft Edge"),
        ("org.mozilla.firefox", "Firefox"),
        ("com.vivaldi.Vivaldi", "Vivaldi"),
        ("app.zen-browser.zen", "Zen"),
    ]

    static var installed: [(id: String, name: String)] {
        candidates.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }
}
