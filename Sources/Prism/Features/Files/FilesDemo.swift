import AppKit

/// Fichiers factices des rendus de démonstration (`--snapshot --demo`), créés dans un dossier temporaire.
@MainActor
enum FilesDemo {
    /// Un faux dossier personnel.
    static var home: URL {
        let url = FeatureDemo.directory.appendingPathComponent("Maison", isDirectory: true)
        populate(url)
        return url
    }

    private static var populated = false

    private static func populate(_ home: URL) {
        guard !populated else { return }
        populated = true
        let fileManager = FileManager.default
        for folder in ["Bureau", "Documents", "Images", "Projets/Prism", "Téléchargements", "Musique"] {
            try? fileManager.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let now = Date()
        func write(_ path: String, _ text: String, hoursAgo: Double) {
            let url = home.appendingPathComponent(path)
            try? Data(text.utf8).write(to: url)
            try? fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-hoursAgo * 3600)], ofItemAtPath: url.path)
        }
        write("Documents/Notes de réunion.md", """
        # Réunion produit — 14 octobre

        ## Décisions
        - Lancer la bêta publique le 4 novembre
        - Garder ⌘K pour le panneau d’actions
        - Ajouter l’aperçu des fichiers dans la recherche

        ## À faire
        1. Finaliser les vignettes des captures (Léa)
        2. Relire les textes de l’agenda (Hugo)
        3. Mesurer le temps d’ouverture du lanceur
        """, hoursAgo: 0.4)
        write("Documents/Budget 2027.csv", "Poste;Montant\nServeurs;1 200\nDesign;3 400\nCommunication;900\n", hoursAgo: 5)
        write("Projets/Prism/Package.swift", "// swift-tools-version:5.10\nimport PackageDescription\n\nlet package = Package(\n    name: \"Prism\",\n    platforms: [.macOS(.v14)]\n)\n", hoursAgo: 26)
        write("Projets/Prism/README.md", "# Prism\n\nUn lanceur pour macOS.\n", hoursAgo: 30)
        write("Téléchargements/facture-octobre.txt", "Facture n° 2026-10-118\nMontant : 49,00 €\n", hoursAgo: 50)
        if let png = image(width: 1600, height: 1000)?.demoPNGData {
            try? png.write(to: home.appendingPathComponent("Images/Maquette accueil.png"))
            try? fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-2 * 3600)], ofItemAtPath: home.appendingPathComponent("Images/Maquette accueil.png").path)
        }
    }

    /// Les fichiers de démonstration dont le nom contient la saisie, les plus récents d'abord.
    static func files(matching query: String) -> [URL] {
        let root = home
        let normalized = query.normalizedForSearch
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])
        var urls: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard !FileOps.isDirectory(url) || !normalized.isEmpty else { continue }
            if normalized.isEmpty || url.lastPathComponent.normalizedForSearch.contains(normalized) { urls.append(url) }
        }
        func date(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        return urls.sorted { date($0) > date($1) }
    }

    /// Une fausse maquette d'interface, pour les vignettes.
    static func image(width: Int, height: Int, hue: CGFloat = 0.62, label: String? = nil) -> NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        NSGradient(colors: [
            NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1),
            NSColor(hue: hue + 0.08, saturation: 0.65, brightness: 0.55, alpha: 1),
        ])?.draw(in: rect, angle: -60)
        let w = CGFloat(width)
        let h = CGFloat(height)
        // Une fenêtre avec sa barre de titre, une barre latérale et des lignes de texte.
        let window = NSRect(x: w * 0.1, y: h * 0.1, width: w * 0.8, height: h * 0.78)
        NSColor(white: 0.98, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: window, xRadius: w * 0.012, yRadius: w * 0.012).fill()
        NSColor(white: 0.9, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: window.minX, y: window.maxY - h * 0.06, width: window.width, height: h * 0.06)).fill()
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            let size = h * 0.022
            NSBezierPath(ovalIn: NSRect(x: window.minX + w * 0.012 + CGFloat(index) * size * 1.6, y: window.maxY - h * 0.03 - size / 2, width: size, height: size)).fill()
        }
        NSColor(hue: hue, saturation: 0.12, brightness: 0.93, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: window.minX, y: window.minY, width: window.width * 0.24, height: window.height - h * 0.06)).fill()
        for line in 0..<7 {
            let y = window.maxY - h * 0.14 - CGFloat(line) * h * 0.08
            NSColor(white: 0.25, alpha: line == 0 ? 0.85 : 0.25).setFill()
            let length = line == 0 ? 0.32 : 0.5 - CGFloat(line % 3) * 0.08
            NSBezierPath(roundedRect: NSRect(x: window.minX + window.width * 0.3, y: y, width: window.width * length, height: h * (line == 0 ? 0.035 : 0.022)), xRadius: 4, yRadius: 4).fill()
        }
        if let label {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: h * 0.05, weight: .bold),
                .foregroundColor: NSColor(white: 0.15, alpha: 0.9),
            ]
            (label as NSString).draw(at: NSPoint(x: window.minX + window.width * 0.3, y: window.minY + h * 0.06), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
}

extension NSBitmapImageRep {
    var demoPNGData: Data? { representation(using: .png, properties: [:]) }
}
