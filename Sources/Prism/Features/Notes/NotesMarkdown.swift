import Foundation

/// La nature d'une ligne de note, pour la mise en forme en direct.
enum NoteLineKind: Equatable {
    case paragraph
    case blank
    case heading(level: Int)
    case bullet
    case ordered(number: Int)
    case task(checked: Bool)
    case quote
    /// « ``` » qui ouvre ou ferme un bloc de code.
    case fence
    /// Une ligne à l'intérieur d'un bloc de code.
    case code
    case rule
}

/// Une ligne analysée. Les plages sont en UTF-16, comme celles de `NSTextStorage`.
struct NoteLine: Equatable {
    /// La ligne, sans son saut de ligne.
    var range: NSRange
    var kind: NoteLineKind
    /// La syntaxe de début de ligne (« ## », « - [ ] », « > », « 1. »), espaces d'indentation compris.
    var marker: NSRange
    /// L'indentation, en caractères.
    var indent: Int
}

/// Un style en ligne : gras, italique, barré, souligné, code, lien.
struct InlineSpan: Equatable {
    enum Kind: Equatable {
        case bold, italic, strike, underline, code
        case link(String)
    }

    var kind: Kind
    /// Le texte mis en forme, syntaxe exclue.
    var content: NSRange
    /// La syntaxe (« ** », « [ », « ](url) »…), atténuée à l'affichage.
    var markers: [NSRange]
}

/// Les styles de bloc qu'on applique à des lignes (barre de format, menu « / », raccourcis).
enum NoteBlockStyle: String, CaseIterable {
    case heading1, heading2, heading3, bullet, ordered, task, quote, code, rule

    var title: String {
        switch self {
        case .heading1: "Titre 1"
        case .heading2: "Titre 2"
        case .heading3: "Titre 3"
        case .bullet: "Liste à puces"
        case .ordered: "Liste numérotée"
        case .task: "Liste de tâches"
        case .quote: "Citation"
        case .code: "Bloc de code"
        case .rule: "Séparateur"
        }
    }

    var symbol: String {
        switch self {
        case .heading1: "textformat.size.larger"
        case .heading2: "textformat.size"
        case .heading3: "textformat.size.smaller"
        case .bullet: "list.bullet"
        case .ordered: "list.number"
        case .task: "checklist"
        case .quote: "text.quote"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .rule: "minus"
        }
    }

    /// La syntaxe, rappelée à droite du menu « / ».
    var hint: String {
        switch self {
        case .heading1: "#"
        case .heading2: "##"
        case .heading3: "###"
        case .bullet: "-"
        case .ordered: "1."
        case .task: "[ ]"
        case .quote: ">"
        case .code: "```"
        case .rule: "---"
        }
    }

    /// Mots qui le trouvent dans le menu « / ».
    var keywords: [String] {
        switch self {
        case .heading1: ["titre", "heading", "h1"]
        case .heading2: ["titre", "heading", "h2", "sous-titre"]
        case .heading3: ["titre", "heading", "h3"]
        case .bullet: ["liste", "puces", "bullet", "list"]
        case .ordered: ["liste", "numerotee", "ordered", "numbered"]
        case .task: ["taches", "todo", "checklist", "cases", "a faire"]
        case .quote: ["citation", "quote"]
        case .code: ["code", "bloc"]
        case .rule: ["separateur", "ligne", "divider", "rule"]
        }
    }
}

enum NotesMarkdown {
    // MARK: - Lignes

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Les motifs sont des constantes du code : une erreur ici est une faute de frappe.
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    private static let headingPattern = regex(#"^(\s{0,3})(#{1,6})(\s+|$)"#)
    private static let taskPattern = regex(#"^(\s*)([-*+])\s\[( |x|X)\](\s|$)"#)
    private static let bulletPattern = regex(#"^(\s*)([-*+])\s"#)
    private static let orderedPattern = regex(#"^(\s*)(\d{1,9})[.)]\s"#)
    private static let quotePattern = regex(#"^(\s*)>\s?"#)
    private static let rulePattern = regex(#"^\s{0,3}(?:-{3,}|\*{3,}|_{3,})\s*$"#)
    private static let fencePattern = regex(#"^\s*```"#)

    /// La nature d'une ligne hors bloc de code, avec la longueur de sa syntaxe de début.
    static func classify(_ line: String) -> (kind: NoteLineKind, markerLength: Int, indent: Int) {
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let indent = line.prefix { $0 == " " || $0 == "\t" }.utf16.count
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return (.blank, 0, indent) }
        if fencePattern.firstMatch(in: line, range: whole) != nil { return (.fence, ns.length, indent) }
        if rulePattern.firstMatch(in: line, range: whole) != nil { return (.rule, ns.length, indent) }
        if let match = headingPattern.firstMatch(in: line, range: whole) {
            return (.heading(level: match.range(at: 2).length), match.range.length, indent)
        }
        if let match = taskPattern.firstMatch(in: line, range: whole) {
            let checked = ns.substring(with: match.range(at: 3)).lowercased() == "x"
            return (.task(checked: checked), match.range.length, indent)
        }
        if let match = bulletPattern.firstMatch(in: line, range: whole) {
            return (.bullet, match.range.length, indent)
        }
        if let match = orderedPattern.firstMatch(in: line, range: whole) {
            return (.ordered(number: Int(ns.substring(with: match.range(at: 2))) ?? 1), match.range.length, indent)
        }
        if let match = quotePattern.firstMatch(in: line, range: whole) {
            return (.quote, match.range.length, indent)
        }
        return (.paragraph, 0, indent)
    }

    /// Toutes les lignes du texte, blocs de code compris.
    static func lines(in text: NSString) -> [NoteLine] {
        var result: [NoteLine] = []
        var inCode = false
        var location = 0
        repeat {
            var end = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let range = NSRange(location: location, length: contentsEnd - location)
            let line = text.substring(with: range)
            let (kind, markerLength, indent) = classify(line)
            if kind == .fence {
                result.append(NoteLine(range: range, kind: .fence, marker: range, indent: indent))
                inCode.toggle()
            } else if inCode {
                result.append(NoteLine(range: range, kind: .code, marker: NSRange(location: location, length: 0), indent: indent))
            } else {
                result.append(NoteLine(range: range, kind: kind, marker: NSRange(location: location, length: markerLength), indent: indent))
            }
            location = end
        } while location < text.length
        // Une dernière ligne vide après un saut de ligne final.
        if text.length > 0, text.character(at: text.length - 1) == 10 {
            result.append(NoteLine(range: NSRange(location: text.length, length: 0), kind: inCode ? .code : .blank, marker: NSRange(location: text.length, length: 0), indent: 0))
        }
        return result
    }

    /// Les natures des lignes d'un texte, pour les autotests.
    static func kinds(of text: String) -> [NoteLineKind] {
        lines(in: text as NSString).map(\.kind)
    }

    // MARK: - Styles en ligne

    private static let codePattern = regex(#"(`+)([^`\n]+?)\1"#)
    private static let linkPattern = regex(#"\[([^\]\n]+)\]\(([^)\s]+)\)"#)
    private static let autolinkPattern = regex(#"\bhttps?://[^\s<>()\[\]]+[^\s<>()\[\].,;:!?'"»]"#)
    private static let boldPattern = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italicStarPattern = regex(#"(?<![*\w])\*(?=[^\s*])([^*\n]+?)(?<=[^\s*])\*(?![*\w])"#)
    private static let italicUnderscorePattern = regex(#"(?<![\w_])_(?=[^\s_])([^_\n]+?)(?<=[^\s_])_(?![\w_])"#)
    private static let strikePattern = regex(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let underlinePattern = regex(#"<u>(.+?)</u>"#)

    /// Les styles en ligne d'une ligne (hors code), plages relatives au texte entier.
    static func inlineSpans(in text: NSString, range: NSRange) -> [InlineSpan] {
        var spans: [InlineSpan] = []
        var protected: [NSRange] = []
        func isFree(_ candidate: NSRange) -> Bool {
            !protected.contains { NSIntersectionRange($0, candidate).length > 0 }
        }
        let string = text as String

        for match in codePattern.matches(in: string, range: range) {
            let ticks = match.range(at: 1).length
            spans.append(InlineSpan(kind: .code, content: match.range(at: 2), markers: [
                NSRange(location: match.range.location, length: ticks),
                NSRange(location: NSMaxRange(match.range) - ticks, length: ticks),
            ]))
            protected.append(match.range)
        }
        for match in linkPattern.matches(in: string, range: range) where isFree(match.range) {
            let label = match.range(at: 1)
            let url = text.substring(with: match.range(at: 2))
            spans.append(InlineSpan(kind: .link(url), content: label, markers: [
                NSRange(location: match.range.location, length: 1),
                NSRange(location: NSMaxRange(label), length: NSMaxRange(match.range) - NSMaxRange(label)),
            ]))
            // Le libellé reste ouvert au gras et à l'italique, l'adresse non.
            protected.append(NSRange(location: NSMaxRange(label), length: NSMaxRange(match.range) - NSMaxRange(label)))
        }
        for match in autolinkPattern.matches(in: string, range: range) where isFree(match.range) {
            spans.append(InlineSpan(kind: .link(text.substring(with: match.range)), content: match.range, markers: []))
            protected.append(match.range)
        }
        let paired: [(NSRegularExpression, InlineSpan.Kind, Int)] = [
            (boldPattern, .bold, 2),
            (strikePattern, .strike, 1),
            (underlinePattern, .underline, 1),
            (italicStarPattern, .italic, 1),
            (italicUnderscorePattern, .italic, 1),
        ]
        for (pattern, kind, group) in paired {
            for match in pattern.matches(in: string, range: range) where isFree(match.range) {
                let content = match.range(at: group)
                spans.append(InlineSpan(kind: kind, content: content, markers: [
                    NSRange(location: match.range.location, length: content.location - match.range.location),
                    NSRange(location: NSMaxRange(content), length: NSMaxRange(match.range) - NSMaxRange(content)),
                ]))
            }
        }
        return spans
    }

    /// Les styles d'une seule ligne, pour les autotests.
    static func inlineKinds(_ line: String) -> [InlineSpan.Kind] {
        let ns = line as NSString
        return inlineSpans(in: ns, range: NSRange(location: 0, length: ns.length)).map(\.kind)
    }

    // MARK: - Texte brut

    /// La ligne privée de ses `count` premières unités UTF-16.
    private static func dropping(_ line: String, _ count: Int) -> String {
        let ns = line as NSString
        return ns.substring(from: min(count, ns.length))
    }

    /// Une ligne sans sa syntaxe : titres de notes, copie en texte.
    static func plainLine(_ line: String, boxes: Bool = true) -> String {
        let (kind, markerLength, _) = classify(line)
        var body = line
        switch kind {
        case .fence, .rule: return ""
        case .task(let checked):
            body = (boxes ? (checked ? "☑ " : "☐ ") : "") + dropping(line, markerLength)
        case .heading, .quote, .bullet, .ordered:
            body = dropping(line, markerLength)
        default:
            break
        }
        return stripInline(body).trimmingCharacters(in: .whitespaces)
    }

    /// Retire la syntaxe en ligne : `**gras**` devient « gras », `[texte](url)` devient « texte ».
    static func stripInline(_ text: String) -> String {
        let ns = text as NSString
        let spans = inlineSpans(in: ns, range: NSRange(location: 0, length: ns.length))
        let markers = spans.flatMap(\.markers).sorted { $0.location > $1.location }
        let result = NSMutableString(string: text)
        var last = Int.max
        for marker in markers where NSMaxRange(marker) <= last {
            result.deleteCharacters(in: marker)
            last = marker.location
        }
        return result as String
    }

    /// Le texte entier sans syntaxe Markdown (« Copier le texte »).
    static func plainText(_ text: String) -> String {
        var inCode = false
        return text.components(separatedBy: "\n").compactMap { line -> String? in
            if classify(line).kind == .fence {
                inCode.toggle()
                return nil
            }
            if inCode { return line }
            if classify(line).kind == .rule { return "" }
            let (kind, markerLength, indent) = classify(line)
            let prefix = String(repeating: " ", count: indent)
            switch kind {
            case .bullet: return prefix + "• " + stripInline(dropping(line, markerLength))
            case .ordered(let number): return prefix + "\(number). " + stripInline(dropping(line, markerLength))
            default: return plainLine(line).isEmpty && kind == .blank ? "" : prefix + plainLine(line)
            }
        }.joined(separator: "\n")
    }

    /// Le Markdown montré par l'aperçu du lanceur : tâches en cases, soulignés sans balises.
    static func previewMarkdown(_ text: String) -> String {
        var inCode = false
        return text.components(separatedBy: "\n").map { line in
            if classify(line).kind == .fence { inCode.toggle(); return line }
            if inCode { return line }
            var line = line.replacingOccurrences(of: "<u>", with: "").replacingOccurrences(of: "</u>", with: "")
            if case .task(let checked) = classify(line).kind {
                let markerLength = classify(line).markerLength
                let body = dropping(line, markerLength)
                line = "- " + (checked ? "☑ ~~" + body + "~~" : "☐ " + body)
                if checked, body.isEmpty { line = "- ☑" }
            }
            return line
        }.joined(separator: "\n")
    }

    // MARK: - Transformations

    /// ⌘↵ : coche ou décoche une tâche ; une autre ligne devient une tâche.
    static func toggledTask(_ line: String) -> String {
        let (kind, markerLength, indent) = classify(line)
        let ns = line as NSString
        let prefix = ns.substring(to: indent)
        switch kind {
        case .task(let checked):
            let body = ns.substring(from: markerLength)
            let bullet = ns.substring(with: NSRange(location: indent, length: 1))
            return prefix + bullet + (checked ? " [ ] " : " [x] ") + body
        case .bullet, .ordered, .quote, .heading:
            return prefix + "- [ ] " + ns.substring(from: markerLength)
        default:
            return prefix + "- [ ] " + ns.substring(from: indent)
        }
    }

    /// Ce qu'Entrée ajoute au début de la ligne suivante dans une liste.
    enum Continuation: Equatable {
        /// La ligne suivante commence par ce préfixe.
        case prefix(String)
        /// L'élément est vide : Entrée sort de la liste.
        case endList
    }

    static func continuation(for line: String) -> Continuation? {
        let (kind, markerLength, indent) = classify(line)
        let ns = line as NSString
        let indentText = ns.substring(to: indent)
        let isEmpty = ns.substring(from: min(markerLength, ns.length)).trimmingCharacters(in: .whitespaces).isEmpty
        switch kind {
        case .task:
            let bullet = ns.substring(with: NSRange(location: indent, length: 1))
            return isEmpty ? .endList : .prefix(indentText + bullet + " [ ] ")
        case .bullet:
            let bullet = ns.substring(with: NSRange(location: indent, length: 1))
            return isEmpty ? .endList : .prefix(indentText + bullet + " ")
        case .ordered(let number):
            let delimiter = ns.substring(with: NSRange(location: markerLength - 2, length: 1))
            return isEmpty ? .endList : .prefix(indentText + "\(number + 1)" + delimiter + " ")
        case .quote:
            return isEmpty ? .endList : .prefix(indentText + "> ")
        default:
            return nil
        }
    }

    /// Applique un style de bloc à des lignes, ou le retire si toutes l'ont déjà.
    static func apply(_ style: NoteBlockStyle, to lines: [String]) -> [String] {
        func matches(_ line: String) -> Bool {
            switch (style, classify(line).kind) {
            case (.heading1, .heading(1)), (.heading2, .heading(2)), (.heading3, .heading(3)),
                 (.bullet, .bullet), (.ordered, .ordered), (.task, .task), (.quote, .quote):
                return true
            default:
                return false
            }
        }
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let removing = !content.isEmpty && content.allSatisfy(matches)
        var number = 0
        return lines.map { line in
            let (kind, markerLength, indent) = classify(line)
            let ns = line as NSString
            let indentText = ns.substring(to: indent)
            // Le texte sans sa syntaxe de bloc actuelle.
            let body: String
            switch kind {
            case .heading, .bullet, .ordered, .task, .quote:
                body = ns.substring(from: min(markerLength, ns.length))
            default:
                body = ns.substring(from: indent)
            }
            if removing { return indentText + body }
            if line.trimmingCharacters(in: .whitespaces).isEmpty, lines.count > 1 { return line }
            switch style {
            case .heading1: return "# " + body
            case .heading2: return "## " + body
            case .heading3: return "### " + body
            case .bullet: return indentText + "- " + body
            case .ordered:
                number += 1
                return indentText + "\(number). " + body
            case .task: return indentText + "- [ ] " + body
            case .quote: return indentText + "> " + body
            case .code, .rule: return line
            }
        }
    }
}
