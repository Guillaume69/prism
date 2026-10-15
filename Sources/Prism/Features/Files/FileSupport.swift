import AppKit
import Quartz
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Données de démonstration des rendus hors écran (`Prism --snapshot … --demo`). Jamais actives en production :
/// elles remplacent l'agenda, les contacts et les fichiers privés quand on vérifie le design.
enum FeatureDemo {
    static let isActive = CommandLine.arguments.contains("--snapshot") && CommandLine.arguments.contains("--demo")
    /// Exécution sans interface (`--snapshot`, `--selftest`) : aucune tâche de fond sur les fichiers de l'utilisateur.
    static let isHeadless = CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--selftest")

    /// Dossier temporaire des fichiers de démonstration.
    static var directory: URL {
        let temporary = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: temporary).appendingPathComponent("prism-demo", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Confirmation

/// Demande de confirmation dans le lanceur, comme l'alerte de Raycast : ↵ confirme, Échap annule.
@MainActor
final class DestructiveConfirmScreen: LauncherScreen {
    let message: String
    let confirmTitle: String
    private let onConfirm: @MainActor () -> ActionOutcome

    init(title: String, message: String, confirmTitle: String, symbol: String = "trash.fill", onConfirm: @escaping @MainActor () -> ActionOutcome) {
        self.message = message
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        super.init(id: "confirm", title: title, icon: .symbol(symbol, Palette.red))
        layout = .custom
        hidesSearchField = true
    }

    func confirm() -> ActionOutcome {
        let outcome = onConfirm()
        return .then(.pop, outcome)
    }

    override func customView() -> AnyView { AnyView(DestructiveConfirmView(screen: self)) }

    override var screenActions: [ItemAction] {
        [
            ItemAction(title: confirmTitle, symbol: "checkmark.circle", shortcut: KeyShortcut(keyCode: 36, modifiers: [], label: "↵"), isDestructive: true) { [weak self] in
                self?.confirm() ?? .stay
            },
            ItemAction(title: "Annuler", symbol: "xmark.circle", shortcut: KeyShortcut(keyCode: 53, modifiers: [], label: "Échap")) { .pop },
        ]
    }

    override func handleKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard event.keyCode == 36 || event.keyCode == 76, modifiers.isEmpty else { return false }
        host?.apply(confirm())
        return true
    }

    override var customViewHandlesNavigation: Bool { true }
}

private struct DestructiveConfirmView: View {
    let screen: DestructiveConfirmScreen

    var body: some View {
        VStack(spacing: 14) {
            ItemIconView(icon: screen.icon, size: 44)
            VStack(spacing: 6) {
                Text(screen.title)
                    .font(.system(size: 16, weight: .semibold))
                Text(screen.message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .frame(maxWidth: 420)
            }
            HStack(spacing: 10) {
                button("Annuler", keys: ["Échap"], destructive: false) { screen.host?.pop() }
                button(screen.confirmTitle, keys: ["↵"], destructive: true) { screen.host?.apply(screen.confirm()) }
            }
            .padding(.top, 6)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func button(_ title: String, keys: [String], destructive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(destructive ? Color.white : Color.primary)
                KeycapRow(symbols: keys)
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(destructive ? AnyShapeStyle(Palette.red.gradient) : AnyShapeStyle(Theme.keycap))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Quick Look

/// L'aperçu Quick Look (⌘Y). Le lanceur reste ouvert pendant l'aperçu, puis reprend le clavier.
@MainActor
final class QuickLookPreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPreview()

    nonisolated(unsafe) private var items: [URL] = []
    private var watcher: Timer?

    static var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
    }

    /// Ouvre l'aperçu, ou le ferme s'il est déjà affiché.
    static func toggle(_ urls: [URL]) -> ActionOutcome {
        if isVisible {
            QLPreviewPanel.shared()?.orderOut(nil)
        } else {
            shared.show(urls)
        }
        return .stay
    }

    static func action(_ urls: @escaping @MainActor () -> [URL]) -> ItemAction {
        ItemAction(title: "Aperçu", symbol: "eye", shortcut: .quickLook) { toggle(urls()) }
    }

    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        items = urls
        AppContext.launcher?.keepOpenOnResign = true
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Le panneau se ferme de plusieurs façons (Échap, bouton, perte du focus) : on surveille sa visibilité.
        watcher?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { QuickLookPreview.shared.checkClosed() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watcher = timer
    }

    private func checkClosed() {
        guard !Self.isVisible else { return }
        watcher?.invalidate()
        watcher = nil
        AppContext.launcher?.keepOpenOnResign = false
        if let launcher = AppContext.launcher, launcher.isVisible {
            launcher.window.makeKeyAndOrderFront(nil)
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        items.indices.contains(index) ? items[index] as NSURL : nil
    }

    /// Espace et ⌘Y referment l'aperçu, comme dans le Finder.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 49 && flags.isEmpty || event.keyCode == 16 && flags == .command {
            MainActor.assumeIsolated { panel.orderOut(nil) }
            return true
        }
        return false
    }
}

// MARK: - Opérations sur les fichiers

enum FileOps {
    /// Le nom d'une copie, à la manière du Finder : « Rapport copie.pdf », puis « Rapport copie 2.pdf ».
    static func duplicateName(for name: String, isDirectory: Bool, exists: (String) -> Bool) -> String {
        let ext = isDirectory ? "" : (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        var candidate = "\(base) copie\(suffix)"
        var index = 2
        while exists(candidate) {
            candidate = "\(base) copie \(index)\(suffix)"
            index += 1
        }
        return candidate
    }

    static func duplicate(_ url: URL) throws -> URL {
        let folder = url.deletingLastPathComponent()
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let name = duplicateName(for: url.lastPathComponent, isDirectory: isDirectory) {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        let target = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }

    /// Renomme en gardant le dossier ; l'extension est ajoutée si elle manque.
    static func rename(_ url: URL, to newName: String, keepExtension: Bool) throws -> URL {
        var name = newName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: ":")
        let ext = url.pathExtension
        if keepExtension, !ext.isEmpty, (name as NSString).pathExtension.lowercased() != ext.lowercased() {
            name += "." + ext
        }
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        guard target.path != url.path else { return url }
        if FileManager.default.fileExists(atPath: target.path) {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    static func displayName(_ url: URL) -> String {
        url.path == "/" ? "/" : FileManager.default.displayName(atPath: url.path)
    }

    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    static func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }
}

// MARK: - Ouvrir avec, Terminal, partage

@MainActor
enum OpenWith {
    /// Les applications capables d'ouvrir le fichier, celle par défaut en tête.
    static func screen(for url: URL) -> LauncherScreen {
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        var seen = Set<String>()
        apps = apps.filter { seen.insert($0.lastPathComponent).inserted }
        if let defaultApp {
            apps.removeAll { $0.path == defaultApp.path }
            apps.insert(defaultApp, at: 0)
        }
        return ListScreen(
            id: "open-with",
            title: "Ouvrir avec…",
            placeholder: "Rechercher une application…",
            icon: .file(url.path),
            empty: { _ in ("app.dashed", "Aucune application ne sait ouvrir ce fichier.") }
        ) { query in
            let normalized = query.normalizedForSearch
            let items = apps.compactMap { app -> ResultItem? in
                let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
                guard normalized.isEmpty || Fuzzy.score(normalized, name) != nil else { return nil }
                return ResultItem(
                    id: "open-with:" + app.path,
                    title: name,
                    subtitle: FileOps.abbreviated(app.deletingLastPathComponent().path),
                    icon: .file(app.path),
                    accessory: app.path == defaultApp?.path ? "Par défaut" : nil,
                    usageKey: "",
                    actions: [ItemAction(title: "Ouvrir avec \(name)", symbol: "arrow.up.forward.app") {
                        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                        return .close
                    }]
                )
            }
            return items.isEmpty ? [] : [ResultSection(id: "apps", title: url.lastPathComponent, items: items)]
        }
    }
}

/// Le terminal choisi dans les réglages des fichiers.
enum TerminalApp: String, CaseIterable, Identifiable {
    case terminal = "com.apple.Terminal"
    case iTerm = "com.googlecode.iterm2"
    case ghostty = "com.mitchellh.ghostty"
    case warp = "dev.warp.Warp-Stable"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .iTerm: "iTerm"
        case .ghostty: "Ghostty"
        case .warp: "Warp"
        }
    }

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue) }
    var isInstalled: Bool { appURL != nil }

    static var installed: [TerminalApp] { allCases.filter(\.isInstalled) }

    @MainActor
    static var preferred: TerminalApp {
        let chosen = TerminalApp(rawValue: FilesSettings.shared.terminal) ?? .terminal
        return chosen.isInstalled ? chosen : .terminal
    }

    /// Ouvre une fenêtre du terminal dans ce dossier.
    func open(_ folder: URL) {
        if self == .warp, let encoded = folder.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "warp://action/new_tab?path=\(encoded)") {
            NSWorkspace.shared.open(url)
            return
        }
        guard let appURL = appURL ?? TerminalApp.terminal.appURL else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Le menu de partage de macOS, ancré en bas à droite du lanceur.
@MainActor
final class SharePicker: NSObject, NSSharingServicePickerDelegate {
    static let shared = SharePicker()

    func show(_ urls: [URL]) -> ActionOutcome {
        guard let launcher = AppContext.launcher, let view = launcher.window.contentView else { return .stay }
        let picker = NSSharingServicePicker(items: urls)
        picker.delegate = self
        launcher.keepOpenOnResign = true
        let anchor = NSRect(x: view.bounds.maxX - 120, y: LauncherLayout.footerHeight, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
        return .stay
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        MainActor.assumeIsolated {
            AppContext.launcher?.keepOpenOnResign = false
            if service != nil { AppContext.launcher?.hide() }
        }
    }
}

// MARK: - Informations et aperçu d'un fichier

/// Ce que le détail montre d'un fichier. Lu en arrière-plan.
struct FileInfo: @unchecked Sendable {
    let url: URL
    var isDirectory = false
    var size: Int64?
    var created: Date?
    var modified: Date?
    var lastUsed: Date?
    var typeDescription: String?
    var contentType: UTType?
    var itemCount: Int?
    var pixelSize: CGSize?
    var textPreview: String?

    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileAllocatedSizeKey, .creationDateKey,
        .contentModificationDateKey, .contentAccessDateKey, .contentTypeKey, .localizedTypeDescriptionKey,
    ]

    /// Les attributs du système de fichiers : rapide, appelé pendant la construction de la liste.
    static func basic(_ url: URL) -> FileInfo {
        var info = FileInfo(url: url)
        guard let values = try? url.resourceValues(forKeys: keys) else { return info }
        info.isDirectory = values.isDirectory == true && values.isPackage != true
        info.size = (values.fileSize ?? values.totalFileAllocatedSize).map(Int64.init)
        info.created = values.creationDate
        info.modified = values.contentModificationDate
        info.contentType = values.contentType
        info.typeDescription = values.localizedTypeDescription ?? values.contentType?.localizedDescription
        return info
    }

    /// Tout le détail : dernière ouverture (Spotlight), contenu d'un dossier, dimensions, début du texte.
    static func full(_ url: URL) -> FileInfo {
        var info = basic(url)
        if let item = MDItemCreateWithURL(nil, url as CFURL),
           let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date {
            info.lastUsed = date
        }
        if info.isDirectory {
            info.itemCount = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.filter { !$0.hasPrefix(".") }.count
        } else if let type = info.contentType {
            if type.conforms(to: .image), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
                info.pixelSize = CGSize(width: width, height: height)
            }
            if isText(type), (info.size ?? 0) < 5_000_000 {
                info.textPreview = textPreview(url)
            }
        }
        return info
    }

    static func isText(_ type: UTType) -> Bool {
        type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) || type.conforms(to: .xml)
            || type.conforms(to: .propertyList) || type.conforms(to: .shellScript) || type.identifier == "net.daringfireball.markdown"
    }

    /// Les premières lignes d'un fichier texte.
    static func textPreview(_ url: URL, bytes: Int = 6_000) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes), !data.isEmpty, !data.contains(0) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(60)
        return lines.joined(separator: "\n")
    }

    /// Le texte complet, pour l'envoyer à l'IA (limité à 200 Ko).
    static func fullText(_ url: URL) -> String? {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType, isText(type) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 200_000), !data.contains(0) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Aperçus des fichiers (vignette, texte, métadonnées), calculés en arrière-plan et gardés en mémoire.
@MainActor
final class FilePreviewCache {
    static let shared = FilePreviewCache()

    private struct Entry {
        let modified: Date?
        let info: FileInfo
        let image: NSImage?
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var inFlight = Set<String>()

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    /// Le détail d'un fichier : complet s'il est en cache, sinon les attributs de base et l'icône.
    func detail(for url: URL) -> ItemDetail {
        let basic = FileInfo.basic(url)
        if let entry = entries[url.path], entry.modified == basic.modified {
            return Self.detail(entry.info, image: entry.image)
        }
        return Self.detail(basic, image: nil)
    }

    /// Prépare les aperçus des premiers fichiers, puis appelle `then` (rechargement de l'écran).
    func prefetch(_ urls: [URL], limit: Int = 40, then: @escaping @MainActor () -> Void) {
        let missing = urls.prefix(limit).filter { url in
            guard !inFlight.contains(url.path) else { return false }
            guard let entry = entries[url.path] else { return true }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return entry.modified != modified
        }
        guard !missing.isEmpty else { return }
        missing.forEach { inFlight.insert($0.path) }
        Task.detached(priority: .userInitiated) {
            var done = 0
            for url in missing {
                let info = FileInfo.full(url)
                let image = await Self.preview(for: info)
                done += 1
                let notify = done == 1 || done == missing.count || done % 8 == 0
                await MainActor.run {
                    FilePreviewCache.shared.store(info, image: image)
                    if notify { then() }
                }
            }
        }
    }

    private func store(_ info: FileInfo, image: NSImage?) {
        let path = info.url.path
        inFlight.remove(path)
        if entries[path] == nil { order.append(path) }
        entries[path] = Entry(modified: info.modified, info: info, image: image)
        if order.count > 400 {
            let removed = order.removeFirst()
            entries[removed] = nil
        }
    }

    /// Vignette des images, PDF et vidéos (Quick Look), rien pour le reste.
    nonisolated static func preview(for info: FileInfo) async -> NSImage? {
        guard !info.isDirectory, let type = info.contentType, info.textPreview == nil else { return nil }
        if type.conforms(to: .image) {
            return ImageThumbnail.make(info.url, maxPixels: 900)
        }
        guard type.conforms(to: .pdf) || type.conforms(to: .movie) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) || type.identifier.contains("word") || type.conforms(to: .rtf) else { return nil }
        return await ImageThumbnail.quickLook(info.url, size: CGSize(width: 440, height: 300))
    }

    static func detail(_ info: FileInfo, image: NSImage?) -> ItemDetail {
        var metadata: [(label: String, value: String)] = []
        metadata.append(("Type", info.isDirectory ? "Dossier" : (info.typeDescription ?? "Document")))
        if info.isDirectory {
            if let count = info.itemCount { metadata.append(("Contenu", count == 0 ? "Vide" : "\(count) élément\(count > 1 ? "s" : "")")) }
        } else if let size = info.size {
            metadata.append(("Taille", ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
        }
        if let pixels = info.pixelSize {
            metadata.append(("Dimensions", "\(Int(pixels.width)) × \(Int(pixels.height))"))
        }
        if let created = info.created { metadata.append(("Création", dateFormatter.string(from: created))) }
        if let modified = info.modified { metadata.append(("Modification", dateFormatter.string(from: modified))) }
        if let lastUsed = info.lastUsed { metadata.append(("Dernière ouverture", dateFormatter.string(from: lastUsed))) }
        metadata.append(("Emplacement", FileOps.abbreviated(info.url.deletingLastPathComponent().path)))
        let picture = image ?? (info.textPreview == nil ? Self.iconBanner(info.url.path) : nil)
        return ItemDetail(text: info.textPreview ?? "", metadata: metadata, image: picture)
    }

    /// L'icône du Finder au centre d'une bande large, pour qu'elle reste à taille raisonnable dans le détail.
    private static func iconBanner(_ path: String) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        return NSImage(size: NSSize(width: 420, height: 150), flipped: false) { rect in
            let side: CGFloat = 128
            icon.draw(in: NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
            return true
        }
    }
}

/// Vignettes d'images (ImageIO) et des autres documents (Quick Look).
enum ImageThumbnail {
    static func make(_ url: URL, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    static func quickLook(_ url: URL, size: CGSize) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2, representationTypes: .thumbnail)
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
    }
}
