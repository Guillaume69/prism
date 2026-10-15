import Foundation

/// Les catégories du sélecteur, dans l'ordre de celui de macOS, plus les symboles Unicode.
enum EmojiCategory: String, CaseIterable, Sendable {
    case smileys, people, nature, food, travel, activities, objects, symbols, flags, unicode

    var title: String {
        switch self {
        case .smileys: "Smileys et émotions"
        case .people: "Personnes"
        case .nature: "Animaux et nature"
        case .food: "Nourriture"
        case .travel: "Voyages"
        case .activities: "Activités"
        case .objects: "Objets"
        case .symbols: "Symboles"
        case .flags: "Drapeaux"
        case .unicode: "Symboles Unicode"
        }
    }
}

/// Les tons de peau (modificateurs de Fitzpatrick).
enum SkinTone: Int, CaseIterable, Sendable {
    case none, light, mediumLight, medium, mediumDark, dark

    var title: String {
        switch self {
        case .none: "Par défaut (jaune)"
        case .light: "Peau claire"
        case .mediumLight: "Peau moyennement claire"
        case .medium: "Peau intermédiaire"
        case .mediumDark: "Peau moyennement foncée"
        case .dark: "Peau foncée"
        }
    }

    var modifier: Unicode.Scalar? {
        self == .none ? nil : Unicode.Scalar(0x1F3FA + UInt32(rawValue))
    }

    /// Une main levée dans ce ton, pour les menus.
    var sample: String { EmojiCatalog.applying(self, to: "✋") }
}

struct EmojiEntry: Sendable, Identifiable {
    /// Le caractère, sans ton de peau.
    let character: String
    /// Le nom anglais, en minuscules.
    let name: String
    let frenchName: String
    let category: EmojiCategory
    /// Sous-groupe des symboles Unicode (« Flèches », « Monnaies »…).
    let group: String?
    let supportsSkinTone: Bool
    /// Mots-clés anglais et français, déjà normalisés pour la recherche.
    let keywords: [String]
    /// Noms anglais et français normalisés.
    let searchName: String
    let frenchSearchName: String

    var id: String { character }

    /// « Visage avec large sourire » : le nom affiché, avec une majuscule.
    var title: String { frenchName.prefix(1).uppercased() + frenchName.dropFirst() }

    /// Les espaces ne se voient pas dans la grille : un glyphe les représente.
    var glyph: String {
        switch character {
        case "\u{00A0}": "⍽"
        case "\u{202F}": "⎵"
        default: character
        }
    }

    /// « U+1F44B U+1F3FD » : les points de code, sans les sélecteurs de variante.
    static func codePoints(of text: String) -> String {
        text.unicodeScalars
            .filter { $0.value != 0xFE0F }
            .map { String(format: "U+%04X", $0.value) }
            .joined(separator: " ")
    }
}

/// Tous les emojis du système (noms d'Apple en anglais et en français, ordre du sélecteur),
/// puis les symboles Unicode utiles pour écrire.
enum EmojiCatalog {
    static let all: [EmojiEntry] = emojis + symbols

    static let emojis: [EmojiEntry] = {
        var entries: [EmojiEntry] = []
        entries.reserveCapacity(2_000)
        for line in EmojiData.table.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7, let category = EmojiCategory(rawValue: fields[1]) else { continue }
            let english = fields[3].lowercased()
            let french = fields[4]
            let keywords = (fields[5].split(separator: "|") + fields[6].split(separator: "|")).map { normalize(String($0)) }
            entries.append(EmojiEntry(
                character: fields[0],
                name: english,
                frenchName: french,
                category: category,
                group: nil,
                supportsSkinTone: fields[2] == "1",
                keywords: keywords,
                searchName: normalize(english),
                frenchSearchName: normalize(french)
            ))
        }
        return entries
    }()

    static let symbols: [EmojiEntry] = {
        var seen = Set<String>()
        var entries: [EmojiEntry] = []
        for group in UnicodeSymbols.groups {
            for line in group.table.split(separator: "\n") {
                let fields = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 2, !fields[0].isEmpty, seen.insert(fields[0]).inserted else { continue }
                let character = fields[0]
                let english = character.unicodeScalars.compactMap { $0.properties.name?.lowercased() }.joined(separator: " ")
                var keywords = fields.count > 2 ? fields[2].split(separator: " ").map { normalize(String($0)) } : []
                keywords.append(normalize(group.title))
                entries.append(EmojiEntry(
                    character: character,
                    name: english,
                    frenchName: fields[1],
                    category: .unicode,
                    group: group.title,
                    supportsSkinTone: false,
                    keywords: keywords,
                    searchName: normalize(english),
                    frenchSearchName: normalize(fields[1])
                ))
            }
        }
        return entries
    }()

    static let byCharacter: [String: EmojiEntry] = Dictionary(all.map { ($0.character, $0) }, uniquingKeysWith: { first, _ in first })

    /// Minuscules sans accents, ligatures défaites (« cœur » → « coeur »), apostrophes droites.
    static func normalize(_ text: String) -> String {
        text.normalizedForSearch
            .replacingOccurrences(of: "œ", with: "oe")
            .replacingOccurrences(of: "æ", with: "ae")
            .replacingOccurrences(of: "’", with: "'")
    }

    // MARK: - Tons de peau

    /// Ajoute le ton après chaque base de modificateur et retire le sélecteur de variante qui la suit :
    /// 👋 → 👋🏽, 🧑‍🤝‍🧑 → 🧑🏽‍🤝‍🧑🏽 (la poignée de main d'un couple garde sa couleur), 👍️ → 👍🏽.
    static func applying(_ tone: SkinTone, to character: String) -> String {
        guard let modifier = tone.modifier else { return character }
        let scalars = Array(character.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            result.append(scalar)
            let isHandshakeInSequence = scalar.value == 0x1F91D && scalars.count > 1
            if scalar.properties.isEmojiModifierBase, !isHandshakeInSequence {
                result.append(modifier)
                if index + 1 < scalars.count, scalars[index + 1].value == 0xFE0F { index += 1 }
            }
            index += 1
        }
        return String(result)
    }

    /// Retire un éventuel ton de peau : la clé commune de 👋 et 👋🏽.
    static func base(of character: String) -> String {
        let stripped = String(String.UnicodeScalarView(character.unicodeScalars.filter { !(0x1F3FB...0x1F3FF).contains($0.value) }))
        if byCharacter[stripped] != nil { return stripped }
        // Les bases comme ☝️ perdent leur FE0F avec le ton : on le remet.
        let qualified = stripped.unicodeScalars.count == 1 ? stripped + "\u{FE0F}" : stripped
        return byCharacter[qualified] != nil ? qualified : stripped
    }

    // MARK: - Recherche

    /// Mots français courants qui ne figurent pas dans les noms d'Apple : ils renvoient à des mots anglais.
    static let frenchAliases: [String: [String]] = [
        "coeur": ["heart"], "amour": ["heart", "love", "kiss"], "rire": ["joy", "laugh", "rolling"], "mdr": ["joy", "laugh", "rolling"],
        "lol": ["joy", "laugh"], "sourire": ["smile", "grin"], "triste": ["sad", "cry", "pensive", "disappointed"],
        "pleurer": ["cry", "sob"], "colere": ["angry", "pouting", "rage"], "enerve": ["angry", "rage"], "fete": ["party", "confetti", "balloon", "tada"],
        "bravo": ["clap", "tada", "trophy"], "felicitations": ["tada", "clap", "confetti"], "anniversaire": ["birthday", "cake", "party"],
        "merci": ["folded hands", "pray"], "prier": ["pray", "folded hands"], "ok": ["ok hand", "check mark"], "oui": ["thumbs up", "check mark"],
        "non": ["thumbs down", "cross mark", "no entry"], "argent": ["money", "dollar", "euro"], "fric": ["money"], "boulot": ["office", "briefcase"],
        "travail": ["office", "briefcase", "computer"], "idee": ["light bulb"], "attention": ["warning"], "danger": ["warning", "skull"],
        "valide": ["check mark"], "fait": ["check mark"], "cent": ["hundred"], "parfait": ["hundred", "ok hand"], "fou": ["zany", "crazy"],
        "peur": ["fearful", "scream"], "dormir": ["sleep", "zzz"], "fatigue": ["tired", "weary", "sleepy"], "malade": ["sick", "nauseated", "mask"],
        "bisou": ["kiss"], "calin": ["hug"], "gene": ["flushed", "grimacing"], "honte": ["flushed", "see-no-evil"], "chaud": ["hot", "fire"],
        "froid": ["cold", "snow"], "beurk": ["nauseated", "vomit"], "cool": ["sunglasses", "cool"], "genial": ["star-struck", "fire", "hundred"],
        "vacances": ["beach", "palm", "airplane"], "plage": ["beach", "umbrella on ground"], "noel": ["christmas", "santa"],
        "paques": ["egg", "rabbit"], "halloween": ["jack-o-lantern", "ghost"], "fusee": ["rocket"], "lancer": ["rocket"],
        "ordi": ["laptop", "computer"], "mail": ["envelope", "e-mail"], "courriel": ["envelope", "e-mail"], "appel": ["telephone", "phone"],
        "photo": ["camera"], "film": ["movie", "clapper"], "musique": ["music", "musical"], "sport": ["soccer", "basketball", "trophy"],
        "foot": ["soccer"], "velo": ["bicycle", "bike"], "voiture": ["car", "automobile"], "train": ["train"], "avion": ["airplane"],
        "biere": ["beer"], "vin": ["wine"], "cafe": ["coffee", "hot beverage"], "the": ["tea", "teacup"], "manger": ["fork", "plate", "food"],
        "bebe": ["baby"], "diable": ["devil", "imp"], "ange": ["angel", "halo"], "caca": ["pile of poo", "poop"], "pouce": ["thumbs"],
        "muscle": ["biceps", "muscle"], "force": ["biceps", "muscle"], "yeux": ["eyes"], "regarder": ["eyes"], "secret": ["shushing", "zipper"],
        "chut": ["shushing"], "reflechir": ["thinking"], "hmm": ["thinking"], "clin": ["wink"], "oeil": ["eye", "wink"],
    ]

    static func searchTerms(for query: String) -> [String] {
        let normalized = normalize(query)
        var terms = [normalized]
        for (french, english) in frenchAliases where french == normalized || (normalized.count >= 3 && french.hasPrefix(normalized)) {
            terms += english
        }
        return terms
    }

    /// Note d'un emoji pour une saisie (plusieurs mots : tous doivent correspondre). `nil` : aucune correspondance.
    /// `fuzzy` : accepte aussi les fautes et abréviations (« lcrne »), quand rien d'autre ne correspond.
    static func score(_ entry: EmojiEntry, query: String, customKeywords: [String] = [], fuzzy: Bool = false) -> Double? {
        let tokens = normalize(query).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return 0 }
        var total = 0.0
        for token in tokens {
            var best = score(entry, token: token, custom: customKeywords, fuzzy: fuzzy)
            // Les mots français courants (« mdr », « fête ») renvoient à des mots anglais.
            for alias in searchTerms(for: token).dropFirst() {
                if let aliasScore = score(entry, token: alias, custom: [], fuzzy: false).map({ $0 * 0.9 }), aliasScore > (best ?? 0) { best = aliasScore }
            }
            guard let best else { return nil }
            total += best
        }
        var result = total / Double(tokens.count)
        let joined = tokens.joined(separator: " ")
        if entry.frenchSearchName == joined || entry.searchName == joined || entry.character == query { result += 10 }
        guard !fuzzy else { return result }
        // Les emojis les plus courants passent devant leurs variantes (« coeur » : ❤️ avant 💘).
        if let rank = popularRank[entry.character] { result += 20 * (1 - Double(rank) / Double(popular.count)) }
        if preferred[joined] == entry.character { result += 40 }
        return result
    }

    /// Les emojis les plus utilisés, du plus courant au moins courant (statistiques d'Unicode).
    static let popular: [String] = [
        "😂", "❤️", "🤣", "👍", "😭", "🙏", "😘", "🥰", "😍", "😊", "🎉", "😁", "💕", "🥺", "😅", "🔥", "☺️", "🤦", "🤷",
        "🙄", "😆", "🤗", "😉", "🎂", "🤔", "👏", "🙂", "😳", "🥳", "😎", "👌", "💜", "😔", "💪", "✨", "💖", "👀", "😋",
        "😏", "😢", "👉", "💗", "😩", "💯", "🌹", "💞", "🎈", "💙", "😃", "😡", "💐", "😜", "🙈", "🤞", "😄", "🤤", "🙌",
        "🤪", "❣️", "😀", "💋", "💀", "👇", "💔", "😌", "💓", "🤩", "🙃", "😬", "😱", "😴", "🤭", "😐", "🌞", "😒", "😇",
        "🌸", "😈", "🎶", "✌️", "🎊", "🥵", "😞", "💚", "☀️", "🖤", "💰", "😚", "👑", "🎁", "💥", "🙋", "☹️", "😑", "🥴",
        "👈", "💩", "✅", "👋", "🤝", "⭐", "🚀", "🐱", "🐶", "⚠️", "❌", "📌", "💡", "☕", "🍕", "🍺", "🇫🇷",
    ]

    private static let popularRank: [String: Int] = Dictionary(popular.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })

    /// Le choix évident pour une saisie générique, comme le premier résultat de Raycast.
    static let preferred: [String: String] = [
        "coeur": "❤️", "heart": "❤️", "amour": "❤️", "love": "❤️", "pouce": "👍", "thumbs up": "👍", "rire": "😂", "mdr": "😂",
        "laugh": "😂", "lol": "😂", "feu": "🔥", "fire": "🔥", "etoile": "⭐", "star": "⭐", "soleil": "☀️", "sun": "☀️",
        "chat": "🐱", "cat": "🐱", "chien": "🐶", "dog": "🐶", "ok": "👌", "fete": "🎉", "party": "🎉", "merci": "🙏",
        "sourire": "😊", "smile": "😊", "triste": "😢", "sad": "😢", "pleurer": "😭", "cry": "😭", "clin d'oeil": "😉", "wink": "😉",
        "check": "✅", "valide": "✅", "croix": "❌", "fusee": "🚀", "rocket": "🚀", "cafe": "☕", "coffee": "☕", "biere": "🍺",
        "beer": "🍺", "idee": "💡", "idea": "💡", "attention": "⚠️", "warning": "⚠️", "main": "👋", "salut": "👋", "bonjour": "👋",
        "wave": "👋", "cool": "😎", "bisou": "😘", "kiss": "😘", "fleche": "→", "arrow": "→", "euro": "€",
    ]

    private static func score(_ entry: EmojiEntry, token: String, custom: [String], fuzzy: Bool) -> Double? {
        var best: Double?
        func consider(_ value: Double) { if value > (best ?? 0) { best = value } }
        for name in [entry.frenchSearchName, entry.searchName] {
            // Plus le nom dépasse la saisie, moins il compte : « cœur rouge » avant « cœur rouge avec pansement ».
            let excess = min(Double(name.count - token.count) * 0.4, 15)
            if name == token { consider(100) } else if name.hasPrefix(token) { consider(90 - excess) }
            else if wordStarts(name, with: token) { consider(80 - excess) } else if token.count >= 3, name.contains(token) { consider(55 - excess) }
        }
        for keyword in custom {
            if keyword == token { consider(98) } else if keyword.hasPrefix(token) { consider(88) }
        }
        for keyword in entry.keywords {
            if keyword == token { consider(75) } else if keyword.hasPrefix(token) { consider(token.count >= 2 ? 65 : 40) }
            else if wordStarts(keyword, with: token) { consider(55) }
        }
        if best == nil, fuzzy, token.count >= 3 {
            for name in [entry.frenchSearchName, entry.searchName] {
                if let value = Fuzzy.score(token, name) { consider(value * 0.5 - min(Double(name.count) * 0.3, 15)) }
            }
        }
        return best
    }

    private static func wordStarts(_ text: String, with token: String) -> Bool {
        text.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "'" || $0 == ":" }).contains { $0.hasPrefix(token) }
    }
}
