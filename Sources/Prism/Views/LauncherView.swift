import AppKit
import SwiftUI

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject private var themes = ThemeStore.shared
    let onSearchFieldCreated: (NSTextField) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(model: model, onFieldCreated: onSearchFieldCreated)
                .background(WindowDragArea(onDoubleClick: Self.resetPosition))
            if !model.compactFavorites.isEmpty {
                CompactFavorites(model: model)
            }
            if !model.isCompact {
                Rectangle().fill(Theme.separator).frame(height: 1)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                BottomBar(model: model)
            }
        }
        .frame(width: LauncherLayout.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.windowTint)
        .themedText()
        .tint(Theme.accent)
        .overlay(alignment: .bottomTrailing) {
            if model.isActionPanelOpen {
                ActionPanelView(model: model)
                    .padding(.trailing, 10)
                    .padding(.bottom, LauncherLayout.footerHeight + 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: LauncherLayout.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LauncherLayout.cornerRadius, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.12), value: model.isActionPanelOpen)
        .environment(\.colorScheme, themes.current.isDark ? .dark : .light)
    }

    /// Double-clic sur la barre de recherche ou le pied : le lanceur revient à sa place habituelle.
    fileprivate static func resetPosition(_ window: NSWindow) {
        NotificationCenter.default.post(name: .prismLauncherResetPosition, object: window)
    }

    @ViewBuilder
    private var content: some View {
        let screen = model.screen
        switch screen.layout {
        case .custom:
            screen.customView()
                .id(ObjectIdentifier(screen))
        case .split(let listWidth):
            if model.sections.isEmpty {
                EmptyStateView(screen: screen, query: model.query)
            } else {
                HStack(spacing: 0) {
                    ResultList(model: model, compact: true)
                        .frame(width: listWidth)
                    Rectangle().fill(Theme.separator).frame(width: 1)
                    DetailPane(item: model.selectedItem)
                }
            }
        case .list:
            if model.sections.isEmpty {
                EmptyStateView(screen: screen, query: model.query)
            } else {
                ResultList(model: model, compact: false)
            }
        }
    }
}

// MARK: - Barre de recherche

private struct SearchBar: View {
    @ObservedObject var model: LauncherModel
    let onFieldCreated: (NSTextField) -> Void

    var body: some View {
        let screen = model.screen
        HStack(spacing: 12) {
            if !model.isRoot {
                Button(action: model.pop) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.keycap))
                }
                .buttonStyle(.plain)
                .help("Retour (Échap)")
            }
            // Un seul champ, toujours présent : les formulaires le masquent sous leur titre.
            ZStack(alignment: .leading) {
                SearchField(text: $model.query, placeholder: screen.placeholder, onCreate: onFieldCreated)
                    .opacity(screen.hidesSearchField ? 0 : 1)
                    .allowsHitTesting(!screen.hidesSearchField)
                if screen.hidesSearchField {
                    HStack(spacing: 9) {
                        ItemIconView(icon: screen.icon, size: 20)
                        Text(screen.title)
                            .font(.system(size: 17, weight: .medium))
                            .lineLimit(1)
                    }
                }
            }
            if model.showsInlineArguments, let item = model.selectedItem {
                InlineArguments(model: model, arguments: item.arguments)
            }
            if model.isSearching {
                ProgressView().controlSize(.small)
            }
            if let filter = screen.filter {
                Menu {
                    ForEach(filter.options) { option in
                        Button {
                            model.selectFilter(option.id)
                        } label: {
                            if option.id == filter.selected {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                } label: {
                    Text(filter.selectedTitle)
                        .font(.system(size: 12.5, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.keycap))
                .help("Filtrer (⌘P)")
            } else if !model.isRoot, !screen.hidesSearchField {
                HStack(spacing: 6) {
                    ItemIconView(icon: screen.icon, size: 16)
                    Text(screen.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, 4)
                .padding(.trailing, 10)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(Theme.keycap))
            }
        }
        .padding(.horizontal, 18)
        .frame(height: LauncherLayout.searchHeight)
    }
}

/// Les arguments d'une commande, tapés dans la barre de recherche (Tab pour y aller, ↵ pour lancer).
private struct InlineArguments: View {
    @ObservedObject var model: LauncherModel
    let arguments: [ItemArgument]
    @FocusState private var focused: Int?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(arguments.enumerated()), id: \.offset) { index, argument in
                field(index, argument)
            }
        }
        .onChange(of: model.argumentFocus) { _, value in focused = value }
        .onChange(of: focused) { _, value in if value != nil { model.argumentFocus = value } }
        .onAppear { focused = model.argumentFocus }
    }

    private func binding(_ index: Int) -> Binding<String> {
        Binding(
            get: { index < model.inlineArguments.count ? model.inlineArguments[index] : "" },
            set: { value in
                while model.inlineArguments.count <= index { model.inlineArguments.append("") }
                model.inlineArguments[index] = value
            }
        )
    }

    @ViewBuilder
    private func field(_ index: Int, _ argument: ItemArgument) -> some View {
        Group {
            if argument.options.isEmpty {
                if argument.isSecure {
                    SecureField(argument.placeholder, text: binding(index))
                } else {
                    TextField(argument.placeholder, text: binding(index))
                }
            } else {
                Picker("", selection: binding(index)) {
                    Text(argument.placeholder).tag("")
                    ForEach(argument.options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .focused($focused, equals: index)
        .frame(width: 128)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.keycap))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(focused == index ? Theme.accent.opacity(0.8) : Theme.separator, lineWidth: 1)
        )
        .help(argument.isOptional ? "Facultatif" : "Requis")
    }
}

/// Les favoris en icônes, sous la barre du mode compact (⌘1 à ⌘9 les lancent).
private struct CompactFavorites: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(model.compactFavorites.prefix(10).enumerated()), id: \.element.id) { index, item in
                Button {
                    model.select(item.id)
                    model.activate()
                } label: {
                    ItemIconView(icon: item.icon, size: 30)
                        .frame(width: 46, height: 46)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.subtleFill))
                }
                .buttonStyle(.plain)
                .help(index < 9 ? "\(item.title) (⌘\(index + 1))" : item.title)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }
}

// MARK: - Liste des résultats

private struct ResultList: View {
    @ObservedObject var model: LauncherModel
    let compact: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 4).id("top")
                    ForEach(model.sections) { section in
                        if let title = section.title {
                            SectionHeader(title: title)
                        }
                        if section.columns > 1 {
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: section.columns),
                                spacing: 6
                            ) {
                                ForEach(section.items) { item in
                                    GridCell(item: item, height: section.cellHeight, isSelected: item.id == model.selectedID)
                                        .id(item.id)
                                        .onTapGesture { click(item) }
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.bottom, 6)
                        } else {
                            ForEach(section.items) { item in
                                row(item)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { click(item) }
                            }
                        }
                    }
                    Color.clear.frame(height: 6)
                }
            }
            .scrollIndicators(.never)
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                if id == model.allItems.first?.id {
                    proxy.scrollTo("top", anchor: .top)
                } else {
                    proxy.scrollTo(id)
                }
            }
            .onChange(of: model.resultsVersion) { _, _ in
                proxy.scrollTo("top", anchor: .top)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ResultItem) -> some View {
        if case .calculator(let expression, let result) = item.style {
            CalculatorCard(
                expression: expression,
                result: result,
                leftCaption: item.accessory ?? "Expression",
                rightCaption: item.subtitle ?? "Résultat",
                color: { if case .color(let color) = item.icon { return color } else { return nil } }(),
                isSelected: item.id == model.selectedID
            )
        } else if case .card(let source, let sourceCaption, let result, let resultCaption) = item.style {
            CalculatorCard(expression: source, result: result, leftCaption: sourceCaption, rightCaption: resultCaption, isSelected: item.id == model.selectedID)
        } else {
            ResultRow(item: item, isSelected: item.id == model.selectedID, compact: compact)
        }
    }

    private func click(_ item: ResultItem) {
        if model.selectedID == item.id {
            model.activate()
        } else {
            model.select(item.id)
        }
    }
}

private struct ResultRow: View {
    let item: ResultItem
    let isSelected: Bool
    let compact: Bool

    var body: some View {
        HStack(spacing: 11) {
            ItemIconView(icon: item.icon, size: 22)
            Text(item.title)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)
            if let subtitle = item.subtitle, !compact {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if !compact {
                ForEach(Array(item.tags.prefix(3).enumerated()), id: \.offset) { _, tag in
                    TagView(text: tag)
                }
            }
            if let accessory = item.accessory {
                Text(accessory)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .opacity(item.isDimmed ? 0.45 : 1)
        .padding(.horizontal, 10)
        .frame(height: LauncherLayout.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? Theme.selection : Color.clear)
        )
        .padding(.horizontal, 8)
    }
}

private struct CalculatorCard: View {
    let expression: String
    let result: String
    var leftCaption = "Expression"
    var rightCaption = "Résultat"
    /// Pastille affichée à côté du résultat (couleurs).
    var color: NSColor? = nil
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            column(expression, caption: leftCaption, swatch: nil)
            Image(systemName: "arrow.right")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.tertiary)
            column(result, caption: rightCaption, swatch: color)
        }
        .frame(height: 118)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isSelected ? Theme.selection : Theme.subtleFill)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    private func column(_ text: String, caption: String, swatch: NSColor?) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                if let swatch {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: swatch))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                        .frame(width: 28, height: 28)
                }
                Text(text)
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
            }
            .padding(.horizontal, 18)
            Text(caption)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(Theme.keycap))
        }
        .frame(maxWidth: .infinity)
    }
}

/// Une cellule de grille : emoji ou vignette d'image.
private struct GridCell: View {
    let item: ResultItem
    let height: CGFloat
    let isSelected: Bool

    var body: some View {
        Group {
            if case .thumbnail = item.style {
                VStack(spacing: 5) {
                    ItemIconView(icon: item.icon, size: height - 34)
                        .frame(maxWidth: .infinity)
                    Text(item.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 6)
                }
            } else {
                ItemIconView(icon: item.icon, size: 32)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Theme.selection : Theme.subtleFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.9) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .help(item.title)
    }
}

private struct DetailPane: View {
    let item: ResultItem?

    var body: some View {
        if let detail = item?.detail {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let image = detail.image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: 260)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        if !detail.text.isEmpty {
                            if detail.isMarkdown {
                                MarkdownText(detail.text)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            } else {
                                Text(detail.text)
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                    }
                    .padding(16)
                }
                if !detail.metadata.isEmpty {
                    Rectangle().fill(Theme.separator).frame(height: 1)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Informations")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 6)
                        ForEach(Array(detail.metadata.enumerated()), id: \.offset) { index, entry in
                            HStack {
                                Text(entry.label).foregroundStyle(.secondary)
                                Spacer()
                                Text(entry.value).lineLimit(1).truncationMode(.middle)
                            }
                            .font(.system(size: 12))
                            .padding(.vertical, 6)
                            if index < detail.metadata.count - 1 {
                                Rectangle().fill(Theme.separator).frame(height: 1)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        } else {
            Color.clear
        }
    }
}

private struct EmptyStateView: View {
    let screen: LauncherScreen
    let query: String

    var body: some View {
        let state = screen.emptyState(query: query)
        VStack(spacing: 10) {
            Image(systemName: state.symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(state.message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Barre du bas et panneau d'actions

private struct BottomBar: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        HStack(spacing: 8) {
            leading
            Spacer(minLength: 12)
            if let primary = model.currentActions.first {
                Button(action: model.activate) {
                    HStack(spacing: 8) {
                        Text(primary.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        KeycapRow(symbols: model.selectedItem == nil ? (primary.shortcut?.symbols ?? ["↵"]) : ["↵"])
                    }
                }
                .buttonStyle(.plain)
                if model.currentActions.count > 1 || model.selectedItem != nil {
                    Rectangle().fill(Theme.separator).frame(width: 1, height: 16).padding(.horizontal, 4)
                    Button(action: model.toggleActionPanel) {
                        HStack(spacing: 8) {
                            Text("Actions")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(model.isActionPanelOpen ? .primary : .secondary)
                            KeycapRow(symbols: ["⌘", "K"])
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: LauncherLayout.footerHeight)
        .background {
            // Sous le contenu mais au-dessus du fond : le pied, hors boutons, déplace la fenêtre.
            ZStack {
                Theme.footer
                WindowDragArea(onDoubleClick: LauncherView.resetPosition)
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }

    @ViewBuilder
    private var leading: some View {
        if let toast = model.toast {
            HStack(spacing: 7) {
                Image(systemName: model.toastIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(model.toastIsError ? Palette.orange : Palette.green)
                Text(toast)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .font(.system(size: 12.5, weight: .medium))
        } else if model.selectedItem.map(isGridItem) == true, let item = model.selectedItem {
            HStack(spacing: 8) {
                ItemIconView(icon: item.icon, size: 16)
                Text(item.title.prefix(1).uppercased() + item.title.dropFirst())
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            HStack(spacing: 8) {
                if model.isRoot {
                    PrismMark(size: 16)
                } else {
                    ItemIconView(icon: model.screen.icon, size: 16)
                }
                Text(model.screen.footerTitle ?? model.screen.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func isGridItem(_ item: ResultItem) -> Bool {
        model.sections.contains { $0.columns > 1 && $0.items.contains { $0.id == item.id } }
    }
}

private struct ActionPanelView: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        let actions = model.filteredActions
        let all = model.currentActions
        VStack(alignment: .leading, spacing: 1) {
            Text(model.selectedItem?.title ?? model.screen.title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                            if let section = action.section, index == 0 || actions[index - 1].section != section {
                                Rectangle().fill(Theme.separator).frame(height: 1).padding(.vertical, 3)
                                Text(section)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.bottom, 2)
                            }
                            row(action, index: index, absoluteIndex: all.firstIndex { $0.id == action.id } ?? index)
                                .id(action.id)
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: model.actionIndex) { _, index in
                    if actions.indices.contains(index) { proxy.scrollTo(actions[index].id) }
                }
            }
            Rectangle().fill(Theme.separator).frame(height: 1).padding(.top, 3)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(model.actionFilter.isEmpty ? "Rechercher une action…" : model.actionFilter)
                    .font(.system(size: 12.5))
                    .foregroundStyle(model.actionFilter.isEmpty ? .tertiary : .primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
        }
        .padding(6)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.popover)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
    }

    private func row(_ action: ItemAction, index: Int, absoluteIndex: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: action.symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(action.isDestructive ? Palette.red : .secondary)
                .frame(width: 18)
            Text(action.title)
                .font(.system(size: 13))
                .foregroundStyle(action.isDestructive ? Palette.red : .primary)
                .lineLimit(1)
            Spacer(minLength: 12)
            KeycapRow(symbols: shortcut(for: action, at: absoluteIndex))
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(index == model.actionIndex ? Theme.selection : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.perform(action) }
    }

    private func shortcut(for action: ItemAction, at index: Int) -> [String] {
        guard model.selectedItem != nil else { return action.shortcut?.symbols ?? [] }
        switch index {
        case 0: return ["↵"]
        case 1: return ["⌘", "↵"]
        default: return action.shortcut?.symbols ?? []
        }
    }
}

/// Texte Markdown simple (titres, listes, code, gras, italique, liens), pour l'IA et les détails.
struct MarkdownText: View {
    let source: String

    init(_ source: String) { self.source = source }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(source).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(.system(size: level == 1 ? 18 : level == 2 ? 16 : 14, weight: .semibold))
        case .paragraph(let text):
            inline(text).font(.system(size: 13.5))
        case .bullet(let text, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary).font(.system(size: 13.5))
                inline(text).font(.system(size: 13.5))
            }
        case .quote(let text):
            HStack(spacing: 8) {
                Rectangle().fill(Theme.accent.opacity(0.6)).frame(width: 3)
                inline(text).font(.system(size: 13.5)).foregroundStyle(.secondary)
            }
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(language.isEmpty ? "code" : language)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        Pasteboard.copy(code)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Copier le code")
                }
                ScrollView(.horizontal) {
                    Text(code)
                        .font(.system(size: 12, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .scrollIndicators(.never)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.subtleFill))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.separator))
        case .rule:
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}

enum MarkdownBlock {
    case heading(Int, String)
    case paragraph(String)
    case bullet(String, marker: String)
    case quote(String)
    case code(language: String, code: String)
    case rule

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        var language = ""

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var lines = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(language: language, code: lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(line)
                    code = lines
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush()
                language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                code = []
            } else if trimmed.isEmpty {
                flush()
            } else if trimmed.hasPrefix("#") {
                flush()
                let level = trimmed.prefix { $0 == "#" }.count
                blocks.append(.heading(level, trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if trimmed == "---" || trimmed == "***" {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flush()
                blocks.append(.bullet(String(trimmed.dropFirst(2)), marker: "•"))
            } else if let match = trimmed.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                flush()
                blocks.append(.bullet(String(trimmed[match.upperBound...]), marker: String(trimmed[match].dropLast())))
            } else if trimmed.hasPrefix("> ") {
                flush()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        if let code { blocks.append(.code(language: language, code: code.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}
