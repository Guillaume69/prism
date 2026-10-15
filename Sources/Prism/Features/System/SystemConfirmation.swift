import AppKit
import SwiftUI

/// Une confirmation dans le lanceur, à la place d'une alerte : ↵ confirme, Échap revient.
/// Sous les deux choix, la liste de ce qui sera touché (applications à quitter, fichiers…).
@MainActor
enum SystemConfirmation {
    static func screen(
        id: String,
        title: String,
        icon: ItemIcon,
        confirmTitle: String,
        confirmSymbol: String,
        message: String,
        detailsTitle: String? = nil,
        details: [ResultItem] = [],
        perform: @escaping @MainActor () -> ActionOutcome
    ) -> ListScreen {
        let confirm = ResultItem(
            id: "confirm.\(id).ok",
            title: confirmTitle,
            subtitle: message,
            icon: .symbol(confirmSymbol, Palette.red),
            accessory: "↵",
            usageKey: "",
            actions: [ItemAction(title: confirmTitle, symbol: confirmSymbol, isDestructive: true, run: perform)]
        )
        let cancel = ResultItem(
            id: "confirm.\(id).cancel",
            title: "Annuler",
            icon: .symbol("xmark", Palette.gray),
            accessory: "Échap",
            usageKey: "",
            actions: [ItemAction(title: "Annuler", symbol: "xmark") { .pop }]
        )
        return ListScreen(id: "confirm." + id, title: title, placeholder: title, icon: icon) { _ in
            var sections = [ResultSection(id: "choice", title: nil, items: [confirm, cancel])]
            if !details.isEmpty {
                sections.append(ResultSection(id: "details", title: detailsTitle, items: details))
            }
            return sections
        }
    }
}

/// Les réglages des commandes système, gardés dans les préférences (préfixe « system. »).
@MainActor
enum SystemPreferences {
    private static let defaults = UserDefaults.standard

    static var confirmEmptyTrash: Bool {
        get { defaults.object(forKey: "system.confirmEmptyTrash") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "system.confirmEmptyTrash") }
    }

    static var confirmQuitAll: Bool {
        get { defaults.object(forKey: "system.confirmQuitAll") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "system.confirmQuitAll") }
    }

    /// Identifiants de paquet que « Quitter toutes les applications » épargne.
    static var quitAllExcluded: [String] {
        get { defaults.stringArray(forKey: "system.quitAllExcluded") ?? [] }
        set { defaults.set(newValue, forKey: "system.quitAllExcluded") }
    }

    /// Le volume du micro avant de le couper, pour le rétablir.
    static var savedMicrophoneVolume: Double {
        get { defaults.object(forKey: "system.micVolume") as? Double ?? 0.75 }
        set { defaults.set(newValue, forKey: "system.micVolume") }
    }
}

/// L'onglet « Système » des réglages : confirmations et apps épargnées par « Quitter toutes les applications ».
struct SystemCommandsSettingsView: View {
    @State private var confirmEmptyTrash = SystemPreferences.confirmEmptyTrash
    @State private var confirmQuitAll = SystemPreferences.confirmQuitAll
    @State private var excluded = SystemPreferences.quitAllExcluded

    var body: some View {
        Form {
            Section {
                Toggle("Demander avant de vider la corbeille", isOn: $confirmEmptyTrash)
                    .onChange(of: confirmEmptyTrash) { _, value in SystemPreferences.confirmEmptyTrash = value }
                Toggle("Demander avant de quitter toutes les applications", isOn: $confirmQuitAll)
                    .onChange(of: confirmQuitAll) { _, value in SystemPreferences.confirmQuitAll = value }
            } header: {
                Text("Confirmations")
            } footer: {
                Text("Redémarrer, éteindre et fermer la session passent par la confirmation de macOS, qui propose de rouvrir les fenêtres.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section {
                AppBundleList(bundleIDs: $excluded, emptyText: "Aucune application épargnée")
                    .onChange(of: excluded) { _, value in SystemPreferences.quitAllExcluded = value }
            } header: {
                Text("Quitter toutes les applications")
            } footer: {
                Text("Ces applications restent ouvertes. Prism et le Finder ne sont jamais quittés.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Une liste d'applications désignées par leur identifiant de paquet, avec ajout (apps ouvertes ou
/// choix dans le Finder) et retrait. Servent aussi la fermeture automatique et les exclusions.
struct AppBundleList: View {
    @Binding var bundleIDs: [String]
    let emptyText: String
    /// Un contrôle à droite de chaque ligne (délai de fermeture automatique…).
    var trailing: ((String) -> AnyView)? = nil

    var body: some View {
        if bundleIDs.isEmpty {
            Text(emptyText).foregroundStyle(.secondary)
        }
        ForEach(bundleIDs, id: \.self) { bundleID in
            HStack(spacing: 8) {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    Image(nsImage: IconCache.icon(for: url.path)).resizable().frame(width: 20, height: 20)
                    Text(AppBundleList.name(of: url))
                } else {
                    Image(systemName: "app.dashed").frame(width: 20, height: 20)
                    Text(bundleID)
                }
                Spacer()
                if let trailing { trailing(bundleID) }
                Button {
                    bundleIDs.removeAll { $0 == bundleID }
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Retirer")
            }
        }
        HStack {
            Menu("Ajouter une application ouverte") {
                ForEach(SystemActions.regularApps().filter { app in
                    app.bundleIdentifier.map { !bundleIDs.contains($0) && !SystemActions.protectedBundleIDs.contains($0) } ?? false
                }, id: \.processIdentifier) { app in
                    Button(app.localizedName ?? app.bundleIdentifier ?? "") {
                        if let id = app.bundleIdentifier { bundleIDs.append(id) }
                    }
                }
            }
            .menuStyle(.button)
            .fixedSize()
            Button("Choisir…") { choose() }
        }
    }

    static func name(of url: URL) -> String {
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        return name
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !bundleIDs.contains(id), !SystemActions.protectedBundleIDs.contains(id) {
                bundleIDs.append(id)
            }
        }
    }
}
