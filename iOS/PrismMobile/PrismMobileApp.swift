import SwiftUI
import UniformTypeIdentifiers

@main
struct PrismMobileApp: App {
    @StateObject private var store = SyncStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onAppear {
                    store.load()
                    AIClient.runLaunchTestIfRequested()
                }
                .onChange(of: phase) { _, newPhase in
                    // Au retour dans l'app : ce que le Mac a synchronisé entre-temps.
                    if newPhase == .active { store.load() }
                }
                .tint(Color(red: 0.55, green: 0.40, blue: 1.0))
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: SyncStore

    var body: some View {
        TabView {
            Tab("IA", systemImage: "sparkles") { ChatListView() }
            Tab("Notes", systemImage: "note.text") { NotesView() }
            Tab("Snippets", systemImage: "text.badge.plus") { SnippetsView() }
            Tab("Liens", systemImage: "link") { QuicklinksView() }
            Tab("Réglages", systemImage: "gearshape") { SettingsView() }
        }
        .sheet(isPresented: .constant(!store.hasSource)) { WelcomeView().interactiveDismissDisabled() }
        .sheet(isPresented: $store.needsPassphrase) { PassphraseView() }
    }
}

/// Le type du fichier de synchronisation, pour le sélecteur de fichiers.
extension UTType {
    static let prismConfig = UTType(filenameExtension: "prismconfig", conformingTo: .json) ?? .json
}

struct WelcomeView: View {
    @EnvironmentObject private var store: SyncStore
    @State private var importing = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "triangle.fill")
                .font(.system(size: 54))
                .foregroundStyle(LinearGradient(colors: [.pink, .purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("Prism sur iPhone").font(.largeTitle.bold())
            Text("Vos notes, snippets, liens rapides et conversations d’IA, synchronisés avec Prism sur le Mac par iCloud Drive.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            VStack(alignment: .leading, spacing: 8) {
                Label("Sur le Mac : Réglages de Prism › Synchronisation › activer, dossier iCloud Drive/Prism", systemImage: "1.circle")
                Label("Ici : choisissez iCloud Drive › Prism › Prism.prismconfig", systemImage: "2.circle")
            }
            .font(.callout)
            .padding()
            .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.5)))
            .padding(.horizontal)
            Spacer()
            Button {
                importing = true
            } label: {
                Label("Choisir le fichier dans iCloud Drive", systemImage: "icloud").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("Commencer sans Mac (données sur l’iPhone)") { store.useLocalFile() }
                .padding(.bottom)
        }
        .padding()
        .fileImporter(isPresented: $importing, allowedContentTypes: [.prismConfig, .json, .data]) { result in
            if case .success(let url) = result { store.choose(url) }
        }
    }
}

struct PassphraseView: View {
    @EnvironmentObject private var store: SyncStore
    @State private var passphrase = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Phrase de passe", text: $passphrase)
                        .textContentType(.password)
                        .onSubmit { store.unlock(with: passphrase) }
                } footer: {
                    Text(store.error ?? "Le fichier est chiffré par Prism sur le Mac : saisissez la même phrase de passe. Elle reste dans le trousseau de l’iPhone.")
                }
            }
            .navigationTitle("Fichier chiffré")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ouvrir") { store.unlock(with: passphrase) }.disabled(passphrase.count < 8)
                }
            }
        }
    }
}
