import AVFoundation
import AppKit
import Speech
import SwiftUI

/// Les réglages de la dictée, dans UserDefaults (« dictation.… »).
@MainActor
final class DictationPreferences: ObservableObject {
    static let shared = DictationPreferences()

    enum Output: String, CaseIterable {
        case paste, copy, both

        var title: String {
            switch self {
            case .paste: "Coller dans l’app active"
            case .copy: "Copier dans le presse-papiers"
            case .both: "Coller et garder dans le presse-papiers"
            }
        }
    }

    private let defaults = UserDefaults.standard

    /// Identifiant de langue de la reconnaissance, « auto » pour la langue du système.
    @Published var language: String { didSet { defaults.set(language, forKey: "dictation.language") } }
    @Published var output: Output { didSet { defaults.set(output.rawValue, forKey: "dictation.output") } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "dictation.sounds") } }
    @Published var muteSystemAudio: Bool { didSet { defaults.set(muteSystemAudio, forKey: "dictation.mute") } }
    @Published var aiCleanup: Bool { didSet { defaults.set(aiCleanup, forKey: "dictation.aiCleanup") } }
    @Published var instructions: String { didSet { defaults.set(instructions, forKey: "dictation.instructions") } }
    @Published var vocabularyText: String { didSet { defaults.set(vocabularyText, forKey: "dictation.vocabulary") } }
    /// Style choisi d'après l'app au premier plan (courrier, messagerie).
    @Published var automaticStyle: Bool { didSet { defaults.set(automaticStyle, forKey: "dictation.autoStyle") } }
    @Published var defaultStyle: DictationStyle { didSet { defaults.set(defaultStyle.rawValue, forKey: "dictation.style") } }

    private init() {
        language = defaults.string(forKey: "dictation.language") ?? "auto"
        output = Output(rawValue: defaults.string(forKey: "dictation.output") ?? "") ?? .paste
        playSounds = defaults.object(forKey: "dictation.sounds") as? Bool ?? true
        muteSystemAudio = defaults.bool(forKey: "dictation.mute")
        aiCleanup = defaults.object(forKey: "dictation.aiCleanup") as? Bool ?? true
        instructions = defaults.string(forKey: "dictation.instructions") ?? ""
        vocabularyText = defaults.string(forKey: "dictation.vocabulary") ?? ""
        automaticStyle = defaults.object(forKey: "dictation.autoStyle") as? Bool ?? true
        defaultStyle = DictationStyle(rawValue: defaults.string(forKey: "dictation.style") ?? "") ?? .standard
    }

    var vocabulary: [String] { DictationCleanup.vocabulary(from: vocabularyText) }

    /// La langue de reconnaissance : celle choisie, sinon la première langue du système.
    var locale: Locale {
        if language != "auto" { return Locale(identifier: language) }
        return Locale(identifier: Locale.preferredLanguages.first ?? Locale.current.identifier)
    }

    func style(for app: NSRunningApplication?) -> DictationStyle {
        if automaticStyle, let style = DictationStyle.automatic(bundleIdentifier: app?.bundleIdentifier) { return style }
        return defaultStyle
    }
}

/// Une dictée enregistrée dans l'historique.
struct DictationEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var text: String
    /// La transcription avant nettoyage.
    var raw: String
    var duration: Double
    var language: String
    var style: DictationStyle
    var app: String?
    var cleanedByAI: Bool

    var words: Int { TextStats.words(text) }
}

@MainActor
final class DictationHistory: ObservableObject {
    static let shared = DictationHistory()

    struct Content: Codable {
        var entries: [DictationEntry] = []
        var stats = DictationStats()
    }

    let store = JSONStore("dictation.json", default: Content())
    private let limit = 500

    private init() {}

    var entries: [DictationEntry] { store.value.entries }
    var stats: DictationStats { store.value.stats }

    func add(_ entry: DictationEntry) {
        var content = store.value
        content.entries.insert(entry, at: 0)
        if content.entries.count > limit { content.entries.removeLast(content.entries.count - limit) }
        content.stats.record(words: entry.words, seconds: entry.duration)
        store.value = content
        objectWillChange.send()
    }

    func remove(_ id: UUID) {
        store.value.entries.removeAll { $0.id == id }
        objectWillChange.send()
    }

    func clear() {
        store.value.entries.removeAll()
        objectWillChange.send()
    }

    func resetStats() {
        store.value.stats = DictationStats()
        objectWillChange.send()
    }
}

/// Ce que la pilule affiche, mis à jour par le contrôleur (ou des valeurs factices pour le rendu hors écran).
@MainActor
final class DictationPillModel: ObservableObject {
    enum Phase: Equatable {
        case starting
        case recording
        case processing(String)
    }

    static let barCount = 28

    @Published var phase: Phase = .starting
    @Published var levels: [CGFloat] = Array(repeating: 0, count: barCount)
    @Published var elapsed: Double = 0
    @Published var transcript = ""
    @Published var style: DictationStyle = .standard
    /// Le texte va dans une note plutôt que dans l'app active.
    @Published var isNote = false

    func push(level: Float) {
        // Un peu de lissage, pour une onde vivante sans tressauter.
        let previous = levels.last ?? 0
        let smoothed = CGFloat(level) * 0.7 + previous * 0.3
        levels.removeFirst()
        levels.append(smoothed)
    }

    func reset() {
        phase = .starting
        levels = Array(repeating: 0, count: Self.barCount)
        elapsed = 0
        transcript = ""
    }
}

/// La dictée : un appui démarre, un second valide, Échap annule. Le texte final est collé dans l'app active.
@MainActor
final class DictationController {
    static let shared = DictationController()
    static let maxDuration: Double = 20 * 60

    let pill = DictationPillModel()
    private var panel: NSPanel?
    private var recorder: DictationRecorder?
    private var escapeKey: HotKey?
    private var escapeMonitor: Any?
    private var timer: Timer?
    private var startDate = Date()
    private var targetApp: NSRunningApplication?
    private var wasMuted: Bool?
    private var isNote = false
    private var isBusy = false
    /// Une sortie ponctuelle (la question de Quick AI) à la place du collage.
    private var customDelivery: ((String) -> Void)?

    /// Dicte un texte remis à `handler` (Quick AI, AI Chat) au lieu d'être collé.
    func dictate(into handler: @escaping (String) -> Void) {
        guard !isRecording else {
            Task { await stop() }
            return
        }
        customDelivery = handler
        toggle()
    }

    var isRecording: Bool { recorder != nil }

    /// Raccourci de la commande : démarre, ou valide la dictée en cours.
    func toggle(note: Bool = false) {
        if isRecording {
            Task { await stop() }
        } else if !isBusy {
            Task { await start(note: note) }
        }
    }

    // MARK: - Démarrage

    func start(note: Bool) async {
        guard !isRecording, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetApp = frontmost
            AppContext.previousApp = frontmost
        } else {
            targetApp = AppContext.previousApp
        }

        // Les autorisations ne sont demandées qu'ici, au premier usage réel.
        guard await Self.requestMicrophone() else {
            Self.explainDenied("Prism n’a pas accès au micro", pane: "Privacy_Microphone")
            return
        }
        guard await Self.requestSpeechRecognition() else {
            Self.explainDenied("Prism n’a pas accès à la reconnaissance vocale", pane: "Privacy_SpeechRecognition")
            return
        }
        let preferences = DictationPreferences.shared
        guard let recorder = DictationRecorder(locale: preferences.locale, vocabulary: preferences.vocabulary), recorder.recognizer.isAvailable else {
            HUD.shared.show("Reconnaissance vocale indisponible pour \(Self.languageName(preferences.locale))", symbol: "exclamationmark.triangle.fill")
            return
        }

        isNote = note
        pill.reset()
        pill.isNote = note
        pill.style = preferences.style(for: targetApp)
        recorder.onLevel = { level in
            DispatchQueue.main.async { MainActor.assumeIsolated { DictationController.shared.pill.push(level: level) } }
        }
        recorder.onText = { text in
            DispatchQueue.main.async { MainActor.assumeIsolated { DictationController.shared.pill.transcript = text } }
        }
        recorder.onFailure = { message in
            DispatchQueue.main.async { MainActor.assumeIsolated { DictationController.shared.fail(message) } }
        }

        if preferences.playSounds { NSSound(named: "Tink")?.play() }
        do {
            try recorder.start()
        } catch {
            HUD.shared.show("Micro indisponible : \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
            return
        }
        self.recorder = recorder
        startDate = Date()
        pill.phase = .recording
        showPanel()
        installEscape()
        startTimer()
        if preferences.muteSystemAudio {
            // Après le son de début, pour qu'on l'entende.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.isRecording else { return }
                self.wasMuted = (SystemAudio.isOutputMuted() ?? false)
                SystemAudio.setOutputMuted(true)
            }
        }
    }

    // MARK: - Fin

    func stop() async {
        guard let recorder else { return }
        self.recorder = nil
        // Pas de nouvelle dictée tant que celle-ci n'est pas collée.
        isBusy = true
        defer { isBusy = false }
        let duration = Date().timeIntervalSince(startDate)
        finishRecording()
        pill.phase = .processing("Transcription…")
        let raw = await recorder.stop()
        let preferences = DictationPreferences.shared
        if preferences.playSounds { NSSound(named: "Pop")?.play() }

        guard !raw.isEmpty else {
            hidePanel()
            HUD.shared.show("Aucune parole détectée", symbol: "mic.slash.fill")
            return
        }

        let language = recorder.recognizer.locale.identifier
        let style = pill.style
        var text = DictationCleanup.clean(raw, language: language, style: style)
        var cleanedByAI = false
        if preferences.aiCleanup, let complete = AppHooks.aiComplete {
            pill.phase = .processing("Nettoyage par l’IA…")
            let system = DictationCleanup.aiSystemPrompt(language: language, style: style, instructions: preferences.instructions, vocabulary: preferences.vocabulary)
            if let cleaned = await Self.withTimeout(seconds: 12, { try await complete(DictationCleanup.aiUserMessage(raw), system) }) {
                let trimmed = DictationCleanup.stripTranscriptTags(cleaned)
                // Une réponse à la place du texte dicté : on garde le nettoyage par règles.
                if DictationCleanup.isFaithful(raw: raw, cleaned: trimmed) {
                    text = trimmed
                    cleanedByAI = true
                }
            }
        }
        hidePanel()

        DictationHistory.shared.add(DictationEntry(
            date: Date(), text: text, raw: raw, duration: duration, language: language,
            style: style, app: targetApp?.localizedName, cleanedByAI: cleanedByAI
        ))
        deliver(text)
    }

    /// Échap : on arrête tout, rien n'est collé.
    func cancel() {
        guard let recorder else { return }
        self.recorder = nil
        recorder.cancel()
        finishRecording()
        hidePanel()
        HUD.shared.show("Dictée annulée", symbol: "xmark.circle.fill")
    }

    private func fail(_ message: String) {
        guard let recorder else { return }
        self.recorder = nil
        recorder.cancel()
        finishRecording()
        hidePanel()
        HUD.shared.show("Dictée interrompue : \(message)", symbol: "exclamationmark.triangle.fill")
    }

    private func finishRecording() {
        timer?.invalidate()
        timer = nil
        escapeKey = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        if let wasMuted {
            SystemAudio.setOutputMuted(wasMuted)
            self.wasMuted = nil
        }
    }

    private func deliver(_ text: String) {
        if let customDelivery {
            self.customDelivery = nil
            customDelivery(text)
            return
        }
        if isNote {
            if let createNote = AppHooks.createNote {
                createNote(text)
            } else {
                Pasteboard.copy(text)
                HUD.shared.show("Note copiée dans le presse-papiers")
            }
            return
        }
        AppContext.previousApp = targetApp
        switch DictationPreferences.shared.output {
        case .copy:
            Pasteboard.copy(text)
            HUD.shared.show("Transcription copiée")
        case .paste:
            CommandRunner.present(Paster.paste(text, restoreClipboard: true))
        case .both:
            CommandRunner.present(Paster.paste(text))
        }
    }

    // MARK: - Minuteur et Échap

    private func startTimer() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let controller = DictationController.shared
                controller.pill.elapsed = Date().timeIntervalSince(controller.startDate)
                if controller.pill.elapsed >= Self.maxDuration {
                    Task { await controller.stop() }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Échap annule partout : raccourci Carbon le temps de l'enregistrement, surveillance du clavier sinon.
    private func installEscape() {
        let key = HotKey(keyCode: 53, modifiers: 0) {
            MainActor.assumeIsolated { DictationController.shared.cancel() }
        }
        if key.isRegistered {
            escapeKey = key
        } else {
            escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return }
                MainActor.assumeIsolated { DictationController.shared.cancel() }
            }
        }
    }

    // MARK: - Pilule

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = DictationPillView.panelSize
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrame(NSRect(x: (area.midX - size.width / 2).rounded(), y: area.minY + 24, width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private func hidePanel() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            MainActor.assumeIsolated {
                if !DictationController.shared.isRecording { panel?.orderOut(nil) }
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = DictationPanel(
            contentRect: NSRect(origin: .zero, size: DictationPillView.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: DictationPillView(model: pill) {
            DictationController.shared.toggle()
        })
        return panel
    }

    // MARK: - Autorisations

    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static func requestSpeechRecognition() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status == .authorized) }
            }
        default: return false
        }
    }

    private static func explainDenied(_ message: String, pane: String) {
        HUD.shared.show("\(message) : autorisez-le dans Réglages Système", symbol: "lock.fill")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func languageName(_ locale: Locale) -> String {
        Locale(identifier: "fr_FR").localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// Le résultat d'une tâche, ou `nil` si elle échoue ou dépasse le délai.
    static func withTimeout(seconds: Double, _ operation: @escaping @Sendable () async throws -> String) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// La pilule ne prend jamais le clavier : l'app active le garde.
private final class DictationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

