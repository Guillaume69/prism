import AppKit

// MARK: - Liens de visioconférence

/// Les services de visio reconnus dans le lien, le lieu ou les notes d'un évènement.
enum MeetingService: String, CaseIterable {
    case zoom, googleMeet, teams, webex, slack, faceTime, skype, whereby, around, jitsi
    case goToMeeting, blueJeans, chime, discord, gather, livestorm

    var title: String {
        switch self {
        case .zoom: "Zoom"
        case .googleMeet: "Google Meet"
        case .teams: "Microsoft Teams"
        case .webex: "Webex"
        case .slack: "Slack Huddle"
        case .faceTime: "FaceTime"
        case .skype: "Skype"
        case .whereby: "Whereby"
        case .around: "Around"
        case .jitsi: "Jitsi Meet"
        case .goToMeeting: "GoTo Meeting"
        case .blueJeans: "BlueJeans"
        case .chime: "Amazon Chime"
        case .discord: "Discord"
        case .gather: "Gather"
        case .livestorm: "Livestorm"
        }
    }

    /// Fin d'adresse : tout sauf les espaces, guillemets et chevrons.
    private static let tail = #"[^\s"'<>\]\)]*"#

    var pattern: String {
        let tail = Self.tail
        switch self {
        case .zoom: return #"https?://(?:[a-z0-9-]+\.)?zoom(?:gov)?\.(?:us|com)/(?:j|my|w|s|wc/join)/"# + tail
        case .googleMeet: return #"https?://meet\.google\.com/(?:[a-z]{3}-[a-z]{4}-[a-z]{3}|lookup/[a-z0-9]+)"# + tail
        case .teams: return #"https?://teams\.(?:microsoft|live)\.com/(?:l/meetup-join|meet|v2/\?meetingjoin)"# + tail
        case .webex: return #"https?://[a-z0-9-]+\.webex\.com/"# + tail
        case .slack: return #"https?://app\.slack\.com/huddle/[a-z0-9]+/[a-z0-9]+"# + tail
        case .faceTime: return #"https?://facetime\.apple\.com/join"# + tail
        case .skype: return #"https?://join\.skype\.com/[a-z0-9]+"# + tail
        case .whereby: return #"https?://(?:[a-z0-9-]+\.)?whereby\.com/[a-z0-9]"# + tail
        case .around: return #"https?://(?:meet\.)?around\.co/[a-z0-9]"# + tail
        case .jitsi: return #"https?://meet\.jit\.si/[a-z0-9]"# + tail
        case .goToMeeting: return #"https?://(?:www\.)?(?:global\.gotomeeting\.com/join|gotomeet\.me|meet\.goto\.com|app\.goto\.com/meeting)/"# + tail
        case .blueJeans: return #"https?://(?:[a-z0-9-]+\.)?bluejeans\.com/[0-9]"# + tail
        case .chime: return #"https?://(?:app\.)?chime\.aws/(?:meetings/)?[0-9a-z]"# + tail
        case .discord: return #"https?://(?:www\.)?discord(?:app)?\.(?:com|gg)/(?:invite/|channels/)?[a-z0-9]"# + tail
        case .gather: return #"https?://app\.gather\.town/app/"# + tail
        case .livestorm: return #"https?://app\.livestorm\.co/"# + tail
        }
    }

    fileprivate var regex: NSRegularExpression? {
        MeetingService.regexes[self]
    }

    private static let regexes: [MeetingService: NSRegularExpression] = Dictionary(uniqueKeysWithValues: allCases.compactMap { service in
        (try? NSRegularExpression(pattern: service.pattern, options: [.caseInsensitive])).map { (service, $0) }
    })
}

/// Un lien de visio trouvé dans un évènement.
struct MeetingLink: Equatable {
    let service: MeetingService
    let url: URL

    /// Le lien de l'évènement d'abord, puis le lieu, puis les notes.
    static func detect(url: URL?, location: String?, notes: String?) -> MeetingLink? {
        for text in [url?.absoluteString, location, notes] {
            if let text, let link = find(in: text) { return link }
        }
        return nil
    }

    /// Le premier lien de visio du texte, y compris derrière les redirections d'Outlook et de Google.
    static func find(in text: String) -> MeetingLink? {
        let unwrapped = unwrapRedirects(in: text)
        for candidate in [text] + unwrapped {
            var best: (range: NSRange, service: MeetingService)?
            let whole = NSRange(candidate.startIndex..., in: candidate)
            for service in MeetingService.allCases {
                guard let match = service.regex?.firstMatch(in: candidate, range: whole) else { continue }
                if best.map({ match.range.location < $0.range.location }) ?? true {
                    best = (match.range, service)
                }
            }
            if let best, let range = Range(best.range, in: candidate) {
                var string = String(candidate[range])
                while let last = string.last, ".,;:!?".contains(last) { string.removeLast() }
                if let url = URL(string: string) { return MeetingLink(service: best.service, url: url) }
            }
        }
        return nil
    }

    /// Les adresses cachées derrière « safelinks.protection.outlook.com/?url= » et « google.com/url?q= ».
    private static func unwrapRedirects(in text: String) -> [String] {
        guard text.contains("safelinks.protection.outlook.com") || text.contains("google.com/url") else { return [] }
        let pattern = #"https?://(?:[a-z0-9.-]*safelinks\.protection\.outlook\.com|www\.google\.com/url)/?\?[^\s"'<>]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text),
                  let components = URLComponents(string: String(text[range])) else { return nil }
            return components.queryItems?.first { $0.name == "url" || $0.name == "q" }?.value
        }
    }

    /// L'adresse de l'application native, quand le service en a une (Zoom, Teams).
    var nativeURL: URL? {
        switch service {
        case .zoom:
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let range = components.path.range(of: "/j/") else { return nil }
            let number = components.path[range.upperBound...].prefix { $0.isNumber }
            guard !number.isEmpty else { return nil }
            var native = URLComponents()
            native.scheme = "zoommtg"
            native.host = components.host ?? "zoom.us"
            native.path = "/join"
            native.queryItems = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: String(number))]
                + (components.queryItems?.filter { $0.name == "pwd" } ?? [])
            return native.url
        case .teams:
            let string = url.absoluteString
            guard let range = string.range(of: "://") else { return nil }
            let rest = string[range.upperBound...].drop { $0 != "/" }
            return URL(string: "msteams:" + rest)
        default:
            return nil
        }
    }
}

// MARK: - Évènements

/// Un évènement, copié depuis EventKit (ou les données de démonstration) pour l'affichage.
struct AgendaEvent: Identifiable {
    enum Response: Equatable {
        case unknown, pending, accepted, declined, tentative

        var label: String {
            switch self {
            case .unknown: "—"
            case .pending: "En attente"
            case .accepted: "Acceptée"
            case .declined: "Refusée"
            case .tentative: "Peut-être"
            }
        }
    }

    struct Attendee {
        var name: String
        var email: String?
        var response: Response
        var isMe = false
        var isOrganizer = false
    }

    let id: String
    var eventIdentifier: String?
    var externalIdentifier: String?
    var title: String
    var start: Date
    var end: Date
    var isAllDay = false
    var calendarID: String
    var calendarTitle: String
    var calendarColor: NSColor
    var location: String?
    var notes: String?
    var url: URL?
    var attendees: [Attendee] = []
    var canEdit = true
    var isRecurring = false
    var isFree = false

    var meeting: MeetingLink? { MeetingLink.detect(url: url, location: location, notes: notes) }
    var myResponse: Response? { attendees.first(where: \.isMe)?.response }
    var isOrganizer: Bool { attendees.isEmpty || attendees.contains { $0.isMe && $0.isOrganizer } }
    var isDeclined: Bool { myResponse == .declined }
    var duration: TimeInterval { end.timeIntervalSince(start) }

    func isOngoing(at now: Date) -> Bool { !isAllDay && start <= now && end > now }
}

// MARK: - Jours, durées, créneaux libres

/// Le nom d'un jour relatif à aujourd'hui : « Aujourd’hui », « Demain », « Jeudi », « Jeudi 23 octobre ».
enum RelativeDay {
    static func title(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let offset = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        switch offset {
        case 0: return "Aujourd’hui"
        case 1: return "Demain"
        case -1: return "Hier"
        default:
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = calendar.locale ?? Locale(identifier: "fr_FR")
            if abs(offset) <= 6 {
                formatter.setLocalizedDateFormatFromTemplate("EEEE")
            } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
                formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
            } else {
                formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMMyyyy")
            }
            let text = formatter.string(from: date)
            return text.prefix(1).uppercased() + text.dropFirst()
        }
    }
}

enum AgendaFormat {
    static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate("jjmm")
        return formatter.string(from: date)
    }

    static func range(_ start: Date, _ end: Date, calendar: Calendar = .current) -> String {
        "\(time(start, calendar: calendar)) – \(time(end, calendar: calendar))"
    }

    /// « 45 min », « 1 h », « 1 h 30 », « 2 jours ».
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 24 * 60, minutes % (24 * 60) == 0 {
            let days = minutes / (24 * 60)
            return days == 1 ? "1 jour" : "\(days) jours"
        }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(String(format: "%02d", rest))"
    }

    /// « Dans 8 min », « Dans 2 h », « En cours ».
    static func countdown(to event: AgendaEvent, now: Date) -> String {
        if event.isOngoing(at: now) { return "En cours" }
        let seconds = event.start.timeIntervalSince(now)
        if seconds < 60 { return "Maintenant" }
        if seconds < 3600 { return "Dans \(Int((seconds / 60).rounded(.up))) min" }
        if seconds < 12 * 3600 { return "Dans " + duration((seconds / 300).rounded() * 300) }
        return ""
    }

    /// Le jour et l'heure : « Aujourd’hui · 10:00 – 11:00 », « Demain · toute la journée ».
    static func when(_ event: AgendaEvent, now: Date, calendar: Calendar = .current) -> String {
        let day = RelativeDay.title(for: event.start, now: now, calendar: calendar)
        if event.isAllDay {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: event.start), to: calendar.startOfDay(for: event.end)).day ?? 1
            return days > 1 ? "\(day) · \(days) jours" : "\(day) · toute la journée"
        }
        return "\(day) · \(range(event.start, event.end, calendar: calendar))"
    }
}

/// Le regroupement des évènements par jour, pour « Mon agenda ».
enum AgendaGrouping {
    struct Group {
        let day: Date
        let title: String
        var events: [AgendaEvent]
    }

    /// Les évènements qui ne sont pas finis, groupés par jour (un évènement commencé avant aujourd'hui va dans
    /// « Aujourd’hui ») ; les évènements d'une journée entière en tête de leur jour.
    static func group(_ events: [AgendaEvent], now: Date, calendar: Calendar = .current) -> [Group] {
        let today = calendar.startOfDay(for: now)
        var groups: [Date: [AgendaEvent]] = [:]
        for event in events where event.end > now {
            let day = max(calendar.startOfDay(for: event.start), today)
            groups[day, default: []].append(event)
        }
        return groups.keys.sorted().map { day in
            let sorted = groups[day, default: []].sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return lhs.start == rhs.start ? lhs.title < rhs.title : lhs.start < rhs.start
            }
            return Group(day: day, title: RelativeDay.title(for: day, now: now, calendar: calendar), events: sorted)
        }
    }

    /// La réunion en cours ou la prochaine (pas une journée entière, pas refusée).
    static func nextMeeting(_ events: [AgendaEvent], now: Date, within: TimeInterval) -> AgendaEvent? {
        let candidates = events.filter { !$0.isAllDay && !$0.isDeclined && $0.end > now }
        if let ongoing = candidates.filter({ $0.isOngoing(at: now) }).max(by: { $0.start < $1.start }),
           !candidates.contains(where: { !$0.isOngoing(at: now) && $0.start.timeIntervalSince(now) <= 5 * 60 }) {
            return ongoing
        }
        return candidates.filter { $0.start > now && $0.start.timeIntervalSince(now) <= within }.min { $0.start < $1.start }
    }
}

/// Les créneaux libres d'une journée de travail.
enum FreeSlots {
    static func compute(
        busy: [DateInterval],
        day: Date,
        workStart: Int,
        workEnd: Int,
        now: Date,
        calendar: Calendar = .current,
        minimum: TimeInterval = 15 * 60
    ) -> [DateInterval] {
        let midnight = calendar.startOfDay(for: day)
        guard let open = calendar.date(byAdding: .hour, value: workStart, to: midnight),
              let close = calendar.date(byAdding: .hour, value: workEnd, to: midnight), close > open else { return [] }
        var cursor = open
        if calendar.isDate(day, inSameDayAs: now), now > cursor {
            // On arrondit aux cinq minutes suivantes : « libre à partir de 10:35 ».
            let seconds = ceil(now.timeIntervalSinceReferenceDate / 300) * 300
            cursor = Date(timeIntervalSinceReferenceDate: seconds)
        }
        var slots: [DateInterval] = []
        for interval in busy.sorted(by: { $0.start < $1.start }) where interval.end > cursor && interval.start < close {
            if interval.start > cursor {
                slots.append(DateInterval(start: cursor, end: min(interval.start, close)))
            }
            cursor = max(cursor, interval.end)
        }
        if cursor < close { slots.append(DateInterval(start: cursor, end: close)) }
        return slots.filter { $0.duration >= minimum }
    }

    /// « Mes disponibilités le mardi 14 octobre : • 09:00 – 10:30 … »
    static func text(_ slots: [DateInterval], day: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        let date = formatter.string(from: day)
        guard !slots.isEmpty else { return "Pas de créneau libre le \(date)." }
        let lines = slots.map { "• \(AgendaFormat.time($0.start, calendar: calendar)) – \(AgendaFormat.time($0.end, calendar: calendar))" }
        return "Mes disponibilités le \(date) :\n" + lines.joined(separator: "\n")
    }
}
