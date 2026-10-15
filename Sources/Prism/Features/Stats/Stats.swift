import AppKit
import SwiftUI

/// « Mes statistiques », à la manière de Raycast Wrapped : ce que vous lancez le plus, et depuis quand.
@MainActor
enum StatsFeature: PrismFeature {
    static var commands: [ResultItem] {
        [Command.screen("stats", "Mes statistiques", subtitle: "Prism", symbol: "chart.bar.fill", color: Palette.orange, keywords: ["wrapped", "stats", "statistiques", "usage", "utilisation"]) { StatsScreen() }]
    }
}

@MainActor
final class StatsScreen: LauncherScreen {
    init() {
        super.init(id: "stats", title: "Mes statistiques", icon: .symbol("chart.bar.fill", Palette.orange))
        layout = .custom
        hidesSearchField = true
    }

    override func customView() -> AnyView { AnyView(StatsView()) }
}

private struct StatsView: View {
    private struct Row: Identifiable {
        let id: String
        let item: ResultItem?
        let title: String
        let count: Int
    }

    var body: some View {
        let entries = UsageStore.shared.allEntries
        let byID = Dictionary(RootScreen.candidates().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let total = entries.reduce(0) { $0 + $1.count }
        let rows = entries
            .filter { !$0.key.hasPrefix("emoji:") }
            .sorted { $0.count > $1.count }
            .prefix(8)
            .map { entry in Row(id: entry.key, item: byID[entry.key], title: byID[entry.key]?.title ?? label(for: entry.key), count: entry.count) }
        let emojis = entries.filter { $0.key.hasPrefix("emoji:") }.sorted { $0.count > $1.count }.prefix(10)
        let apps = entries.filter { $0.key.hasPrefix("app:") }.reduce(0) { $0 + $1.count }
        let commands = entries.filter { $0.key.hasPrefix("command:") }.reduce(0) { $0 + $1.count }
        let first = entries.map(\.last).min()
        let maxCount = max(rows.first?.count ?? 1, 1)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    tile("\(total)", "lancements")
                    tile("\(apps)", "apps ouvertes")
                    tile("\(commands)", "commandes")
                    tile("\(entries.count)", "éléments différents")
                }
                if rows.isEmpty {
                    Text("Lancez quelques apps et commandes : vos statistiques apparaîtront ici.")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Vos favoris de fait").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(rows) { row in
                            HStack(spacing: 10) {
                                ItemIconView(icon: row.item?.icon ?? .glyph("circle"), size: 20)
                                Text(row.title).font(.system(size: 13)).lineLimit(1).frame(width: 220, alignment: .leading)
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Theme.accent.gradient)
                                    .frame(width: max(6, 330 * CGFloat(row.count) / CGFloat(maxCount)), height: 10)
                                Spacer(minLength: 0)
                                Text("\(row.count)").font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                }
                if !emojis.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Emojis préférés").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            ForEach(Array(emojis.enumerated()), id: \.offset) { _, entry in
                                Text(String(entry.key.dropFirst("emoji:".count))).font(.system(size: 26))
                            }
                        }
                    }
                }
                if let first {
                    Text("Données locales depuis le \(first.formatted(date: .long, time: .omitted)), jamais envoyées.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(24)
        }
    }

    private func tile(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded))
            Text(caption).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.subtleFill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.separator))
    }

    private func label(for key: String) -> String {
        if key.hasPrefix("app:") { return URL(fileURLWithPath: String(key.dropFirst(4))).deletingPathExtension().lastPathComponent }
        if let colon = key.firstIndex(of: ":") { return String(key[key.index(after: colon)...]) }
        return key
    }
}
