import AppKit

/// Historique du presse-papiers : texte, images, fichiers, liens, e-mails, couleurs, avec tous leurs formats.
/// NSPasteboard est interrogé deux fois par seconde ; l'écriture sur disque, les vignettes
/// et la reconnaissance de texte se font en arrière-plan.
@MainActor
final class ClipboardMonitor: ObservableObject {
    static let shared = ClipboardMonitor()

    typealias Entry = ClipboardEntry

    /// Les entrées, de la plus récente à la plus ancienne.
    @Published private(set) var entries: [Entry] = []

    /// Dernière copie faite hors de Prism : « Coller en séquence » repart alors du début.
    private(set) var lastExternalChange = Date.distantPast

    private var changeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var pruneTimer: Timer?
    private var ignoreUntil = Date.distantPast
    private var haystacks: [UUID: String] = [:]
    private var pendingSave: DispatchWorkItem?
    /// Contenu des entrées de démonstration (rendus hors application), qui ne vont pas sur disque.
    private var memoryContent: [UUID: [[String: Data]]] = [:]
    private var recognitionQueue: [UUID] = []
    private var isRecognizing = false

    private var settings: ClipboardSettings { .shared }

    /// Rendus et autotests : ni lecture ni écriture des données de l'utilisateur.
    static let isOffline = CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--selftest")

    private init() {
        if Self.isOffline {
            if CommandLine.arguments.contains("--snapshot") { loadDemo() }
            return
        }
        ClipboardStorage.root = StoreLocation.subdirectory("Clipboard")
        load()
    }

    func start() {
        guard !Self.isOffline else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardMonitor.shared.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let pruneTimer = Timer(timeInterval: 1_800, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardMonitor.shared.prune() }
        }
        RunLoop.main.add(pruneTimer, forMode: .common)
        self.pruneTimer = pruneTimer
        recognizeMissing()
        // L'ancien historique, protégé, ne se lit qu'une fois la session déverrouillée.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ClipboardMonitor.shared.importLegacyIfPresent() }
        }
    }

    /// Rattrape la migration de l'ancien `clipboard.json` s'il est encore là.
    func importLegacyIfPresent() {
        guard let added = ClipboardStorage.importLegacy(legacyURL: StoreLocation.file("clipboard.json"), existing: Set(entries.map(\.id))),
              !added.isEmpty else { return }
        entries += added
        sortEntries()
        ClipboardStorage.saveIndex(entries)
        NotificationCenter.default.post(name: .clipboardDidChange, object: nil)
    }

    /// Les copies de Prism lui-même (lecture de la sélection, collage depuis l'historique) ne vont pas dans l'historique.
    func ignoreNextChange() {
        ignoreUntil = Date().addingTimeInterval(1.5)
    }

    // MARK: - Capture

    /// Ce qu'on lit du presse-papiers au moment de la copie.
    struct Capture {
        var items: [[String: Data]]
        var plainText: String?
        var filePaths: [String]
        var kind: Entry.Kind
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        guard Date() > ignoreUntil else { return }
        lastExternalChange = Date()
        guard Preferences.shared.clipboardHistoryEnabled else { return }
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: ClipboardClassifier.concealedTypes) else { return }
        let app = NSWorkspace.shared.frontmostApplication
        if let bundleID = app?.bundleIdentifier, settings.disabledApps.contains(bundleID) { return }
        guard let capture = Self.read(pasteboard) else { return }
        ingest(capture, date: Date(), app: app?.localizedName, bundleID: app?.bundleIdentifier)
    }

    /// Tous les éléments et tous leurs formats. `nil` : rien à garder (presse-papiers vide, format inconnu).
    static func read(_ pasteboard: NSPasteboard) -> Capture? {
        let items = (pasteboard.pasteboardItems ?? []).map { item -> [String: Data] in
            var formats: [String: Data] = [:]
            for type in item.types where !ClipboardClassifier.skippedTypes.contains(type.rawValue) && !ClipboardClassifier.concealedTypes.contains(type.rawValue) {
                if let data = item.data(forType: type) { formats[type.rawValue] = data }
            }
            return formats
        }.filter { !$0.isEmpty }
        guard !items.isEmpty else { return nil }

        var plainText = pasteboard.string(forType: .string)
        if plainText == nil, let rtf = pasteboard.data(forType: .rtf) {
            plainText = NSAttributedString(rtf: rtf, documentAttributes: nil)?.string
        }
        if plainText == nil, let html = pasteboard.data(forType: .html) {
            plainText = NSAttributedString(html: html, documentAttributes: nil)?.string
        }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard let kind = ClipboardClassifier.kind(types: items.map { Array($0.keys) }, plainText: plainText) else { return nil }
        if kind == .files, urls.isEmpty { return nil }
        return Capture(items: items, plainText: plainText, filePaths: urls.map(\.path), kind: kind)
    }

    /// Enregistre une copie : empreinte en arrière-plan, puis doublon remonté ou nouvelle entrée écrite sur disque.
    func ingest(_ capture: Capture, date: Date, app: String?, bundleID: String?) {
        ClipboardStorage.queue.async {
            guard let items = ClipboardStorage.capped(capture.items) else {
                NSLog("Prism : copie trop volumineuse, ignorée par l’historique")
                return
            }
            let allTypes = items.flatMap { $0.keys }
            let imageType = ClipboardClassifier.mainImageType(in: allTypes)
            let imageData = imageType.flatMap { type in items.lazy.compactMap { $0[type] }.first }
            let text = capture.plainText ?? ""
            let signature: String
            switch capture.kind {
            case .files: signature = ClipboardSignature.files(capture.filePaths)
            case .image: signature = imageData.map(ClipboardSignature.image) ?? ClipboardSignature.text(text)
            default: signature = ClipboardSignature.text(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.bump(signature: signature, date: date, app: app, bundleID: bundleID) { return }
                    self.store(capture, items: items, imageType: imageType, imageData: imageData, signature: signature, date: date, app: app, bundleID: bundleID)
                }
            }
        }
    }

    /// Le même contenu est déjà dans l'historique : il remonte en tête.
    private func bump(signature: String, date: Date, app: String?, bundleID: String?) -> Bool {
        guard let index = entries.firstIndex(where: { $0.signature == signature }) else { return false }
        entries[index].date = date
        entries[index].copyCount += 1
        if let app {
            entries[index].sourceApp = app
            entries[index].sourceBundleID = bundleID
        }
        sortEntries()
        changed()
        return true
    }

    private func store(_ capture: Capture, items: [[String: Data]], imageType: String?, imageData: Data?, signature: String, date: Date, app: String?, bundleID: String?) {
        let id = UUID()
        let text: String
        switch capture.kind {
        case .files: text = capture.filePaths.joined(separator: "\n")
        case .image: text = capture.plainText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        default: text = capture.plainText ?? ""
        }
        let base = Entry(
            id: id,
            kind: capture.kind,
            text: text,
            date: date,
            sourceApp: app,
            sourceBundleID: bundleID,
            signature: signature,
            formats: Array(Set(items.flatMap { $0.keys })).sorted(),
            itemCount: items.count,
            byteSize: items.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } },
            files: capture.kind == .files ? capture.filePaths : []
        )
        ClipboardStorage.queue.async {
            guard ClipboardStorage.writeContent(items, id: id) else { return }
            var entry = base
            if entry.kind == .image, let imageData, let imageType {
                guard let size = ClipboardStorage.processImage(imageData, id: id) else {
                    ClipboardStorage.removeFolders([id])
                    return
                }
                entry.image = .init(width: size.width, height: size.height, format: ClipboardClassifier.imageFormatName(imageType))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.insert(entry) }
            }
        }
    }

    private func insert(_ entry: Entry) {
        // Une copie identique a pu arriver entre-temps.
        if entries.contains(where: { $0.signature == entry.signature }) {
            ClipboardStorage.removeFolders([entry.id])
            return
        }
        entries.append(entry)
        sortEntries()
        prune(notify: false)
        changed()
        if entry.kind == .image {
            enqueueRecognition(entry.id)
        } else if entry.kind == .files, entry.files.count == 1 {
            let id = entry.id
            ClipboardStorage.processFilePreview(entry.files[0], id: id) { made in
                guard made else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        ClipboardImageCache.invalidate(id)
                        NotificationCenter.default.post(name: .clipboardDidChange, object: nil)
                    }
                }
            }
        }
    }

    // MARK: - Modifications

    func remove(_ id: UUID) {
        remove(ids: [id])
    }

    func remove(ids: [UUID]) {
        let set = Set(ids)
        guard entries.contains(where: { set.contains($0.id) }) else { return }
        entries.removeAll { set.contains($0.id) }
        for id in set {
            haystacks[id] = nil
            memoryContent[id] = nil
            ClipboardImageCache.invalidate(id)
        }
        ClipboardStorage.removeFolders(Array(set))
        changed()
    }

    /// Efface tout l'historique, entrées épinglées comprises.
    func clear() {
        clear(includingPinned: true)
    }

    func clear(includingPinned: Bool) {
        remove(ids: entries.filter { includingPinned || !$0.isPinned }.map(\.id))
    }

    func togglePin(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].pinnedAt = entries[index].isPinned ? nil : Date()
        changed()
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[index].name = trimmed.isEmpty ? nil : trimmed
        haystacks[id] = nil
        changed()
    }

    /// Nouveau texte pour une entrée textuelle : le texte riche d'origine ne correspond plus, il est remplacé.
    func updateText(_ id: UUID, to text: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let items = [[NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]]
        entries[index].text = String(text.prefix(Entry.indexedTextLimit))
        entries[index].characterCount = text.count
        entries[index].kind = ClipboardClassifier.kind(forText: text)
        entries[index].signature = ClipboardSignature.text(text.trimmingCharacters(in: .whitespacesAndNewlines))
        entries[index].formats = [NSPasteboard.PasteboardType.string.rawValue]
        entries[index].itemCount = 1
        entries[index].byteSize = text.utf8.count
        haystacks[id] = nil
        if Self.isOffline {
            memoryContent[id] = items
        } else {
            ClipboardStorage.queue.async { ClipboardStorage.writeContent(items, id: id) }
        }
        changed()
    }

    /// Après un collage ou une copie depuis l'historique, l'entrée remonte en tête (réglage).
    func markUsed(_ id: UUID) {
        guard settings.moveToTopOnUse, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].date = Date()
        entries[index].copyCount += 1
        sortEntries()
        changed()
    }

    /// Applique la durée de conservation et le nombre maximal d'entrées.
    func prune(notify: Bool = true) {
        let expired = ClipboardRetention.expired(entries, now: Date(), retention: settings.retention, maxCount: settings.maxEntries)
        guard !expired.isEmpty else { return }
        if notify {
            remove(ids: Array(expired))
        } else {
            entries.removeAll { expired.contains($0.id) }
            ClipboardStorage.removeFolders(Array(expired))
        }
    }

    // MARK: - Contenu

    /// Tous les formats d'origine, pour recoller à l'identique.
    func content(for entry: Entry) -> [[NSPasteboard.PasteboardType: Data]] {
        let stored = memoryContent[entry.id] ?? ClipboardStorage.readContent(entry.id)
        if let stored, !stored.isEmpty {
            return stored.map { Dictionary(uniqueKeysWithValues: $0.map { (NSPasteboard.PasteboardType($0.key), $0.value) }) }
        }
        return [[.string: Data(entry.text.utf8)]]
    }

    /// Le texte complet (celui de l'index peut être tronqué).
    func fullText(_ entry: Entry) -> String {
        guard entry.characterCount > entry.text.count else { return entry.text }
        for item in content(for: entry) {
            if let data = item[.string], let text = String(data: data, encoding: .utf8) { return text }
        }
        return entry.text
    }

    /// Les données de l'image principale.
    func imageData(_ entry: Entry) -> (type: String, data: Data)? {
        for item in content(for: entry) {
            let types = item.keys.map(\.rawValue)
            if let type = ClipboardClassifier.mainImageType(in: types), let data = item[NSPasteboard.PasteboardType(type)] {
                return (type, data)
            }
        }
        return nil
    }

    enum WriteMode {
        case original, plainText, png
    }

    /// Remet l'entrée dans le presse-papiers sans l'ajouter de nouveau à l'historique.
    func write(_ entry: Entry, mode: WriteMode = .original, appendingNewline: Bool = false) {
        ignoreNextChange()
        switch mode {
        case .plainText:
            Pasteboard.copy(fullText(entry) + (appendingNewline ? "\n" : ""))
        case .png:
            if let image = imageData(entry), let png = image.type == "public.png" ? image.data : ClipboardStorage.pngData(image.data) {
                Pasteboard.write([[.png: png]])
            } else {
                Pasteboard.write(content(for: entry))
            }
        case .original:
            if appendingNewline, entry.isTextual {
                Pasteboard.copy(fullText(entry) + "\n")
            } else {
                Pasteboard.write(content(for: entry))
            }
        }
        changeCount = NSPasteboard.general.changeCount
    }

    /// Le texte de la n-ième entrée textuelle (0 : la plus récente), pour `{clipboard offset=n}`.
    func text(at offset: Int) -> String? {
        let textual = entries.filter(\.isTextual)
        guard textual.indices.contains(offset) else { return nil }
        return fullText(textual[offset])
    }

    /// Le texte où chercher, gardé en mémoire.
    func haystack(_ entry: Entry) -> String {
        if let cached = haystacks[entry.id] { return cached }
        let value = ClipboardSearch.haystack(entry)
        haystacks[entry.id] = value
        return value
    }

    // MARK: - Reconnaissance de texte

    /// Reconnaît le texte des images qui ne l'ont pas encore été (réglage activé après coup, redémarrage).
    func recognizeMissing() {
        guard settings.recognizeText else { return }
        for entry in entries where entry.kind == .image && !entry.isRecognized {
            enqueueRecognition(entry.id)
        }
    }

    private func enqueueRecognition(_ id: UUID) {
        guard !Self.isOffline, !recognitionQueue.contains(id) else { return }
        recognitionQueue.append(id)
        runRecognition()
    }

    private func runRecognition() {
        guard !isRecognizing, !recognitionQueue.isEmpty else { return }
        let id = recognitionQueue.removeFirst()
        guard let entry = entries.first(where: { $0.id == id }), let data = imageData(entry)?.data else {
            runRecognition()
            return
        }
        isRecognizing = true
        let recognizeText = settings.recognizeText
        let accurate = settings.accurateRecognition
        Task { @MainActor in
            let image: CGImage? = await withCheckedContinuation { continuation in
                ClipboardStorage.queue.async { continuation.resume(returning: ClipboardStorage.fullImage(data)) }
            }
            var text: String?
            var codes: [String] = []
            if let image {
                if recognizeText { text = await TextRecognition.recognize(image, accurate: accurate) }
                codes = await TextRecognition.barcodes(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
            }
            if let index = self.entries.firstIndex(where: { $0.id == id }) {
                if recognizeText {
                    self.entries[index].recognizedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.entries[index].isRecognized = true
                }
                self.entries[index].barcodes = codes
                self.haystacks[id] = nil
                self.changed()
            }
            self.isRecognizing = false
            self.runRecognition()
        }
    }

    /// Reconnaît le texte d'une image tout de suite (action « Copier le texte de l'image »), en mode précis.
    func recognizeNow(_ entry: Entry) async -> String? {
        guard let data = imageData(entry)?.data else { return nil }
        let image: CGImage? = await withCheckedContinuation { continuation in
            ClipboardStorage.queue.async { continuation.resume(returning: ClipboardStorage.fullImage(data)) }
        }
        guard let image else { return nil }
        return await TextRecognition.recognize(image, accurate: true)
    }

    // MARK: - Persistance

    private func load() {
        entries = ClipboardStorage.loadIndex() ?? []
        if let added = ClipboardStorage.importLegacy(legacyURL: StoreLocation.file("clipboard.json"), existing: Set(entries.map(\.id))) {
            entries += added
            if !added.isEmpty { ClipboardStorage.saveIndex(entries) }
        }
        sortEntries()
        ClipboardStorage.removeOrphans(keeping: Set(entries.map(\.id)))
        prune(notify: false)
    }

    private func sortEntries() {
        entries.sort { $0.date > $1.date }
    }

    private func changed() {
        scheduleSave()
        NotificationCenter.default.post(name: .clipboardDidChange, object: nil)
    }

    private func scheduleSave() {
        guard !Self.isOffline else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { ClipboardStorage.saveIndex(ClipboardMonitor.shared.entries) }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: - Démonstration

    /// Un historique varié pour les rendus (`--snapshot`) : jamais les données de l'utilisateur.
    private func loadDemo() {
        let now = Date()
        func entry(_ text: String, minutes: Double, app: String, kind: ClipboardEntry.Kind? = nil, formats: [String] = ["public.utf8-plain-text"]) -> Entry {
            var entry = Entry(
                kind: kind ?? ClipboardClassifier.kind(forText: text),
                text: text,
                date: now.addingTimeInterval(-minutes * 60),
                sourceApp: app,
                signature: ClipboardSignature.text(text),
                formats: formats,
                byteSize: text.utf8.count
            )
            entry.copyCount = 1
            return entry
        }
        var list: [Entry] = []
        list.append(entry("func greet(_ name: String) -> String {\n    \"Bonjour, \\(name) !\"\n}", minutes: 2, app: "Xcode"))
        list.append(entry("https://github.com/apple/swift-collections", minutes: 6, app: "Safari"))

        var image = Entry(kind: .image, text: "", date: now.addingTimeInterval(-12 * 60), sourceApp: "Aperçu", signature: "i:demo", formats: ["public.png", "public.tiff"], byteSize: 1_843_200)
        image.image = .init(width: 1_440, height: 900, format: "PNG")
        image.recognizedText = "Prism\nUn lanceur pour macOS"
        image.isRecognized = true
        if let picture = Self.demoImage() {
            ClipboardImageCache.store(picture, id: image.id, kind: "preview")
            ClipboardImageCache.store(picture, id: image.id, kind: "thumbnail")
            if let tiff = picture.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                memoryContent[image.id] = [["public.png": png]]
                image.byteSize = png.count
            }
        }
        list.append(image)

        list.append(entry("#5E5CE6", minutes: 25, app: "Figma"))
        list.append(entry("camille.martin@exemple.fr", minutes: 58, app: "Mail"))
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [home.appendingPathComponent("Documents").path, home.appendingPathComponent("Downloads").path]
        var files = Entry(kind: .files, text: paths.joined(separator: "\n"), date: now.addingTimeInterval(-3 * 3_600), sourceApp: "Finder", signature: ClipboardSignature.files(paths), formats: ["public.file-url"], itemCount: 2, files: paths)
        files.byteSize = 0
        list.append(files)
        list.append(entry("rgb(255, 149, 0)", minutes: 60 * 5, app: "Safari"))
        list.append(entry("Le comité se réunira jeudi à 10 h pour arrêter le calendrier de la version 2.0.\nOrdre du jour : bilan du trimestre, priorités, recrutements.", minutes: 60 * 26, app: "Notes", formats: ["public.html", "public.rtf", "public.utf8-plain-text"]))
        list.append(entry("npm run build -- --watch", minutes: 60 * 50, app: "Terminal"))
        list.append(entry("Merci pour votre retour, je vous envoie la version corrigée dans la journée.", minutes: 60 * 24 * 4, app: "Mail"))

        var pinnedLink = entry("https://developer.apple.com/documentation/appkit/nspasteboard", minutes: 60 * 24 * 9, app: "Safari")
        pinnedLink.pinnedAt = now
        pinnedLink.name = "Documentation de NSPasteboard"
        var pinnedText = entry("IBAN : FR76 3000 6000 0112 3456 7890 189", minutes: 60 * 24 * 20, app: "Notes")
        pinnedText.pinnedAt = now.addingTimeInterval(-60)
        pinnedText.name = "IBAN du compte courant"
        list += [pinnedLink, pinnedText]
        entries = list.sorted { $0.date > $1.date }
    }

    private static func demoImage() -> NSImage? {
        let size = NSSize(width: 1_440, height: 900)
        return NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [
                NSColor(srgbRed: 0.36, green: 0.36, blue: 0.90, alpha: 1),
                NSColor(srgbRed: 0.90, green: 0.36, blue: 0.62, alpha: 1),
            ])?.draw(in: rect, angle: -35)
            NSColor(white: 1, alpha: 0.16).setFill()
            NSBezierPath(ovalIn: NSRect(x: 900, y: 420, width: 620, height: 620)).fill()
            NSBezierPath(ovalIn: NSRect(x: -160, y: -220, width: 560, height: 560)).fill()
            let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 150, weight: .bold), .foregroundColor: NSColor.white]
            ("Prism" as NSString).draw(at: NSPoint(x: 140, y: 420), withAttributes: title)
            let subtitle: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 56, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.85)]
            ("Un lanceur pour macOS" as NSString).draw(at: NSPoint(x: 146, y: 330), withAttributes: subtitle)
            return true
        }
    }
}
