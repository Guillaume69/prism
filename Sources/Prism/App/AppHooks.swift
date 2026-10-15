import AppKit
import Vision

/// Points de jonction entre fonctionnalités : chacune renseigne les siens au démarrage (`start()`),
/// les autres s'en servent s'ils existent. Le presse-papiers propose ainsi « Enregistrer comme snippet »
/// sans dépendre du code des snippets.
@MainActor
enum AppHooks {
    /// Formulaire de création d'un snippet, prérempli avec ce texte.
    static var createSnippet: ((_ text: String) -> ActionOutcome)?
    /// Formulaire de création d'un lien rapide, prérempli.
    static var createQuicklink: ((_ link: String, _ name: String) -> ActionOutcome)?
    /// Ouvre Quick AI dans le lanceur avec cette question (touche Tab de la recherche principale).
    static var quickAI: ((_ prompt: String) -> LauncherScreen)?
    /// Envoie du texte (et des pièces jointes en texte) à la fenêtre AI Chat.
    static var sendToAIChat: ((_ text: String, _ attachments: [String]) -> ActionOutcome)?
    /// Une réponse de l'IA d'un seul tenant (traduction, nettoyage d'une dictée, recherche d'emoji).
    static var aiComplete: ((_ prompt: String, _ system: String?) async throws -> String)?
    /// Crée une note avec ce texte et ouvre la fenêtre des notes.
    static var createNote: ((_ text: String) -> Void)?
    /// Écran de traduction prérempli.
    static var translate: ((_ text: String) -> LauncherScreen)?
}

/// Reconnaissance de texte et de QR codes sur l'appareil (Vision), pour le presse-papiers et les captures.
enum TextRecognition {
    static func recognize(_ image: NSImage, accurate: Bool = false) async -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return await recognize(cgImage, accurate: accurate)
    }

    static func recognize(_ image: CGImage, accurate: Bool = false) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = accurate ? .accurate : .fast
                request.usesLanguageCorrection = accurate
                request.automaticallyDetectsLanguage = true
                let handler = VNImageRequestHandler(cgImage: image)
                try? handler.perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.isEmpty ? nil : lines.joined(separator: "\n"))
            }
        }
    }

    /// Le contenu des QR codes et codes-barres de l'image.
    static func barcodes(_ image: NSImage) async -> [String] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNDetectBarcodesRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage)
                try? handler.perform([request])
                continuation.resume(returning: (request.results ?? []).compactMap(\.payloadStringValue))
            }
        }
    }
}
