import AVFoundation
import Speech

/// Enregistrement du micro et reconnaissance vocale (Speech), hors de l'acteur principal :
/// le micro arrive sur le fil audio. Les rappels repassent sur le fil principal.
final class DictationRecorder: @unchecked Sendable {
    /// Niveau du micro (0…1), environ vingt fois par seconde.
    var onLevel: (@Sendable (Float) -> Void)?
    /// Transcription complète jusqu'ici, segments terminés compris.
    var onText: (@Sendable (String) -> Void)?
    /// Échec de la reconnaissance en cours de route.
    var onFailure: (@Sendable (String) -> Void)?

    let recognizer: SFSpeechRecognizer
    private let vocabulary: [String]
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Les segments terminés : la reconnaissance repart d'un nouveau segment si le précédent s'arrête.
    private var committed = ""
    private var current = ""
    private var stopping = false
    private var finish: CheckedContinuation<String, Never>?
    /// Le résultat final est arrivé avant qu'on l'attende.
    private var finalReceived = false
    private var lastLevel = Date.distantPast

    init?(locale: Locale, vocabulary: [String]) {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return nil }
        self.recognizer = recognizer
        self.vocabulary = vocabulary
    }

    var isOnDevice: Bool { recognizer.supportsOnDeviceRecognition }

    func start() throws {
        startSegment()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Prism.Dictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Aucun micro disponible"])
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = self.request
        lock.unlock()
        request?.append(buffer)

        let now = Date()
        guard now.timeIntervalSince(lastLevel) > 0.045 else { return }
        lastLevel = now
        let level = Self.level(of: buffer)
        onLevel?(level)
    }

    /// Niveau perçu : moyenne quadratique en décibels, ramenée entre 0 (−50 dB) et 1.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        let decibels = 20 * log10(max(rms, 0.000_01))
        return min(1, max(0, (decibels + 50) / 50))
    }

    private func startSegment() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = vocabulary
        request.addsPunctuation = true
        // Sur l'appareil quand c'est possible : rien ne part sur le réseau, et pas de limite d'une minute.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        lock.lock()
        self.request = request
        lock.unlock()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result: result, error: error, request: request)
        }
    }

    private var fullText: String {
        [committed, current].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, request: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        guard request === self.request else { lock.unlock(); return }
        if let result {
            current = result.bestTranscription.formattedString
        }
        let ended = result?.isFinal == true || error != nil
        if ended {
            if !current.isEmpty { committed = fullText }
            current = ""
        }
        let text = fullText
        let stopping = self.stopping
        lock.unlock()

        onText?(text)
        guard ended else { return }
        if stopping {
            lock.lock()
            finalReceived = true
            lock.unlock()
            resumeFinish()
        } else if let error, (error as NSError).code != 1110, (error as NSError).code != 216 {
            // 1110 : aucune parole dans le segment ; 216 : segment annulé. Les autres erreurs arrêtent la dictée.
            onFailure?(error.localizedDescription)
        } else {
            // Le segment s'est arrêté seul (silence, limite de durée) : on repart, le micro continue.
            startSegment()
        }
    }

    /// Arrête le micro et attend la transcription finale (trois secondes au plus).
    func stop() async -> String {
        let request = lock.withLock {
            stopping = true
            return self.request
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        return await withCheckedContinuation { continuation in
            lock.lock()
            if finalReceived {
                let text = committed
                lock.unlock()
                continuation.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
                return
            }
            finish = continuation
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in self?.resumeFinish() }
        }
    }

    private func resumeFinish() {
        lock.lock()
        let continuation = finish
        finish = nil
        if !current.isEmpty {
            committed = fullText
            current = ""
        }
        let text = committed
        lock.unlock()
        continuation?.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func cancel() {
        lock.lock()
        stopping = true
        request = nil
        lock.unlock()
        task?.cancel()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
