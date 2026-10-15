import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Réglages des captures d'écran (« screenshots.* »).
@MainActor
final class ScreenshotsSettings: ObservableObject {
    static let shared = ScreenshotsSettings()

    private let defaults = UserDefaults.standard

    /// Colonnes de la grille, de 3 à 6.
    @Published var columns: Int {
        didSet { defaults.set(columns, forKey: "screenshots.columns") }
    }

    /// Dossiers surveillés en plus de l'emplacement des captures et du Bureau.
    @Published var extraFolders: [String] {
        didSet { defaults.set(extraFolders, forKey: "screenshots.extraFolders") }
    }

    /// Montre toutes les images et vidéos des dossiers, pas seulement les captures.
    @Published var allMedia: Bool {
        didSet { defaults.set(allMedia, forKey: "screenshots.allMedia") }
    }

    @Published var ocrEnabled: Bool {
        didSet { defaults.set(ocrEnabled, forKey: "screenshots.ocrEnabled") }
    }

    /// Reconnaissance précise (plus lente) plutôt que rapide.
    @Published var ocrAccurate: Bool {
        didSet { defaults.set(ocrAccurate, forKey: "screenshots.ocrAccurate") }
    }

    /// Âge (jours) au-delà duquel les captures non épinglées vont à la corbeille ; 0 : jamais.
    @Published var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: "screenshots.retentionDays") }
    }

    /// Captures épinglées (chemins) : en tête de la grille, jamais purgées.
    @Published var pinned: [String] {
        didSet { defaults.set(pinned, forKey: "screenshots.pinned") }
    }

    private init() {
        columns = min(6, max(3, defaults.object(forKey: "screenshots.columns") as? Int ?? 4))
        extraFolders = defaults.stringArray(forKey: "screenshots.extraFolders") ?? []
        allMedia = defaults.bool(forKey: "screenshots.allMedia")
        ocrEnabled = defaults.object(forKey: "screenshots.ocrEnabled") as? Bool ?? true
        ocrAccurate = defaults.bool(forKey: "screenshots.ocrAccurate")
        retentionDays = defaults.integer(forKey: "screenshots.retentionDays")
        pinned = defaults.stringArray(forKey: "screenshots.pinned") ?? []
    }
}

/// Une capture (ou un média) trouvée dans un dossier surveillé.
struct ScreenshotFile: Equatable, Sendable {
    let url: URL
    let name: String
    let date: Date
    let modified: Date
    let size: Int64
    let isVideo: Bool
    let isScreenshot: Bool

    var path: String { url.path }
}

// MARK: - Recherche

/// La saisie de la recherche : mots libres et filtres `name:`, `text:`, `date:`. Sans état : testée par `--selftest`.
struct ScreenshotQuery: Equatable {
    var words: [String] = []
    var names: [String] = []
    var texts: [String] = []
    var range: DateInterval?
    /// Une date que l'on n'a pas comprise (« date:bientôt »).
    var invalidDate: String?

    private static let datePhrases: [(phrases: [String], kind: String)] = [
        (["semaine derniere", "la semaine derniere", "last week"], "lastWeek"),
        (["cette semaine", "this week"], "thisWeek"),
        (["mois dernier", "le mois dernier", "last month"], "lastMonth"),
        (["ce mois", "ce mois-ci", "this month"], "thisMonth"),
        (["aujourd'hui", "aujourdhui", "today"], "today"),
        (["avant-hier"], "dayBeforeYesterday"),
        (["hier", "yesterday"], "yesterday"),
    ]

    static func parse(_ query: String, now: Date, calendar: Calendar = .current) -> ScreenshotQuery {
        var result = ScreenshotQuery()
        let text = query.replacingOccurrences(of: "’", with: "'")
        var rest = Substring(text)
        func takeToken() -> String {
            if rest.first == "\"" {
                rest = rest.dropFirst()
                let value = rest.prefix { $0 != "\"" }
                rest = rest.dropFirst(value.count).dropFirst()
                return String(value)
            }
            let value = rest.prefix { !$0.isWhitespace }
            rest = rest.dropFirst(value.count)
            return String(value)
        }
        while true {
            rest = rest.drop { $0.isWhitespace }
            guard !rest.isEmpty else { break }
            let lowered = rest.lowercased()
            if let key = ["name:", "nom:", "text:", "texte:", "date:"].first(where: { lowered.hasPrefix($0) }) {
                rest = rest.dropFirst(key.count)
                if key == "date:" {
                    let normalized = String(rest).normalizedForSearch
                    let phrases = datePhrases.flatMap { entry in entry.phrases.map { ($0, entry.kind) } }.sorted { $0.0.count > $1.0.count }
                    if let (phrase, kind) = phrases.first(where: { normalized.hasPrefix($0.0) && (normalized.count == $0.0.count || normalized.dropFirst($0.0.count).first?.isWhitespace == true) }) {
                        rest = rest.dropFirst(phrase.count)
                        result.range = range(kind, now: now, calendar: calendar)
                    } else {
                        let value = takeToken()
                        if let day = isoDay(value, calendar: calendar) {
                            result.range = calendar.dateInterval(of: .day, for: day)
                        } else if !value.isEmpty {
                            let quoted = value.normalizedForSearch
                            if let match = phrases.first(where: { $0.0 == quoted }) {
                                result.range = range(match.1, now: now, calendar: calendar)
                            } else {
                                result.invalidDate = value
                            }
                        }
                    }
                } else {
                    let value = takeToken().normalizedForSearch
                    guard !value.isEmpty else { continue }
                    if key.hasPrefix("n") { result.names.append(value) } else { result.texts.append(value) }
                }
            } else {
                let word = takeToken().normalizedForSearch
                if !word.isEmpty { result.words.append(word) }
            }
        }
        return result
    }

    private static func isoDay(_ value: String, calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func range(_ kind: String, now: Date, calendar: Calendar) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> DateInterval? {
            calendar.date(byAdding: .day, value: offset, to: today).flatMap { calendar.dateInterval(of: .day, for: $0) }
        }
        switch kind {
        case "today": return day(0)
        case "yesterday": return day(-1)
        case "dayBeforeYesterday": return day(-2)
        case "thisWeek": return calendar.dateInterval(of: .weekOfYear, for: now)
        case "lastWeek": return calendar.date(byAdding: .day, value: -7, to: now).flatMap { calendar.dateInterval(of: .weekOfYear, for: $0) }
        case "thisMonth": return calendar.dateInterval(of: .month, for: now)
        case "lastMonth": return calendar.date(byAdding: .month, value: -1, to: now).flatMap { calendar.dateInterval(of: .month, for: $0) }
        default: return nil
        }
    }

    var isEmpty: Bool { words.isEmpty && names.isEmpty && texts.isEmpty && range == nil && invalidDate == nil }

    /// `text` : le texte reconnu dans l'image, s'il est connu.
    func matches(name: String, text: String?, date: Date) -> Bool {
        guard invalidDate == nil else { return false }
        if let range, !(range.start <= date && date < range.end) { return false }
        let normalizedName = name.replacingOccurrences(of: "’", with: "'").normalizedForSearch
        let normalizedText = text?.normalizedForSearch ?? ""
        for value in names where !normalizedName.contains(value) { return false }
        for value in texts where !normalizedText.contains(value) { return false }
        for word in words where !normalizedName.contains(word) && !normalizedText.contains(word) { return false }
        return true
    }
}

// MARK: - Bibliothèque

/// Les captures des dossiers surveillés : inventaire, surveillance, vignettes et texte reconnu, en cache.
@MainActor
final class ScreenshotLibrary {
    static let shared = ScreenshotLibrary()

    private(set) var files: [ScreenshotFile] = []
    private(set) var isScanning = false
    private(set) var hasScanned = false
    /// Nombre de captures dont le texte reste à reconnaître.
    private(set) var ocrRemaining = 0
    var onChange: (@MainActor () -> Void)?

    private var thumbnails: [String: NSImage] = [:]
    private var thumbnailQueue: [ScreenshotFile] = []
    private var thumbnailsRunning = false
    private var ocr: [String: OCREntry] = [:]
    private var ocrLoaded = false
    private var ocrRunning = false
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var watchedPaths: [String] = []
    private var notifyWork: DispatchWorkItem?
    private var scanWork: DispatchWorkItem?
    private var purgeTimer: Timer?

    struct OCREntry: Codable {
        var modified: Double
        var text: String
    }

    // MARK: Dossiers

    /// L'emplacement des captures choisi dans « Capture d’écran » (le Bureau par défaut).
    static var systemLocation: URL {
        let defaults = UserDefaults(suiteName: "com.apple.screencapture")
        if let location = defaults?.string(forKey: "location"), !location.isEmpty {
            return URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true)
        }
        return desktop
    }

    static var desktop: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    var folders: [URL] {
        if FeatureDemo.isActive { return [ScreenshotsDemo.folder] }
        var seen = Set<String>()
        let all = [Self.systemLocation, Self.desktop] + ScreenshotsSettings.shared.extraFolders.map { URL(fileURLWithPath: $0, isDirectory: true) }
        return all.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Le cache des vignettes et du texte reconnu : un sous-dossier propre aux captures.
    var cacheDirectory: URL {
        if FeatureDemo.isActive {
            let url = FeatureDemo.directory.appendingPathComponent("cache", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        return StoreLocation.subdirectory("ScreenshotsCache")
    }

    /// Hors démonstration, un rendu ou un autotest ne lit jamais les dossiers de l'utilisateur.
    private var isReadAllowed: Bool { FeatureDemo.isActive || !FeatureDemo.isHeadless }

    // MARK: Inventaire

    /// Première utilisation : cache du texte, inventaire, surveillance des dossiers.
    func activate() {
        guard isReadAllowed else { return }
        loadOCRCache()
        if !hasScanned { scan(synchronously: FeatureDemo.isActive) }
        watchFolders()
    }

    func scan(synchronously: Bool = false) {
        guard isReadAllowed else { return }
        let folders = folders
        let allMedia = ScreenshotsSettings.shared.allMedia
        if synchronously {
            apply(Self.scanFolders(folders, allMedia: allMedia))
            return
        }
        guard !isScanning else { return }
        isScanning = true
        Task.detached(priority: .userInitiated) {
            let found = ScreenshotLibrary.scanFolders(folders, allMedia: allMedia)
            await MainActor.run { ScreenshotLibrary.shared.apply(found) }
        }
    }

    private func apply(_ found: [ScreenshotFile]) {
        isScanning = false
        hasScanned = true
        files = found
        notify()
        startOCR()
    }

    nonisolated static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "webp", "bmp"]
    nonisolated static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    nonisolated private static let screenshotPrefixes = [
        "capture d'ecran", "enregistrement de l'ecran", "screenshot", "screen shot", "screen recording",
        "bildschirmfoto", "bildschirmaufnahme", "captura de pantalla", "grabacion de pantalla", "schermata", "registrazione schermo",
        "cleanshot", "skarmavbild", "schermafbeelding",
    ]

    /// Le nom d'une capture de macOS, dans les langues courantes.
    nonisolated static func isScreenshotName(_ name: String) -> Bool {
        let normalized = name.replacingOccurrences(of: "’", with: "'").normalizedForSearch
        return screenshotPrefixes.contains { normalized.hasPrefix($0) }
    }

    nonisolated static func scanFolders(_ folders: [URL], allMedia: Bool) -> [ScreenshotFile] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var found: [String: ScreenshotFile] = [:]
        for folder in folders {
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            for url in urls {
                let ext = url.pathExtension.lowercased()
                let isImage = imageExtensions.contains(ext)
                let isVideo = videoExtensions.contains(ext)
                guard isImage || isVideo else { continue }
                let name = url.lastPathComponent
                let isScreenshot = isScreenshotName(name)
                guard isScreenshot || allMedia else { continue }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let modified = values.contentModificationDate ?? .distantPast
                found[url.standardizedFileURL.path] = ScreenshotFile(
                    url: url, name: name, date: values.creationDate ?? modified, modified: modified,
                    size: Int64(values.fileSize ?? 0), isVideo: isVideo, isScreenshot: isScreenshot
                )
            }
        }
        return found.values.sorted { $0.date > $1.date }
    }

    /// La plus récente capture d'image, inventaire relu tout de suite.
    func latestScreenshot() -> ScreenshotFile? {
        guard isReadAllowed else { return nil }
        let found = Self.scanFolders(folders, allMedia: false)
        return found.first { !$0.isVideo }
    }

    private func watchFolders() {
        let paths = folders.map(\.path)
        guard paths != watchedPaths, !FeatureDemo.isHeadless else { return }
        watchers.forEach { $0.cancel() }
        watchers = []
        watchedPaths = paths
        for path in paths {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { ScreenshotLibrary.shared.scheduleScan() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watchers.append(source)
        }
    }

    /// Les réglages des dossiers ont changé : nouvel inventaire, nouvelle surveillance.
    func foldersDidChange() {
        guard hasScanned else { return }
        watchFolders()
        scan()
    }

    private func scheduleScan() {
        scanWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { ScreenshotLibrary.shared.scan() } }
        scanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Prévient l'écran affiché, au plus toutes les 150 ms.
    private func notify() {
        notifyWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { ScreenshotLibrary.shared.onChange?() } }
        notifyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: Vignettes

    nonisolated private static let thumbnailPixels = 360

    func thumbnail(for file: ScreenshotFile) -> NSImage? {
        thumbnails[file.path + "|\(file.modified.timeIntervalSince1970)"]
    }

    /// Prépare les vignettes de ces fichiers, en arrière-plan, dans l'ordre d'affichage.
    func requestThumbnails(_ wanted: [ScreenshotFile]) {
        let missing = wanted.filter { thumbnail(for: $0) == nil && !thumbnailQueue.contains($0) }
        guard !missing.isEmpty else { return }
        thumbnailQueue += missing
        runThumbnails()
    }

    private func runThumbnails() {
        guard !thumbnailsRunning, !thumbnailQueue.isEmpty else { return }
        thumbnailsRunning = true
        let batch = Array(thumbnailQueue.prefix(12))
        let cache = cacheDirectory.appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        Task.detached(priority: .utility) {
            var made: [(String, NSImage)] = []
            for file in batch {
                if let image = await ScreenshotLibrary.loadThumbnail(file, cache: cache) {
                    made.append((file.path + "|\(file.modified.timeIntervalSince1970)", image))
                }
            }
            let finished = made
            await MainActor.run {
                let library = ScreenshotLibrary.shared
                for (key, image) in finished { library.thumbnails[key] = image }
                library.thumbnailQueue.removeAll { batch.contains($0) }
                library.thumbnailsRunning = false
                library.notify()
                library.runThumbnails()
            }
        }
    }

    nonisolated private static func cacheKey(_ file: ScreenshotFile) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in "\(file.path)|\(file.modified.timeIntervalSince1970)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    /// Vignette carrée : l'image entière, aux coins arrondis, centrée (cache disque, sinon ImageIO ou Quick Look).
    nonisolated private static func loadThumbnail(_ file: ScreenshotFile, cache: URL) async -> NSImage? {
        let cached = cache.appendingPathComponent(cacheKey(file) + ".png")
        if let source = CGImageSourceCreateWithURL(cached as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
        }
        var picture: CGImage?
        if !file.isVideo, let source = CGImageSourceCreateWithURL(file.url as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
            ]
            picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        if picture == nil {
            let size = CGSize(width: thumbnailPixels / 2, height: thumbnailPixels / 2)
            let preview = await ImageThumbnail.quickLook(file.url, size: size)
            picture = preview?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard let picture, let square = squared(picture, isVideo: file.isVideo) else { return nil }
        if let destination = CGImageDestinationCreateWithURL(cached as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, square, nil)
            CGImageDestinationFinalize(destination)
        }
        return NSImage(cgImage: square, size: NSSize(width: square.width / 2, height: square.height / 2))
    }

    nonisolated private static func squared(_ image: CGImage, isVideo: Bool) -> CGImage? {
        let side = CGFloat(thumbnailPixels)
        guard let context = CGContext(
            data: nil, width: thumbnailPixels, height: thumbnailPixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let scale = min(side / CGFloat(image.width), side / CGFloat(image.height))
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        let rect = CGRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height)
        context.interpolationQuality = .high
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
        context.clip()
        context.draw(image, in: rect)
        context.restoreGState()
        if isVideo {
            // Un bouton de lecture : l'enregistrement se distingue d'une capture.
            let radius: CGFloat = 26
            let center = CGPoint(x: side / 2, y: side / 2)
            context.setFillColor(CGColor(gray: 0, alpha: 0.55))
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.setFillColor(CGColor(gray: 1, alpha: 0.95))
            context.beginPath()
            context.move(to: CGPoint(x: center.x - 8, y: center.y - 12))
            context.addLine(to: CGPoint(x: center.x - 8, y: center.y + 12))
            context.addLine(to: CGPoint(x: center.x + 13, y: center.y))
            context.closePath()
            context.fillPath()
        }
        return context.makeImage()
    }

    // MARK: Texte reconnu

    private var ocrURL: URL { cacheDirectory.appendingPathComponent("ocr.json") }

    private func loadOCRCache() {
        guard !ocrLoaded else { return }
        ocrLoaded = true
        if FeatureDemo.isActive {
            ocr = ScreenshotsDemo.texts
            return
        }
        if let data = try? Data(contentsOf: ocrURL), let decoded = try? JSONDecoder().decode([String: OCREntry].self, from: data) {
            ocr = decoded
        }
    }

    private func saveOCRCache() {
        guard !FeatureDemo.isActive else { return }
        let existing = Set(files.map(\.path))
        // Les captures supprimées sortent du cache ; celles des dossiers retirés aussi.
        let snapshot = ocr.filter { existing.contains($0.key) }
        let url = ocrURL
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    func text(for file: ScreenshotFile) -> String? {
        guard let entry = ocr[file.path], entry.modified == file.modified.timeIntervalSince1970 else { return nil }
        return entry.text
    }

    /// Reconnaît le texte des captures qui n'en ont pas encore, une à une, en arrière-plan.
    private func startOCR() {
        let settings = ScreenshotsSettings.shared
        guard settings.ocrEnabled, !ocrRunning, !FeatureDemo.isActive else { return }
        let pending = files.filter { !$0.isVideo && text(for: $0) == nil }
        ocrRemaining = pending.count
        guard !pending.isEmpty else { return }
        ocrRunning = true
        let accurate = settings.ocrAccurate
        Task.detached(priority: .background) {
            var done = 0
            for file in pending.prefix(400) {
                let text = await ScreenshotLibrary.recognize(file.url, accurate: accurate) ?? ""
                done += 1
                let save = done % 10 == 0
                await MainActor.run {
                    let library = ScreenshotLibrary.shared
                    library.ocr[file.path] = OCREntry(modified: file.modified.timeIntervalSince1970, text: text)
                    library.ocrRemaining = max(0, library.ocrRemaining - 1)
                    if save { library.saveOCRCache() }
                }
            }
            await MainActor.run {
                let library = ScreenshotLibrary.shared
                library.ocrRunning = false
                library.saveOCRCache()
                library.notify()
            }
        }
    }

    /// Le texte d'une capture, tout de suite (« Copier le texte » avant l'indexation).
    func recognizeNow(_ file: ScreenshotFile) async -> String? {
        if let cached = text(for: file) { return cached }
        let text = await Self.recognize(file.url, accurate: true)
        ocr[file.path] = OCREntry(modified: file.modified.timeIntervalSince1970, text: text ?? "")
        saveOCRCache()
        return text
    }

    nonisolated private static func recognize(_ url: URL, accurate: Bool) async -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_600,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return await TextRecognition.recognize(image, accurate: accurate)
    }

    func clearCache() {
        ocr = [:]
        thumbnails = [:]
        try? FileManager.default.removeItem(at: cacheDirectory)
        ocrLoaded = true
        startOCR()
    }

    // MARK: Fichiers

    func forget(_ file: ScreenshotFile) {
        files.removeAll { $0.path == file.path }
        ScreenshotsSettings.shared.pinned.removeAll { $0 == file.path }
        notify()
    }

    func togglePin(_ file: ScreenshotFile) {
        let settings = ScreenshotsSettings.shared
        if settings.pinned.contains(file.path) {
            settings.pinned.removeAll { $0 == file.path }
        } else {
            settings.pinned.append(file.path)
        }
    }

    // MARK: Conservation

    /// Programme la mise à la corbeille des vieilles captures, si elle est activée.
    func schedulePurge() {
        guard !FeatureDemo.isHeadless, purgeTimer == nil else { return }
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { ScreenshotLibrary.shared.purgeIfNeeded() }
        }
        timer.fireDate = Date().addingTimeInterval(90)
        RunLoop.main.add(timer, forMode: .common)
        purgeTimer = timer
    }

    /// Met à la corbeille les captures (jamais les autres médias) non épinglées, plus vieilles que le délai choisi.
    func purgeIfNeeded() {
        let days = ScreenshotsSettings.shared.retentionDays
        guard days > 0, !FeatureDemo.isHeadless else { return }
        let cutoff = Date().addingTimeInterval(-TimeInterval(days) * 86_400)
        let pinned = Set(ScreenshotsSettings.shared.pinned)
        let old = Self.scanFolders(folders, allMedia: false).filter { $0.isScreenshot && !pinned.contains($0.path) && $0.date < cutoff }
        var trashed = 0
        for file in old where (try? FileManager.default.trashItem(at: file.url, resultingItemURL: nil)) != nil {
            trashed += 1
        }
        if trashed > 0 {
            NSLog("Prism : \(trashed) capture(s) de plus de \(days) jour(s) mise(s) à la corbeille")
            if hasScanned { scan() }
        }
    }
}
