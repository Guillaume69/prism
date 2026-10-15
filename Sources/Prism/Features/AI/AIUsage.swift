import AppKit

/// L'utilisation de l'IA, à la place des crédits de Raycast : requêtes et jetons par jour et par modèle,
/// coût estimé d'après des tarifs publics (modifiables), et un budget mensuel facultatif qui bloque les modèles
/// payants une fois atteint. Apple Intelligence et Ollama, sur l'appareil, restent gratuits et jamais bloqués.
@MainActor
final class AIUsage {
    static let shared = AIUsage()

    struct Counter: Codable, Equatable {
        var requests = 0
        var input = 0
        var output = 0
    }

    struct Content: Codable {
        /// « 2026-10-15 » → « anthropic:claude-… » → compteur.
        var days: [String: [String: Counter]] = [:]
        /// Budget mensuel en dollars ; 0 : aucun.
        var monthlyBudget: Double = 0
        /// Le mois déjà averti à 80 % du budget.
        var warnedMonth: String?
    }

    private let store = JSONStore("ai-usage.json", default: Content())

    var content: Content { store.value }

    // MARK: - Jetons et tarifs

    /// Une estimation : environ quatre caractères par jeton (les fournisseurs ne renvoient pas tous le compte).
    nonisolated static func tokens(characters: Int) -> Int { characters == 0 ? 0 : max(1, characters / 4) }

    /// Tarifs publics en dollars par million de jetons (entrée, sortie), par fragment du nom de modèle,
    /// du plus précis au plus général. `ai-prices.json` les remplace (mêmes clés).
    static let defaultPrices: [(match: String, input: Double, output: Double)] = [
        ("opus", 5, 25), ("sonnet", 3, 15), ("haiku", 1, 5),
        ("gpt-5-nano", 0.05, 0.4), ("gpt-5-mini", 0.25, 2), ("gpt-5", 1.25, 10),
        ("gpt-4.1-nano", 0.1, 0.4), ("gpt-4.1-mini", 0.4, 1.6), ("gpt-4.1", 2, 8),
        ("gpt-4o-mini", 0.15, 0.6), ("gpt-4o", 2.5, 10), ("o4-mini", 1.1, 4.4), ("o3", 2, 8),
    ]

    static var pricesFile: URL { StoreLocation.file("ai-prices.json") }

    private func prices() -> [(match: String, input: Double, output: Double)] {
        guard let data = try? Data(contentsOf: Self.pricesFile),
              let custom = try? JSONSerialization.jsonObject(with: data) as? [String: [Double]] else { return Self.defaultPrices }
        let overrides = custom.compactMap { key, value in value.count == 2 ? (match: key, input: value[0], output: value[1]) : nil }
            .sorted { $0.match.count > $1.match.count }
        return overrides + Self.defaultPrices
    }

    /// Le tarif d'un modèle ; zéro pour les modèles sur l'appareil, `nil` s'il est inconnu (fournisseur compatible).
    func price(_ key: String) -> (input: Double, output: Double)? {
        let kind = key.split(separator: ":").first.map(String.init) ?? ""
        if kind == AIProviderKind.apple.rawValue || kind == AIProviderKind.ollama.rawValue { return (0, 0) }
        let model = key.dropFirst(kind.count + 1).lowercased()
        guard let match = prices().first(where: { model.contains($0.match.lowercased()) }) else { return nil }
        return (match.input, match.output)
    }

    func cost(_ key: String, _ counter: Counter) -> Double? {
        price(key).map { (Double(counter.input) * $0.input + Double(counter.output) * $0.output) / 1_000_000 }
    }

    nonisolated static func isPaid(_ kind: AIProviderKind) -> Bool { kind == .anthropic || kind == .openAI }

    // MARK: - Relevé

    nonisolated static func dayKey(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func key(kind: AIProviderKind, model: String) -> String { "\(kind.rawValue):\(model)" }

    func record(kind: AIProviderKind, model: String, inputCharacters: Int, outputCharacters: Int, date: Date = Date()) {
        guard !AIRuntime.isEphemeral else { return }
        let day = Self.dayKey(date)
        let key = Self.key(kind: kind, model: model)
        var counter = store.value.days[day]?[key] ?? Counter()
        counter.requests += 1
        counter.input += Self.tokens(characters: inputCharacters)
        counter.output += Self.tokens(characters: outputCharacters)
        store.value.days[day, default: [:]][key] = counter
        warnIfNeeded()
    }

    /// Les compteurs d'un mois (« 2026-10 »), par modèle.
    func month(_ prefix: String = String(dayKey().prefix(7))) -> [String: Counter] {
        var result: [String: Counter] = [:]
        for (day, models) in store.value.days where day.hasPrefix(prefix) {
            for (key, counter) in models {
                var total = result[key] ?? Counter()
                total.requests += counter.requests
                total.input += counter.input
                total.output += counter.output
                result[key] = total
            }
        }
        return result
    }

    func monthCost(_ prefix: String = String(dayKey().prefix(7))) -> Double {
        month(prefix).reduce(0) { $0 + (cost($1.key, $1.value) ?? 0) }
    }

    // MARK: - Budget

    var monthlyBudget: Double {
        get { store.value.monthlyBudget }
        set { store.value.monthlyBudget = max(0, newValue) }
    }

    /// L'erreur à rendre avant une requête payante quand le budget du mois est atteint.
    func budgetError(for kind: AIProviderKind) -> AIError? {
        guard Self.isPaid(kind), monthlyBudget > 0 else { return nil }
        let spent = monthCost()
        guard spent >= monthlyBudget else { return nil }
        return .unavailable(String(format: "Budget mensuel de l’IA atteint (%.2f $ sur %.2f $). Relevez-le dans « Utilisation de l’IA », ou utilisez Apple Intelligence ou Ollama, gratuits.", spent, monthlyBudget))
    }

    private func warnIfNeeded() {
        let month = String(Self.dayKey().prefix(7))
        guard monthlyBudget > 0, store.value.warnedMonth != month, monthCost() >= monthlyBudget * 0.8 else { return }
        store.value.warnedMonth = month
        HUD.shared.show(String(format: "IA : 80 %% du budget du mois utilisés (%.2f $)", monthCost()), symbol: "gauge.with.dots.needle.67percent")
    }

    func reset() { store.value.days = [:] }

    /// Rend un état antérieur (essais).
    func restore(_ content: Content) { store.value = content }

    // MARK: - Écran

    static func screen() -> LauncherScreen {
        ListScreen(id: "ai.usage", title: "Utilisation de l’IA", placeholder: "Rechercher un modèle…",
                   icon: .symbol("chart.bar.xaxis", Palette.violet)) { query in
            let usage = AIUsage.shared
            let month = usage.month()
            let spent = usage.monthCost()
            let totals = month.values.reduce(Counter()) { Counter(requests: $0.requests + $1.requests, input: $0.input + $1.input, output: $0.output + $1.output) }
            var sections: [ResultSection] = []
            let budget = usage.monthlyBudget > 0 ? String(format: " sur %.2f $ (%.0f %%)", usage.monthlyBudget, spent / usage.monthlyBudget * 100) : " — aucun budget"
            sections.append(ResultSection(id: "month", title: "Ce mois-ci", items: [
                ResultItem(id: "usage.month", title: String(format: "≈ %.2f $ estimés", spent) + budget,
                           subtitle: "\(totals.requests) requête(s) · \(format(totals.input)) jetons envoyés · \(format(totals.output)) reçus",
                           icon: .symbol("gauge.with.dots.needle.50percent", Palette.violet), usageKey: "", actions: actions()),
            ]))
            let rows = month.sorted { (usage.cost($0.key, $0.value) ?? 0, $0.value.requests) > (usage.cost($1.key, $1.value) ?? 0, $1.value.requests) }
                .filter { query.isEmpty || Fuzzy.score(query.normalizedForSearch, label($0.key)) != nil }
                .map { key, counter in
                    let cost = usage.cost(key, counter)
                    return ResultItem(id: "usage.model." + key, title: label(key),
                                      subtitle: "\(counter.requests) requête(s) · \(format(counter.input)) → \(format(counter.output)) jetons",
                                      icon: .symbol(key.hasPrefix("apple") || key.hasPrefix("ollama") ? "cpu" : "cloud", key.hasPrefix("apple") || key.hasPrefix("ollama") ? Palette.green : Palette.blue),
                                      accessory: cost.map { $0 == 0 ? "gratuit (sur l’appareil)" : String(format: "≈ %.3f $", $0) } ?? "tarif inconnu",
                                      usageKey: "", actions: actions())
                }
            if !rows.isEmpty { sections.append(ResultSection(id: "models", title: "Par modèle", items: rows)) }
            let days = usage.content.days.keys.sorted(by: >).prefix(14).map { day -> ResultItem in
                let models = usage.content.days[day] ?? [:]
                let requests = models.values.reduce(0) { $0 + $1.requests }
                let cost = models.reduce(0) { $0 + (usage.cost($1.key, $1.value) ?? 0) }
                return ResultItem(id: "usage.day." + day, title: day, subtitle: "\(requests) requête(s)", icon: .glyph("calendar"),
                                  accessory: String(format: "≈ %.3f $", cost), usageKey: "", actions: actions())
            }
            if query.isEmpty, !days.isEmpty { sections.append(ResultSection(id: "days", title: "Par jour", items: Array(days))) }
            return sections
        }
    }

    private static func actions() -> [ItemAction] {
        [
            ItemAction(title: "Définir le budget mensuel…", symbol: "dollarsign.circle") { .push(budgetForm()) },
            ItemAction(title: "Modifier les tarifs", symbol: "tablecells") {
                if !FileManager.default.fileExists(atPath: pricesFile.path) {
                    let defaults = Dictionary(defaultPrices.map { ($0.match, [$0.input, $0.output]) }, uniquingKeysWith: { first, _ in first })
                    if let data = try? JSONSerialization.data(withJSONObject: defaults, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: pricesFile) }
                }
                NSWorkspace.shared.open(pricesFile)
                return .close
            },
            ItemAction(title: "Remettre les compteurs à zéro", symbol: "arrow.counterclockwise", isDestructive: true) {
                AIUsage.shared.reset()
                return .then(.refresh, .toast("Compteurs remis à zéro"))
            },
        ]
    }

    static func budgetForm() -> LauncherScreen {
        let current = AIUsage.shared.monthlyBudget
        return FormScreen(id: "ai.usage.budget", title: "Budget mensuel de l’IA", icon: .symbol("dollarsign.circle", Palette.violet), fields: [
            FormField(id: "budget", label: "Budget ($)", kind: .text, placeholder: "0 : aucun budget", value: current > 0 ? String(format: "%.2f", current) : "",
                      info: "Au-delà, Prism refuse les requêtes aux modèles payants (Anthropic, OpenAI) jusqu’au mois suivant. Apple Intelligence et Ollama restent disponibles."),
        ]) { state in
            let raw = state.trimmed("budget").replacingOccurrences(of: ",", with: ".")
            guard raw.isEmpty || Double(raw) != nil else { state.error = "Un nombre, par exemple 10 ou 12,50"; return .stay }
            AIUsage.shared.monthlyBudget = Double(raw) ?? 0
            return .then(.pop, .toast(raw.isEmpty || Double(raw) == 0 ? "Aucun budget" : "Budget enregistré"))
        }
    }

    private static func label(_ key: String) -> String {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = AIProviderKind(rawValue: parts[0]) else { return key }
        return AIModelChoice.model(kind, parts[1]).label
    }

    private static func format(_ count: Int) -> String {
        count >= 1_000_000 ? String(format: "%.1f M", Double(count) / 1_000_000) : count >= 1000 ? String(format: "%.1f k", Double(count) / 1000) : "\(count)"
    }

    // MARK: - Autotests

    static func selfTest(_ check: (Bool, String) -> Void) {
        check(tokens(characters: 400) == 100 && tokens(characters: 0) == 0, "utilisation de l’IA : jetons estimés")
        let usage = AIUsage.shared
        check(usage.price("apple:")?.input == 0 && usage.price("ollama:llama3.2")?.output == 0, "utilisation de l’IA : modèles sur l’appareil gratuits")
        check(usage.price("anthropic:claude-sonnet-5-5")?.input == 3 && usage.price("openai:gpt-5-mini")?.output == 2, "utilisation de l’IA : tarifs par modèle")
        check(usage.price("openai:custom:groq/llama") == nil, "utilisation de l’IA : tarif inconnu signalé")
        let cost = usage.cost("anthropic:claude-sonnet-5-5", Counter(requests: 1, input: 1_000_000, output: 100_000))
        check(cost.map { abs($0 - 4.5) < 0.001 } == true, "utilisation de l’IA : coût estimé")
        check(isPaid(.anthropic) && !isPaid(.apple) && !isPaid(.ollama), "utilisation de l’IA : seuls les modèles payants sont budgétés")
    }
}
