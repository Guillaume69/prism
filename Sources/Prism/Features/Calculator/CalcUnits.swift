import Foundation

/// Les grandeurs que la calculatrice sait convertir entre elles.
enum UnitCategory: String {
    case length, mass, volume, temperature, area, speed, time, data, energy, pressure, angle, power, currency
}

/// Une unité : son symbole affiché, sa grandeur, et son facteur vers l'unité de base de la grandeur
/// (mètre, kilogramme, mètre cube, seconde, octet, joule, pascal, radian, watt ; kelvin avec décalage).
struct CalcUnit: Equatable {
    let symbol: String
    let category: UnitCategory
    let factor: Double
    var offset: Double = 0
    /// Code ISO pour une devise (le facteur vient alors des taux).
    var currency: String? = nil

    static func == (lhs: CalcUnit, rhs: CalcUnit) -> Bool {
        lhs.symbol == rhs.symbol && lhs.category == rhs.category && lhs.currency == rhs.currency
    }
}

/// Le contexte d'un calcul : date, fuseau, langue, réglages de conversion, taux de change.
/// Injectable pour des autotests déterministes.
struct CalcContext {
    var now = Date()
    var timeZone = TimeZone.current
    var locale = Locale.current
    /// Taille de base d'un rem/em en pixels.
    var remBase: Double = 16
    /// Pixels par pouce pour px ⇄ longueurs physiques (96 en CSS).
    var ppi: Double = 96
    var defaultCurrency = "EUR"
    /// Taux : 1 EUR = taux × devise.
    var rates: [String: Double] = [:]
    var ratesDate: Date?

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        calendar.firstWeekday = 2
        return calendar
    }
}

enum CalcUnits {
    private static func unit(_ symbol: String, _ category: UnitCategory, _ factor: Double, offset: Double = 0) -> CalcUnit {
        CalcUnit(symbol: symbol, category: category, factor: factor, offset: offset)
    }

    // MARK: - Unités

    static let meter = unit("m", .length, 1)
    static let second = unit("s", .time, 1)
    static let minute = unit("min", .time, 60)
    static let hour = unit("h", .time, 3_600)
    static let day = unit("j", .time, 86_400)
    static let celsius = unit("°C", .temperature, 1, offset: 273.15)
    static let fahrenheit = unit("°F", .temperature, 5.0 / 9.0, offset: 459.67 * 5.0 / 9.0)
    static let kelvin = unit("K", .temperature, 1)

    /// Les unités à facteur fixe, par alias insensibles à la casse (français et anglais, pluriels).
    static let caseInsensitive: [String: CalcUnit] = {
        var table: [String: CalcUnit] = [:]
        func add(_ unit: CalcUnit, _ aliases: [String]) {
            for alias in aliases { table[alias.lowercased()] = unit }
        }
        // Longueur
        add(unit("mm", .length, 0.001), ["mm", "millimètre", "millimètres", "millimetre", "millimetres", "millimeter", "millimeters"])
        add(unit("cm", .length, 0.01), ["cm", "centimètre", "centimètres", "centimetre", "centimetres", "centimeter", "centimeters"])
        add(unit("dm", .length, 0.1), ["dm", "décimètre", "décimètres", "decimeter", "decimeters"])
        add(meter, ["m", "mètre", "mètres", "metre", "metres", "meter", "meters"])
        add(unit("km", .length, 1_000), ["km", "kilomètre", "kilomètres", "kilometre", "kilometres", "kilometer", "kilometers", "kms"])
        add(unit("µm", .length, 1e-6), ["µm", "um", "micromètre", "micromètres", "micrometer", "micrometers", "micron", "microns"])
        add(unit("nm", .length, 1e-9), ["nanomètre", "nanomètres", "nanometer", "nanometers"])
        add(unit("in", .length, 0.0254), ["inch", "inches", "pouce", "pouces", "\"", "″"])
        add(unit("ft", .length, 0.3048), ["ft", "foot", "feet", "pied", "pieds", "'", "′"])
        add(unit("yd", .length, 0.9144), ["yd", "yard", "yards", "yds"])
        add(unit("mi", .length, 1_609.344), ["mi", "mile", "miles"])
        add(unit("nmi", .length, 1_852), ["nmi", "mille marin", "milles marins", "nautical mile", "nautical miles"])
        add(unit("al", .length, 9.4607e15), ["année-lumière", "années-lumière", "light year", "light years", "ly"])
        add(unit("ua", .length, 1.495978707e11), ["ua", "unité astronomique", "unités astronomiques"])
        // Masse
        add(unit("mg", .mass, 1e-6), ["mg", "milligramme", "milligrammes", "milligram", "milligrams"])
        add(unit("g", .mass, 0.001), ["g", "gramme", "grammes", "gram", "grams", "gr"])
        add(unit("kg", .mass, 1), ["kg", "kilo", "kilos", "kilogramme", "kilogrammes", "kilogram", "kilograms", "kgs"])
        add(unit("t", .mass, 1_000), ["t", "tonne", "tonnes", "ton", "tons"])
        add(unit("oz", .mass, 0.028349523125), ["oz", "once", "onces", "ounce", "ounces"])
        add(unit("lb", .mass, 0.45359237), ["lb", "lbs", "livre", "livres", "pound", "pounds"])
        add(unit("st", .mass, 6.35029318), ["stone", "stones"])
        add(unit("ct", .mass, 0.0002), ["carat", "carats"])
        // Volume
        add(unit("ml", .volume, 1e-6), ["ml", "millilitre", "millilitres", "milliliter", "milliliters"])
        add(unit("cl", .volume, 1e-5), ["cl", "centilitre", "centilitres", "centiliter", "centiliters"])
        add(unit("dl", .volume, 1e-4), ["dl", "décilitre", "décilitres", "deciliter", "deciliters"])
        add(unit("l", .volume, 0.001), ["l", "litre", "litres", "liter", "liters"])
        add(unit("m³", .volume, 1), ["m3", "m³", "mètre cube", "mètres cubes", "cubic meter", "cubic meters"])
        add(unit("cm³", .volume, 1e-6), ["cm3", "cm³", "cc"])
        add(unit("c. à café", .volume, 4.92892e-6), ["tsp", "cuillère à café", "cuillères à café", "teaspoon", "teaspoons", "càc"])
        add(unit("c. à soupe", .volume, 1.478676e-5), ["tbsp", "cuillère à soupe", "cuillères à soupe", "tablespoon", "tablespoons", "càs"])
        add(unit("tasse", .volume, 2.365882e-4), ["cup", "cups", "tasse", "tasses"])
        add(unit("fl oz", .volume, 2.957353e-5), ["fl oz", "floz", "fluid ounce", "fluid ounces"])
        add(unit("pt", .volume, 4.731765e-4), ["pint", "pints", "pinte", "pintes"])
        add(unit("qt", .volume, 9.463529e-4), ["quart", "quarts", "qt"])
        add(unit("gal", .volume, 3.785412e-3), ["gal", "gallon", "gallons"])
        // Température
        add(celsius, ["°c", "c", "celsius", "degré celsius", "degrés celsius", "degree celsius", "degrees celsius", "℃"])
        add(fahrenheit, ["°f", "f", "fahrenheit", "degré fahrenheit", "degrés fahrenheit", "degrees fahrenheit", "℉"])
        add(kelvin, ["kelvin", "kelvins"])
        // Surface
        add(unit("mm²", .area, 1e-6), ["mm2", "mm²"])
        add(unit("cm²", .area, 1e-4), ["cm2", "cm²"])
        add(unit("m²", .area, 1), ["m2", "m²", "mètre carré", "mètres carrés", "square meter", "square meters", "sqm"])
        add(unit("km²", .area, 1e6), ["km2", "km²", "kilomètre carré", "kilomètres carrés", "square kilometer", "square kilometers"])
        add(unit("ha", .area, 10_000), ["ha", "hectare", "hectares"])
        add(unit("a", .area, 100), ["are", "ares"])
        add(unit("acre", .area, 4_046.8564224), ["acre", "acres"])
        add(unit("ft²", .area, 0.09290304), ["ft2", "ft²", "sq ft", "square foot", "square feet", "pied carré", "pieds carrés"])
        add(unit("in²", .area, 0.00064516), ["in2", "in²", "sq in", "square inch", "square inches"])
        add(unit("mi²", .area, 2_589_988.110336), ["mi2", "mi²", "square mile", "square miles"])
        // Vitesse
        add(unit("m/s", .speed, 1), ["m/s", "mps", "mètre par seconde", "mètres par seconde", "meters per second"])
        add(unit("km/h", .speed, 1 / 3.6), ["km/h", "kmh", "kph", "kilomètre heure", "kilomètres heure", "kilomètres par heure", "kilometers per hour"])
        add(unit("mph", .speed, 0.44704), ["mph", "mi/h", "miles per hour", "miles par heure"])
        add(unit("nd", .speed, 0.514444), ["noeud", "noeuds", "nœud", "nœuds", "knot", "knots", "kn", "kt"])
        add(unit("ft/s", .speed, 0.3048), ["ft/s", "fps", "feet per second"])
        // Temps
        add(unit("ms", .time, 0.001), ["ms", "milliseconde", "millisecondes", "millisecond", "milliseconds"])
        add(second, ["s", "sec", "secs", "seconde", "secondes", "second", "seconds"])
        add(minute, ["min", "mins", "minute", "minutes", "mn"])
        add(hour, ["h", "hr", "hrs", "heure", "heures", "hour", "hours"])
        add(day, ["j", "jour", "jours", "day", "days", "d"])
        add(unit("sem.", .time, 604_800), ["sem", "semaine", "semaines", "week", "weeks", "wk", "wks"])
        add(unit("mois", .time, 2_629_746), ["mois", "month", "months"])
        add(unit("ans", .time, 31_556_952), ["an", "ans", "année", "années", "year", "years", "yr", "yrs"])
        add(unit("siècles", .time, 3_155_695_200), ["siècle", "siècles", "century", "centuries"])
        // Données (formes longues ; les abréviations dépendent de la casse)
        add(unit("bit", .data, 0.125), ["bit", "bits"])
        add(unit("o", .data, 1), ["octet", "octets", "byte", "bytes"])
        add(unit("Ko", .data, 1_000), ["kilooctet", "kilooctets", "kilo-octet", "kilo-octets", "kilobyte", "kilobytes"])
        add(unit("Mo", .data, 1e6), ["mégaoctet", "mégaoctets", "megaoctet", "méga-octet", "méga-octets", "megabyte", "megabytes"])
        add(unit("Go", .data, 1e9), ["gigaoctet", "gigaoctets", "giga-octet", "giga-octets", "gigabyte", "gigabytes"])
        add(unit("To", .data, 1e12), ["téraoctet", "téraoctets", "teraoctet", "téra-octet", "terabyte", "terabytes"])
        add(unit("Kio", .data, 1_024), ["kib", "kio", "kibibyte", "kibibytes"])
        add(unit("Mio", .data, 1_048_576), ["mib", "mio", "mebibyte", "mebibytes"])
        add(unit("Gio", .data, 1_073_741_824), ["gib", "gio", "gibibyte", "gibibytes"])
        add(unit("Tio", .data, 1_099_511_627_776), ["tib", "tio", "tebibyte", "tebibytes"])
        // Énergie
        add(unit("J", .energy, 1), ["joule", "joules"])
        add(unit("kJ", .energy, 1_000), ["kj", "kilojoule", "kilojoules"])
        add(unit("cal", .energy, 4.184), ["cal", "calorie", "calories"])
        add(unit("kcal", .energy, 4_184), ["kcal", "kilocalorie", "kilocalories", "kcals"])
        add(unit("Wh", .energy, 3_600), ["wh", "wattheure", "wattheures", "watt hour", "watt hours"])
        add(unit("kWh", .energy, 3.6e6), ["kwh", "kilowattheure", "kilowattheures", "kilowatt hour", "kilowatt hours"])
        add(unit("eV", .energy, 1.602176634e-19), ["ev", "électronvolt", "electronvolt"])
        add(unit("BTU", .energy, 1_055.06), ["btu"])
        // Pression
        add(unit("Pa", .pressure, 1), ["pa", "pascal", "pascals"])
        add(unit("hPa", .pressure, 100), ["hpa", "hectopascal", "hectopascals"])
        add(unit("kPa", .pressure, 1_000), ["kpa", "kilopascal", "kilopascals"])
        add(unit("bar", .pressure, 100_000), ["bar", "bars"])
        add(unit("mbar", .pressure, 100), ["mbar", "millibar", "millibars"])
        add(unit("atm", .pressure, 101_325), ["atm", "atmosphère", "atmosphères", "atmosphere", "atmospheres"])
        add(unit("psi", .pressure, 6_894.757), ["psi"])
        add(unit("mmHg", .pressure, 133.322), ["mmhg"])
        // Angle
        add(unit("°", .angle, Double.pi / 180), ["°", "deg", "degré", "degrés", "degree", "degrees"])
        add(unit("rad", .angle, 1), ["rad", "radian", "radians"])
        add(unit("grad", .angle, Double.pi / 200), ["grad", "grade", "grades", "gon"])
        add(unit("tr", .angle, 2 * Double.pi), ["tour", "tours", "turn", "turns", "rev"])
        // Puissance
        add(unit("W", .power, 1), ["w", "watt", "watts"])
        add(unit("kW", .power, 1_000), ["kw", "kilowatt", "kilowatts"])
        add(unit("MW", .power, 1e6), ["mégawatt", "mégawatts", "megawatt", "megawatts"])
        add(unit("ch", .power, 735.49875), ["ch", "cheval", "chevaux", "cheval-vapeur", "chevaux-vapeur"])
        add(unit("hp", .power, 745.699872), ["hp", "horsepower"])
        return table
    }()

    /// Abréviations dont la casse compte (Mb mégabit, MB mégaoctet, MW mégawatt…).
    static let caseSensitive: [String: CalcUnit] = [
        "b": unit("bit", .data, 0.125),
        "B": unit("o", .data, 1),
        "o": unit("o", .data, 1),
        "kb": unit("kbit", .data, 125), "Kb": unit("kbit", .data, 125), "kbit": unit("kbit", .data, 125),
        "KB": unit("Ko", .data, 1_000), "kB": unit("Ko", .data, 1_000), "Ko": unit("Ko", .data, 1_000), "ko": unit("Ko", .data, 1_000),
        "Mb": unit("Mbit", .data, 125_000), "Mbit": unit("Mbit", .data, 125_000), "mbit": unit("Mbit", .data, 125_000),
        "MB": unit("Mo", .data, 1e6), "Mo": unit("Mo", .data, 1e6),
        "Gb": unit("Gbit", .data, 1.25e8), "Gbit": unit("Gbit", .data, 1.25e8),
        "GB": unit("Go", .data, 1e9), "Go": unit("Go", .data, 1e9), "go": unit("Go", .data, 1e9),
        "Tb": unit("Tbit", .data, 1.25e11),
        "TB": unit("To", .data, 1e12), "To": unit("To", .data, 1e12),
        "PB": unit("Po", .data, 1e15), "Po": unit("Po", .data, 1e15),
        "MW": unit("MW", .power, 1e6),
        "K": kelvin,
        "J": unit("J", .energy, 1),
    ]

    /// Unités du design : px, pt, rem, em, dont la valeur dépend du contexte (ppi, taille de base).
    static func design(_ alias: String, context: CalcContext) -> CalcUnit? {
        let inch = 0.0254
        switch alias.lowercased() {
        case "px", "pixel", "pixels": return CalcUnit(symbol: "px", category: .length, factor: inch / context.ppi)
        case "pt", "point", "points": return CalcUnit(symbol: "pt", category: .length, factor: inch / 72)
        case "rem": return CalcUnit(symbol: "rem", category: .length, factor: inch / context.ppi * context.remBase)
        case "em": return CalcUnit(symbol: "em", category: .length, factor: inch / context.ppi * context.remBase)
        default: return nil
        }
    }

    /// Tous les alias, pour reconnaître le plus long d'abord (« km/h » avant « km »).
    static let allAliases: [String] = {
        var aliases = Set(caseInsensitive.keys).union(caseSensitive.keys)
        aliases.formUnion(["px", "pixel", "pixels", "pt", "point", "points", "rem", "em"])
        aliases.formUnion(CalcCurrencies.aliases.keys)
        return aliases.sorted { $0.count > $1.count }
    }()

    /// L'unité désignée par un alias exact.
    static func lookup(_ alias: String, context: CalcContext) -> CalcUnit? {
        if let unit = caseSensitive[alias] { return unit }
        if let unit = design(alias, context: context) { return unit }
        if let code = CalcCurrencies.code(for: alias) { return CalcCurrencies.unit(code) }
        return caseInsensitive[alias.lowercased()]
    }

    /// Convertit une valeur d'une unité dans une autre de même grandeur.
    static func convert(_ value: Double, from: CalcUnit, to: CalcUnit, context: CalcContext) -> Double? {
        guard from.category == to.category else { return nil }
        if from.category == .currency {
            guard let source = from.currency, let target = to.currency else { return nil }
            return CalcCurrencies.convert(value, from: source, to: target, rates: context.rates)
        }
        let base = value * from.factor + from.offset
        return (base - to.offset) / to.factor
    }
}
