import AppKit
import CryptoKit

/// Une entrée de l'historique du presse-papiers. Le texte et les informations vivent dans l'index
/// (`Clipboard/history.json`) ; tous les formats d'origine, dans le dossier de l'entrée.
struct ClipboardEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case text, link, email, color, image, files
    }

    struct ImageInfo: Codable, Equatable {
        var width: Int
        var height: Int
        /// Format de la donnée principale : « PNG », « TIFF », « JPEG »…
        var format: String
    }

    let id: UUID
    var kind: Kind
    /// Le texte brut (les chemins, un par ligne, pour des fichiers), limité à `indexedTextLimit` caractères.
    var text: String
    /// Dernière copie : l'ordre de l'historique.
    var date: Date
    var firstCopied: Date
    var sourceApp: String?
    var sourceBundleID: String?
    /// Nom donné par l'utilisateur (« Renommer l'entrée »).
    var name: String?
    var pinnedAt: Date?
    var copyCount: Int
    /// Empreinte du contenu, pour ne garder qu'une entrée par contenu.
    var signature: String
    /// Les formats d'origine (types du presse-papiers), tous gardés sur disque.
    var formats: [String]
    var itemCount: Int
    var byteSize: Int
    /// Nombre de caractères du texte complet (le texte de l'index peut être tronqué).
    var characterCount: Int
    var image: ImageInfo?
    var files: [String]
    var recognizedText: String?
    var barcodes: [String]
    /// La reconnaissance de texte est passée (avec ou sans résultat).
    var isRecognized: Bool

    static let indexedTextLimit = 100_000

    var isPinned: Bool { pinnedAt != nil }

    init(
        id: UUID = UUID(),
        kind: Kind,
        text: String,
        date: Date,
        sourceApp: String? = nil,
        sourceBundleID: String? = nil,
        signature: String,
        formats: [String] = [],
        itemCount: Int = 1,
        byteSize: Int = 0,
        image: ImageInfo? = nil,
        files: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.text = String(text.prefix(Self.indexedTextLimit))
        self.date = date
        firstCopied = date
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
        copyCount = 1
        self.signature = signature
        self.formats = formats
        self.itemCount = itemCount
        self.byteSize = byteSize
        characterCount = text.count
        self.image = image
        self.files = files
        barcodes = []
        isRecognized = false
    }

    // Décodage tolérant : un champ ajouté plus tard ne rend pas l'historique illisible.
    enum CodingKeys: String, CodingKey {
        case id, kind, text, date, firstCopied, sourceApp, sourceBundleID, name, pinnedAt, copyCount, signature
        case formats, itemCount, byteSize, characterCount, image, files, recognizedText, barcodes, isRecognized
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? ClipboardClassifier.kind(forText: text)
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        firstCopied = try container.decodeIfPresent(Date.self, forKey: .firstCopied) ?? date
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        pinnedAt = try container.decodeIfPresent(Date.self, forKey: .pinnedAt)
        copyCount = try container.decodeIfPresent(Int.self, forKey: .copyCount) ?? 1
        signature = try container.decodeIfPresent(String.self, forKey: .signature) ?? ClipboardSignature.text(text)
        formats = try container.decodeIfPresent([String].self, forKey: .formats) ?? []
        itemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount) ?? 1
        byteSize = try container.decodeIfPresent(Int.self, forKey: .byteSize) ?? text.utf8.count
        characterCount = try container.decodeIfPresent(Int.self, forKey: .characterCount) ?? text.count
        image = try container.decodeIfPresent(ImageInfo.self, forKey: .image)
        files = try container.decodeIfPresent([String].self, forKey: .files) ?? []
        recognizedText = try container.decodeIfPresent(String.self, forKey: .recognizedText)
        barcodes = try container.decodeIfPresent([String].self, forKey: .barcodes) ?? []
        isRecognized = try container.decodeIfPresent(Bool.self, forKey: .isRecognized) ?? false
    }

    /// Le titre affiché : le nom donné, sinon la première ligne, les dimensions de l'image ou le nom des fichiers.
    var displayTitle: String {
        if let name, !name.isEmpty { return name }
        return automaticTitle
    }

    var automaticTitle: String {
        switch kind {
        case .image:
            if let image { return "Image (\(image.width) × \(image.height))" }
            return "Image"
        case .files:
            let names = files.map { FileManager.default.displayName(atPath: $0) }
            if names.count == 1 { return names[0] }
            return "\(names.count) éléments : " + names.prefix(3).joined(separator: ", ") + (names.count > 3 ? "…" : "")
        default:
            let line = text
                .split(whereSeparator: \.isNewline)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? text
            return String(line.prefix(200))
        }
    }

    var typeLabel: String {
        switch kind {
        case .text:
            let rich = formats.contains { ClipboardClassifier.richTextTypes.contains($0) }
            return rich ? "Texte riche" : "Texte"
        case .link: return "Lien"
        case .email: return "Adresse e-mail"
        case .color: return "Couleur"
        case .image: return "Image " + (image?.format ?? "")
        case .files:
            if files.count > 1 { return "\(files.count) éléments" }
            var isDirectory: ObjCBool = false
            let exists = files.first.map { FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) } ?? false
            return exists && isDirectory.boolValue && !(files.first?.hasSuffix(".app") ?? false) ? "Dossier" : "Fichier"
        }
    }

    /// L'entrée a d'autres formats que le texte brut (texte riche, HTML) : « Coller en texte brut » a un sens.
    var hasRichText: Bool {
        formats.contains { ClipboardClassifier.richTextTypes.contains($0) }
    }

    /// Les entrées dont le contenu est du texte (modifiable, envoyable à l'IA, enregistrable en snippet).
    var isTextual: Bool { [.text, .link, .email, .color].contains(kind) }
}

// MARK: - Classement

/// Reconnaît le type d'une copie : lien, e-mail, couleur, texte, image, fichiers.
enum ClipboardClassifier {
    /// Types posés par les gestionnaires de mots de passe pour ne pas être enregistrés (nspasteboard.org).
    static let concealedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
    ]

    /// Promesses de fichiers : sans l'application qui les a faites, elles ne se recollent pas.
    static let skippedTypes: Set<String> = [
        "com.apple.NSFilePromiseItemMetaData",
        "com.apple.pasteboard.promised-file-content-type",
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-suggested-file-name",
        "NSPromiseContentsPboardType",
    ]

    static let imageTypes: [String] = [
        "public.png", "public.tiff", "public.jpeg", "public.heic", "com.compuserve.gif",
        "com.microsoft.bmp", "org.webmproject.webp",
    ]

    static let richTextTypes: Set<String> = [
        "public.rtf", "public.html", "com.apple.flat-rtfd", "com.apple.webarchive",
        "com.microsoft.word.doc", "org.openxmlformats.wordprocessingml.document",
    ]

    static let fileURLType = "public.file-url"

    static func imageFormatName(_ type: String) -> String {
        switch type {
        case "public.png": "PNG"
        case "public.tiff": "TIFF"
        case "public.jpeg": "JPEG"
        case "public.heic": "HEIC"
        case "com.compuserve.gif": "GIF"
        case "com.microsoft.bmp": "BMP"
        case "org.webmproject.webp": "WebP"
        default: type
        }
    }

    /// La donnée d'image à garder pour l'aperçu : la première dans l'ordre de préférence.
    static func mainImageType(in types: [String]) -> String? {
        imageTypes.first { types.contains($0) }
    }

    /// Le type d'une copie, d'après les types de ses éléments et son texte. `nil` : rien à garder.
    static func kind(types: [[String]], plainText: String?) -> ClipboardEntry.Kind? {
        let all = types.flatMap { $0 }
        if all.contains(fileURLType) { return .files }
        let trimmed = plainText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasImage = mainImageType(in: all) != nil
        // Une image copiée depuis un navigateur s'accompagne souvent de son adresse : c'est une image.
        if hasImage, trimmed.isEmpty || link(in: trimmed) != nil { return .image }
        if !trimmed.isEmpty { return kind(forText: trimmed) }
        return hasImage ? .image : nil
    }

    static func kind(forText text: String) -> ClipboardEntry.Kind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ParsedColor(trimmed) != nil { return .color }
        if email(in: trimmed) != nil { return .email }
        if link(in: trimmed) != nil { return .link }
        return .text
    }

    /// Un lien seul : `https://…`, `ftp://…`, `slack://…`, ou `www.exemple.fr`.
    static func link(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 4_000,
              !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        if trimmed.lowercased().hasPrefix("www."), trimmed.dropFirst(4).contains("."),
           let url = URL(string: "https://" + trimmed), url.host != nil {
            return url
        }
        guard let range = trimmed.range(of: "://"),
              let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }),
              range.upperBound < trimmed.endIndex else { return nil }
        if ["http", "https", "ftp"].contains(scheme.lowercased()) {
            guard let host = url.host, host.contains(".") || host == "localhost" else { return nil }
        }
        return url
    }

    /// Une adresse e-mail seule, avec ou sans `mailto:`.
    static func email(in text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("mailto:") { trimmed = String(trimmed.dropFirst(7)) }
        let pattern = #"^[A-Z0-9._%+'-]+@[A-Z0-9-]+(\.[A-Z0-9-]+)*\.[A-Z]{2,}$"#
        guard trimmed.count < 320, trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return trimmed
    }

    /// Symbole d'une entrée de texte : code, nombre ou texte.
    static func textSymbol(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Double(trimmed.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "")) != nil { return "number" }
        if trimmed.contains("{") || trimmed.contains("};") || trimmed.contains("=>") || trimmed.contains("</") { return "chevron.left.forwardslash.chevron.right" }
        return "text.alignleft"
    }
}

// MARK: - Couleurs

/// Une couleur écrite en CSS : `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb()`, `rgba()`, `hsl()`, `hsla()`.
struct ParsedColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init?(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") {
            guard let parsed = Self.hex(String(value.dropFirst())) else { return nil }
            self = parsed
        } else if let parsed = Self.function(value) {
            self = parsed
        } else {
            return nil
        }
    }

    private static func hex(_ digits: String) -> ParsedColor? {
        guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        let expanded = digits.count <= 4 ? digits.map { "\($0)\($0)" }.joined() : digits
        guard let number = UInt64(expanded, radix: 16) else { return nil }
        if expanded.count == 8 {
            return ParsedColor(
                red: Double((number >> 24) & 0xFF) / 255, green: Double((number >> 16) & 0xFF) / 255,
                blue: Double((number >> 8) & 0xFF) / 255, alpha: Double(number & 0xFF) / 255
            )
        }
        return ParsedColor(red: Double((number >> 16) & 0xFF) / 255, green: Double((number >> 8) & 0xFF) / 255, blue: Double(number & 0xFF) / 255)
    }

    /// `rgb(255, 0, 0)`, `rgba(255 0 0 / 50%)`, `hsl(210, 50%, 40%)`…
    private static func function(_ value: String) -> ParsedColor? {
        guard let open = value.firstIndex(of: "("), value.hasSuffix(")") else { return nil }
        let name = String(value[..<open]).trimmingCharacters(in: .whitespaces)
        guard ["rgb", "rgba", "hsl", "hsla"].contains(name) else { return nil }
        let inside = value[value.index(after: open)..<value.index(before: value.endIndex)]
        let parts = inside
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ")
            .map(String.init)
        guard parts.count == 3 || parts.count == 4 else { return nil }

        func number(_ text: String) -> (value: Double, isPercent: Bool)? {
            var text = text
            let isPercent = text.hasSuffix("%")
            if isPercent { text.removeLast() }
            if text.hasSuffix("deg") { text.removeLast(3) }
            guard let value = Double(text) else { return nil }
            return (value, isPercent)
        }
        guard let first = number(parts[0]), let second = number(parts[1]), let third = number(parts[2]) else { return nil }
        var alpha = 1.0
        if parts.count == 4 {
            guard let parsed = number(parts[3]) else { return nil }
            alpha = parsed.isPercent ? parsed.value / 100 : parsed.value
        }
        guard (0...1).contains(alpha) else { return nil }

        if name.hasPrefix("rgb") {
            func channel(_ component: (value: Double, isPercent: Bool)) -> Double? {
                let value = component.isPercent ? component.value / 100 : component.value / 255
                return (0...1).contains(value) ? value : nil
            }
            guard let red = channel(first), let green = channel(second), let blue = channel(third) else { return nil }
            return ParsedColor(red: red, green: green, blue: blue, alpha: alpha)
        }
        guard (0...100).contains(second.value), (0...100).contains(third.value) else { return nil }
        let hue = (first.value.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        let (red, green, blue) = hslToRGB(hue, second.value / 100, third.value / 100)
        return ParsedColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    private static func hslToRGB(_ hue: Double, _ saturation: Double, _ lightness: Double) -> (Double, Double, Double) {
        guard saturation > 0 else { return (lightness, lightness, lightness) }
        let q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        func component(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return (component(hue + 1 / 3), component(hue), component(hue - 1 / 3))
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private func byte(_ value: Double) -> Int { Int((value * 255).rounded()) }

    var hexString: String {
        var result = String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        if alpha < 1 { result += String(format: "%02X", byte(alpha)) }
        return result
    }

    var rgbString: String {
        alpha < 1
            ? "rgba(\(byte(red)), \(byte(green)), \(byte(blue)), \(Self.short(alpha)))"
            : "rgb(\(byte(red)), \(byte(green)), \(byte(blue)))"
    }

    var hslString: String {
        let maximum = max(red, green, blue), minimum = min(red, green, blue)
        let lightness = (maximum + minimum) / 2
        var hue = 0.0, saturation = 0.0
        let delta = maximum - minimum
        if delta > 0 {
            saturation = lightness > 0.5 ? delta / (2 - maximum - minimum) : delta / (maximum + minimum)
            if maximum == red {
                hue = (green - blue) / delta + (green < blue ? 6 : 0)
            } else if maximum == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue *= 60
        }
        let core = "\(Int(hue.rounded())), \(Int((saturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%"
        return alpha < 1 ? "hsla(\(core), \(Self.short(alpha)))" : "hsl(\(core))"
    }

    private static func short(_ value: Double) -> String {
        String(format: "%g", (value * 100).rounded() / 100)
    }
}

// MARK: - Empreintes

enum ClipboardSignature {
    static func text(_ text: String) -> String { "t:" + digest(Data(text.utf8)) }
    static func files(_ paths: [String]) -> String { "f:" + digest(Data(paths.joined(separator: "\n").utf8)) }
    static func image(_ data: Data) -> String { "i:" + digest(data) }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Filtre, recherche, rétention

/// Le filtre de type du menu déroulant (⌘P).
enum ClipboardTypeFilter: String, CaseIterable {
    case all, text, images, files, links, emails, colors

    var title: String {
        switch self {
        case .all: "Tous les types"
        case .text: "Texte"
        case .images: "Images"
        case .files: "Fichiers"
        case .links: "Liens"
        case .emails: "E-mails"
        case .colors: "Couleurs"
        }
    }

    func includes(_ kind: ClipboardEntry.Kind) -> Bool {
        switch self {
        case .all: true
        case .text: kind == .text
        case .images: kind == .image
        case .files: kind == .files
        case .links: kind == .link
        case .emails: kind == .email
        case .colors: kind == .color
        }
    }
}

enum ClipboardSearch {
    /// Le texte où chercher : contenu, nom donné, texte reconnu, noms des fichiers, application.
    static func haystack(_ entry: ClipboardEntry) -> String {
        var parts = [entry.text]
        if let name = entry.name { parts.append(name) }
        if let recognized = entry.recognizedText { parts.append(recognized) }
        parts += entry.barcodes
        parts += entry.files.map { ($0 as NSString).lastPathComponent }
        if let app = entry.sourceApp { parts.append(app) }
        if entry.kind == .image { parts.append("image") }
        return parts.joined(separator: "\n").normalizedForSearch
    }

    /// Tous les mots de la saisie doivent se trouver dans l'entrée.
    static func matches(haystack: String, query: String) -> Bool {
        let terms = query.normalizedForSearch.split(whereSeparator: \.isWhitespace)
        return terms.allSatisfy { haystack.contains($0) }
    }

    static func filter(_ entries: [ClipboardEntry], type: ClipboardTypeFilter, query: String, haystack: (ClipboardEntry) -> String = haystack) -> [ClipboardEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            type.includes(entry.kind) && (trimmed.isEmpty || matches(haystack: haystack(entry), query: trimmed))
        }
    }
}

/// Durée de conservation de l'historique.
enum ClipboardRetention: String, CaseIterable, Identifiable {
    case day, week, month, threeMonths, sixMonths, year, unlimited

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "1 jour"
        case .week: "1 semaine"
        case .month: "1 mois"
        case .threeMonths: "3 mois"
        case .sixMonths: "6 mois"
        case .year: "1 an"
        case .unlimited: "Sans limite"
        }
    }

    var interval: TimeInterval? {
        let day: TimeInterval = 86_400
        switch self {
        case .day: return day
        case .week: return 7 * day
        case .month: return 31 * day
        case .threeMonths: return 92 * day
        case .sixMonths: return 183 * day
        case .year: return 366 * day
        case .unlimited: return nil
        }
    }

    /// Les entrées à effacer : trop anciennes, ou au-delà du nombre maximal. Les épinglées restent.
    static func expired(_ entries: [ClipboardEntry], now: Date, retention: ClipboardRetention, maxCount: Int) -> Set<UUID> {
        var removed = Set<UUID>()
        let unpinned = entries.filter { !$0.isPinned }.sorted { $0.date > $1.date }
        if let interval = retention.interval {
            let cutoff = now.addingTimeInterval(-interval)
            for entry in unpinned where entry.date < cutoff { removed.insert(entry.id) }
        }
        if maxCount > 0, unpinned.count > maxCount {
            for entry in unpinned[maxCount...] { removed.insert(entry.id) }
        }
        return removed
    }
}

/// « Supprimer les entrées des 5 dernières minutes »…
enum ClipboardRecentRange: Int, CaseIterable {
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800
    case hour = 3_600
    case day = 86_400

    var title: String {
        switch self {
        case .fiveMinutes: "Des 5 dernières minutes"
        case .fifteenMinutes: "Des 15 dernières minutes"
        case .thirtyMinutes: "Des 30 dernières minutes"
        case .hour: "De la dernière heure"
        case .day: "Des dernières 24 heures"
        }
    }

    /// Les entrées copiées dans l'intervalle, épinglées exceptées.
    func ids(in entries: [ClipboardEntry], now: Date) -> [UUID] {
        let cutoff = now.addingTimeInterval(-TimeInterval(rawValue))
        return entries.filter { !$0.isPinned && $0.date >= cutoff }.map(\.id)
    }
}

// MARK: - Migration

/// L'ancien historique (`clipboard.json`) : du texte seul.
enum ClipboardMigration {
    struct LegacyEntry: Decodable {
        let id: UUID
        let text: String
        let date: Date
        let sourceApp: String?
    }

    /// Les entrées de l'ancien format, converties. `nil` si le fichier est illisible.
    static func decode(_ data: Data) -> [LegacyEntry]? {
        // Les dates de l'ancien fichier sont au format par défaut de `JSONEncoder` ; ISO 8601 par précaution.
        (try? JSONDecoder().decode([LegacyEntry].self, from: data)) ?? (try? JSONDecoder.prism.decode([LegacyEntry].self, from: data))
    }

    static func entries(fromLegacy data: Data) -> [ClipboardEntry]? {
        guard let legacy = decode(data) else { return nil }
        var seen = Set<String>()
        return legacy.compactMap { old in
            let signature = ClipboardSignature.text(old.text)
            guard seen.insert(signature).inserted else { return nil }
            return ClipboardEntry(
                id: old.id,
                kind: ClipboardClassifier.kind(forText: old.text),
                text: old.text,
                date: old.date,
                sourceApp: old.sourceApp,
                signature: signature,
                formats: [NSPasteboard.PasteboardType.string.rawValue],
                byteSize: old.text.utf8.count
            )
        }
    }
}
