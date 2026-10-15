import Foundation

/// Fuseaux horaires, heures et dates, en français comme en anglais :
/// « heure à Tokyo », « 5pm ldn in sf », « décalage Paris », « dans 4 heures », « lundi dans 3 semaines »,
/// « jours jusqu’à Noël », « 5 août + 5 jours », « 145 min en durée », « heures ouvrées en 2026 ».
enum CalcTime {
    // MARK: - Villes

    /// Identifiant de fuseau : noms (français, anglais), abréviations et codes d'aéroports.
    private static let cityTable: [(zone: String, names: [String])] = [
        ("Europe/Paris", ["paris", "cdg", "orly", "ory", "france", "lyon", "marseille", "toulouse", "nice", "bordeaux", "lille", "nantes", "strasbourg", "montpellier", "rennes"]),
        ("Europe/London", ["londres", "london", "ldn", "lhr", "lgw", "royaume-uni", "uk", "angleterre", "england", "manchester", "edimbourg", "edinburgh", "glasgow", "liverpool"]),
        ("Europe/Dublin", ["dublin", "irlande", "ireland"]),
        ("Europe/Lisbon", ["lisbonne", "lisbon", "lis", "porto", "portugal"]),
        ("Europe/Madrid", ["madrid", "mad", "barcelone", "barcelona", "bcn", "espagne", "spain", "seville", "valence", "valencia"]),
        ("Europe/Brussels", ["bruxelles", "brussels", "bru", "belgique", "belgium", "anvers", "antwerp", "liege"]),
        ("Europe/Amsterdam", ["amsterdam", "ams", "pays-bas", "netherlands", "rotterdam", "la haye", "the hague"]),
        ("Europe/Luxembourg", ["luxembourg"]),
        ("Europe/Berlin", ["berlin", "ber", "allemagne", "germany", "munich", "muc", "francfort", "frankfurt", "fra", "hambourg", "hamburg", "cologne", "koln"]),
        ("Europe/Zurich", ["zurich", "zrh", "geneve", "geneva", "gva", "suisse", "switzerland", "berne", "bern", "lausanne", "bale", "basel"]),
        ("Europe/Vienna", ["vienne", "vienna", "vie", "autriche", "austria"]),
        ("Europe/Rome", ["rome", "roma", "fco", "italie", "italy", "milan", "mxp", "naples", "florence", "venise", "venice", "turin"]),
        ("Europe/Monaco", ["monaco"]),
        ("Europe/Prague", ["prague", "praha", "prg", "tchequie", "czechia"]),
        ("Europe/Warsaw", ["varsovie", "warsaw", "waw", "pologne", "poland", "cracovie", "krakow"]),
        ("Europe/Budapest", ["budapest", "hongrie", "hungary"]),
        ("Europe/Copenhagen", ["copenhague", "copenhagen", "cph", "danemark", "denmark"]),
        ("Europe/Stockholm", ["stockholm", "arn", "suede", "sweden"]),
        ("Europe/Oslo", ["oslo", "norvege", "norway"]),
        ("Europe/Helsinki", ["helsinki", "finlande", "finland"]),
        ("Europe/Athens", ["athenes", "athens", "ath", "grece", "greece"]),
        ("Europe/Istanbul", ["istanbul", "ist", "turquie", "turkey", "ankara"]),
        ("Europe/Bucharest", ["bucarest", "bucharest", "roumanie", "romania"]),
        ("Europe/Sofia", ["sofia", "bulgarie", "bulgaria"]),
        ("Europe/Kyiv", ["kiev", "kyiv", "ukraine"]),
        ("Europe/Moscow", ["moscou", "moscow", "svo", "russie", "russia", "saint-petersbourg", "st petersburg"]),
        ("Atlantic/Reykjavik", ["reykjavik", "islande", "iceland"]),
        ("Africa/Casablanca", ["casablanca", "maroc", "morocco", "rabat", "marrakech"]),
        ("Africa/Algiers", ["alger", "algiers", "algerie", "algeria"]),
        ("Africa/Tunis", ["tunis", "tunisie", "tunisia"]),
        ("Africa/Cairo", ["le caire", "caire", "cairo", "egypte", "egypt"]),
        ("Africa/Dakar", ["dakar", "senegal"]),
        ("Africa/Abidjan", ["abidjan", "cote d'ivoire", "ivory coast"]),
        ("Africa/Lagos", ["lagos", "nigeria"]),
        ("Africa/Nairobi", ["nairobi", "kenya"]),
        ("Africa/Johannesburg", ["johannesburg", "jnb", "afrique du sud", "south africa", "le cap", "cape town", "pretoria"]),
        ("Indian/Reunion", ["la reunion", "reunion", "saint-denis de la reunion"]),
        ("Indian/Mauritius", ["maurice", "ile maurice", "mauritius"]),
        ("Asia/Dubai", ["dubai", "dxb", "abou dabi", "abu dhabi", "emirats", "uae"]),
        ("Asia/Qatar", ["doha", "qatar"]),
        ("Asia/Riyadh", ["riyad", "riyadh", "arabie saoudite", "saudi arabia", "djeddah", "jeddah"]),
        ("Asia/Jerusalem", ["jerusalem", "tel aviv", "tlv", "israel"]),
        ("Asia/Beirut", ["beyrouth", "beirut", "liban", "lebanon"]),
        ("Asia/Tehran", ["teheran", "tehran", "iran"]),
        ("Asia/Karachi", ["karachi", "pakistan", "lahore", "islamabad"]),
        ("Asia/Kolkata", ["inde", "india", "bombay", "mumbai", "bom", "delhi", "new delhi", "del", "bangalore", "bengaluru", "calcutta", "kolkata", "chennai", "hyderabad", "ist"]),
        ("Asia/Kathmandu", ["katmandou", "kathmandu", "nepal"]),
        ("Asia/Dhaka", ["dacca", "dhaka", "bangladesh"]),
        ("Asia/Bangkok", ["bangkok", "bkk", "thailande", "thailand"]),
        ("Asia/Ho_Chi_Minh", ["ho chi minh", "saigon", "hanoi", "vietnam"]),
        ("Asia/Jakarta", ["jakarta", "indonesie", "indonesia"]),
        ("Asia/Singapore", ["singapour", "singapore", "sin"]),
        ("Asia/Kuala_Lumpur", ["kuala lumpur", "malaisie", "malaysia"]),
        ("Asia/Manila", ["manille", "manila", "philippines"]),
        ("Asia/Hong_Kong", ["hong kong", "hongkong", "hkg"]),
        ("Asia/Shanghai", ["shanghai", "pvg", "pekin", "beijing", "pek", "chine", "china", "shenzhen", "canton", "guangzhou"]),
        ("Asia/Taipei", ["taipei", "taiwan"]),
        ("Asia/Seoul", ["seoul", "icn", "coree", "korea", "coree du sud", "south korea"]),
        ("Asia/Tokyo", ["tokyo", "nrt", "hnd", "japon", "japan", "osaka", "kyoto", "jst"]),
        ("Australia/Perth", ["perth"]),
        ("Australia/Adelaide", ["adelaide"]),
        ("Australia/Darwin", ["darwin"]),
        ("Australia/Brisbane", ["brisbane", "bne", "gold coast"]),
        ("Australia/Sydney", ["sydney", "syd", "australie", "australia", "canberra"]),
        ("Australia/Melbourne", ["melbourne", "mel"]),
        ("Pacific/Auckland", ["auckland", "akl", "nouvelle-zelande", "new zealand", "wellington"]),
        ("Pacific/Noumea", ["noumea", "nouvelle-caledonie", "new caledonia"]),
        ("Pacific/Tahiti", ["tahiti", "papeete", "polynesie"]),
        ("Pacific/Honolulu", ["honolulu", "hnl", "hawai", "hawaii"]),
        ("America/Anchorage", ["anchorage", "alaska"]),
        ("America/Los_Angeles", ["los angeles", "la", "lax", "san francisco", "sf", "sfo", "seattle", "sea", "san diego", "las vegas", "vegas", "portland", "san jose", "silicon valley", "californie", "california", "pst", "pdt", "pt"]),
        ("America/Vancouver", ["vancouver", "yvr"]),
        ("America/Phoenix", ["phoenix", "arizona"]),
        ("America/Denver", ["denver", "den", "salt lake city", "mst", "mdt"]),
        ("America/Chicago", ["chicago", "ord", "dallas", "dfw", "houston", "iah", "austin", "nouvelle-orleans", "new orleans", "minneapolis", "cst", "cdt", "ct"]),
        ("America/Mexico_City", ["mexico", "mexico city", "mex", "mexique"]),
        ("America/New_York", ["new york", "nyc", "ny", "jfk", "lga", "ewr", "boston", "bos", "washington", "dc", "miami", "mia", "atlanta", "atl", "philadelphie", "philadelphia", "detroit", "est", "edt", "et"]),
        ("America/Toronto", ["toronto", "yyz", "ottawa"]),
        ("America/Montreal", ["montreal", "yul", "quebec"]),
        ("America/Halifax", ["halifax"]),
        ("America/Havana", ["la havane", "havana", "cuba"]),
        ("America/Martinique", ["martinique", "fort-de-france"]),
        ("America/Guadeloupe", ["guadeloupe", "pointe-a-pitre"]),
        ("America/Cayenne", ["cayenne", "guyane"]),
        ("America/Bogota", ["bogota", "colombie", "colombia"]),
        ("America/Lima", ["lima", "perou", "peru"]),
        ("America/Caracas", ["caracas", "venezuela"]),
        ("America/Santiago", ["santiago", "chili", "chile"]),
        ("America/Argentina/Buenos_Aires", ["buenos aires", "argentine", "argentina"]),
        ("America/Sao_Paulo", ["sao paulo", "gru", "rio", "rio de janeiro", "bresil", "brazil", "brasilia"]),
        ("America/Montevideo", ["montevideo", "uruguay"]),
        ("UTC", ["utc", "gmt", "zulu", "z"]),
    ]

    /// Le nom affiché des abréviations courantes.
    private static let abbreviations: [String: String] = [
        "sf": "San Francisco", "sfo": "San Francisco", "la": "Los Angeles", "lax": "Los Angeles", "nyc": "New York", "ny": "New York",
        "jfk": "New York", "ldn": "Londres", "lhr": "Londres", "dc": "Washington", "cdg": "Paris", "hkg": "Hong Kong",
    ]

    private static let cities: [String: (name: String, zone: TimeZone)] = {
        var table: [String: (String, TimeZone)] = [:]
        for (identifier, names) in cityTable {
            guard let zone = TimeZone(identifier: identifier) else { continue }
            let first = names.first.map { $0.count <= 3 ? $0.uppercased() : $0.capitalized } ?? identifier
            for name in names {
                // Une ville nommée garde son nom ; une abréviation prend celui de sa ville.
                let display = abbreviations[name] ?? (name.count > 3 ? name.capitalized : first)
                table[name.normalizedForSearch] = (display, zone)
            }
        }
        return table
    }()

    /// Une ville, un pays ou une abréviation de fuseau.
    static func city(_ text: String) -> (name: String, zone: TimeZone)? {
        let key = text.normalizedForSearch.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !key.isEmpty else { return nil }
        if let found = cities[key] { return found }
        // Un identifiant de fuseau tel quel : « Europe/Paris ».
        if let zone = TimeZone(identifier: text.trimmingCharacters(in: .whitespaces)) {
            return (zone.identifier.components(separatedBy: "/").last?.replacingOccurrences(of: "_", with: " ") ?? zone.identifier, zone)
        }
        if let zone = TimeZone(abbreviation: key.uppercased()) { return (key.uppercased(), zone) }
        return nil
    }

    // MARK: - Heures et durées

    /// « 5pm », « 5 pm », « 17h », « 17h30 », « 17:30 », « 5:30pm », « midi », « minuit », « noon ».
    static func clock(_ text: String) -> (hour: Int, minute: Int)? {
        let t = text.normalizedForSearch.replacingOccurrences(of: " ", with: "")
        switch t {
        case "midi", "noon": return (12, 0)
        case "minuit", "midnight": return (0, 0)
        default: break
        }
        let pattern = #"^(\d{1,2})(?:(?:h|:)(\d{2})?)?(am|pm)?$"#
        guard let match = t.range(of: pattern, options: .regularExpression), match.lowerBound == t.startIndex else { return nil }
        let groups = captures(t, pattern)
        guard var hour = Int(groups[0]) else { return nil }
        let minute = Int(groups[1]) ?? 0
        let suffix = groups[2]
        // Un nombre seul n'est une heure qu'avec « h », « : », am ou pm.
        guard t.contains("h") || t.contains(":") || !suffix.isEmpty else { return nil }
        if suffix == "pm", hour < 12 { hour += 12 }
        if suffix == "am", hour == 12 { hour = 0 }
        guard hour < 24, minute < 60 else { return nil }
        return (hour, minute)
    }

    private static let durationUnits: [String: Calendar.Component] = [
        "s": .second, "sec": .second, "seconde": .second, "secondes": .second, "second": .second, "seconds": .second,
        "min": .minute, "mins": .minute, "minute": .minute, "minutes": .minute, "mn": .minute,
        "h": .hour, "hr": .hour, "hrs": .hour, "heure": .hour, "heures": .hour, "hour": .hour, "hours": .hour,
        "j": .day, "jour": .day, "jours": .day, "day": .day, "days": .day, "d": .day,
        "semaine": .weekOfYear, "semaines": .weekOfYear, "sem": .weekOfYear, "week": .weekOfYear, "weeks": .weekOfYear, "w": .weekOfYear,
        "mois": .month, "month": .month, "months": .month,
        "an": .year, "ans": .year, "annee": .year, "annees": .year, "year": .year, "years": .year, "y": .year,
    ]

    /// « 4 hours », « 3 jours », « 2 semaines » ; plusieurs : « 1 h 30 min ».
    static func duration(_ text: String) -> [(Calendar.Component, Int)]? {
        let normalized = text.normalizedForSearch
        let pattern = #"(\d+)\s*([a-z]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = normalized as NSString
        let matches = regex.matches(in: normalized, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        // Tout le texte doit être fait de durées.
        let covered = matches.reduce(0) { $0 + $1.range.length }
        let significant = normalized.filter { !$0.isWhitespace && $0 != "," && $0 != "+" && $0 != "e" && $0 != "t" }.count
        guard covered >= significant - 3 else { return nil }
        var result: [(Calendar.Component, Int)] = []
        for match in matches {
            guard let amount = Int(ns.substring(with: match.range(at: 1))),
                  let component = durationUnits[ns.substring(with: match.range(at: 2))] else { return nil }
            result.append((component, amount))
        }
        return result
    }

    // MARK: - Dates

    private static let months: [String: Int] = [
        "janvier": 1, "janv": 1, "jan": 1, "january": 1, "fevrier": 2, "fev": 2, "feb": 2, "february": 2,
        "mars": 3, "mar": 3, "march": 3, "avril": 4, "avr": 4, "apr": 4, "april": 4, "mai": 5, "may": 5,
        "juin": 6, "jun": 6, "june": 6, "juillet": 7, "juil": 7, "jul": 7, "july": 7, "aout": 8, "aug": 8, "august": 8,
        "septembre": 9, "sept": 9, "sep": 9, "september": 9, "octobre": 10, "oct": 10, "october": 10,
        "novembre": 11, "nov": 11, "november": 11, "decembre": 12, "dec": 12, "december": 12,
    ]

    private static let weekdays: [String: Int] = [
        "dimanche": 1, "sunday": 1, "sun": 1, "lundi": 2, "monday": 2, "mon": 2, "mardi": 3, "tuesday": 3, "tue": 3,
        "mercredi": 4, "wednesday": 4, "wed": 4, "jeudi": 5, "thursday": 5, "thu": 5, "vendredi": 6, "friday": 6, "fri": 6,
        "samedi": 7, "saturday": 7, "sat": 7,
    ]

    /// Fêtes courantes : (mois, jour).
    private static let holidays: [String: (Int, Int)] = [
        "noel": (12, 25), "christmas": (12, 25), "xmas": (12, 25), "nouvel an": (1, 1), "jour de l'an": (1, 1), "new year": (1, 1),
        "new year's day": (1, 1), "halloween": (10, 31), "saint-valentin": (2, 14), "saint valentin": (2, 14), "valentine's day": (2, 14),
        "14 juillet": (7, 14), "fete nationale": (7, 14), "toussaint": (11, 1), "armistice": (11, 11), "fete du travail": (5, 1),
        "reveillon": (12, 31), "new year's eve": (12, 31),
    ]

    /// « 31 mars », « mar 31 », « March 31 », « 5 août 2026 », « 25/12 », « 2026-12-25 », « Noël », « demain », « lundi ».
    static func date(_ text: String, context: CalcContext, preferFuture: Bool = true) -> Date? {
        let calendar = context.calendar
        let today = calendar.startOfDay(for: context.now)
        var t = text.normalizedForSearch.trimmingCharacters(in: .whitespaces)
        for article in ["le ", "the ", "a ", "à "] where t.hasPrefix(article) { t.removeFirst(article.count) }
        switch t {
        case "aujourd'hui", "aujourd’hui", "today", "maintenant", "now": return today
        case "demain", "tomorrow": return calendar.date(byAdding: .day, value: 1, to: today)
        case "hier", "yesterday": return calendar.date(byAdding: .day, value: -1, to: today)
        case "apres-demain": return calendar.date(byAdding: .day, value: 2, to: today)
        default: break
        }
        func build(_ month: Int, _ day: Int, _ year: Int?) -> Date? {
            var components = DateComponents(year: year ?? calendar.component(.year, from: today), month: month, day: day)
            guard var date = calendar.date(from: components), calendar.component(.day, from: date) == day else { return nil }
            if year == nil, preferFuture, date < today {
                components.year = (components.year ?? 0) + 1
                date = calendar.date(from: components) ?? date
            }
            return date
        }
        if let holiday = holidays[t] { return build(holiday.0, holiday.1, nil) }
        if let weekday = weekdays[t] {
            let current = calendar.component(.weekday, from: today)
            var delta = (weekday - current + 7) % 7
            if delta == 0 { delta = 7 }
            return calendar.date(byAdding: .day, value: delta, to: today)
        }
        let iso = captures(t, #"^(\d{4})-(\d{1,2})-(\d{1,2})$"#)
        if iso.count == 3, let y = Int(iso[0]), let m = Int(iso[1]), let d = Int(iso[2]) { return build(m, d, y) }
        let slash = captures(t, #"^(\d{1,2})[/.](\d{1,2})(?:[/.](\d{2,4}))?$"#)
        if slash.count == 3, let d = Int(slash[0]), let m = Int(slash[1]) {
            var year = Int(slash[2])
            if let y = year, y < 100 { year = 2000 + y }
            // Ordre jour/mois en français, mois/jour pour une langue anglaise d'Amérique.
            if context.locale.identifier.hasPrefix("en_US") { return build(d, m, year) }
            return build(m, d, year)
        }
        let dayMonth = captures(t, #"^(\d{1,2})(?:er)?\s+([a-z]+)\.?(?:\s+(\d{4}))?$"#)
        if dayMonth.count == 3, let d = Int(dayMonth[0]), let m = months[dayMonth[1]] { return build(m, d, Int(dayMonth[2])) }
        let monthDay = captures(t, #"^([a-z]+)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?$"#)
        if monthDay.count == 3, let m = months[monthDay[0]], let d = Int(monthDay[1]) { return build(m, d, Int(monthDay[2])) }
        return nil
    }

    // MARK: - Évaluation

    static func evaluate(_ query: String, context: CalcContext) -> CalcAnswer? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = q.normalizedForSearch.replacingOccurrences(of: "’", with: "'")
        let calendar = context.calendar

        // Instants.
        switch n {
        case "now", "maintenant", "time", "heure", "l'heure", "quelle heure", "quelle heure est-il", "current time", "what time is it":
            return answer(q, time(context.now, zone: context.timeZone, context: context, withDate: true), caption: "Heure locale")
        case "today", "aujourd'hui", "date", "date du jour":
            return answer(q, day(context.now, context: context), caption: "Aujourd’hui")
        case "tomorrow", "demain":
            return answer(q, day(calendar.date(byAdding: .day, value: 1, to: context.now) ?? context.now, context: context), caption: "Demain")
        case "yesterday", "hier":
            return answer(q, day(calendar.date(byAdding: .day, value: -1, to: context.now) ?? context.now, context: context), caption: "Hier")
        case "week number", "numero de semaine", "semaine", "week", "quelle semaine":
            return answer(q, "Semaine \(calendar.component(.weekOfYear, from: context.now))", raw: "\(calendar.component(.weekOfYear, from: context.now))", caption: "Numéro de semaine (ISO)")
        case "unix", "timestamp", "now in unix", "unix time", "horodatage":
            let value = Int(context.now.timeIntervalSince1970)
            return answer(q, "\(value)", caption: "Horodatage Unix")
        default:
            break
        }

        // Horodatages Unix et ISO 8601.
        let unix = captures(n, #"^(?:unix|timestamp|horodatage)\s+(\d{9,13})$"#)
        if unix.count == 1, let value = Double(unix[0]) {
            let date = Date(timeIntervalSince1970: value > 1e11 ? value / 1000 : value)
            return answer(q, time(date, zone: context.timeZone, context: context, withDate: true), caption: "Date locale")
        }
        if q.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}"#, options: .regularExpression) != nil {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = formatter.date(from: q) ?? {
                formatter.formatOptions = [.withInternetDateTime]
                return formatter.date(from: q)
            }()
            if let date {
                return answer(q, time(date, zone: context.timeZone, context: context, withDate: true), caption: "Heure locale")
            }
        }

        // « heure à Tokyo », « time in tokyo + 4 hours », « Tokyo time ».
        let timeIn = captures(n, #"^(?:what time is it in|time in|current time in|heure (?:a|en|au)|quelle heure (?:est-il )?(?:a|en|au)|l'heure (?:a|en|au))\s+(.+)$"#)
        if timeIn.count == 1 {
            let rest = timeIn[0]
            // « time in 4 hours » : une durée, pas une ville.
            if let parts = duration(rest), let date = add(parts, to: context.now, calendar: calendar) {
                return answer(q, time(date, zone: context.timeZone, context: context, withDate: true), caption: "Dans \(rest)")
            }
            var placeText = rest
            var offset: [(Calendar.Component, Int)] = []
            var sign = 1
            for separator in [" + ", " - ", "+", "-"] where placeText.contains(separator) {
                let pieces = placeText.components(separatedBy: separator)
                if pieces.count == 2, let parts = duration(pieces[1]) {
                    placeText = pieces[0]
                    offset = parts
                    sign = separator.contains("-") ? -1 : 1
                    break
                }
            }
            // « time in 4 hours in san francisco ».
            let durationIn = captures(placeText, #"^(.+?)\s+(?:in|a|en)\s+(.+)$"#)
            if offset.isEmpty, durationIn.count == 2, let parts = duration(durationIn[0]), let place = city(durationIn[1]),
               let date = add(parts, to: context.now, calendar: calendar) {
                return answer(q, time(date, zone: place.zone, context: context, withDate: true), caption: "\(place.name), dans \(durationIn[0])")
            }
            if let place = city(placeText) {
                var date = context.now
                if !offset.isEmpty { date = add(offset.map { ($0.0, $0.1 * sign) }, to: date, calendar: calendar) ?? date }
                return answer(q, time(date, zone: place.zone, context: context, withDate: true), caption: "\(place.name) · \(offsetText(place.zone, at: date, context: context))")
            }
        }
        let suffixTime = captures(n, #"^(.+)\s+(?:time|heure)$"#)
        if suffixTime.count == 1, let place = city(suffixTime[0]) {
            return answer(q, time(context.now, zone: place.zone, context: context, withDate: true), caption: "\(place.name) · \(offsetText(place.zone, at: context.now, context: context))")
        }

        // « dans 4 heures », « in 3 days ».
        let inDuration = captures(n, #"^(?:in|dans)\s+(.+)$"#)
        if inDuration.count == 1, let parts = duration(inDuration[0]), let date = add(parts, to: context.now, calendar: calendar) {
            let onlyDays = parts.allSatisfy { [.day, .weekOfYear, .month, .year].contains($0.0) }
            return answer(q, onlyDays ? day(date, context: context) : time(date, zone: context.timeZone, context: context, withDate: true), caption: "Dans \(inDuration[0])")
        }

        // « décalage Paris », « time diff Tokyo ».
        let diff = captures(n, #"^(?:time diff(?:erence)?|diff|decalage(?: horaire)?(?: avec)?|ecart(?: avec)?)\s+(.+)$"#)
        if diff.count == 1, let place = city(diff[0]) {
            let seconds = place.zone.secondsFromGMT(for: context.now) - context.timeZone.secondsFromGMT(for: context.now)
            let hours = Double(seconds) / 3600
            let text: String
            if seconds == 0 {
                text = "Même heure"
            } else {
                let amount = Calculator.format(abs(hours))
                text = hours > 0 ? "+\(amount) h" : "−\(amount) h"
            }
            return answer(q, text, caption: "\(place.name) par rapport à ici")
        }

        // « 5pm ldn in sf », « 17h Paris en New York », « 9h en Tokyo ».
        let convert = captures(n, #"^(.+?)\s+(?:in|en|to|a|vers)\s+(.+)$"#)
        if convert.count == 2, let target = city(convert[1]) {
            let source = convert[0]
            var clockText = source
            var sourceZone = context.timeZone
            var sourceName = "ici"
            if let space = source.firstIndex(of: " "), let place = city(String(source[source.index(after: space)...])) {
                clockText = String(source[..<space])
                sourceZone = place.zone
                sourceName = place.name
            }
            if let (hour, minute) = clock(clockText) {
                var sourceCalendar = calendar
                sourceCalendar.timeZone = sourceZone
                var components = sourceCalendar.dateComponents([.year, .month, .day], from: context.now)
                components.hour = hour
                components.minute = minute
                if let date = sourceCalendar.date(from: components) {
                    return answer(q, time(date, zone: target.zone, context: context, withDate: true), caption: "\(target.name), pour \(clockText) à \(sourceName)")
                }
            }
        }

        // « lundi dans 3 semaines », « monday in 3 weeks ».
        let weekdayIn = captures(n, #"^([a-z]+)\s+(?:in|dans)\s+(\d+)\s+(semaines?|weeks?)$"#)
        if weekdayIn.count == 3, let next = date(weekdayIn[0], context: context), weekdays[weekdayIn[0]] != nil, let count = Int(weekdayIn[1]),
           let target = calendar.date(byAdding: .weekOfYear, value: count, to: next) {
            return answer(q, day(target, context: context), caption: relative(target, context: context))
        }

        // « jours jusqu’à Noël », « days until 31 Mar », « jours depuis le 1 janvier ».
        let until = captures(n, #"^(?:days until|days till|days to|jours (?:avant|jusqu'a|jusqu'au|d'ici|restants avant))\s+(.+)$"#)
        if until.count == 1, let target = date(until[0], context: context) {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: context.now), to: target).day ?? 0
            return answer(q, "\(days) jour\(abs(days) > 1 ? "s" : "")", raw: "\(days)", caption: "Jusqu’au \(day(target, context: context))")
        }
        let since = captures(n, #"^(?:days since|jours depuis)\s+(.+)$"#)
        if since.count == 1, let target = date(since[0], context: context, preferFuture: false) {
            let days = calendar.dateComponents([.day], from: target, to: calendar.startOfDay(for: context.now)).day ?? 0
            return answer(q, "\(days) jour\(abs(days) > 1 ? "s" : "")", raw: "\(days)", caption: "Depuis le \(day(target, context: context))")
        }

        // « 5 août + 5 jours », « August 5 + 5 », « 15h45 + 5 h », « 3:45pm + 5 ».
        let arithmetic = captures(n, #"^(.+?)\s*([+-])\s*(\d+)\s*([a-z]*)$"#)
        if arithmetic.count == 4, let amount = Int(arithmetic[2]) {
            let sign = arithmetic[1] == "-" ? -1 : 1
            let unitText = arithmetic[3]
            if let (hour, minute) = clock(arithmetic[0]) {
                let component = unitText.isEmpty ? Calendar.Component.hour : durationUnits[unitText]
                var components = calendar.dateComponents([.year, .month, .day], from: context.now)
                components.hour = hour
                components.minute = minute
                if let component, [.hour, .minute, .second].contains(component), let start = calendar.date(from: components),
                   let result = calendar.date(byAdding: component, value: amount * sign, to: start) {
                    return answer(q, time(result, zone: context.timeZone, context: context, withDate: false), caption: "Heure")
                }
            } else if let start = date(arithmetic[0], context: context, preferFuture: false) {
                let component = unitText.isEmpty ? Calendar.Component.day : durationUnits[unitText]
                if let component, let result = calendar.date(byAdding: component, value: amount * sign, to: start) {
                    return answer(q, day(result, context: context), caption: relative(result, context: context))
                }
            }
        }

        // « 145 min en durée », « 145 mins to timespan ».
        let span = captures(n, #"^(.+?)\s+(?:to|en|in|as)\s+(?:timespan|duree|temps|duration)$"#)
        if span.count == 1, let parts = duration(span[0]) {
            let seconds = parts.reduce(0.0) { total, part in total + Self.seconds(of: part.0) * Double(part.1) }
            return answer(q, readable(seconds), caption: "Durée")
        }

        // « heures ouvrées en 2026 », « workdays in 2026 », « 55 h en jours ouvrés ».
        let work = captures(n, #"^(workhours|work hours|heures ouvrees|heures travaillees|workdays|work days|jours ouvres|jours ouvrables)\s+(?:in|en)\s+(\d{4})$"#)
        if work.count == 2, let year = Int(work[1]) {
            let days = workdays(in: year, calendar: calendar)
            let hours = work[0].contains("heure") || work[0].contains("hour")
            return answer(q, hours ? "\(days * 8) h" : "\(days) jours", raw: "\(hours ? days * 8 : days)", caption: hours ? "Heures ouvrées en \(year) (8 h/jour)" : "Jours ouvrés en \(year), du lundi au vendredi")
        }
        let toWorkdays = captures(n, #"^(\d+(?:[.,]\d+)?)\s*(?:h|heures|hours)\s+(?:in|en)\s+(?:workdays|work days|jours ouvres|jours de travail)$"#)
        if toWorkdays.count == 1, let hours = Double(toWorkdays[0].replacingOccurrences(of: ",", with: ".")) {
            return answer(q, "\(Calculator.format(hours / 8)) jours", raw: Calculator.format(hours / 8, grouping: false), caption: "Jours ouvrés de 8 h")
        }

        // « semaine 42 ».
        let week = captures(n, #"^(?:semaine|week)\s+(\d{1,2})(?:\s+(\d{4}))?$"#)
        if week.count == 2, let number = Int(week[0]), number >= 1, number <= 53 {
            var components = DateComponents()
            components.weekOfYear = number
            components.yearForWeekOfYear = Int(week[1]) ?? calendar.component(.yearForWeekOfYear, from: context.now)
            components.weekday = 2
            if let monday = calendar.date(from: components), let sunday = calendar.date(byAdding: .day, value: 6, to: monday) {
                return answer(q, "\(short(monday, context: context)) – \(short(sunday, context: context))", caption: "Semaine \(number)")
            }
        }
        return nil
    }

    // MARK: - Outils

    static func captures(_ text: String, _ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return [] }
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
    }

    private static func add(_ parts: [(Calendar.Component, Int)], to date: Date, calendar: Calendar) -> Date? {
        var result = date
        for (component, amount) in parts {
            guard let next = calendar.date(byAdding: component, value: amount, to: result) else { return nil }
            result = next
        }
        return result
    }

    private static func seconds(of component: Calendar.Component) -> Double {
        switch component {
        case .second: 1
        case .minute: 60
        case .hour: 3_600
        case .day: 86_400
        case .weekOfYear: 604_800
        case .month: 2_629_746
        case .year: 31_556_952
        default: 0
        }
    }

    /// « 2 h 25 min », « 3 j 4 h ».
    static func readable(_ seconds: Double) -> String {
        var rest = Int(seconds.rounded())
        let units: [(Int, String)] = [(86_400, "j"), (3_600, "h"), (60, "min"), (1, "s")]
        var parts: [String] = []
        for (size, label) in units where rest >= size {
            parts.append("\(rest / size) \(label)")
            rest %= size
        }
        return parts.isEmpty ? "0 s" : parts.joined(separator: " ")
    }

    private static func workdays(in year: Int, calendar: Calendar) -> Int {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else { return 0 }
        var count = 0
        var day = start
        while day < end {
            let weekday = calendar.component(.weekday, from: day)
            if weekday != 1, weekday != 7 { count += 1 }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? end
        }
        return count
    }

    private static func time(_ date: Date, zone: TimeZone, context: CalcContext, withDate: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = context.locale
        formatter.timeZone = zone
        let sameYear = context.calendar.component(.year, from: date) == context.calendar.component(.year, from: context.now)
        formatter.setLocalizedDateFormatFromTemplate(withDate ? (sameYear ? "EEEdMMMHHmm" : "EEEdMMMyyyyHHmm") : "HHmm")
        return formatter.string(from: date)
    }

    private static func day(_ date: Date, context: CalcContext) -> String {
        let formatter = DateFormatter()
        formatter.locale = context.locale
        formatter.timeZone = context.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMMyyyy")
        return formatter.string(from: date)
    }

    private static func short(_ date: Date, context: CalcContext) -> String {
        let formatter = DateFormatter()
        formatter.locale = context.locale
        formatter.timeZone = context.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return formatter.string(from: date)
    }

    private static func relative(_ date: Date, context: CalcContext) -> String {
        let days = context.calendar.dateComponents([.day], from: context.calendar.startOfDay(for: context.now), to: context.calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "Aujourd’hui"
        case 1: return "Demain"
        case -1: return "Hier"
        case let value where value > 0: return "Dans \(value) jours"
        default: return "Il y a \(-days) jours"
        }
    }

    private static func offsetText(_ zone: TimeZone, at date: Date, context: CalcContext) -> String {
        let seconds = zone.secondsFromGMT(for: date) - context.timeZone.secondsFromGMT(for: date)
        guard seconds != 0 else { return "même heure qu’ici" }
        let hours = Calculator.format(Double(abs(seconds)) / 3600)
        return seconds > 0 ? "+\(hours) h" : "−\(hours) h"
    }

    private static func answer(_ query: String, _ result: String, raw: String? = nil, caption: String) -> CalcAnswer {
        CalcAnswer(expression: query, result: result, raw: raw ?? result, rightCaption: caption)
    }
}
