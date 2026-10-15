import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// L'historique sur disque, dans `Application Support/Prism/Clipboard/` :
/// `history.json` (l'index) et un dossier par entrée, avec tous les formats d'origine (`pasteboard.plist`),
/// la vignette (`thumbnail.png`) et l'aperçu (`preview.png`). Les fonctions sans `@MainActor`
/// s'appellent depuis la file d'arrière-plan.
enum ClipboardStorage {
    /// `nil` hors de l'application (rendus et autotests) : rien n'est lu ni écrit.
    nonisolated(unsafe) static var root: URL?

    /// Taille maximale des formats gardés pour une entrée ; au-delà, seuls les formats essentiels restent.
    static let maxEntryBytes = 64 * 1_024 * 1_024

    static let queue = DispatchQueue(label: "app.prism.clipboard.storage", qos: .utility)

    static func folder(_ id: UUID) -> URL? {
        root?.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func thumbnailURL(_ id: UUID) -> URL? { folder(id)?.appendingPathComponent("thumbnail.png") }
    static func previewURL(_ id: UUID) -> URL? { folder(id)?.appendingPathComponent("preview.png") }
    private static func contentURL(_ id: UUID) -> URL? { folder(id)?.appendingPathComponent("pasteboard.plist") }
    private static var indexURL: URL? { root?.appendingPathComponent("history.json") }

    // MARK: - Contenu d'une entrée

    @discardableResult
    static func writeContent(_ items: [[String: Data]], id: UUID) -> Bool {
        guard let folder = folder(id), let url = contentURL(id) else { return false }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: items, format: .binary, options: 0)
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            NSLog("Prism : écriture de l’entrée impossible : \(error.localizedDescription)")
            return false
        }
    }

    static func readContent(_ id: UUID) -> [[String: Data]]? {
        guard let url = contentURL(id), let data = try? Data(contentsOf: url),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Data]] else { return nil }
        return list
    }

    /// Garde les formats sous la taille maximale : si l'entrée la dépasse, seuls restent le texte brut,
    /// le texte riche, les fichiers et une image. `nil` : trop lourde même ainsi.
    static func capped(_ items: [[String: Data]]) -> [[String: Data]]? {
        func size(_ list: [[String: Data]]) -> Int { list.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } } }
        guard size(items) > maxEntryBytes else { return items }
        let essential: Set<String> = [
            NSPasteboard.PasteboardType.string.rawValue, "public.rtf", "public.html", ClipboardClassifier.fileURLType,
        ]
        let reduced = items.map { formats -> [String: Data] in
            var kept = formats.filter { essential.contains($0.key) }
            if let image = ClipboardClassifier.mainImageType(in: Array(formats.keys)) { kept[image] = formats[image] }
            return kept
        }
        return size(reduced) > maxEntryBytes ? nil : reduced
    }

    static func removeFolders(_ ids: [UUID]) {
        guard root != nil, !ids.isEmpty else { return }
        queue.async {
            for id in ids {
                if let folder = folder(id) { try? FileManager.default.removeItem(at: folder) }
            }
        }
    }

    // MARK: - Images

    /// Dimensions de l'image, vignette et aperçu écrits dans le dossier de l'entrée.
    static func processImage(_ data: Data, id: UUID) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        if width == 0 || height == 0, let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            width = image.width
            height = image.height
        }
        guard width > 0, height > 0 else { return nil }
        if let preview = thumbnail(source, maxPixels: 1_200), let url = previewURL(id) { writePNG(preview, to: url) }
        if let small = thumbnail(source, maxPixels: 96), let url = thumbnailURL(id) { writePNG(small, to: url) }
        return (width, height)
    }

    static func thumbnail(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// L'image entière, pour la reconnaissance de texte.
    static func fullImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Au-delà de 4 000 pixels, Vision ne gagne rien : on réduit.
        return thumbnail(source, maxPixels: 4_000)
    }

    @discardableResult
    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// Données PNG d'une image (TIFF copiée par Aperçu, par exemple), pour « Coller en PNG ».
    static func pngData(_ data: Data) -> Data? {
        NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }

    /// Aperçu Quick Look d'un fichier (PDF, image, document), écrit comme celui d'une image.
    static func processFilePreview(_ path: String, id: UUID, completion: @escaping @Sendable (Bool) -> Void) {
        guard let previewURL = previewURL(id), let thumbnailURL = thumbnailURL(id) else { return completion(false) }
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: 600, height: 600),
            scale: 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let image = representation?.cgImage else { return completion(false) }
            queue.async {
                writePNG(image, to: previewURL)
                let source = CGImageSourceCreateWithURL(previewURL as CFURL, nil)
                if let source, let small = thumbnail(source, maxPixels: 96) { writePNG(small, to: thumbnailURL) }
                completion(true)
            }
        }
    }

    // MARK: - Index

    private struct Index: Codable {
        var version = 1
        var entries: [ClipboardEntry]
    }

    static func loadIndex() -> [ClipboardEntry]? {
        guard let url = indexURL, let data = try? Data(contentsOf: url) else { return nil }
        // Dates au format par défaut (précises à la fraction de seconde, pour l'ordre des copies rapprochées).
        return ((try? JSONDecoder().decode(Index.self, from: data)) ?? (try? JSONDecoder.prism.decode(Index.self, from: data)))?.entries
    }

    static func saveIndex(_ entries: [ClipboardEntry]) {
        guard let url = indexURL else { return }
        queue.async {
            guard let data = try? JSONEncoder().encode(Index(entries: entries)) else { return }
            try? data.write(to: url, options: [.atomic])
        }
    }

    /// Dossiers d'entrées qui ne sont plus dans l'index (suppression interrompue) : effacés.
    static func removeOrphans(keeping ids: Set<UUID>) {
        guard let root else { return }
        queue.async {
            let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for child in children {
                guard let id = UUID(uuidString: child.lastPathComponent), !ids.contains(id) else { continue }
                try? FileManager.default.removeItem(at: child)
            }
        }
    }

    /// Taille de l'historique sur disque, en octets.
    static func diskSize() -> Int {
        guard let root, let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            total += (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
        }
        return total
    }

    // MARK: - Migration de l'ancien historique

    /// L'ancien `clipboard.json` (texte seul) rejoint le nouvel historique, sans doublon ; il est gardé
    /// en `clipboard.json.bak`. `nil` tant qu'il n'existe pas ou reste illisible : l'ancienne version
    /// le protégeait (`completeFileProtection`), il ne se lit pas quand la session est verrouillée.
    /// On réessaie donc à chaque lancement et à chaque déverrouillage.
    static func importLegacy(legacyURL: URL, existing: Set<UUID>) -> [ClipboardEntry]? {
        guard root != nil, FileManager.default.fileExists(atPath: legacyURL.path),
              let data = try? Data(contentsOf: legacyURL),
              let entries = ClipboardMigration.entries(fromLegacy: data) else { return nil }
        // Le texte complet de l'ancien fichier (l'index peut le tronquer), pour recoller à l'identique.
        let fullTexts = Dictionary((ClipboardMigration.decode(data) ?? []).map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        let added = entries.filter { !existing.contains($0.id) }
        for entry in added {
            let full = fullTexts[entry.id] ?? entry.text
            guard writeContent([[NSPasteboard.PasteboardType.string.rawValue: Data(full.utf8)]], id: entry.id) else { return nil }
        }
        let backup = legacyURL.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        do {
            try FileManager.default.moveItem(at: legacyURL, to: backup)
        } catch {
            NSLog("Prism : migration du presse-papiers incomplète : \(error.localizedDescription)")
        }
        return added
    }
}

/// Vignettes et aperçus gardés en mémoire. Les images se chargent depuis le disque au premier affichage.
@MainActor
enum ClipboardImageCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func thumbnail(_ id: UUID) -> NSImage? { image(id, kind: "thumbnail", url: ClipboardStorage.thumbnailURL(id)) }
    static func preview(_ id: UUID) -> NSImage? { image(id, kind: "preview", url: ClipboardStorage.previewURL(id)) }

    /// Pour les rendus hors application : images gardées en mémoire seulement.
    static func store(_ image: NSImage, id: UUID, kind: String) {
        cache.setObject(image, forKey: "\(kind):\(id.uuidString)" as NSString)
    }

    static func invalidate(_ id: UUID) {
        cache.removeObject(forKey: "thumbnail:\(id.uuidString)" as NSString)
        cache.removeObject(forKey: "preview:\(id.uuidString)" as NSString)
    }

    private static func image(_ id: UUID, kind: String, url: URL?) -> NSImage? {
        let key = "\(kind):\(id.uuidString)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Chargée paresseusement : l'image n'est lue qu'au premier dessin.
        let image = NSImage(byReferencing: url)
        cache.setObject(image, forKey: key)
        return image
    }

    /// La place de l'aperçu dans le détail : largeur de la colonne, hauteur laissée par les lignes d'informations
    /// (28 points chacune) et le texte affiché dessous.
    static func previewCanvas(rows: Int, textLines: Int) -> NSSize {
        let content = LauncherLayout.height - LauncherLayout.searchHeight - LauncherLayout.footerHeight - 2
        let information = 43 + CGFloat(rows) * 28
        let text = textLines > 0 ? CGFloat(textLines) * 15.5 + 12 : 0
        let height = content - 1 - information - 32 - text
        return NSSize(width: LauncherLayout.width - ClipboardScreen.listWidth - 1 - 32, height: max(90, min(260, height.rounded(.down))))
    }

    /// L'image entière, centrée dans la place de l'aperçu, coins arrondis.
    static func fitted(_ image: NSImage, key: String, size: NSSize) -> NSImage {
        let cacheKey = "fitted:\(key):\(Int(size.height))" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        let fitted = NSImage(size: size, flipped: false) { rect in
            let source = image.size
            guard source.width > 0, source.height > 0 else { return false }
            let scale = min(rect.width / source.width, rect.height / source.height, 1.5)
            let drawn = NSSize(width: source.width * scale, height: source.height * scale)
            let target = NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height).integral
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: target, xRadius: 8, yRadius: 8).addClip()
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            NSColor(white: 0.5, alpha: 0.22).setStroke()
            let border = NSBezierPath(roundedRect: target.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            border.lineWidth = 1
            border.stroke()
            return true
        }
        cache.setObject(fitted, forKey: cacheKey)
        return fitted
    }

    /// Les icônes des fichiers copiés, en éventail, pour le détail.
    static func fileIcons(_ paths: [String], size: NSSize) -> NSImage {
        let cacheKey = "files:\(paths.joined(separator: "|")):\(Int(size.height))" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        let icons = paths.prefix(5).map { NSWorkspace.shared.icon(forFile: $0) }
        let image = NSImage(size: size, flipped: false) { rect in
            let edge = min(rect.height, 128)
            let step = icons.count > 1 ? min(edge * 0.62, (rect.width - edge) / CGFloat(icons.count - 1)) : 0
            let total = edge + step * CGFloat(icons.count - 1)
            for (index, icon) in icons.enumerated() {
                let frame = NSRect(x: rect.midX - total / 2 + step * CGFloat(index), y: rect.midY - edge / 2, width: edge, height: edge)
                icon.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
        cache.setObject(image, forKey: cacheKey)
        return image
    }

    /// Une pastille de couleur pour le détail, sur un damier si elle est transparente.
    static func swatch(_ color: ParsedColor, size: NSSize) -> NSImage {
        let key = "swatch:\(color.hexString):\(Int(size.height))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            path.addClip()
            if color.alpha < 1 {
                NSColor.white.setFill()
                rect.fill()
                NSColor(white: 0.82, alpha: 1).setFill()
                let tile: CGFloat = 12
                for row in 0..<Int(rect.height / tile) + 1 {
                    for column in 0..<Int(rect.width / tile) + 1 where (row + column) % 2 == 0 {
                        NSRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile).fill()
                    }
                }
            }
            color.nsColor.setFill()
            rect.fill(using: .sourceOver)
            NSColor(white: 0.5, alpha: 0.25).setStroke()
            path.lineWidth = 2
            path.stroke()
            return true
        }
        cache.setObject(image, forKey: key)
        return image
    }
}
