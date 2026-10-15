import AppIntents

/// « Demander à Prism » : une question à l'IA depuis Raccourcis, Siri ou le bouton Action.
struct AskPrismIntent: AppIntent {
    static let title: LocalizedStringResource = "Demander à Prism"
    static let description = IntentDescription("Pose une question à l’IA de Prism et rend sa réponse.")

    @Parameter(title: "Question")
    var question: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        var answer = ""
        for try await chunk in AIClient.stream([AIMessage(role: "user", content: question)]) { answer += chunk }
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

struct PrismShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskPrismIntent(), phrases: ["Demander à \(.applicationName)", "Ask \(.applicationName)"],
                    shortTitle: "Demander à Prism", systemImageName: "sparkles")
    }
}
