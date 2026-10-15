import AVFoundation
import AppKit
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// L'état de l'écran de traduction, observé par sa vue.
@MainActor
final class TranslateState: ObservableObject {
    /// Langue source choisie ; `nil` : détection automatique.
    @Published var source: TranslationLanguage?
    @Published var target: TranslationLanguage
    @Published private(set) var text = ""
    @Published private(set) var detected: TranslationLanguage?
    @Published private(set) var output: TranslationOutput?
    @Published private(set) var issue: TranslationIssue?
    @Published private(set) var isTranslating = false
    /// Paire à télécharger par `prepareTranslation` (vue `translationTask`).
    @Published var downloadPair: DownloadPair?

    struct DownloadPair: Equatable {
        let source: TranslationLanguage
        let target: TranslationLanguage
    }

    /// Appelé quand le chargement commence ou finit (indicateur de la barre de recherche).
    var onLoadingChange: ((Bool) -> Void)?

    private var work: Task<Void, Never>?
    private var generation = 0

    init(source: TranslationLanguage?, target: TranslationLanguage) {
        self.source = source
        self.target = target
    }

    /// La langue réellement visée : la langue de repli quand le texte est déjà dans la langue cible.
    var effectiveTarget: TranslationLanguage {
        let from = source ?? detected
        return from == target ? Languages.alternate(for: target) : target
    }

    var translation: String { output?.text ?? "" }

    func update(text newText: String) {
        guard newText != text else { return }
        text = newText
        schedule(delay: 0.3)
    }

    /// Relance la traduction, après un changement de langue ou un téléchargement.
    func retranslate() {
        schedule(delay: 0)
    }

    /// Anti-rebond : la traduction part 300 ms après la dernière frappe.
    private func schedule(delay: Double) {
        work?.cancel()
        generation += 1
        let current = generation
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        detected = source == nil ? Languages.detect(trimmed) : nil
        guard !trimmed.isEmpty else {
            output = nil
            issue = nil
            setTranslating(false)
            return
        }
        let source = source
        let target = effectiveTarget
        // Déjà traduit : aucun délai, rien ne clignote.
        if let cached = Translator.cached(trimmed, from: source, to: target) {
            output = cached
            issue = nil
            setTranslating(false)
            return
        }
        setTranslating(true)
        work = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            do {
                let result = try await Translator.translate(trimmed, from: source, to: target)
                guard let self, self.generation == current else { return }
                self.output = result
                self.issue = nil
            } catch {
                guard let self, self.generation == current, !Task.isCancelled else { return }
                if TranslateDemo.isActive, let demo = TranslateDemo.output(for: trimmed, source: self.detected, target: target) {
                    self.output = demo
                    self.issue = nil
                } else {
                    self.output = nil
                    self.issue = error as? TranslationIssue ?? .failed(error.localizedDescription)
                }
            }
            self?.setTranslating(false)
        }
    }

    private func setTranslating(_ value: Bool) {
        guard isTranslating != value else { return }
        isTranslating = value
        onLoadingChange?(value)
    }
}

/// L'écran « Traduire » : la saisie est le texte source, la traduction s'affiche dessous au fil de la frappe.
@MainActor
final class TranslateScreen: LauncherScreen {
    let state: TranslateState
    /// Fermer plutôt que revenir quand Échap trouve le champ vide (commande lancée par raccourci).
    var closesOnEscape = false
    private var pendingQuery: String?

    /// Sans langues précisées : celles des réglages (source par défaut, dernière cible utilisée).
    convenience init(prefill: String? = nil) {
        let preferences = TranslatePreferences.shared
        self.init(source: preferences.initialSource, target: preferences.initialTarget, prefill: prefill)
    }

    init(source: TranslationLanguage?, target: TranslationLanguage, title: String = "Traduire", prefill: String? = nil) {
        state = TranslateState(source: source, target: target)
        pendingQuery = prefill
        super.init(id: "translate", title: title, placeholder: "Texte à traduire…", icon: .symbol("character.bubble.fill", Palette.blue))
        layout = .custom
        updateFilter()
        state.onLoadingChange = { [weak self] loading in self?.isLoading = loading }
    }

    /// Le menu de la barre de recherche : la langue cible.
    override var filter: ScreenFilter? {
        didSet {
            guard let selected = filter?.selected, selected != state.target.code, let language = Languages.language(code: selected) else { return }
            setTarget(language)
        }
    }

    private func updateFilter() {
        let options = Languages.all.map { ScreenFilter.Option(id: $0.code, title: $0.title) }
        if filter?.selected != state.target.code {
            filter = ScreenFilter(options: options, selected: state.target.code)
        }
    }

    // MARK: - Langues

    func setTarget(_ language: TranslationLanguage) {
        guard state.target != language else { return }
        state.target = language
        TranslatePreferences.shared.lastTarget = language.code
        updateFilter()
        state.retranslate()
        host?.screenStateChanged()
    }

    func setSource(_ language: TranslationLanguage?) {
        guard state.source != language else { return }
        state.source = language
        state.retranslate()
        host?.screenStateChanged()
    }

    /// Inverse les langues, et le texte avec la traduction, comme Raycast.
    func swapLanguages() {
        let from = state.source ?? state.detected
        let to = state.effectiveTarget
        let translation = state.translation
        guard let from else { return }
        state.source = to
        state.target = from
        TranslatePreferences.shared.lastTarget = from.code
        updateFilter()
        if !translation.isEmpty {
            host?.query = translation
            host?.moveCaretToEnd?()
        }
        state.retranslate()
        host?.screenStateChanged()
    }

    func targetPicker() -> LauncherScreen {
        TranslateLanguagePicker.screen(title: "Langue cible", current: state.target, includesDetect: false) { [weak self] language in
            if let language { self?.setTarget(language) }
        }
    }

    func sourcePicker() -> LauncherScreen {
        TranslateLanguagePicker.screen(title: "Langue source", current: state.source, includesDetect: true) { [weak self] language in
            self?.setSource(language)
        }
    }

    // MARK: - Cycle de vie

    override func queryDidChange(_ query: String) {
        state.update(text: query)
    }

    override func didAppear() {
        // Texte transmis par `AppHooks.translate` : posé une fois l'écran entré, sinon le lanceur viderait la saisie.
        guard let prefill = pendingQuery else { return }
        pendingQuery = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, let host = self.host, host.screen === self, host.query.isEmpty else { return }
            host.query = prefill
            host.moveCaretToEnd?()
        }
    }

    override func didDisappear() {
        TranslateSpeaker.stop()
    }

    override func customView() -> AnyView {
        AnyView(TranslateView(state: state, screen: self))
    }

    // MARK: - Clavier

    override func handleKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let host else { return false }
        switch (event.keyCode, modifiers) {
        case (53, []): // Échap : vide le champ, puis ferme.
            if !host.query.isEmpty {
                host.query = ""
                return true
            }
            if closesOnEscape {
                host.close()
                return true
            }
            return false
        case (35, [.command]): // ⌘P
            host.push(targetPicker())
            return true
        case (35, [.command, .shift]): // ⇧⌘P
            host.push(sourcePicker())
            return true
        default:
            return false
        }
    }

    // MARK: - Actions

    static let copyShortcut = KeyShortcut(keyCode: 36, modifiers: [.command], label: "↵")
    static let pasteShortcut = KeyShortcut(keyCode: 36, modifiers: [.command, .option], label: "↵")
    static let copySourceShortcut = KeyShortcut(keyCode: 36, modifiers: [.command, .shift], label: "↵")
    static let swapShortcut = KeyShortcut(keyCode: 1, modifiers: [.command], label: "S")
    static let targetShortcut = KeyShortcut(keyCode: 35, modifiers: [.command], label: "P")
    static let sourceShortcut = KeyShortcut(keyCode: 35, modifiers: [.command, .shift], label: "P")
    static let speakShortcut = KeyShortcut(keyCode: 1, modifiers: [.command, .shift], label: "S")

    override var screenActions: [ItemAction] {
        let translation = state.translation
        let source = host?.query.trimmingCharacters(in: .whitespacesAndNewlines) ?? state.text
        let enter = KeyShortcut(keyCode: 36, modifiers: [], label: "↵")
        let copy = ItemAction(title: "Copier la traduction", symbol: "doc.on.doc", shortcut: TranslatePreferences.shared.primaryAction == .copy ? enter : Self.copyShortcut) {
            guard !translation.isEmpty else { return .toast("Rien à copier") }
            Pasteboard.copy(translation)
            return .hud("Traduction copiée")
        }
        let paste = ItemAction(title: Actions.pasteTitle, symbol: "doc.on.clipboard", shortcut: TranslatePreferences.shared.primaryAction == .paste ? enter : Self.pasteShortcut) {
            guard !translation.isEmpty else { return .toast("Rien à coller") }
            return Paster.paste(translation)
        }
        var actions = TranslatePreferences.shared.primaryAction == .paste ? [paste, copy] : [copy, paste]
        actions.append(ItemAction(title: "Copier le texte source", symbol: "text.quote", shortcut: Self.copySourceShortcut) {
            guard !source.isEmpty else { return .toast("Rien à copier") }
            Pasteboard.copy(source)
            return .hud("Texte source copié")
        })
        if let sendToAIChat = AppHooks.sendToAIChat {
            actions.append(ItemAction(title: "Continuer dans AI Chat", symbol: "bubble.left.and.text.bubble.right", shortcut: .toAI) {
                let target = self.state.effectiveTarget
                var prompt = "Texte original :\n\(source)"
                if !translation.isEmpty { prompt += "\n\nTraduction en \(target.french) :\n\(translation)" }
                return sendToAIChat(prompt, [])
            })
        }

        actions += [
            ItemAction(title: "Inverser les langues", symbol: "arrow.left.arrow.right", shortcut: Self.swapShortcut, section: "Langues") { [weak self] in
                self?.swapLanguages()
                return .stay
            },
            ItemAction(title: "Langue cible : \(state.effectiveTarget.title)…", symbol: "character.bubble", shortcut: Self.targetShortcut, section: "Langues") { [weak self] in
                guard let self else { return .stay }
                return .push(self.targetPicker())
            },
            ItemAction(title: "Langue source : \(state.source?.title ?? "Détecter")…", symbol: "text.magnifyingglass", shortcut: Self.sourceShortcut, section: "Langues") { [weak self] in
                guard let self else { return .stay }
                return .push(self.sourcePicker())
            },
        ]

        if case .notInstalled(let from, let to) = state.issue {
            actions += TranslateScreen.downloadActions(state: state, from: from, to: to)
        }

        if !translation.isEmpty {
            actions.append(ItemAction(title: TranslateSpeaker.isSpeaking ? "Arrêter la lecture" : "Prononcer la traduction", symbol: "speaker.wave.2", shortcut: Self.speakShortcut, section: "Écouter") { [weak self] in
                guard let self else { return .stay }
                TranslateSpeaker.toggle(translation, language: self.state.effectiveTarget)
                return .stay
            })
        }
        if !source.isEmpty, let language = state.source ?? state.detected {
            actions.append(ItemAction(title: "Prononcer le texte source", symbol: "speaker.wave.1", section: "Écouter") {
                TranslateSpeaker.toggle(source, language: language)
                return .stay
            })
        }

        let pairName = TranslationCommand.defaultName(source: state.source, target: state.effectiveTarget)
        actions.append(ItemAction(title: "Créer la commande « \(pairName) »", symbol: "plus.square.on.square", shortcut: .create, section: "Commandes") { [weak self] in
            .push(TranslationCommandForms.form(for: TranslationCommand(name: pairName, source: self?.state.source?.code, target: self?.state.effectiveTarget.code ?? "en")))
        })
        actions.append(ItemAction(title: "Réglages de la traduction", symbol: "gearshape", section: "Commandes") {
            SettingsNavigation.shared.selection = "translate"
            NotificationCenter.default.post(name: .prismOpenSettings, object: nil)
            return .close
        })
        return actions
    }

    static func downloadActions(state: TranslateState, from: TranslationLanguage, to: TranslationLanguage) -> [ItemAction] {
        [
            ItemAction(title: "Télécharger \(from.french) et \(to.french)", symbol: "arrow.down.circle", section: "Langues") {
                state.downloadPair = .init(source: from, target: to)
                return .stay
            },
            ItemAction(title: "Ouvrir les réglages des langues de traduction", symbol: "gearshape", section: "Langues") {
                Translator.openLanguageSettings()
                return .close
            },
        ]
    }
}

// MARK: - Vue

struct TranslateView: View {
    @ObservedObject var state: TranslateState
    let screen: TranslateScreen
    @ObservedObject private var speaker = TranslateSpeaker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.separator).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .modifier(TranslationDownloadModifier(state: state))
    }

    // Langues et compteur.
    private var header: some View {
        HStack(spacing: 8) {
            LanguageChip(
                title: sourceTitle,
                symbol: state.source == nil ? "wand.and.stars" : nil,
                help: "Langue source (⇧⌘P)"
            ) { screen.host?.push(screen.sourcePicker()) }
            Button {
                screen.swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .help("Inverser les langues (⌘S)")
            LanguageChip(title: state.effectiveTarget.title, symbol: nil, help: "Langue cible (⌘P)") {
                screen.host?.push(screen.targetPicker())
            }
            if state.effectiveTarget != state.target {
                Text("déjà en \(state.target.french)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if !state.text.isEmpty {
                Text(TextStats.summary(state.text))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private var sourceTitle: String {
        if let source = state.source { return source.title }
        if let detected = state.detected { return "Détecté : \(detected.french)" }
        return "Détecter la langue"
    }

    @ViewBuilder
    private var content: some View {
        if state.text.isEmpty {
            placeholder(symbol: "character.bubble", title: "Tapez ou collez un texte à traduire",
                        detail: "Vers le \(state.target.french). ⌘P change la langue cible, ⇧⌘P la langue source, ⌘S les inverse.")
        } else if let output = state.output {
            ScrollView(.vertical) {
                Text(output.text)
                    .font(.system(size: fontSize(for: output.text), weight: .regular))
                    .lineSpacing(3)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                    .opacity(state.isTranslating ? 0.55 : 1)
                    .animation(.easeOut(duration: 0.15), value: state.isTranslating)
            }
            .scrollIndicators(.automatic)
        } else if let issue = state.issue {
            issueView(issue)
        } else {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Traduction…")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private func fontSize(for text: String) -> CGFloat {
        switch text.count {
        case ..<80: 26
        case ..<220: 21
        case ..<500: 17
        default: 15
        }
    }

    private func placeholder(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func issueView(_ issue: TranslationIssue) -> some View {
        VStack(spacing: 12) {
            Image(systemName: issue.symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Palette.orange)
            Text(issue.message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            if case .notInstalled(let from, let to) = issue {
                HStack(spacing: 8) {
                    Button("Télécharger") { state.downloadPair = .init(source: from, target: to) }
                    Button("Réglages des langues…") { Translator.openLanguageSettings() }
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    // Moteur et raccourcis.
    private var footer: some View {
        HStack(spacing: 10) {
            if let output = state.output {
                Label(output.engine.label, systemImage: output.engine.symbol)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .labelStyle(.titleAndIcon)
            }
            Spacer()
            if speaker.isSpeaking {
                Label("Lecture…", systemImage: "speaker.wave.2.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 30)
    }
}

extension TranslationIssue {
    var symbol: String {
        switch self {
        case .notInstalled: "arrow.down.circle"
        case .undetectable: "questionmark.circle"
        default: "exclamationmark.triangle"
        }
    }
}

/// Pastille cliquable d'une langue, dans l'en-tête de la traduction.
private struct LanguageChip: View {
    let title: String
    let symbol: String?
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.keycap))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Téléchargement des langues par le système (`prepareTranslation`), quand une paire manque.
private struct TranslationDownloadModifier: ViewModifier {
    @ObservedObject var state: TranslateState

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(macOS 15, *) {
            content.translationTask(configuration) { session in
                // La feuille du système prend le clavier : le lanceur reste ouvert le temps du téléchargement.
                AppContext.launcher?.keepOpenOnResign = true
                defer { AppContext.launcher?.keepOpenOnResign = false }
                do {
                    try await session.prepareTranslation()
                } catch {
                    Translator.openLanguageSettings()
                }
                state.downloadPair = nil
                state.retranslate()
            }
        } else {
            content
        }
        #else
        content
        #endif
    }

    #if canImport(Translation)
    @available(macOS 15, *)
    private var configuration: TranslationSession.Configuration? {
        state.downloadPair.map { TranslationSession.Configuration(source: $0.source.localeLanguage, target: $0.target.localeLanguage) }
    }
    #endif
}

// MARK: - Choix d'une langue

/// Liste des langues avec recherche floue (« jap » → japonais), ouverte par ⌘P et ⇧⌘P.
@MainActor
enum TranslateLanguagePicker {
    static func screen(title: String, current: TranslationLanguage?, includesDetect: Bool, choose: @escaping @MainActor (TranslationLanguage?) -> Void) -> LauncherScreen {
        let statuses = TranslationStatusCache.shared
        let screen = ListScreen(
            id: "translate.picker",
            title: title,
            placeholder: "Rechercher une langue…",
            icon: .symbol("globe", Palette.blue)
        ) { query in
            var items: [ResultItem] = []
            if includesDetect, query.isEmpty || Fuzzy.score(query.normalizedForSearch, "detecter automatiquement detect") != nil {
                items.append(ResultItem(
                    id: "language:auto",
                    title: "Détecter la langue",
                    subtitle: "Reconnue au fil de la frappe",
                    icon: current == nil ? .tinted("checkmark", Theme.accent) : .glyph("wand.and.stars"),
                    usageKey: "",
                    actions: [ItemAction(title: "Choisir", symbol: "checkmark") { choose(nil); return .pop }]
                ))
            }
            for language in Languages.search(query) {
                items.append(ResultItem(
                    id: "language:" + language.code,
                    title: language.title,
                    subtitle: language.english == language.nativeName ? language.english : "\(language.english) · \(language.nativeName)",
                    icon: language == current ? .tinted("checkmark", Theme.accent) : .glyph("character.bubble"),
                    accessory: statuses.label(for: language),
                    usageKey: "",
                    actions: [ItemAction(title: "Choisir \(language.french)", symbol: "checkmark") { choose(language); return .pop }]
                ))
            }
            return items.isEmpty ? [] : [ResultSection(id: "languages", title: "Langues", items: items)]
        }
        screen.onAppear = { [weak screen] in
            statuses.refresh { screen?.reload() }
        }
        return screen
    }
}

/// L'état des langues dans Apple Translation (installée, à télécharger), lu une fois puis gardé.
@MainActor
final class TranslationStatusCache: ObservableObject {
    static let shared = TranslationStatusCache()
    @Published private(set) var statuses: [String: Translator.PairStatus] = [:]
    private var loading = false
    private var loadedAt = Date.distantPast

    func label(for language: TranslationLanguage) -> String? {
        switch statuses[language.code] {
        case .installed: "Installée"
        case .downloadable: "À télécharger"
        case .unsupported: Translator.isAIAvailable ? "Par l’IA" : "Non prise en charge"
        case .unavailable, nil: nil
        }
    }

    /// Chaque langue est testée avec l'anglais (le français pour l'anglais lui-même).
    func refresh(force: Bool = false, completion: (@MainActor () -> Void)? = nil) {
        guard Translator.isAppleAvailable, !loading, force || Date().timeIntervalSince(loadedAt) > 60 else { return }
        loading = true
        Task { @MainActor in
            var result: [String: Translator.PairStatus] = [:]
            let english = Languages.all[0]
            let french = Languages.all[1]
            for language in Languages.all {
                result[language.code] = await Translator.status(from: language, to: language == english ? french : english)
            }
            statuses = result
            loading = false
            loadedAt = Date()
            completion?()
        }
    }
}

// MARK: - Lecture à voix haute

@MainActor
final class TranslateSpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = TranslateSpeaker()
    @Published private(set) var isSpeakingNow = false
    private let synthesizer = AVSpeechSynthesizer()

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    static var isSpeaking: Bool { shared.isSpeakingNow }

    static func toggle(_ text: String, language: TranslationLanguage) {
        if shared.synthesizer.isSpeaking {
            stop()
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice(for: language)
        shared.synthesizer.speak(utterance)
        shared.isSpeakingNow = true
    }

    static func stop() {
        guard shared.synthesizer.isSpeaking else { return }
        shared.synthesizer.stopSpeaking(at: .immediate)
        shared.isSpeakingNow = false
    }

    /// La meilleure voix installée de la langue : améliorée si possible, celle de la région du système sinon.
    static func voice(for language: TranslationLanguage) -> AVSpeechSynthesisVoice? {
        let prefixes: [String]
        switch language.code {
        case "zh-Hans": prefixes = ["zh-CN"]
        case "zh-Hant": prefixes = ["zh-TW", "zh-HK"]
        case "pt-BR": prefixes = ["pt-BR", "pt"]
        case "nb": prefixes = ["nb", "no"]
        default: prefixes = [language.code]
        }
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            prefixes.contains { voice.language.hasPrefix($0) }
        }
        return voices.max { lhs, rhs in lhs.quality.rawValue < rhs.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: prefixes[0])
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { TranslateSpeaker.shared.isSpeakingNow = false } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { TranslateSpeaker.shared.isSpeakingNow = false } }
    }
}

extension TranslateSpeaker {
    var isSpeaking: Bool { isSpeakingNow }
}

// MARK: - Démonstration

/// Rendu hors écran (`--snapshot`) sans moteur disponible : une traduction factice, signalée comme telle.
enum TranslateDemo {
    static var isActive: Bool { CommandLine.arguments.contains("--snapshot") }

    @MainActor
    static func output(for text: String, source: TranslationLanguage?, target: TranslationLanguage) -> TranslationOutput? {
        let samples: [String: String] = [
            "fr": "Bonjour, comment allez-vous aujourd’hui ? Le temps est magnifique.",
            "en": "Hello, how are you today? The weather is lovely.",
            "de": "Hallo, wie geht es Ihnen heute? Das Wetter ist herrlich.",
        ]
        let text = samples[target.code] ?? "[\(target.title)] \(text)"
        return TranslationOutput(text: text, source: source, target: target, engine: .demo)
    }
}
