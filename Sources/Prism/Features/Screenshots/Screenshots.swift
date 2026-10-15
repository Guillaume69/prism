import AppKit
import SwiftUI

// MARK: - Écran

/// « Rechercher des captures d’écran » : grille de vignettes, filtres `name:`, `text:`, `date:`, ⌘P par type.
@MainActor
final class ScreenshotsScreen: LauncherScreen {
    init() {
        super.init(id: "screenshots", title: "Captures d’écran", placeholder: "Rechercher… (name:, text:, date:hier)", icon: .symbol("camera.viewfinder", Palette.indigo))
        filter = ScreenFilter(options: [
            .init(id: "all", title: "Tout"),
            .init(id: "images", title: "Captures"),
            .init(id: "videos", title: "Enregistrements"),
            .init(id: "pinned", title: "Épinglées"),
        ], selected: "all")
    }

    override func didAppear() {
        let library = ScreenshotLibrary.shared
        library.onChange = { [weak self] in
            guard let self else { return }
            self.isLoading = library.isScanning
            self.reload()
        }
        isLoading = !library.hasScanned && !FeatureDemo.isHeadless
        library.activate()
        if library.hasScanned { library.scan() }
    }

    override func didDisappear() {
        ScreenshotLibrary.shared.onChange = nil
    }

    /// Hauteur des cellules : vignette carrée plus la légende, selon le nombre de colonnes.
    static func cellHeight(columns: Int) -> CGFloat {
        let width = (LauncherLayout.width - 20 - 6 * CGFloat(columns - 1)) / CGFloat(columns)
        return (width * 0.82 + 30).rounded()
    }

    override func sections(query: String) -> [ResultSection] {
        let library = ScreenshotLibrary.shared
        let settings = ScreenshotsSettings.shared
        let now = Date()
        let parsed = ScreenshotQuery.parse(query, now: now)
        let pinned = Set(settings.pinned)
        let kind = filter?.selected ?? "all"
        let files = library.files.filter { file in
            switch kind {
            case "images": guard !file.isVideo else { return false }
            case "videos": guard file.isVideo else { return false }
            case "pinned": guard pinned.contains(file.path) else { return false }
            default: break
            }
            return parsed.matches(name: file.name, text: library.text(for: file), date: file.date)
        }
        let shown = Array(files.prefix(300))
        library.requestThumbnails(Array(shown.prefix(80)))
        let columns = settings.columns
        let height = Self.cellHeight(columns: columns)
        var sections: [ResultSection] = []
        let pinnedFiles = kind == "pinned" ? [] : shown.filter { pinned.contains($0.path) }
        if !pinnedFiles.isEmpty {
            sections.append(ResultSection(id: "pinned", title: "Épinglées", items: pinnedFiles.map { item($0, pinned: true, now: now) }, columns: columns, cellHeight: height))
        }
        var buckets: [(title: String, files: [ScreenshotFile])] = []
        for file in shown where kind == "pinned" || !pinned.contains(file.path) {
            let title = Self.bucket(for: file.date, now: now)
            if buckets.last?.title == title {
                buckets[buckets.count - 1].files.append(file)
            } else {
                buckets.append((title, [file]))
            }
        }
        for bucket in buckets {
            sections.append(ResultSection(
                id: "bucket-" + bucket.title,
                title: bucket.title,
                items: bucket.files.map { item($0, pinned: pinned.contains($0.path), now: now) },
                columns: columns,
                cellHeight: height
            ))
        }
        return sections
    }

    /// Groupes de la grille : aujourd'hui, hier, cette semaine, ce mois-ci, puis par mois.
    static func bucket(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Aujourd’hui" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Hier" }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return "Cette semaine" }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) { return "Ce mois-ci" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(date, equalTo: now, toGranularity: .year) ? "MMMM" : "MMMMyyyy")
        let text = formatter.string(from: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Le titre d'une vignette : la date des captures (« Aujourd’hui, 10:32 »), le nom des autres fichiers.
    static func title(for file: ScreenshotFile, now: Date) -> String {
        guard file.isScreenshot else { return (file.name as NSString).deletingPathExtension }
        return RelativeDay.title(for: file.date, now: now) + ", " + AgendaFormat.time(file.date)
    }

    private func item(_ file: ScreenshotFile, pinned: Bool, now: Date) -> ResultItem {
        let library = ScreenshotLibrary.shared
        let icon: ItemIcon = library.thumbnail(for: file).map { .image($0) } ?? .file(file.path)
        return ResultItem(
            id: "screenshot:" + file.path,
            title: Self.title(for: file, now: now),
            subtitle: file.name,
            icon: icon,
            tags: pinned ? ["Épinglée"] : [],
            style: .thumbnail,
            usageKey: "",
            actions: ScreenshotActions.actions(file, pinned: pinned, screen: self)
        )
    }

    override func emptyState(query: String) -> (symbol: String, message: String) {
        let library = ScreenshotLibrary.shared
        if isLoading || library.isScanning { return ("hourglass", "Recherche des captures…") }
        if FeatureDemo.isHeadless && !FeatureDemo.isActive { return ("camera.viewfinder", "Rendu hors écran : les dossiers ne sont pas lus.") }
        let parsed = ScreenshotQuery.parse(query, now: Date())
        if let invalid = parsed.invalidDate {
            return ("calendar.badge.exclamationmark", "Date inconnue : « \(invalid) ».\nEssayez date:aujourd’hui, date:hier, date:semaine dernière ou date:2026-10-14.")
        }
        if library.files.isEmpty {
            return ("camera.viewfinder", "Aucune capture d’écran dans \(library.folders.map { FileOps.abbreviated($0.path) }.joined(separator: ", ")).\nAppuyez sur ⇧⌘4 pour en faire une.")
        }
        return ("magnifyingglass", "Aucune capture pour « \(query) »")
    }

    override var footerTitle: String? {
        let library = ScreenshotLibrary.shared
        let count = library.files.count
        var text = "\(count) capture\(count > 1 ? "s" : "")"
        if library.ocrRemaining > 0, ScreenshotsSettings.shared.ocrEnabled {
            text += " · lecture du texte (\(library.ocrRemaining) restantes)"
        }
        return text
    }
}

// MARK: - Actions

@MainActor
enum ScreenshotActions {
    /// Le contenu du presse-papiers : l'image et le fichier, pour que chaque application prenne ce qu'elle sait coller.
    static func pasteboardItem(_ file: ScreenshotFile) -> [NSPasteboard.PasteboardType: Data] {
        var item: [NSPasteboard.PasteboardType: Data] = [.fileURL: file.url.dataRepresentation]
        guard !file.isVideo else { return item }
        if file.url.pathExtension.lowercased() == "png", let data = try? Data(contentsOf: file.url) {
            item[.png] = data
        } else if let image = NSImage(contentsOf: file.url), let tiff = image.tiffRepresentation {
            item[.tiff] = tiff
        }
        return item
    }

    static func actions(_ file: ScreenshotFile, pinned: Bool, screen: LauncherScreen) -> [ItemAction] {
        var actions: [ItemAction] = [
            ItemAction(title: Actions.pasteTitle, symbol: "doc.on.clipboard") {
                Paster.paste(items: [pasteboardItem(file)])
            },
            ItemAction(title: file.isVideo ? "Copier le fichier" : "Copier l’image", symbol: "doc.on.doc") {
                Pasteboard.write([pasteboardItem(file)])
                return .hud(file.isVideo ? "Fichier copié" : "Image copiée")
            },
        ]
        if !file.isVideo {
            actions.append(ItemAction(title: "Copier le texte de l’image", symbol: "text.viewfinder", shortcut: .copyText) {
                if let text = ScreenshotLibrary.shared.text(for: file), !text.isEmpty {
                    Pasteboard.copy(text)
                    return .hud("Texte copié")
                }
                Task {
                    let text = await ScreenshotLibrary.shared.recognizeNow(file)
                    if let text, !text.isEmpty {
                        Pasteboard.copy(text)
                        HUD.shared.show("Texte copié")
                    } else {
                        HUD.shared.show("Aucun texte dans l’image", symbol: "text.viewfinder")
                    }
                }
                return .close
            })
        }
        actions.append(QuickLookPreview.action { [file.url] })
        actions.append(Actions.reveal(file.path))
        actions.append(ItemAction(title: "Ouvrir", symbol: "arrow.up.forward.app") {
            NSWorkspace.shared.open(file.url)
            return .close
        })
        actions.append(ItemAction(title: "Ouvrir avec…", symbol: "arrow.up.right.square", shortcut: .openWith) {
            .push(OpenWith.screen(for: file.url))
        })
        actions.append(ItemAction(title: pinned ? "Retirer l’épingle" : "Épingler", symbol: pinned ? "pin.slash" : "pin", shortcut: .pin, section: "Organiser") {
            ScreenshotLibrary.shared.togglePin(file)
            return .refresh
        })
        actions.append(ItemAction(title: "Renommer…", symbol: "pencil", shortcut: .edit, section: "Organiser") {
            .push(renameForm(file))
        })
        actions.append(ItemAction(title: "Copier le chemin", symbol: "link", shortcut: KeyShortcut(keyCode: 8, modifiers: [.command, .option, .shift], label: "C"), section: "Organiser") {
            Pasteboard.copy(file.path)
            return .hud("Chemin copié")
        })
        actions.append(ItemAction(title: "Actualiser", symbol: "arrow.clockwise", shortcut: .refresh, section: "Organiser") {
            ScreenshotLibrary.shared.scan()
            return .stay
        })
        actions.append(ItemAction(title: "Mettre à la corbeille", symbol: "trash", shortcut: .removeEntry, isDestructive: true, section: "Organiser") {
            .push(DestructiveConfirmScreen(
                title: "Mettre à la corbeille ?",
                message: "« \(file.name) » sera placé dans la corbeille\(pinned ? " (elle est épinglée)" : "").",
                confirmTitle: "Mettre à la corbeille"
            ) {
                do {
                    try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
                    ScreenshotLibrary.shared.forget(file)
                    HUD.shared.show("Capture mise à la corbeille", symbol: "trash.fill")
                    return .refresh
                } catch {
                    return .toast("Impossible : \(error.localizedDescription)")
                }
            })
        })
        return actions
    }

    static func renameForm(_ file: ScreenshotFile) -> LauncherScreen {
        let base = (file.name as NSString).deletingPathExtension
        let form = FormScreen(
            id: "screenshots.rename",
            title: "Renommer la capture",
            icon: .symbol("pencil", Palette.indigo),
            submitTitle: "Renommer",
            fields: [
                FormField(id: "name", label: "Nom", kind: .text, placeholder: base, value: base,
                          info: "L’extension « .\(file.url.pathExtension) » est conservée."),
            ]
        ) { state in
            let name = state.trimmed("name")
            guard !name.isEmpty else { state.error = "Le nom ne peut pas être vide"; return .stay }
            do {
                let renamed = try FileOps.rename(file.url, to: name, keepExtension: true)
                let settings = ScreenshotsSettings.shared
                if let index = settings.pinned.firstIndex(of: file.path) { settings.pinned[index] = renamed.path }
                ScreenshotLibrary.shared.scan()
                HUD.shared.show("Renommée en « \(renamed.lastPathComponent) »")
                return .pop
            } catch CocoaError.fileWriteFileExists {
                state.error = "Un fichier porte déjà ce nom"
                return .stay
            } catch {
                state.error = error.localizedDescription
                return .stay
            }
        }
        return form
    }
}

// MARK: - Fonctionnalité

@MainActor
enum ScreenshotsFeature: PrismFeature {
    static func start() {
        // La conservation lit les dossiers : seulement si l'utilisateur l'a activée.
        if ScreenshotsSettings.shared.retentionDays > 0 { ScreenshotLibrary.shared.schedulePurge() }
    }

    static var commands: [ResultItem] {
        [
            Command.screen("screenshots", "Rechercher des captures d’écran", subtitle: "Captures d’écran", symbol: "camera.viewfinder", color: Palette.indigo, keywords: ["search screenshots", "captures", "screenshot", "images", "enregistrements"]) { ScreenshotsScreen() },
            Command.run("screenshots.paste-latest", "Coller la dernière capture d’écran", subtitle: "Captures d’écran", symbol: "photo.on.rectangle.angled", color: Palette.indigo, keywords: ["paste latest screenshot", "derniere capture"]) {
                pasteLatest()
            },
        ]
    }

    static func pasteLatest() -> ActionOutcome {
        guard let latest = ScreenshotLibrary.shared.latestScreenshot() else {
            return .hud("Aucune capture d’écran trouvée")
        }
        return Paster.paste(items: [ScreenshotActions.pasteboardItem(latest)])
    }

    static var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "screenshots", title: "Captures d’écran", symbol: "camera.viewfinder", color: Palette.indigo, order: 47) { AnyView(ScreenshotsSettingsView()) }]
    }

    /// `prism://screenshots?q=texte`, `prism://screenshots/paste-latest`.
    static func handle(url: URL) -> Bool {
        guard url.host == "screenshots" else { return false }
        if url.path == "/paste-latest" {
            if case .hud(let message) = pasteLatest() { HUD.shared.show(message, symbol: "photo") }
            return true
        }
        guard let launcher = AppContext.launcher else { return false }
        launcher.show(reset: true)
        launcher.model.push(ScreenshotsScreen(), query: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? "")
        return true
    }

    static func selfTest(_ check: (Bool, String) -> Void) {
        check(ScreenshotLibrary.isScreenshotName("Capture d’écran 2026-10-14 à 10.32.15.png"), "captures : nom français")
        check(ScreenshotLibrary.isScreenshotName("Screenshot 2026-10-14 at 10.32.15.png") && ScreenshotLibrary.isScreenshotName("Screen Recording 2026-10-14.mov"), "captures : noms anglais")
        check(ScreenshotLibrary.isScreenshotName("Enregistrement de l'écran 2026-10-14.mov"), "captures : enregistrement de l’écran")
        check(!ScreenshotLibrary.isScreenshotName("Vacances.png"), "captures : photo ordinaire écartée")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .current
        calendar.locale = Locale(identifier: "fr_FR")
        calendar.firstWeekday = 2
        func date(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour)) ?? Date()
        }
        let now = date(10, 14, 10)
        let mixed = ScreenshotQuery.parse("name:facture date:hier reçu", now: now, calendar: calendar)
        check(mixed.names == ["facture"] && mixed.words == ["recu"], "filtres : name: et mot libre")
        check(mixed.range == DateInterval(start: date(10, 13, 0), end: date(10, 14, 0)), "filtres : date:hier")
        let week = ScreenshotQuery.parse("text:\"mot de passe\" date:semaine dernière", now: now, calendar: calendar)
        check(week.texts == ["mot de passe"], "filtres : text: entre guillemets")
        check(week.range == DateInterval(start: date(10, 5, 0), end: date(10, 12, 0)), "filtres : date:semaine dernière (lundi à dimanche)")
        check(ScreenshotQuery.parse("date:last week", now: now, calendar: calendar).range == week.range, "filtres : date:last week")
        check(ScreenshotQuery.parse("date:yesterday", now: now, calendar: calendar).range == mixed.range, "filtres : date:yesterday")
        check(ScreenshotQuery.parse("date:aujourd’hui", now: now, calendar: calendar).range?.start == date(10, 14, 0), "filtres : date:aujourd’hui avec apostrophe typographique")
        check(ScreenshotQuery.parse("date:2026-10-01", now: now, calendar: calendar).range?.start == date(10, 1, 0), "filtres : date au format ISO")
        check(ScreenshotQuery.parse("date:bientot", now: now, calendar: calendar).invalidDate == "bientot", "filtres : date inconnue signalée")
        check(mixed.matches(name: "Capture d’écran facture.png", text: "Reçu n° 42", date: date(10, 13, 9)), "filtres : correspondance nom, texte et date")
        check(!mixed.matches(name: "Capture d’écran facture.png", text: "Reçu n° 42", date: date(10, 12, 9)), "filtres : hors de la date")
        check(!week.matches(name: "Capture.png", text: nil, date: date(10, 6)), "filtres : texte requis mais inconnu")
        check(ScreenshotQuery.parse("date:ce mois-ci", now: now, calendar: calendar).range?.start == date(10, 1, 0), "filtres : date:ce mois-ci")
    }
}

// MARK: - Réglages

struct ScreenshotsSettingsView: View {
    @ObservedObject private var settings = ScreenshotsSettings.shared

    private let retentions: [(days: Int, title: String)] = [
        (0, "Jamais (toujours garder)"), (1, "1 jour"), (7, "1 semaine"), (30, "1 mois"), (90, "3 mois"), (180, "6 mois"), (365, "1 an"),
    ]

    var body: some View {
        Form {
            Section("Affichage") {
                Picker("Colonnes de la grille", selection: $settings.columns) {
                    ForEach(3...6, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Montrer toutes les images et vidéos des dossiers, pas seulement les captures", isOn: $settings.allMedia)
                    .onChange(of: settings.allMedia) { _, _ in ScreenshotLibrary.shared.foldersDidChange() }
            }

            Section {
                folderRow(ScreenshotLibrary.systemLocation.path, caption: "Emplacement des captures")
                if ScreenshotLibrary.systemLocation.standardizedFileURL != ScreenshotLibrary.desktop.standardizedFileURL {
                    folderRow(ScreenshotLibrary.desktop.path, caption: "Bureau")
                }
                ForEach(settings.extraFolders, id: \.self) { path in
                    HStack {
                        folderRow(path, caption: nil)
                        Button {
                            settings.extraFolders.removeAll { $0 == path }
                            ScreenshotLibrary.shared.foldersDidChange()
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Ne plus surveiller ce dossier")
                    }
                }
                Button("Ajouter un dossier…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = true
                    panel.prompt = "Surveiller"
                    guard panel.runModal() == .OK else { return }
                    for url in panel.urls where !settings.extraFolders.contains(url.path) {
                        settings.extraFolders.append(url.path)
                    }
                    ScreenshotLibrary.shared.foldersDidChange()
                }
            } header: {
                Text("Dossiers surveillés")
            } footer: {
                Text("L’emplacement des captures se règle dans l’app Capture d’écran (⇧⌘5 › Options).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Reconnaître le texte des captures", isOn: $settings.ocrEnabled)
                Picker("Reconnaissance", selection: $settings.ocrAccurate) {
                    Text("Rapide").tag(false)
                    Text("Précise (plus lente)").tag(true)
                }
                .disabled(!settings.ocrEnabled)
                Button("Vider le cache des vignettes et du texte") {
                    ScreenshotLibrary.shared.clearCache()
                }
            } header: {
                Text("Texte des captures")
            } footer: {
                Text("La reconnaissance se fait sur votre Mac. Le texte trouvé permet de chercher dans les captures (text:) ; il est gardé dans un cache local.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section {
                Picker("Mettre à la corbeille les captures de plus de", selection: $settings.retentionDays) {
                    ForEach(retentions, id: \.days) { Text($0.title).tag($0.days) }
                }
                .onChange(of: settings.retentionDays) { _, days in
                    if days > 0 { ScreenshotLibrary.shared.schedulePurge() }
                }
            } header: {
                Text("Conservation")
            } footer: {
                Text("Seules les captures d’écran non épinglées des dossiers surveillés vont à la corbeille, jamais les autres images. Vous pouvez les y récupérer.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func folderRow(_ path: String, caption: String?) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: IconCache.icon(for: path)).resizable().frame(width: 18, height: 18)
            Text(FileOps.abbreviated(path)).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let caption {
                Text(caption).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }
}
