import AppKit

/// Agenda factice des rendus de démonstration (`--snapshot --demo`).
enum CalendarDemo {
    static let calendars: [AgendaCalendar] = [
        AgendaCalendar(id: "demo.work", title: "Travail", color: NSColor(srgbRed: 0.24, green: 0.55, blue: 1, alpha: 1), source: "iCloud", isWritable: true),
        AgendaCalendar(id: "demo.team", title: "Équipe produit", color: NSColor(srgbRed: 1, green: 0.58, blue: 0.25, alpha: 1), source: "Google", isWritable: true),
        AgendaCalendar(id: "demo.personal", title: "Personnel", color: NSColor(srgbRed: 0.25, green: 0.78, blue: 0.45, alpha: 1), source: "iCloud", isWritable: true),
    ]

    static func events(now: Date) -> [AgendaEvent] {
        let calendar = Calendar.current
        let base = Date(timeIntervalSinceReferenceDate: ceil(now.timeIntervalSinceReferenceDate / 300) * 300)
        let today = calendar.startOfDay(for: now)
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.date(byAdding: .day, value: day, to: today) ?? today) ?? today
        }
        func event(_ id: String, _ title: String, _ start: Date, _ minutes: Int, _ calendarIndex: Int, location: String? = nil, notes: String? = nil, url: String? = nil, attendees: [AgendaEvent.Attendee] = [], allDay: Bool = false) -> AgendaEvent {
            let source = calendars[calendarIndex]
            return AgendaEvent(
                id: "demo." + id, title: title, start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)), isAllDay: allDay,
                calendarID: source.id, calendarTitle: source.title, calendarColor: source.color,
                location: location, notes: notes, url: url.flatMap(URL.init(string:)), attendees: attendees
            )
        }
        let me = AgendaEvent.Attendee(name: "Moi", email: "moi@exemple.fr", response: .accepted, isMe: true)
        let lea = AgendaEvent.Attendee(name: "Léa Martin", email: "lea.martin@exemple.fr", response: .accepted, isOrganizer: true)
        let hugo = AgendaEvent.Attendee(name: "Hugo Bernard", email: "hugo@exemple.fr", response: .accepted)
        let ines = AgendaEvent.Attendee(name: "Inès Dubois", email: "ines.dubois@exemple.fr", response: .tentative)
        let karim = AgendaEvent.Attendee(name: "Karim Haddad", email: "karim@exemple.fr", response: .pending)
        var pendingMe = me
        pendingMe.response = .pending
        return [
            event("weekly", "Point hebdo équipe", Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 60).rounded(.up) * 60 + 6 * 60), 30, 1,
                  notes: "Ordre du jour :\n- Bêta publique\n- Retours des premiers testeurs\n- Priorités de la semaine\n\nRejoindre avec Google Meet : https://meet.google.com/xqz-ftbw-kmn",
                  attendees: [lea, me, hugo, ines, karim]),
            event("design", "Revue de design : recherche de fichiers", base.addingTimeInterval(2 * 3600), 60, 0,
                  location: "https://us02web.zoom.us/j/81234567890?pwd=Prism2026",
                  notes: "Maquettes dans le dossier partagé. Venir avec deux propositions pour l’aperçu des fichiers.",
                  attendees: [hugo, me, ines]),
            event("client", "Appel client Acme", base.addingTimeInterval(4 * 3600 + 30 * 60), 30, 0,
                  notes: "Rejoindre la réunion Microsoft Teams\nhttps://teams.microsoft.com/l/meetup-join/19%3ameeting_YmFj%40thread.v2/0",
                  attendees: [AgendaEvent.Attendee(name: "Paul Garnier", email: "paul@acme.com", response: .accepted, isOrganizer: true), pendingMe]),
            event("bday", "Anniversaire de Léa", at(0, 0), 24 * 60, 2, allDay: true),
            event("standup", "Stand-up", at(1, 9, 30), 15, 1, url: "https://app.slack.com/huddle/T01ABCDEF/C02GHIJKL", attendees: [lea, me, hugo]),
            event("lunch", "Déjeuner avec Hugo", at(1, 12, 30), 90, 2, location: "Café Marlette, 51 rue des Martyrs, Paris"),
            event("dentist", "Dentiste", at(1, 17, 15), 45, 2, location: "Cabinet du Dr Lefèvre"),
            event("roadmap", "Atelier roadmap T1", at(2, 10), 120, 1, location: "Salle Jupiter", notes: "https://acme.webex.com/acme/j.php?MTID=m8b2f", attendees: [lea, me, hugo, ines, karim]),
            event("retro", "Rétrospective", at(3, 16), 60, 1, url: "https://whereby.com/equipe-produit", attendees: [lea, me]),
            event("train", "Train pour Lyon", at(4, 8, 4), 120, 2, location: "Paris Gare de Lyon"),
        ]
    }
}
