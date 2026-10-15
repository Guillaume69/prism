import AVFoundation
import AppKit
import Speech
import SwiftUI

/// Dictée : « Dicter » (à associer à un raccourci global), historique, dernière transcription, note dictée.
@MainActor
enum DictationFeature: PrismFeature {
    static var commands: [ResultItem] {
        var items = [
            Command.run(
                "dictation", "Dicter", subtitle: "Dictée", symbol: "mic.fill", color: Palette.red,
                keywords: ["dictation", "dictate", "dictee", "voix", "voice", "micro", "parler", "transcription", "speech"]
            ) {
                DictationController.shared.toggle()
                return .close
            },
            Command.screen(
                "dictation.history", "Historique des dictées", subtitle: "Dictée", symbol: "clock.arrow.circlepath", color: Palette.red,
                keywords: ["dictation history", "transcriptions", "dictee"], screen: historyScreen
            ),
            Command.make(
                "dictation.last", "Dernière transcription", subtitle: "Dictée", symbol: "text.bubble.fill", color: Palette.red,
                keywords: ["last transcript", "dictee", "coller", "copier"],
                actions: [
                    ItemAction(title: "Coller la dernière transcription", symbol: "doc.on.clipboard") {
                        guard let last = DictationHistory.shared.entries.first else { return .toast("Aucune dictée pour l’instant") }
                        return Paster.paste(last.text)
                    },
                    ItemAction(title: "Copier la dernière transcription", symbol: "doc.on.doc") {
                        guard let last = DictationHistory.shared.entries.first else { return .toast("Aucune dictée pour l’instant") }
                        Pasteboard.copy(last.text)
                        return .hud("Transcription copiée")
                    },
                ]
            ),
        ]
        if AppHooks.createNote != nil {
            items.append(Command.run(
                "dictation.note", "Dicter une note", subtitle: "Dictée", symbol: "note.text", color: Palette.red,
                keywords: ["dictate note", "dictee", "note vocale", "voice note"]
            ) {
                DictationController.shared.toggle(note: true)
                return .close
            })
        }
        return items
    }

    // MARK: - Historique

    static func historyScreen() -> LauncherScreen {
        ListScreen(
            id: "dictation.history",
            title: "Historique des dictées",
            placeholder: "Rechercher dans les dictées…",
            icon: .symbol("clock.arrow.circlepath", Palette.red),
            layout: .split(listWidth: 300),
            empty: { query in
                query.isEmpty
                    ? ("mic", "Aucune dictée pour l’instant.\nLancez « Dicter » et parlez : le texte apparaîtra ici.")
                    : ("magnifyingglass", "Aucune dictée ne contient « \(query) »")
            },
            sections: historySections
        )
    }

    static func historySections(query: String) -> [ResultSection] {
        let normalized = query.normalizedForSearch
        let entries = DictationHistory.shared.entries.filter { normalized.isEmpty || $0.text.normalizedForSearch.contains(normalized) }
        guard !entries.isEmpty else { return [] }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .short
        let full = DateFormatter()
        full.dateStyle = .medium
        full.timeStyle = .short
        let items = entries.map { entry -> ResultItem in
            var metadata: [(label: String, value: String)] = [
                ("Date", full.string(from: entry.date)),
                ("Durée", DictationStats.format(duration: entry.duration)),
                ("Mots", "\(entry.words)"),
                ("Langue", DictationController.languageName(Locale(identifier: entry.language))),
                ("Style", entry.style.title),
                ("Nettoyage", entry.cleanedByAI ? "IA" : "Règles"),
            ]
            if let app = entry.app { metadata.insert(("Application", app), at: 1) }
            var actions = [
                Actions.paste(entry.text),
                Actions.copy(entry.text, hud: "Transcription copiée"),
            ]
            if entry.raw != entry.text {
                actions.append(Actions.copy(entry.raw, title: "Copier la transcription brute", symbol: "waveform", shortcut: .copyText, hud: "Transcription brute copiée"))
            }
            if let createNote = AppHooks.createNote {
                actions.append(ItemAction(title: "Créer une note", symbol: "note.text.badge.plus", shortcut: .create) {
                    createNote(entry.text)
                    return .close
                })
            }
            actions += [
                ItemAction(title: "Supprimer la dictée", symbol: "trash", shortcut: .removeEntry, isDestructive: true) {
                    DictationHistory.shared.remove(entry.id)
                    return .refresh
                },
                ItemAction(title: "Effacer tout l’historique", symbol: "trash.slash", shortcut: .removeAll, isDestructive: true) {
                    DictationHistory.shared.clear()
                    return .refresh
                },
            ]
            return ResultItem(
                id: "dictation:" + entry.id.uuidString,
                title: String(entry.text.prefix(200)),
                icon: .glyph(entry.style == .email ? "envelope" : entry.style == .message ? "bubble.left" : "waveform"),
                accessory: relative.localizedString(for: entry.date, relativeTo: Date()),
                detail: ItemDetail(text: entry.text, metadata: metadata, isMarkdown: false),
                usageKey: "",
                actions: actions
            )
        }
        return [ResultSection(id: "dictations", title: query.isEmpty ? "Récentes" : "Résultats", items: items)]
    }

    // MARK: - Liens profonds

    /// `prism://dictation/toggle`, `…/start`, `…/stop`, `…/cancel`, `…/note`.
    static func handle(url: URL) -> Bool {
        guard url.host == "dictation" else { return false }
        let controller = DictationController.shared
        switch url.path {
        case "/start": if !controller.isRecording { controller.toggle() }
        case "/stop": if controller.isRecording { controller.toggle() }
        case "/cancel": controller.cancel()
        case "/note": controller.toggle(note: true)
        default: controller.toggle()
        }
        return true
    }

    // MARK: - Réglages

    static var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "dictation", title: "Dictée", symbol: "mic.fill", color: Palette.red, order: 61) {
            AnyView(DictationSettingsView())
        }]
    }

    // MARK: - Autotests

    static func selfTest(_ check: (Bool, String) -> Void) {
        check(!DictationCleanup.isFaithful(raw: "Quelle carte ?", cleaned: "La carte est la carte des deux mondes, le monde des humains et le monde des dieux."), "dictée : une réponse de l’IA est refusée")
        check(DictationCleanup.isFaithful(raw: "euh bonjour je voulais te dire que euh demain ça marche", cleaned: "Bonjour, je voulais te dire que demain ça marche."), "dictée : un vrai nettoyage est accepté")
        check(DictationCleanup.stripTranscriptTags("<transcript>\nBonjour.\n</transcript>") == "Bonjour.", "dictée : balises retirées de la réponse")
        let fr = DictationCleanup.clean("euh bonjour, euh je voulais savoir si tu es disponible demain ?", language: "fr-FR", style: .standard)
        check(fr == "Bonjour, je voulais savoir si tu es disponible demain\u{202F}?", "nettoyage français : hésitations, majuscule, espace fine avant ?")
        let colon = DictationCleanup.clean("voici la liste: du pain et du lait", language: "fr-FR", style: .standard)
        check(colon == "Voici la liste\u{00A0}: du pain et du lait.", "espace insécable avant les deux-points, point final")
        check(DictationCleanup.clean("rendez-vous à 10:30", language: "fr-FR", style: .standard) == "Rendez-vous à 10:30.", "heure laissée intacte")
        check(DictationCleanup.clean("c'est génial! vraiment!", language: "fr", style: .standard) == "C'est génial\u{202F}! Vraiment\u{202F}!", "majuscule après le point d'exclamation")
        let en = DictationCleanup.clean("um so I think uh we should ship it , right ?", language: "en-US", style: .standard)
        check(en == "So I think we should ship it, right?", "nettoyage anglais : hésitations et espaces")
        check(DictationCleanup.clean("Umbrella is ready", language: "en", style: .standard) == "Umbrella is ready.", "un mot qui commence par « um » est gardé")
        check(DictationCleanup.clean("ok à tout à l'heure.", language: "fr", style: .message) == "Ok à tout à l'heure", "messagerie : pas de point final")
        check(DictationCleanup.clean("euh", language: "fr", style: .standard).isEmpty, "hésitation seule : texte vide")
        check(DictationCleanup.vocabulary(from: "Prism, Raycast\nSwiftUI, prism").count == 3, "vocabulaire sans doublon")
        check(DictationCleanup.vocabulary(from: (1...80).map { "mot\($0)" }.joined(separator: ",")).count == 50, "vocabulaire limité à 50 mots")
        let prompt = DictationCleanup.aiSystemPrompt(language: "fr-FR", style: .email, instructions: "Tutoie", vocabulary: ["Prism"])
        check(prompt.contains("email") && prompt.contains("Prism") && prompt.contains("Tutoie"), "consignes de l'IA : style, vocabulaire, instructions")

        check(DictationStyle.automatic(bundleIdentifier: "com.apple.mail") == .email, "Mail → e-mail")
        check(DictationStyle.automatic(bundleIdentifier: "com.microsoft.Outlook") == .email, "Outlook → e-mail")
        check(DictationStyle.automatic(bundleIdentifier: "com.apple.MobileSMS") == .message, "Messages → messagerie")
        check(DictationStyle.automatic(bundleIdentifier: "com.tinyspeck.slackmacgap") == .message, "Slack → messagerie")
        check(DictationStyle.automatic(bundleIdentifier: "net.whatsapp.WhatsApp") == .message, "WhatsApp → messagerie")
        check(DictationStyle.automatic(bundleIdentifier: "com.apple.Safari") == nil, "Safari : style par défaut")

        var stats = DictationStats()
        stats.record(words: 120, seconds: 60)
        stats.record(words: 30, seconds: 30)
        check(stats.sessions == 2 && stats.words == 150, "statistiques cumulées")
        check(abs(stats.wordsPerMinute - 100) < 0.001, "mots par minute")
        check(abs(stats.timeSaved - 135) < 0.001, "temps gagné sur une frappe à 40 mots par minute")
        check(DictationStats().wordsPerMinute == 0, "aucune division par zéro")
        check(DictationStats.clock(65) == "1:05", "minuteur")
        check(DictationStats.format(duration: 3_725) == "1 h 02 min", "durée en heures")
    }
}

// MARK: - Réglages

struct DictationSettingsView: View {
    @ObservedObject private var preferences = DictationPreferences.shared
    @ObservedObject private var history = DictationHistory.shared
    @ObservedObject private var config = CommandConfigStore.shared
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var speech = SFSpeechRecognizer.authorizationStatus()

    /// Les langues de la reconnaissance vocale, par leur nom français.
    private static let locales: [(id: String, name: String)] = SFSpeechRecognizer.supportedLocales()
        .map { ($0.identifier, Locale(identifier: "fr_FR").localizedString(forIdentifier: $0.identifier) ?? $0.identifier) }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

    var body: some View {
        Form {
            Section {
                LabeledContent("Raccourci de « Dicter »") {
                    HotkeyRecorder(value: Binding(
                        get: { config.config(for: "command:dictation").hotkey.map(HotkeyCoding.encode) ?? "" },
                        set: { value in
                            let hotkey = HotkeyCoding.decode(value)
                            if let hotkey, let owner = config.owner(of: hotkey), owner != "command:dictation" {
                                config.update(owner) { $0.hotkey = nil }
                            }
                            config.update("command:dictation") { $0.hotkey = hotkey?.isValid == true ? hotkey : nil }
                        }
                    ))
                    .frame(width: 200, height: 26)
                }
                Picker("Langue", selection: $preferences.language) {
                    Text("Automatique (langue du système)").tag("auto")
                    Divider()
                    ForEach(Self.locales, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("Texte dicté", selection: $preferences.output) {
                    ForEach(DictationPreferences.Output.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Sons de début et de fin", isOn: $preferences.playSounds)
                Toggle("Couper le son du système pendant l’enregistrement", isOn: $preferences.muteSystemAudio)
            } header: {
                Text("Dicter")
            } footer: {
                Text("Un appui sur le raccourci démarre la dictée, un second la valide et colle le texte ; Échap l’annule. 20 minutes au plus. La reconnaissance se fait sur l’appareil quand la langue le permet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Nettoyer la transcription avec l’IA", isOn: $preferences.aiCleanup)
                    .disabled(AppHooks.aiComplete == nil)
                if AppHooks.aiComplete == nil {
                    Text("L’IA n’est pas configurée : la transcription est nettoyée par des règles simples (hésitations, majuscules, ponctuation).")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Instructions personnalisées")
                    TextEditor(text: $preferences.instructions)
                        .font(.system(size: 12))
                        .frame(height: 54)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.25)))
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Vocabulaire")
                        Spacer()
                        Text("\(preferences.vocabulary.count) / 50")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    TextField("", text: $preferences.vocabularyText, prompt: Text("Noms propres, termes techniques… séparés par des virgules"), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("Choisir le style selon l’app au premier plan", isOn: $preferences.automaticStyle)
                Picker("Style par défaut", selection: $preferences.defaultStyle) {
                    ForEach(DictationStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Nettoyage")
            } footer: {
                Text("Style automatique : Mail, Outlook et Spark donnent un e-mail ; Messages, Slack, WhatsApp, Discord et Telegram, un message court.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                let stats = history.stats
                HStack(spacing: 0) {
                    StatTile(value: "\(stats.words)", label: "mots dictés")
                    StatTile(value: "\(Int(stats.wordsPerMinute.rounded()))", label: "mots par minute")
                    StatTile(value: DictationStats.format(duration: stats.timeSaved), label: "gagnés sur la frappe")
                    StatTile(value: "\(stats.sessions)", label: "dictées")
                }
                HStack {
                    Text("Temps gagné estimé par rapport à une frappe de 40 mots par minute.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remettre à zéro") { history.resetStats() }
                        .disabled(stats.sessions == 0)
                }
            } header: {
                Text("Statistiques")
            }

            Section("Autorisations") {
                PermissionRow(title: "Micro", granted: microphone == .authorized, denied: microphone == .denied || microphone == .restricted, pane: "Privacy_Microphone") {
                    Task {
                        _ = await DictationController.requestMicrophone()
                        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
                    }
                }
                PermissionRow(title: "Reconnaissance vocale", granted: speech == .authorized, denied: speech == .denied || speech == .restricted, pane: "Privacy_SpeechRecognition") {
                    Task {
                        _ = await DictationController.requestSpeechRecognition()
                        speech = SFSpeechRecognizer.authorizationStatus()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let denied: Bool
    let pane: String
    let request: () -> Void

    var body: some View {
        LabeledContent(title) {
            if granted {
                Label("Autorisé", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.green)
            } else if denied {
                Button("Ouvrir les Réglages Système…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
                }
            } else {
                Button("Autoriser…", action: request)
            }
        }
    }
}
