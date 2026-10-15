import AppKit

/// Les invitations : EventKit ne sait pas inviter, on écrit donc un fichier iCalendar (`.ics`, RFC 5545)
/// et on prépare un message Mail aux participants, que l'utilisateur relit et envoie lui-même.
@MainActor
enum CalendarInvitation {
    /// Les adresses e-mail d'une liste libre (« lea@exemple.fr, Hugo <hugo@exemple.fr> »).
    static func emails(in text: String) -> [String] {
        let pattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Le texte iCalendar de l'invitation (heures en UTC, lignes CRLF, texte échappé).
    static func ics(title: String, start: Date, end: Date, isAllDay: Bool, location: String?, url: URL?, notes: String?, attendees: [String], uid: String = UUID().uuidString, now: Date = Date()) -> String {
        func stamp(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return formatter.string(from: date)
        }
        func day(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd"
            return formatter.string(from: date)
        }
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
        }
        var lines = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Prism//Calendrier//FR", "METHOD:PUBLISH", "CALSCALE:GREGORIAN",
            "BEGIN:VEVENT", "UID:\(uid)@prism", "DTSTAMP:\(stamp(now))",
        ]
        if isAllDay {
            lines += ["DTSTART;VALUE=DATE:\(day(start))", "DTEND;VALUE=DATE:\(day(end > start ? end : start.addingTimeInterval(86_400)))"]
        } else {
            lines += ["DTSTART:\(stamp(start))", "DTEND:\(stamp(end))"]
        }
        lines.append("SUMMARY:\(escape(title))")
        if let location, !location.isEmpty { lines.append("LOCATION:\(escape(location))") }
        if let url { lines.append("URL:\(url.absoluteString)") }
        if let notes, !notes.isEmpty { lines.append("DESCRIPTION:\(escape(notes))") }
        lines += attendees.map { "ATTENDEE;ROLE=REQ-PARTICIPANT;RSVP=TRUE:mailto:\($0)" }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Prépare l'invitation dans le client mail par défaut (Mail, Gmail dans un navigateur…), sans l'envoyer.
    /// Un lien `mailto:` ne sait pas joindre de fichier : le `.ics`, rangé dans Téléchargements, est montré dans le Finder
    /// pour être glissé dans le message. (Ni le service de partage de Mail ni AppleScript n'y joignent un fichier de façon fiable.)
    static func compose(draft: CalendarService.Draft, attendees: [String]) -> ActionOutcome {
        let text = ics(title: draft.title, start: draft.start, end: draft.end, isAllDay: draft.isAllDay, location: draft.location, url: draft.url, notes: draft.notes, attendees: attendees)
        let name = String(draft.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").prefix(60))
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let file = downloads.appendingPathComponent("\(name).ics")
        let subject = "Invitation : \(draft.title)"
        // Un navigateur choisi comme client mail n'ouvre un `mailto:` que si un webmail s'y est inscrit : on ouvre Gmail directement.
        let link = mailtoHandledByBrowser
            ? gmailComposeURL(to: attendees, subject: subject, body: message(for: draft))
            : mailtoURL(to: attendees, subject: subject, body: message(for: draft))
        guard (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil, let link else {
            return .toast("Évènement créé, mais l’invitation n’a pas pu être préparée")
        }
        NSWorkspace.shared.open(link)
        NSWorkspace.shared.activateFileViewerSelecting([file])
        return .hud("Évènement créé : glissez « \(file.lastPathComponent) » dans le message")
    }

    /// Le client mail par défaut est-il un navigateur (celui qui ouvre aussi les pages web) ?
    static var mailtoHandledByBrowser: Bool {
        guard let mail = URL(string: "mailto:a@example.com"), let web = URL(string: "https://example.com"),
              let mailApp = NSWorkspace.shared.urlForApplication(toOpen: mail) else { return false }
        return mailApp == NSWorkspace.shared.urlForApplication(toOpen: web)
    }

    /// La fenêtre de rédaction de Gmail, pré-remplie.
    static func gmailComposeURL(to recipients: [String], subject: String, body: String) -> URL? {
        var components = URLComponents(string: "https://mail.google.com/mail/")
        components?.queryItems = [
            URLQueryItem(name: "view", value: "cm"), URLQueryItem(name: "fs", value: "1"),
            URLQueryItem(name: "to", value: recipients.joined(separator: ",")),
            URLQueryItem(name: "su", value: subject), URLQueryItem(name: "body", value: body),
        ]
        return components?.url
    }

    /// Le texte du message.
    static func message(for draft: CalendarService.Draft) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateStyle = .full
        formatter.timeStyle = draft.isAllDay ? .none : .short
        return "Bonjour,\n\nJe vous invite à « \(draft.title) », \(formatter.string(from: draft.start)).\(draft.location.map { "\nLieu : \($0)" } ?? "")\(draft.url.map { "\nLien : \($0.absoluteString)" } ?? "")\n\nL’invitation est jointe (fichier .ics) : ouvrez-la pour l’ajouter à votre calendrier."
    }

    /// Un lien `mailto:` (RFC 6068) : destinataires, objet et texte encodés.
    static func mailtoURL(to recipients: [String], subject: String, body: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#,;/:")
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let to = recipients.map { $0.addingPercentEncoding(withAllowedCharacters: allowed.union(CharacterSet(charactersIn: "@"))) ?? $0 }.joined(separator: ",")
        return URL(string: "mailto:\(to)?subject=\(encode(subject))&body=\(encode(body.replacingOccurrences(of: "\n", with: "\r\n")))")
    }
}
