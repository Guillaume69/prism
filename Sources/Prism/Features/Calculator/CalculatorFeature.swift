import AppKit
import SwiftUI

/// Réglages de la calculatrice.
@MainActor
final class CalculatorSettings: ObservableObject {
    static let shared = CalculatorSettings()
    private let defaults = UserDefaults.standard

    @Published var remBase: Double { didSet { defaults.set(remBase, forKey: "calculator.remBase") } }
    @Published var defaultCurrency: String { didSet { defaults.set(defaultCurrency, forKey: "calculator.defaultCurrency") } }
    @Published var colorConversion: Bool { didSet { defaults.set(colorConversion, forKey: "calculator.colorConversion") } }

    private init() {
        remBase = defaults.object(forKey: "calculator.remBase") as? Double ?? 16
        defaultCurrency = defaults.string(forKey: "calculator.defaultCurrency") ?? (Locale.current.currency?.identifier ?? "EUR")
        colorConversion = defaults.object(forKey: "calculator.colorConversion") as? Bool ?? true
    }
}

/// L'historique des calculs copiés ou collés.
struct CalculationRecord: Codable, Identifiable {
    var id = UUID()
    var expression: String
    var result: String
    var raw: String
    var date = Date()
}

@MainActor
enum CalculatorHistory {
    static let store = JSONStore("calculator-history.json", default: [CalculationRecord]())

    static func record(_ answer: CalcAnswer) {
        var records = store.value
        records.removeAll { $0.expression == answer.expression && $0.result == answer.result }
        records.insert(CalculationRecord(expression: answer.expression, result: answer.result, raw: answer.raw), at: 0)
        store.value = Array(records.prefix(500))
    }
}

extension KeyShortcut {
    static let copyRaw = KeyShortcut(keyCode: 8, modifiers: [.command, .option], label: "C")
    static let copyQuestion = KeyShortcut(keyCode: 8, modifiers: [.command, .option, .shift], label: "C")
}

@MainActor
enum CalculatorFeature: PrismFeature {
    static func start() {
        CurrencyRates.shared.refreshIfNeeded()
    }

    static func topSections(query: String) -> [ResultSection] {
        guard let item = Calculator.item(for: query) else { return [] }
        return [ResultSection(id: "calculator", title: "Calculatrice", items: [item])]
    }

    /// La carte de la recherche principale et ses actions.
    static func item(for answer: CalcAnswer) -> ResultItem {
        var actions: [ItemAction] = []
        if let color = answer.color {
            actions.append(ItemAction(title: "Copier la couleur en…", symbol: "paintpalette") { .push(colorScreen(color)) })
            actions.append(copy(answer, color.hexString, title: "Copier en HEX", shortcut: nil))
            actions.append(ItemAction(title: "Coller en HEX", symbol: "doc.on.clipboard") {
                CalculatorHistory.record(answer)
                return Paster.paste(color.hexString)
            })
        } else {
            actions.append(copy(answer, answer.raw.isEmpty ? answer.result : answer.result, title: "Copier le résultat", shortcut: nil))
            actions.append(ItemAction(title: "Coller le résultat", symbol: "doc.on.clipboard") {
                CalculatorHistory.record(answer)
                return Paster.paste(answer.result)
            })
            actions.append(copy(answer, answer.raw, title: "Copier le résultat brut", shortcut: .copyRaw))
        }
        actions.append(copy(answer, "\(answer.expression) = \(answer.result)", title: "Copier la question et la réponse", shortcut: .copyQuestion))
        actions.append(ItemAction(title: "Historique de la calculatrice", symbol: "clock.arrow.circlepath") { .push(historyScreen()) })
        return ResultItem(
            id: "calculator",
            title: answer.result,
            subtitle: answer.rightCaption,
            icon: answer.color.map { .color($0.nsColor) } ?? .symbol("plus.forwardslash.minus", Palette.orange),
            accessory: answer.leftCaption,
            style: .calculator(expression: answer.expression, result: answer.result),
            usageKey: "calculator",
            actions: actions
        )
    }

    private static func copy(_ answer: CalcAnswer, _ text: String, title: String, shortcut: KeyShortcut?) -> ItemAction {
        ItemAction(title: title, symbol: "doc.on.doc", shortcut: shortcut) {
            CalculatorHistory.record(answer)
            Pasteboard.copy(text)
            return .hud("Copié : \(text)")
        }
    }

    static func colorScreen(_ color: CalcColor) -> LauncherScreen {
        ListScreen(id: "calculator.color", title: "Copier la couleur en…", placeholder: "Format…", icon: .color(color.nsColor)) { query in
            let normalized = query.normalizedForSearch
            let items = color.formats
                .filter { normalized.isEmpty || $0.name.normalizedForSearch.contains(normalized) }
                .map { format in
                    ResultItem(
                        id: "color." + format.name,
                        title: format.value,
                        icon: .color(color.nsColor),
                        accessory: format.name,
                        usageKey: "",
                        actions: [
                            Actions.copy(format.value, hud: "Copié : \(format.value)"),
                            Actions.paste(format.value),
                        ]
                    )
                }
            return [ResultSection(id: "formats", title: "Formats", items: items)]
        }
    }

    static func historyScreen() -> LauncherScreen {
        ListScreen(
            id: "calculator.history",
            title: "Historique de la calculatrice",
            placeholder: "Rechercher un calcul…",
            icon: .symbol("clock.arrow.circlepath", Palette.orange),
            empty: { query in query.isEmpty ? ("clock", "Les calculs copiés ou collés apparaîtront ici.") : ("magnifyingglass", "Aucun calcul pour « \(query) »") }
        ) { query in
            let normalized = query.normalizedForSearch
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .short
            let items = CalculatorHistory.store.value
                .filter { normalized.isEmpty || $0.expression.normalizedForSearch.contains(normalized) || $0.result.normalizedForSearch.contains(normalized) }
                .map { record in
                    ResultItem(
                        id: "calc-history:" + record.id.uuidString,
                        title: record.result,
                        subtitle: record.expression,
                        icon: .symbol("plus.forwardslash.minus", Palette.orange),
                        accessory: relative.localizedString(for: record.date, relativeTo: Date()),
                        usageKey: "",
                        actions: [
                            Actions.copy(record.result, hud: "Copié : \(record.result)"),
                            Actions.paste(record.result),
                            Actions.copy("\(record.expression) = \(record.result)", title: "Copier la question et la réponse", symbol: "text.append", shortcut: .copyQuestion),
                            ItemAction(title: "Recalculer", symbol: "arrow.uturn.backward", shortcut: .edit) { .then(.popToRoot, .setQuery(record.expression)) },
                            ItemAction(title: "Supprimer", symbol: "trash", shortcut: .removeEntry, isDestructive: true) {
                                CalculatorHistory.store.value.removeAll { $0.id == record.id }
                                return .refresh
                            },
                            ItemAction(title: "Effacer l’historique", symbol: "trash.slash", shortcut: .removeAll, isDestructive: true) {
                                CalculatorHistory.store.value = []
                                return .refresh
                            },
                        ]
                    )
                }
            return items.isEmpty ? [] : [ResultSection(id: "history", title: "Calculs récents", items: items)]
        }
    }

    static var commands: [ResultItem] {
        [Command.screen("calculator.history", "Historique de la calculatrice", subtitle: "Calculatrice", symbol: "clock.arrow.circlepath", color: Palette.orange, keywords: ["calculator history", "calculs", "historique"], screen: historyScreen)]
    }

    static var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "calculator", title: "Calculatrice", symbol: "plus.forwardslash.minus", color: Palette.orange, order: 40) { AnyView(CalculatorSettingsView()) }]
    }

    // MARK: - Autotests

    static func selfTest(_ check: (Bool, String) -> Void) {
        var context = CalcContext()
        context.locale = Locale(identifier: "fr_FR")
        context.timeZone = TimeZone(identifier: "Europe/Paris") ?? .current
        context.now = ISO8601DateFormatter().date(from: "2026-10-14T10:00:00Z") ?? Date()
        context.rates = ["USD": 1.10, "GBP": 0.85, "JPY": 160, "BTC": 0.00001, "CHF": 0.95]
        context.ratesDate = context.now
        context.defaultCurrency = "EUR"

        func result(_ query: String) -> String? { Calculator.answer(for: query, context: context)?.result }
        func number(_ query: String) -> Double? {
            guard let raw = Calculator.answer(for: query, context: context)?.raw else { return nil }
            let compact = raw.replacingOccurrences(of: "\u{202F}", with: "").replacingOccurrences(of: "\u{00A0}", with: "")
            let match = CalcTime.captures(compact, #"(-?[0-9][0-9 ]*(?:[.,][0-9]+)?(?:[eE][-+]?[0-9]+)?)"#).first ?? ""
            return Double(match.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: "."))
        }
        func near(_ query: String, _ expected: Double, _ tolerance: Double = 1e-6) {
            let value = number(query)
            check(value.map { abs($0 - expected) <= max(tolerance, abs(expected) * 1e-9) } ?? false, "« \(query) » ≈ \(expected) (obtenu \(value.map { "\($0)" } ?? "rien"))")
        }
        func none(_ query: String) {
            check(Calculator.answer(for: query, context: context) == nil, "« \(query) » ne donne pas de carte")
        }
        func contains(_ query: String, _ fragment: String) {
            let value = result(query) ?? ""
            check(value.contains(fragment), "« \(query) » contient « \(fragment) » (obtenu « \(value) »)")
        }

        // Arithmétique
        near("2+2*3", 8)
        near("(1+2)^2", 9)
        near("-2^2", -4)
        near("10 % 3", 1)
        near("3,5 * 2", 7)
        near("2 x 3", 6)
        near("sqrt(16) + sin(0)", 4)
        near("5!", 120)
        near("square root of 625", 25)
        near("racine carrée de 625", 25)
        near("2 power 10", 1024)
        near("2 puissance 10", 1024)
        near("10K / 4", 2500)
        near("1,5M + 1", 1_500_001)
        near("1 000 000 / 2", 500_000)
        near("cos(60°)", 0.5, 1e-9)
        near("tanh(0)", 0)
        near("17 mod 5", 2)
        none("42")
        none("safari")
        none("e")
        none("10 km")
        // Pourcentages
        near("52% of 900", 468)
        near("52 % de 900", 468)
        near("20% off 80", 64)
        near("80 + 15%", 92)
        near("80 - 20%", 64)
        near("30 is what % of 120", 25)
        near("50 to 75 in %", 50)
        // Unités
        near("10 ft in m", 3.048)
        near("10 pieds en mètres", 3.048)
        near("5 km to mi", 3.10685596, 1e-6)
        near("25 c en f", 77)
        near("100 °F in °C", 37.7777777778, 1e-6)
        near("1 kg en livres", 2.20462262, 1e-6)
        near("3 h 20 min en minutes", 200)
        near("1 Go en Mo", 1000)
        near("1 GiB in MiB", 1024)
        near("100 km/h en mph", 62.1371192, 1e-6)
        near("2 l en ml", 2000)
        near("1 kWh en J", 3_600_000)
        near("1 atm en hPa", 1013.25)
        near("2rem in px", 32)
        near("32px en rem", 2)
        near("2 inches in px at 72 ppi", 144)
        near("5 km + 300 m", 5.3)
        near("90° en rad", Double.pi / 2, 1e-9)
        near("1 ha en m²", 10_000)
        // Devises
        near("100 usd in eur", 100 / 1.10, 0.006)
        near("100 $ en €", 100 / 1.10, 0.006)
        near("$100 in gbp", 100 / 1.10 * 0.85, 0.006)
        near("USD1K en eur", 1000 / 1.10, 0.006)
        near("1 btc en eur", 100_000)
        none("50 eur")
        near("50 usd", 50 / 1.10, 0.006)
        // Bases
        contains("255 in hex", "0xFF")
        contains("10 en binaire", "0b1010")
        near("0xff", 255)
        // Couleurs
        check(Calculator.answer(for: "#ff6363", context: context)?.color != nil, "couleur hexadécimale reconnue")
        check(CalcColor.parse("rgb(255 99 99)")?.hexString == "#FF6363", "rgb() → #FF6363")
        check(CalcColor.parse("hsl(0 100% 50%)")?.hexString == "#FF0000", "hsl() → rouge")
        check(CalcColor.parse("#ff6363")?.hslString == "hsl(0 100% 69%)", "HSL d’une couleur")
        let oklch = CalcColor.parse("oklch(62.8% 0.2577 29.23)")?.hexString ?? ""
        check(oklch == "#FF0000" || oklch == "#FE0000", "oklch() → rouge (\(oklch))")
        let lab = CalcColor.parse("lab(54.29% 80.8 69.89)")?.hexString ?? ""
        check(lab == "#FF0000" || lab == "#FE0000" || lab == "#FF0001", "lab() → rouge (\(lab))")
        // Temps et dates
        contains("heure à Tokyo", "19:00")
        contains("time in tokyo", "19:00")
        contains("5pm ldn in paris", "18:00")
        contains("17h Paris en New York", "11:00")
        check(result("décalage Tokyo") == "+7 h", "décalage avec Tokyo (\(result("décalage Tokyo") ?? "rien"))")
        contains("dans 4 heures", "16:00")
        contains("lundi dans 3 semaines", "9 novembre")
        check(result("jours jusqu’à Noël") == "72 jours", "jours jusqu’à Noël (\(result("jours jusqu’à Noël") ?? "rien"))")
        check(result("days until 31 Dec") == "78 jours", "days until 31 Dec (\(result("days until 31 Dec") ?? "rien"))")
        contains("5 août 2026 + 5 jours", "10 août")
        contains("15h45 + 5 h", "20:45")
        check(result("145 min en durée") == "2 h 25 min", "145 min en durée")
        check(result("heures ouvrées en 2026") == "2088 h", "heures ouvrées en 2026 (\(result("heures ouvrées en 2026") ?? "rien"))")
        check(result("55 h en jours ouvrés") == "6,875 jours", "55 h en jours ouvrés")
        contains("unix 1700000000", "2023")
        contains("2024-03-15T14:30:00Z", "15:30")
        check(Calculator.looksLikeCalculation("2+") , "« 2+ » ressemble à un calcul")
        check(Calculator.evaluate("2+") == nil, "expression incomplète refusée")
        check(Calculator.evaluate("12*3") == 36, "évaluation numérique pour les placeholders")
    }
}

struct CalculatorSettingsView: View {
    @ObservedObject private var settings = CalculatorSettings.shared
    @State private var ratesDate = CurrencyRates.shared.date

    var body: some View {
        Form {
            Section("Conversions") {
                Toggle("Reconnaître les couleurs (#ff6363, rgb(), hsl(), oklch()…)", isOn: $settings.colorConversion)
                Stepper("Taille de base d’un rem/em : \(Int(settings.remBase)) px", value: $settings.remBase, in: 8...32)
                Picker("Devise par défaut", selection: $settings.defaultCurrency) {
                    ForEach(CalcCurrencies.fiat, id: \.self) { code in
                        Text("\(code) — \(Locale.current.localizedString(forCurrencyCode: code) ?? code)").tag(code)
                    }
                }
            }
            Section {
                LabeledContent("Taux de change") {
                    if let ratesDate {
                        Text("du \(ratesDate.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text("pas encore chargés").foregroundStyle(.secondary)
                    }
                }
                Button("Actualiser les taux") {
                    CurrencyRates.shared.refreshIfNeeded(force: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { ratesDate = CurrencyRates.shared.date }
                }
            } footer: {
                Text("Taux publics d’open.er-api.com et de Coinbase, actualisés une fois par jour. Aucune donnée n’est envoyée.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("Historique") {
                LabeledContent("Calculs enregistrés", value: "\(CalculatorHistory.store.value.count)")
                Button("Effacer l’historique", role: .destructive) { CalculatorHistory.store.value = [] }
            }
        }
        .formStyle(.grouped)
    }
}
