import SwiftUI

/// L'onglet « Fenêtres » des réglages : écart, moitiés répétées, Stage Manager, commandes et dispositions.
struct WindowSettingsView: View {
    @ObservedObject private var preferences = WindowPreferences.shared
    @ObservedObject private var store = WindowStore.shared
    @State private var accessibilityGranted = AccessibilityGate.isGranted

    var body: some View {
        Form {
            Section {
                LabeledContent("Écart entre les fenêtres") {
                    HStack(spacing: 10) {
                        Slider(value: $preferences.gap, in: 0...32, step: 1)
                            .frame(width: 220)
                        Text("\(Int(preferences.gap)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                Picker("« Moitié gauche » répétée", selection: $preferences.repeatHalf) {
                    ForEach(RepeatHalfBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
            } header: {
                Text("Rangement")
            } footer: {
                Text("L’écart s’applique entre les fenêtres et avec les bords de l’écran. Relancer « Moitié gauche » ou « Moitié droite » sur une fenêtre déjà rangée ainsi peut la faire passer par 2/3 puis 1/3 de l’écran, ou l’envoyer sur l’écran voisin.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Laisser la place à la bande de Stage Manager", isOn: $preferences.respectStageManager)
                LabeledContent("Largeur de la bande") {
                    HStack(spacing: 10) {
                        Slider(value: $preferences.stageManagerWidth, in: 80...320, step: 10)
                            .frame(width: 220)
                        Text("\(Int(preferences.stageManagerWidth)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                .disabled(!preferences.respectStageManager)
            } header: {
                Text("Stage Manager")
            } footer: {
                Text(WindowPreferences.stageManagerIsActive ? "Stage Manager est actif : la marge est réservée à gauche de l’écran." : "Stage Manager est inactif : aucune marge n’est réservée.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                if store.data.commands.isEmpty {
                    Text("Aucune commande. Créez-en avec « Créer une commande de fenêtre » dans Prism.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.data.commands) { command in
                    HStack(spacing: 8) {
                        ItemIconView(icon: .symbol(command.spec.anchor.symbol, WindowsFeature.color), size: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(command.name).font(.system(size: 12.5))
                            Text(command.spec.summary).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            store.deleteCommand(command.id)
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Supprimer la commande")
                    }
                }
            } header: {
                Text("Commandes personnalisées")
            }

            Section {
                if store.data.layouts.isEmpty {
                    Text("Aucune disposition. Enregistrez-en avec « Enregistrer la disposition actuelle » dans Prism.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.data.layouts) { layout in
                    LayoutSettingsRow(layout: layout)
                }
            } header: {
                Text("Dispositions")
            }

            Section {
                LabeledContent("Accessibilité") {
                    if accessibilityGranted {
                        Label("Autorisée", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.green)
                    } else {
                        Button("Autoriser…") { _ = AccessibilityGate.request() }
                    }
                }
            } header: {
                Text("Autorisations")
            } footer: {
                Text("Les bureaux passent par les raccourcis de Mission Control (⌃1 à ⌃9, ⌃← et ⌃→), à activer dans Réglages Système › Clavier › Raccourcis. Envoyer une fenêtre à un autre bureau est fait au mieux : macOS ne le permet pas officiellement.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Une disposition : renommer sur place, l'autre comportement, supprimer.
private struct LayoutSettingsRow: View {
    let layout: SavedWindowLayout
    @State private var name = ""

    var body: some View {
        HStack(spacing: 8) {
            ItemIconView(icon: .symbol("rectangle.3.group", WindowsFeature.color), size: 18)
            VStack(alignment: .leading, spacing: 1) {
                TextField("Nom", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .onSubmit(rename)
                Text(layout.summary).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { layout.otherWindows },
                set: { value in
                    var updated = layout
                    updated.otherWindows = value
                    WindowStore.shared.save(updated)
                }
            )) {
                ForEach(OtherWindowsBehavior.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Button(role: .destructive) {
                WindowStore.shared.deleteLayout(layout.id)
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Supprimer la disposition")
        }
        .onAppear { name = layout.name }
    }

    private func rename() {
        let cleaned = name.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, cleaned != layout.name else { return }
        var updated = layout
        updated.name = cleaned
        WindowStore.shared.save(updated)
    }
}
