import AppKit
import Foundation

/// Le résultat d'un calcul, prêt pour la carte « Expression → Résultat ».
struct CalcAnswer {
    var expression: String
    var result: String
    /// Le résultat sans séparateurs de milliers ni unité superflue, pour ⌥⌘C.
    var raw: String
    var leftCaption: String = "Expression"
    var rightCaption: String = "Résultat"
    var color: CalcColor? = nil
}

/// Une valeur avec son unité éventuelle ; `isPercent` pour « 80 + 15% ».
struct Quantity {
    var value: Double
    var unit: CalcUnit?
    var isPercent = false

    static func number(_ value: Double) -> Quantity { Quantity(value: value, unit: nil) }
}

/// La calculatrice de la recherche principale, inspirée de Soulver : arithmétique, unités, devises,
/// pourcentages, bases, couleurs, fuseaux horaires et dates.
enum Calculator {
    // MARK: - Lexique

    enum Token: Equatable {
        case number(Double)
        case unit(CalcUnit)
        case op(Character)
        case lparen
        case rparen
        case ident(String)
        case factorial

        var isOperandEnd: Bool {
            switch self {
            case .number, .rparen, .ident, .unit, .factorial: true
            default: false
            }
        }

        var isOperandStart: Bool {
            switch self {
            case .number, .lparen, .ident: true
            default: false
            }
        }
    }

    static let constants: [String: Double] = [
        "pi": .pi, "π": .pi, "e": M_E, "tau": 2 * .pi, "phi": (1 + 5.0.squareRoot()) / 2,
    ]

    static let functions: [String: (Double) -> Double] = [
        "sqrt": { $0.squareRoot() }, "racine": { $0.squareRoot() }, "cbrt": cbrt,
        "sin": sin, "cos": cos, "tan": tan, "cot": { 1 / tan($0) }, "sec": { 1 / cos($0) }, "csc": { 1 / sin($0) },
        "asin": asin, "acos": acos, "atan": atan, "arcsin": asin, "arccos": acos, "arctan": atan,
        "sinh": sinh, "cosh": cosh, "tanh": tanh, "asinh": asinh, "acosh": acosh, "atanh": atanh,
        "ln": log, "log": log10, "log2": log2, "log10": log10, "exp": exp, "abs": abs,
        "round": { $0.rounded() }, "arrondi": { $0.rounded() }, "floor": floor, "ceil": ceil, "trunc": trunc,
        "fact": factorial, "factorial": factorial,
    ]

    static func factorial(_ value: Double) -> Double {
        guard value >= 0, value <= 170, value == value.rounded() else { return .nan }
        return (1...max(1, Int(value))).reduce(1.0) { $0 * Double($1) }
    }

    /// Multiplicateurs collés au nombre : 10K, 1,5M, 2Md, 3bn.
    private static let suffixes: [String: Double] = ["k": 1e3, "K": 1e3, "M": 1e6, "Md": 1e9, "md": 1e9, "bn": 1e9, "B": 1e9, "G": 1e9, "T": 1e12]

    static func tokenize(_ input: String, context: CalcContext = CalcContext()) -> [Token]? {
        var tokens: [Token] = []
        let chars = Array(input)
        var i = 0
        func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace || c == "=" && i == chars.count - 1 {
                i += 1
                continue
            }
            if isDigit(c) || ((c == "." || c == ",") && i + 1 < chars.count && isDigit(chars[i + 1])) {
                var text = ""
                var j = i
                while j < chars.count {
                    let d = chars[j]
                    if isDigit(d) {
                        text.append(d)
                    } else if d == "." || d == "," {
                        text.append(".")
                    } else if (d == " " || d == "\u{202F}" || d == "\u{00A0}"), j + 3 < chars.count, isDigit(chars[j + 1]), isDigit(chars[j + 2]), isDigit(chars[j + 3]),
                              j + 4 >= chars.count || !isDigit(chars[j + 4]), text.count <= 3 || text.contains("§") {
                        // Séparateur de milliers : « 1 000 000 ».
                        text.append("§")
                    } else {
                        break
                    }
                    j += 1
                }
                text = text.replacingOccurrences(of: "§", with: "")
                // « 1,000,000 » ou « 1.234,5 » : plusieurs points, les derniers chiffres décident.
                let dots = text.filter { $0 == "." }.count
                if dots > 1 {
                    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
                    text = parts.dropLast().joined() + (parts.last.map { $0.count == 3 ? String($0) : "." + $0 } ?? "")
                }
                guard var value = Double(text) else { return nil }
                // Suffixe collé (« 10K », « 2Md »), sauf s'il commence une unité (« 10km »).
                for (suffix, multiplier) in suffixes.sorted(by: { $0.key.count > $1.key.count }) {
                    let end = j + suffix.count
                    guard end <= chars.count, String(chars[j..<end]) == suffix else { continue }
                    if end < chars.count, chars[end].isLetter { continue }
                    value *= multiplier
                    j = end
                    break
                }
                tokens.append(.number(value))
                i = j
                continue
            }
            if c == "!" {
                tokens.append(.factorial)
                i += 1
                continue
            }
            // Unités et devises : l'alias le plus long qui finit sur une frontière de mot.
            if let (unit, length) = matchUnit(chars, at: i, context: context) {
                // « x » entre deux nombres reste une multiplication.
                tokens.append(.unit(unit))
                i += length
                continue
            }
            if c.isLetter {
                let nextIsLetter = i + 1 < chars.count && chars[i + 1].isLetter
                if (c == "x" || c == "X"), !nextIsLetter, tokens.last?.isOperandEnd == true {
                    tokens.append(.op("*"))
                    i += 1
                    continue
                }
                var name = ""
                var j = i
                while j < chars.count, chars[j].isLetter || (isDigit(chars[j]) && !name.isEmpty) {
                    name.append(chars[j])
                    j += 1
                }
                tokens.append(.ident(name.lowercased()))
                i = j
                continue
            }
            switch c {
            case "+", "-", "*", "/", "^", "%": tokens.append(.op(c))
            case "×", "·", "∙": tokens.append(.op("*"))
            case "÷", ":": tokens.append(.op("/"))
            case "−", "–": tokens.append(.op("-"))
            case "(": tokens.append(.lparen)
            case ")": tokens.append(.rparen)
            case "π": tokens.append(.ident("pi"))
            default: return nil
            }
            i += 1
        }
        return tokens
    }

    private static func matchUnit(_ chars: [Character], at index: Int, context: CalcContext) -> (CalcUnit, Int)? {
        let first = chars[index]
        guard first.isLetter || "°$€£¥₹₩₽₺₪₴฿₫₦₿Ξ\"'″′µ℃℉".contains(first) else { return nil }
        let remaining = chars.count - index
        for alias in CalcUnits.allAliases where alias.count <= remaining {
            let candidate = String(chars[index..<(index + alias.count)])
            guard candidate.lowercased() == alias.lowercased() else { continue }
            let end = index + alias.count
            if let last = alias.last, last.isLetter, end < chars.count, chars[end].isLetter { continue }
            // Les fonctions et constantes gardent la priorité (« sec », « e »).
            if functions[candidate.lowercased()] != nil || constants[candidate.lowercased()] != nil { continue }
            guard let unit = CalcUnits.lookup(candidate, context: context) else { continue }
            return (unit, alias.count)
        }
        return nil
    }

    // MARK: - Analyse

    struct Parser {
        let tokens: [Token]
        let context: CalcContext
        var pos = 0

        var peek: Token? { pos < tokens.count ? tokens[pos] : nil }

        mutating func expression() -> Quantity? {
            guard var value = term() else { return nil }
            while true {
                if case .op(let o)? = peek, o == "+" || o == "-" {
                    pos += 1
                    guard let rhs = term() else { return nil }
                    guard let sum = Calculator.add(value, rhs, subtract: o == "-", context: context) else { return nil }
                    value = sum
                } else if value.unit != nil, case .number? = peek, let rhs = juxtaposed(value.unit) {
                    // « 3 h 20 min », « 1 m 80 cm » : les parties s'additionnent.
                    guard let sum = Calculator.add(value, rhs, subtract: false, context: context) else { return nil }
                    value = sum
                } else {
                    break
                }
            }
            return value
        }

        /// Un nombre suivi d'une unité de même grandeur, sans opérateur.
        mutating func juxtaposed(_ unit: CalcUnit?) -> Quantity? {
            let saved = pos
            guard case .number(let number)? = peek else { return nil }
            pos += 1
            if case .unit(let next)? = peek, next.category == unit?.category {
                pos += 1
                return Quantity(value: number, unit: next)
            }
            pos = saved
            return nil
        }

        mutating func term() -> Quantity? {
            guard var value = unary() else { return nil }
            loop: while let token = peek {
                switch token {
                case .op(let o) where o == "*" || o == "/" || o == "%":
                    pos += 1
                    guard let rhs = unary() else { return nil }
                    guard let product = Calculator.multiply(value, rhs, operator: o) else { return nil }
                    value = product
                case .ident(let name) where name == "mod" || name == "modulo":
                    pos += 1
                    guard let rhs = unary() else { return nil }
                    guard let product = Calculator.multiply(value, rhs, operator: "%") else { return nil }
                    value = product
                case .lparen, .ident:
                    // Multiplication implicite : 2(3+4), 2pi.
                    guard let rhs = unary() else { return nil }
                    guard let product = Calculator.multiply(value, rhs, operator: "*") else { return nil }
                    value = product
                default:
                    break loop
                }
            }
            return value
        }

        mutating func unary() -> Quantity? {
            if case .op(let o)? = peek, o == "-" || o == "+" {
                pos += 1
                guard var value = unary() else { return nil }
                if o == "-" { value.value = -value.value }
                return value
            }
            return power()
        }

        mutating func power() -> Quantity? {
            guard let base = postfix() else { return nil }
            if case .op("^")? = peek {
                pos += 1
                guard let exponent = unary(), exponent.unit == nil, base.unit == nil else { return nil }
                return .number(pow(base.value, exponent.value))
            }
            return base
        }

        mutating func postfix() -> Quantity? {
            guard var value = primary() else { return nil }
            while let token = peek {
                if case .factorial = token {
                    pos += 1
                    guard value.unit == nil else { return nil }
                    value = .number(Calculator.factorial(value.value))
                } else if case .op("%") = token {
                    // « 10 % 3 » est un modulo, « 50 % » un pourcentage.
                    if pos + 1 < tokens.count, tokens[pos + 1].isOperandStart { break }
                    pos += 1
                    value = Quantity(value: value.value / 100, unit: nil, isPercent: true)
                } else if case .unit(let unit) = token, value.unit == nil, !value.isPercent {
                    pos += 1
                    value.unit = unit
                } else {
                    break
                }
            }
            return value
        }

        mutating func primary() -> Quantity? {
            guard let token = peek else { return nil }
            pos += 1
            switch token {
            case .number(let value):
                return .number(value)
            case .unit(let unit):
                // Devise devant le nombre : « $100 », « USD1K ».
                guard case .number(let value)? = peek else { return nil }
                pos += 1
                return Quantity(value: value, unit: unit)
            case .lparen:
                guard let value = expression() else { return nil }
                if case .rparen? = peek { pos += 1 }
                return value
            case .ident(let name):
                if let constant = Calculator.constants[name] { return .number(constant) }
                guard let function = Calculator.functions[name] else { return nil }
                let argument: Quantity?
                if case .lparen? = peek {
                    pos += 1
                    argument = expression()
                    if case .rparen? = peek { pos += 1 }
                } else {
                    argument = power()
                }
                guard var argument else { return nil }
                // Les angles en degrés passent en radians pour la trigonométrie.
                if let unit = argument.unit {
                    guard unit.category == .angle else { return nil }
                    argument = .number(argument.value * unit.factor)
                }
                return .number(function(argument.value))
            default:
                return nil
            }
        }
    }

    static func add(_ lhs: Quantity, _ rhs: Quantity, subtract: Bool, context: CalcContext) -> Quantity? {
        let sign: Double = subtract ? -1 : 1
        if rhs.isPercent, !lhs.isPercent {
            // « 80 + 15% » vaut 92, comme dans Soulver.
            return Quantity(value: lhs.value * (1 + sign * rhs.value), unit: lhs.unit)
        }
        switch (lhs.unit, rhs.unit) {
        case (nil, nil):
            return Quantity(value: lhs.value + sign * rhs.value, unit: nil, isPercent: lhs.isPercent && rhs.isPercent)
        case (let unit?, nil):
            return Quantity(value: lhs.value + sign * rhs.value, unit: unit)
        case (nil, let unit?):
            return Quantity(value: lhs.value + sign * rhs.value, unit: unit)
        case (let left?, let right?):
            if left.category == .temperature, right.category == .temperature {
                // Un écart de température : seule l'échelle compte.
                let delta = rhs.value * right.factor / left.factor
                return Quantity(value: lhs.value + sign * delta, unit: left)
            }
            guard let converted = CalcUnits.convert(rhs.value, from: right, to: left, context: context) else { return nil }
            return Quantity(value: lhs.value + sign * converted, unit: left)
        }
    }

    static func multiply(_ lhs: Quantity, _ rhs: Quantity, operator op: Character) -> Quantity? {
        func apply(_ a: Double, _ b: Double) -> Double {
            switch op {
            case "*": a * b
            case "/": a / b
            default: a.truncatingRemainder(dividingBy: b)
            }
        }
        switch (lhs.unit, rhs.unit) {
        case (nil, nil):
            return .number(apply(lhs.value, rhs.value))
        case (let unit?, nil):
            return Quantity(value: apply(lhs.value, rhs.value), unit: unit)
        case (nil, let unit?) where op == "*":
            return Quantity(value: lhs.value * rhs.value, unit: unit)
        case (let left?, let right?) where op == "/" && left.category == right.category && left.category != .currency:
            // Un rapport de deux grandeurs identiques n'a pas d'unité.
            return .number((lhs.value * left.factor) / (rhs.value * right.factor))
        default:
            return nil
        }
    }

    // MARK: - Évaluation

    /// La valeur numérique d'une expression sans unité (placeholders, autres fonctionnalités).
    static func evaluate(_ input: String) -> Double? {
        guard let quantity = evaluateQuantity(rewrite(input), context: CalcContext()), quantity.unit == nil, quantity.value.isFinite else { return nil }
        return quantity.value
    }

    static func evaluateQuantity(_ input: String, context: CalcContext) -> Quantity? {
        guard let tokens = tokenize(input, context: context), !tokens.isEmpty else { return nil }
        var parser = Parser(tokens: tokens, context: context)
        guard let value = parser.expression(), parser.pos == tokens.count, value.value.isFinite || value.value.isNaN == false else { return nil }
        guard value.value.isFinite else { return nil }
        return value
    }

    /// Les mots des opérations, en français et en anglais, deviennent des symboles.
    static func rewrite(_ input: String) -> String {
        var text = " " + input.replacingOccurrences(of: "’", with: "'") + " "
        let replacements: [(String, String)] = [
            (#"(?i)\b(?:square root of|racine carr[ée]e de|racine de|sqrt of)\s+"#, "sqrt "),
            (#"(?i)\b(?:cube root of|racine cubique de)\s+"#, "cbrt "),
            (#"(?i)\s+(?:to the power of|power|puissance|exposant)\s+"#, " ^ "),
            (#"(?i)\s+(?:times|fois|multiplied by|multiplié par)\s+"#, " * "),
            (#"(?i)\s+(?:divided by|divisé par|sur)\s+"#, " / "),
            (#"(?i)\s+(?:plus)\s+"#, " + "),
            (#"(?i)\s+(?:minus|moins)\s+"#, " - "),
            (#"(?i)\s+(?:squared|au carré)\s+"#, " ^ 2 "),
            (#"(?i)\s+(?:cubed|au cube)\s+"#, " ^ 3 "),
        ]
        for (pattern, replacement) in replacements {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Une saisie n'est un calcul que si elle a au moins un nombre et autre chose qu'un nombre.
    static func looksLikeCalculation(_ input: String) -> Bool {
        guard let tokens = tokenize(rewrite(input)) else { return false }
        let hasNumber = tokens.contains { if case .number = $0 { true } else { false } }
        let hasOther = tokens.contains { if case .number = $0 { false } else { true } }
        return hasNumber && hasOther
    }

    static func format(_ value: Double, grouping: Bool = true, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.usesGroupingSeparator = grouping
        let magnitude = abs(value)
        if magnitude >= 1e15 || (magnitude < 1e-6 && value != 0) {
            formatter.numberStyle = .scientific
            formatter.maximumFractionDigits = 6
        } else {
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = magnitude >= 1000 ? 4 : 10
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func format(_ quantity: Quantity, context: CalcContext, grouping: Bool = true) -> String {
        guard let unit = quantity.unit else {
            if quantity.isPercent { return format(quantity.value * 100, grouping: grouping, locale: context.locale) + " %" }
            return format(quantity.value, grouping: grouping, locale: context.locale)
        }
        if let code = unit.currency {
            return CalcCurrencies.format(quantity.value, code: code, locale: context.locale, grouping: grouping)
        }
        let number = format((quantity.value * 1e9).rounded() / 1e9, grouping: grouping, locale: context.locale)
        return unit.symbol.hasPrefix("°") && unit.symbol.count > 1 ? "\(number) \(unit.symbol)" : "\(number) \(unit.symbol)"
    }

    // MARK: - Calcul complet

    /// Le contexte réel : réglages de la calculatrice et taux de change en cache.
    @MainActor
    static var liveContext: CalcContext {
        var context = CalcContext()
        let settings = CalculatorSettings.shared
        context.remBase = settings.remBase
        context.defaultCurrency = settings.defaultCurrency
        context.rates = CurrencyRates.shared.rates
        context.ratesDate = CurrencyRates.shared.date
        return context
    }

    /// Le calcul de la saisie, de la plus spécifique à la plus générale des formes reconnues.
    static func answer(for query: String, context original: CalcContext, colors: Bool = true) -> CalcAnswer? {
        var context = original
        var input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.count < 300 else { return nil }

        if colors, let color = CalcColor.parse(input) {
            return CalcAnswer(expression: input, result: color.hexString, raw: color.hexString, leftCaption: "Couleur", rightCaption: color.rgbString, color: color)
        }
        if let base = baseConversion(input) { return base }
        if let time = CalcTime.evaluate(input, context: context) { return time }

        // « 2 inches in px at 72 ppi ».
        let ppi = CalcTime.captures(input, #"^(.+?)\s+(?:at|à|a)\s+(\d+(?:[.,]\d+)?)\s*(?:ppi|dpi)$"#)
        if ppi.count == 2, let value = Double(ppi[1].replacingOccurrences(of: ",", with: ".")) {
            context.ppi = value
            input = ppi[0]
        }

        if let percent = percentPhrase(input, context: context) { return percent }

        let rewritten = rewrite(input)
        // « 10 ft in m », « 100 usd en eur », « 25 c to f ».
        if let (left, target) = splitConversion(rewritten, context: context) {
            guard let quantity = evaluateQuantity(left, context: context) else { return nil }
            return convert(quantity, to: target, expression: input, context: context)
        }

        guard looksLikeCalculation(rewritten), let quantity = evaluateQuantity(rewritten, context: context) else { return nil }
        // Une devise seule se convertit vers la devise par défaut, si elle en diffère.
        if let unit = quantity.unit, unit.category == .currency, let code = unit.currency, code != context.defaultCurrency,
           isSingleQuantity(rewritten, context: context) {
            return convert(quantity, to: CalcCurrencies.unit(context.defaultCurrency), expression: input, context: context)
        }
        // Une quantité seule, sans calcul ni conversion (« 10 km »), n'a rien à montrer.
        if quantity.unit != nil, isSingleQuantity(rewritten, context: context) { return nil }
        let display = format(quantity, context: context)
        let raw = format(quantity, context: context, grouping: false)
        return CalcAnswer(expression: input, result: display, raw: raw, rightCaption: caption(for: quantity))
    }

    private static func caption(for quantity: Quantity) -> String {
        guard let unit = quantity.unit else { return "Résultat" }
        switch unit.category {
        case .currency: return "Résultat en \(unit.currency ?? "")"
        default: return "Résultat"
        }
    }

    private static func isSingleQuantity(_ input: String, context: CalcContext) -> Bool {
        guard let tokens = tokenize(input, context: context) else { return false }
        return tokens.count == 2 && tokens.contains { if case .number = $0 { true } else { false } }
            && tokens.contains { if case .unit = $0 { true } else { false } }
    }

    /// Sépare « gauche in|en|to|as|into|→ cible » quand la cible est une unité ou une base.
    private static func splitConversion(_ input: String, context: CalcContext) -> (String, Target)? {
        let pattern = #"^(.+)\s+(?:in|en|to|as|into|vers|→|->|=)\s+(.+)$"#
        let parts = CalcTime.captures(input, pattern)
        guard parts.count == 2 else { return nil }
        let targetText = parts[1].trimmingCharacters(in: .whitespaces)
        if let unit = unitTarget(targetText, context: context) { return (parts[0], unit) }
        return nil
    }

    private static func unitTarget(_ text: String, context: CalcContext) -> Target? {
        if let unit = CalcUnits.lookup(text, context: context) { return unit }
        if text.hasSuffix("s"), let unit = CalcUnits.lookup(String(text.dropLast()), context: context) { return unit }
        return nil
    }

    typealias Target = CalcUnit

    private static func convert(_ quantity: Quantity, to target: CalcUnit, expression: String, context: CalcContext) -> CalcAnswer? {
        let source = quantity.unit ?? target
        if source.category == .currency, target.category == .currency, context.rates.isEmpty {
            return CalcAnswer(expression: expression, result: "…", raw: "", rightCaption: "Taux de change en cours de chargement")
        }
        guard let value = CalcUnits.convert(quantity.value, from: source, to: target, context: context) else { return nil }
        let result = Quantity(value: value, unit: target)
        var caption = "Résultat"
        if target.category == .currency, let date = context.ratesDate {
            let formatter = DateFormatter()
            formatter.locale = context.locale
            formatter.setLocalizedDateFormatFromTemplate("dMMM")
            caption = "Taux du \(formatter.string(from: date))"
        }
        return CalcAnswer(expression: expression, result: format(result, context: context), raw: format(result, context: context, grouping: false), rightCaption: caption)
    }

    // MARK: - Pourcentages

    private static func percentPhrase(_ input: String, context: CalcContext) -> CalcAnswer? {
        let text = input.replacingOccurrences(of: "’", with: "'")
        func value(_ expression: String) -> Quantity? { evaluateQuantity(rewrite(expression), context: context) }
        func result(_ quantity: Quantity, _ caption: String) -> CalcAnswer {
            CalcAnswer(expression: input, result: format(quantity, context: context), raw: format(quantity, context: context, grouping: false), rightCaption: caption)
        }
        // « 20% off 80 », « 20 % de remise sur 80 ».
        let off = CalcTime.captures(text, #"^(.+?)\s*%\s+(?:off|de remise sur|de réduction sur|de reduction sur)\s+(.+)$"#)
        if off.count == 2, let p = value(off[0]), p.unit == nil, let base = value(off[1]) {
            return result(Quantity(value: base.value * (1 - p.value / 100), unit: base.unit), "Après remise")
        }
        // « 52% of 900 », « 52 % de 900 ».
        let of = CalcTime.captures(text, #"^(.+?)\s*%\s+(?:of|de|d')\s*(.+)$"#)
        if of.count == 2, let p = value(of[0]), p.unit == nil, let base = value(of[1]) {
            return result(Quantity(value: base.value * p.value / 100, unit: base.unit), "Pourcentage")
        }

        // « 30 is what % of 120 », « 30 est quel % de 120 », « 30 sur 120 en % ».
        let what = CalcTime.captures(text, #"^(.+?)\s+(?:is what\s*%\s*of|est quel\s*%\s*de|représente quel\s*%\s*de|sur)\s+(.+?)(?:\s+en\s*%)?$"#)
        if what.count == 2, text.contains("%"), let part = value(what[0]), let whole = value(what[1]), whole.value != 0 {
            var partValue = part.value
            if let from = part.unit, let to = whole.unit, let converted = CalcUnits.convert(part.value, from: from, to: to, context: context) {
                partValue = converted
            }
            let ratio = partValue / whole.value
            return result(Quantity(value: ratio, unit: nil, isPercent: true), "Part")
        }
        // « 50 to 75 in % », « de 50 à 75 en % » : la variation.
        let change = CalcTime.captures(text, #"^(?:de\s+)?(.+?)\s+(?:to|à|a)\s+(.+?)\s+(?:in|en)\s*%$"#)
        if change.count == 2, let from = value(change[0]), let to = value(change[1]), from.value != 0 {
            return result(Quantity(value: (to.value - from.value) / from.value, unit: nil, isPercent: true), "Variation")
        }
        return nil
    }

    // MARK: - Bases

    private static func baseConversion(_ input: String) -> CalcAnswer? {
        let text = input.lowercased().trimmingCharacters(in: .whitespaces)
        func parseLiteral(_ literal: String) -> Int? {
            let t = literal.replacingOccurrences(of: "_", with: "")
            if t.hasPrefix("0x") { return Int(t.dropFirst(2), radix: 16) }
            if t.hasPrefix("0b") { return Int(t.dropFirst(2), radix: 2) }
            if t.hasPrefix("0o") { return Int(t.dropFirst(2), radix: 8) }
            return Int(t)
        }
        let targets: [String: (radix: Int, prefix: String, name: String)] = [
            "hex": (16, "0x", "Hexadécimal"), "hexa": (16, "0x", "Hexadécimal"), "hexadecimal": (16, "0x", "Hexadécimal"), "hexadécimal": (16, "0x", "Hexadécimal"),
            "binary": (2, "0b", "Binaire"), "binaire": (2, "0b", "Binaire"), "bin": (2, "0b", "Binaire"),
            "octal": (8, "0o", "Octal"), "oct": (8, "0o", "Octal"),
            "decimal": (10, "", "Décimal"), "décimal": (10, "", "Décimal"), "dec": (10, "", "Décimal"),
        ]
        let parts = CalcTime.captures(text, #"^([0-9a-fx_ob]+)\s+(?:in|en|to|as|into)\s+([a-zé]+)$"#)
        if parts.count == 2, let value = parseLiteral(parts[0]), let target = targets[parts[1]] {
            let digits = String(value, radix: target.radix).uppercased()
            let result = target.prefix + (target.radix == 16 ? digits : digits.lowercased())
            return CalcAnswer(expression: input, result: result, raw: result, rightCaption: target.name)
        }
        // Un littéral seul : « 0xff », « 0b1010 ».
        if text.range(of: #"^0[xbo][0-9a-f_]+$"#, options: .regularExpression) != nil, let value = parseLiteral(text) {
            return CalcAnswer(expression: input, result: format(Double(value)), raw: "\(value)", rightCaption: "Décimal")
        }
        return nil
    }

    // MARK: - Résultat de la recherche principale

    @MainActor
    static func item(for query: String) -> ResultItem? {
        let context = liveContext
        if context.rates.isEmpty || (context.ratesDate.map { Date().timeIntervalSince($0) > 86_400 } ?? true) {
            CurrencyRates.shared.refreshIfNeeded()
        }
        guard let answer = answer(for: query, context: context, colors: CalculatorSettings.shared.colorConversion) else { return nil }
        return CalculatorFeature.item(for: answer)
    }
}
