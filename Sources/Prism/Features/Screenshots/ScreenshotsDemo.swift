import AppKit

/// Captures factices des rendus de démonstration (`--snapshot --demo`), dessinées dans un dossier temporaire.
@MainActor
enum ScreenshotsDemo {
    private static var populated = false

    static var folder: URL {
        let url = FeatureDemo.directory.appendingPathComponent("Captures", isDirectory: true)
        populate(url)
        return url
    }

    private static let samples: [(hoursAgo: Double, hue: CGFloat, label: String, name: String?)] = [
        (0.3, 0.60, "Réglages", nil), (1.2, 0.02, "Facture", nil), (3, 0.33, "Tableau de bord", nil),
        (5, 0.75, "Maquette", nil), (6, 0.15, "Notes", "Maquette accueil v2"), (26, 0.12, "Erreur", nil), (28, 0.52, "Agenda", nil),
        (30, 0.90, "Statistiques", nil), (75, 0.42, "Code", nil), (100, 0.68, "Messages", nil),
        (150, 0.08, "Carte", nil), (400, 0.58, "Rapport", nil), (900, 0.28, "Ancienne", nil),
    ]

    private static func populate(_ folder: URL) {
        guard !populated else { return }
        populated = true
        let fileManager = FileManager.default
        // Les noms dépendent de l'heure : on repart d'un dossier vide à chaque rendu.
        try? fileManager.removeItem(at: folder)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "yyyy-MM-dd 'à' HH.mm.ss"
        let now = Date()
        for sample in samples {
            let date = now.addingTimeInterval(-sample.hoursAgo * 3600)
            let name = (sample.name ?? "Capture d’écran \(formatter.string(from: date))") + ".png"
            let url = folder.appendingPathComponent(name)
            if let data = FilesDemo.image(width: 1440, height: 900, hue: sample.hue, label: sample.label)?.demoPNGData {
                try? data.write(to: url)
            }
            try? fileManager.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
        }
    }

    /// Le texte « reconnu » des captures de démonstration.
    static var texts: [String: ScreenshotLibrary.OCREntry] {
        var result: [String: ScreenshotLibrary.OCREntry] = [:]
        for file in ScreenshotLibrary.scanFolders([folder], allMedia: true) {
            result[file.path] = .init(modified: file.modified.timeIntervalSince1970, text: "Prism \(file.name)")
        }
        return result
    }
}
