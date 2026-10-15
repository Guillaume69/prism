import AppKit
import SwiftUI

/// « Run », l'équivalent macOS de la commande Run de Raycast pour Windows : exécuter une commande du terminal
/// depuis le lanceur (`> commande` dans la recherche principale), avec un historique et des commandes enregistrées.
struct RunCommand: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var command: String
    /// Ouvrir dans le Terminal plutôt que d'afficher la sortie dans le lanceur.
    var inTerminal = false
}

@MainActor
enum RunStore {
    struct Content: Codable {
        var history: [String] = []
        var saved: [RunCommand] = []
    }

    static let store = JSONStore("run.json", default: Content())

    static func remember(_ command: String) {
        var history = store.value.history
        history.removeAll { $0 == command }
        history.insert(command, at: 0)
        store.value.history = Array(history.prefix(50))
    }
}

/// Le résultat d'une commande : sortie, code de retour, durée.
struct RunResult: Equatable {
    var output: String
    var status: Int32
    var duration: TimeInterval
}

enum RunExecutor {
    /// Exécute dans le shell de connexion de l'utilisateur (alias et PATH de son profil), depuis le dossier personnel.
    static func run(_ command: String, timeout: TimeInterval = 60) async -> RunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let started = Date()
                let process = Process()
                let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-l", "-c", command]
                process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                var data = Data()
                let lock = NSLock()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    lock.lock()
                    if data.count < 2_000_000 { data.append(chunk) }
                    lock.unlock()
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: RunResult(output: "Lancement impossible : \(error.localizedDescription)", status: -1, duration: 0))
                    return
                }
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning, Date() < deadline { usleep(50_000) }
                var timedOut = false
                if process.isRunning {
                    process.terminate()
                    timedOut = true
                }
                process.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                lock.lock()
                data.append(pipe.fileHandleForReading.readDataToEndOfFile())
                let output = String(decoding: data, as: UTF8.self)
                lock.unlock()
                let cleaned = stripANSI(output) + (timedOut ? "\n[Arrêtée au bout de \(Int(timeout)) s]" : "")
                continuation.resume(returning: RunResult(output: cleaned, status: process.terminationStatus, duration: Date().timeIntervalSince(started)))
            }
        }
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }

    /// Ouvre la commande dans le Terminal (AppleScript).
    static func openInTerminal(_ command: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        AppleScript.run("tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell")
    }
}

/// L'écran du résultat : la sortie en police à chasse fixe, le code de retour, la durée.
@MainActor
final class RunResultScreen: LauncherScreen {
    let command: String
    private(set) var result: RunResult?

    init(command: String) {
        self.command = command
        super.init(id: "run.result", title: command, icon: .symbol("terminal.fill", Palette.gray))
        layout = .custom
        hidesSearchField = true
    }

    override func didAppear() {
        guard result == nil else { return }
        isLoading = true
        RunStore.remember(command)
        Task {
            let result = await RunExecutor.run(command)
            self.result = result
            isLoading = false
            host?.screenStateChanged()
        }
    }

    override var footerTitle: String? {
        guard let result else { return "Exécution…" }
        return "\(result.status == 0 ? "Terminée" : "Code \(result.status)") en \(String(format: "%.1f", result.duration)) s"
    }

    // La vue reçoit le résultat par valeur : SwiftUI la redessine quand il arrive.
    override func customView() -> AnyView { AnyView(RunOutputView(command: command, result: result)) }

    override var screenActions: [ItemAction] {
        let output = result?.output ?? ""
        return [
            ItemAction(title: "Copier la sortie", symbol: "doc.on.doc", shortcut: KeyShortcut(keyCode: 36, modifiers: [.command], label: "↵")) {
                Pasteboard.copy(output)
                return .hud("Sortie copiée")
            },
            ItemAction(title: "Coller la sortie", symbol: "doc.on.clipboard") { Paster.paste(output) },
            ItemAction(title: "Relancer", symbol: "arrow.clockwise", shortcut: .refresh) { [command] in .replace(RunResultScreen(command: command)) },
            ItemAction(title: "Ouvrir dans le Terminal", symbol: "terminal", shortcut: .openTerminal) { [command] in
                RunExecutor.openInTerminal(command)
                return .close
            },
            ItemAction(title: "Enregistrer la commande", symbol: "square.and.arrow.down", shortcut: .create) { [command] in
                .push(RunFeature.form(RunCommand(name: "", command: command)))
            },
        ]
    }

    override func handleKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        if (event.keyCode == 36 || event.keyCode == 76), modifiers.isEmpty || modifiers == .command, let first = screenActions.first {
            host?.apply(first.run())
            return true
        }
        return false
    }

    override var customViewHandlesNavigation: Bool { true }
}

private struct RunOutputView: View {
    let command: String
    let result: RunResult?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("$ " + command)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let result {
                    Text(result.output.isEmpty ? "(aucune sortie)" : result.output)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(result.status == 0 ? Color.primary : Palette.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
    }
}

@MainActor
enum RunFeature: PrismFeature {
    /// « > commande » dans la recherche principale.
    static func topSections(query: String) -> [ResultSection] {
        guard query.hasPrefix(">") else { return [] }
        let command = query.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return [] }
        return [ResultSection(id: "run", title: "Terminal", items: [item(command: command, title: "Exécuter « \(command) »")])]
    }

    static func item(command: String, title: String, id: String? = nil) -> ResultItem {
        ResultItem(
            id: id ?? "run:" + command,
            title: title,
            subtitle: id == nil ? "Dans votre shell" : command,
            icon: .symbol("terminal.fill", Palette.gray),
            accessory: "Run",
            usageKey: "",
            actions: [
                ItemAction(title: "Exécuter et afficher la sortie", symbol: "play.fill") { .push(RunResultScreen(command: command)) },
                ItemAction(title: "Ouvrir dans le Terminal", symbol: "terminal", shortcut: .openTerminal) {
                    RunStore.remember(command)
                    RunExecutor.openInTerminal(command)
                    return .close
                },
                ItemAction(title: "Copier la commande", symbol: "doc.on.doc", shortcut: .copyText) {
                    Pasteboard.copy(command)
                    return .hud("Commande copiée")
                },
            ]
        )
    }

    /// L'écran « Exécuter une commande » : la saisie s'exécute, l'historique et les commandes enregistrées se relancent.
    static func screen() -> LauncherScreen {
        ListScreen(id: "run", title: "Exécuter une commande", placeholder: "Commande du terminal…", icon: .symbol("terminal.fill", Palette.gray)) { query in
            var sections: [ResultSection] = []
            let typed = query.trimmingCharacters(in: .whitespaces)
            if !typed.isEmpty {
                sections.append(ResultSection(id: "typed", title: nil, items: [item(command: typed, title: "Exécuter « \(typed) »")]))
            }
            let normalized = typed.normalizedForSearch
            let saved = RunStore.store.value.saved.filter { normalized.isEmpty || $0.name.normalizedForSearch.contains(normalized) || $0.command.normalizedForSearch.contains(normalized) }
            if !saved.isEmpty {
                sections.append(ResultSection(id: "saved", title: "Commandes enregistrées", items: saved.map { saved in
                    var row = item(command: saved.command, title: saved.name, id: "run.saved:" + saved.id.uuidString)
                    row.actions += [
                        ItemAction(title: "Modifier", symbol: "pencil", shortcut: .edit) { .push(form(saved)) },
                        ItemAction(title: "Supprimer", symbol: "trash", shortcut: .removeEntry, isDestructive: true) {
                            RunStore.store.value.saved.removeAll { $0.id == saved.id }
                            return .refresh
                        },
                    ]
                    return row
                }))
            }
            let history = RunStore.store.value.history.filter { normalized.isEmpty || $0.normalizedForSearch.contains(normalized) }.prefix(15)
            if !history.isEmpty {
                sections.append(ResultSection(id: "history", title: "Récentes", items: history.map { command in
                    var row = item(command: command, title: command, id: "run.history:" + command)
                    row.actions.append(ItemAction(title: "Retirer de l’historique", symbol: "trash", shortcut: .removeEntry, isDestructive: true) {
                        RunStore.store.value.history.removeAll { $0 == command }
                        return .refresh
                    })
                    return row
                }))
            }
            return sections
        }
    }

    static func form(_ existing: RunCommand) -> FormScreen {
        FormScreen(
            id: "run.form", title: existing.name.isEmpty ? "Enregistrer une commande" : "Modifier la commande", icon: .symbol("terminal.fill", Palette.gray),
            fields: [
                FormField(id: "name", label: "Nom", kind: .text, placeholder: "Par exemple : Vider le cache DNS", value: existing.name),
                FormField(id: "command", label: "Commande", kind: .textArea(lines: 3), placeholder: "sudo dscacheutil -flushcache", value: existing.command,
                          info: "Exécutée dans votre shell de connexion, depuis le dossier personnel. Chaque commande enregistrée devient une commande de la recherche principale (alias, raccourci)."),
                FormField(id: "terminal", label: "", kind: .checkbox(label: "Ouvrir dans le Terminal (commandes interactives, sudo)"), value: existing.inTerminal ? "true" : "false"),
            ]
        ) { state in
            let name = state.trimmed("name")
            let command = state.trimmed("command")
            guard !name.isEmpty, !command.isEmpty else {
                state.error = "Donnez un nom et une commande."
                return .stay
            }
            var updated = existing
            updated.name = name
            updated.command = command
            updated.inTerminal = state.bool("terminal")
            if let index = RunStore.store.value.saved.firstIndex(where: { $0.id == updated.id }) {
                RunStore.store.value.saved[index] = updated
            } else {
                RunStore.store.value.saved.append(updated)
            }
            return .then(.pop, .toast("Commande « \(name) » enregistrée"))
        }
    }

    static var commands: [ResultItem] {
        [
            Command.screen("run", "Exécuter une commande", subtitle: "Terminal", symbol: "terminal.fill", color: Palette.gray,
                           keywords: ["run", "shell", "terminal", "commande", "exécuter", "bash", "zsh"], screen: screen),
            Command.screen("run.create", "Enregistrer une commande du terminal", subtitle: "Terminal", symbol: "terminal", color: Palette.gray,
                           keywords: ["create run command", "alias", "shell"]) { form(RunCommand(name: "", command: "")) },
        ] + RunStore.store.value.saved.map { saved in
            Command.run("run.saved." + saved.id.uuidString, saved.name, subtitle: saved.command, symbol: "terminal.fill", color: Palette.gray, keywords: ["run", "terminal"]) {
                if saved.inTerminal {
                    RunExecutor.openInTerminal(saved.command)
                    return .close
                }
                return .push(RunResultScreen(command: saved.command))
            }
        }
    }

    static func selfTest(_ check: (Bool, String) -> Void) {
        check(RunExecutor.stripANSI("\u{1B}[31mrouge\u{1B}[0m") == "rouge", "Run : codes de couleur retirés")
        check(topSections(query: "> echo bonjour").first?.items.first?.title == "Exécuter « echo bonjour »", "Run : « > commande » dans la recherche")
        check(topSections(query: "echo").isEmpty, "Run : sans « > », rien")
    }
}
