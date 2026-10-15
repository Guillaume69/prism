import Foundation

/// Devises et cryptomonnaies : codes, symboles, noms français et anglais.
enum CalcCurrencies {
    static let fiat = [
        "EUR", "USD", "GBP", "CHF", "JPY", "CNY", "CAD", "AUD", "NZD", "SEK", "NOK", "DKK", "PLN", "CZK", "HUF", "RON",
        "BGN", "TRY", "RUB", "UAH", "INR", "BRL", "MXN", "ARS", "CLP", "COP", "ZAR", "MAD", "TND", "DZD", "EGP", "NGN",
        "KRW", "SGD", "HKD", "TWD", "THB", "IDR", "MYR", "PHP", "VND", "ILS", "AED", "SAR", "QAR", "KWD", "XOF", "XAF",
        "ISK", "PKR", "BDT", "LKR", "KES", "PEN", "UYU",
    ]
    static let crypto = ["BTC", "ETH", "SOL", "XRP", "ADA", "DOGE", "LTC", "DOT", "AVAX", "MATIC", "BNB", "USDT", "USDC", "TRX", "LINK", "XLM"]

    static let aliases: [String: String] = {
        var table: [String: String] = [:]
        for code in fiat + crypto { table[code.lowercased()] = code }
        let names: [String: [String]] = [
            "EUR": ["€", "euro", "euros"],
            "USD": ["$", "us$", "dollar", "dollars", "dollar américain", "dollars américains", "usd$"],
            "GBP": ["£", "livre sterling", "livres sterling", "pound sterling", "pounds sterling", "sterling"],
            "JPY": ["¥", "yen", "yens"],
            "CNY": ["yuan", "yuans", "renminbi", "rmb"],
            "CHF": ["franc suisse", "francs suisses", "swiss franc", "swiss francs"],
            "CAD": ["dollar canadien", "dollars canadiens", "canadian dollar", "canadian dollars", "c$"],
            "AUD": ["dollar australien", "dollars australiens", "australian dollar", "australian dollars", "a$"],
            "INR": ["₹", "roupie", "roupies", "rupee", "rupees"],
            "KRW": ["₩", "won", "wons"],
            "RUB": ["₽", "rouble", "roubles", "ruble", "rubles"],
            "TRY": ["₺", "livre turque", "livres turques", "lira", "liras"],
            "BRL": ["r$", "real", "reais", "réal", "réaux"],
            "MXN": ["peso mexicain", "pesos mexicains", "mexican peso", "mexican pesos"],
            "MAD": ["dirham", "dirhams"],
            "ILS": ["₪", "shekel", "shekels"],
            "UAH": ["₴", "hryvnia"],
            "PLN": ["zł", "zloty", "zlotys"],
            "THB": ["฿", "baht"],
            "VND": ["₫", "dong"],
            "NGN": ["₦", "naira"],
            "SEK": ["couronne suédoise", "couronnes suédoises", "swedish krona"],
            "NOK": ["couronne norvégienne", "couronnes norvégiennes", "norwegian krone"],
            "DKK": ["couronne danoise", "couronnes danoises", "danish krone"],
            "XOF": ["franc cfa", "francs cfa", "fcfa"],
            "BTC": ["₿", "bitcoin", "bitcoins"],
            "ETH": ["ether", "ethereum", "Ξ"],
            "SOL": ["solana"],
            "DOGE": ["dogecoin"],
            "LTC": ["litecoin"],
            "XRP": ["ripple"],
            "ADA": ["cardano"],
        ]
        for (code, list) in names {
            for name in list { table[name.lowercased()] = code }
        }
        return table
    }()

    static func code(for alias: String) -> String? {
        aliases[alias.lowercased()]
    }

    static func unit(_ code: String) -> CalcUnit {
        CalcUnit(symbol: code, category: .currency, factor: 1, currency: code)
    }

    static func isCrypto(_ code: String) -> Bool { crypto.contains(code) }

    /// Taux exprimés pour 1 EUR : montant en EUR = montant / taux.
    static func convert(_ value: Double, from source: String, to target: String, rates: [String: Double]) -> Double? {
        if source == target { return value }
        let sourceRate = source == "EUR" ? 1 : rates[source]
        let targetRate = target == "EUR" ? 1 : rates[target]
        guard let sourceRate, let targetRate, sourceRate > 0 else { return nil }
        return value / sourceRate * targetRate
    }

    /// « 1 234,56 $ US », ou « 0,00123 BTC » pour une cryptomonnaie.
    static func format(_ value: Double, code: String, locale: Locale, grouping: Bool = true) -> String {
        if isCrypto(code) {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = grouping
            formatter.maximumFractionDigits = abs(value) < 1 ? 8 : 4
            return (formatter.string(from: NSNumber(value: value)) ?? "\(value)") + " " + code
        }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.usesGroupingSeparator = grouping
        if abs(value) < 0.01, value != 0 { formatter.maximumFractionDigits = 6 }
        return formatter.string(from: NSNumber(value: value)) ?? "\(value) \(code)"
    }
}

/// Les taux de change, gardés dans `calculator-rates.json` et rafraîchis une fois par jour, en arrière-plan.
/// Sources publiques sans clé : open.er-api.com (devises) et Coinbase (cryptomonnaies). Aucune donnée envoyée.
@MainActor
final class CurrencyRates {
    static let shared = CurrencyRates()

    struct Snapshot: Codable {
        var rates: [String: Double]
        var date: Date
    }

    private(set) var snapshot: Snapshot?
    private var isRefreshing = false
    private let fileName = "calculator-rates.json"

    private init() {
        if let data = try? Data(contentsOf: StoreLocation.file(fileName)) {
            snapshot = try? JSONDecoder.prism.decode(Snapshot.self, from: data)
        }
    }

    var rates: [String: Double] { snapshot?.rates ?? [:] }
    var date: Date? { snapshot?.date }

    /// Relance le téléchargement si les taux ont plus d'un jour (ou si c'est demandé).
    func refreshIfNeeded(force: Bool = false) {
        if !force, let date, Date().timeIntervalSince(date) < 86_400 { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            var merged = rates
            var date = Date()
            if let fiat = await Self.fetchFiat() {
                merged.merge(fiat.rates) { _, new in new }
                date = fiat.date
            }
            if let crypto = await Self.fetchCrypto() {
                merged.merge(crypto) { _, new in new }
            }
            isRefreshing = false
            guard !merged.isEmpty else { return }
            let snapshot = Snapshot(rates: merged, date: date)
            self.snapshot = snapshot
            if let data = try? JSONEncoder.prism.encode(snapshot) {
                try? data.write(to: StoreLocation.file(fileName), options: .atomic)
            }
            NotificationCenter.default.post(name: .prismDataDidChange, object: nil)
        }
    }

    private static func fetchFiat() async -> (rates: [String: Double], date: Date)? {
        guard let url = URL(string: "https://open.er-api.com/v6/latest/EUR"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rates = json["rates"] as? [String: Double] else { return nil }
        let date = (json["time_last_update_unix"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
        return (rates, date)
    }

    private static func fetchCrypto() async -> [String: Double]? {
        guard let url = URL(string: "https://api.coinbase.com/v2/exchange-rates?currency=EUR"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["data"] as? [String: Any],
              let rates = payload["rates"] as? [String: String] else { return nil }
        var result: [String: Double] = [:]
        for code in CalcCurrencies.crypto {
            if let text = rates[code], let value = Double(text) { result[code] = value }
        }
        return result
    }
}
