import AppKit

let arguments = CommandLine.arguments

if arguments.count >= 3, arguments[1] == "--render-icon" {
    do {
        try IconRenderer.writeIconset(to: URL(fileURLWithPath: arguments[2]))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Icône : \(error)\n".utf8))
        exit(1)
    }
}

if arguments.count >= 3, arguments[1] == "--post-keys" {
    // Processus enfant du pont d'essai : des frappes venues d'ailleurs que Prism, pour ses interceptions.
    MainActor.assumeIsolated { SystemKeys.post(text: arguments[2]) }
    exit(0)
}

if arguments.contains("--toggle") {
    // Ouvre ou ferme l'instance qui tourne, pour les essais et les scripts.
    DistributedNotificationCenter.default().postNotificationName(AppDelegate.toggleNotification, object: nil, deliverImmediately: true)
    exit(0)
}

if arguments.count >= 3, arguments[1] == "--debug" {
    let command = arguments.dropFirst(2).joined(separator: "\u{1F}")
    DistributedNotificationCenter.default().postNotificationName(DebugBridge.notification, object: command, deliverImmediately: true)
    exit(0)
}

if arguments.contains("--snapshot-focus") {
    exit(MainActor.assumeIsolated { FocusSnapshot.run(arguments: arguments) })
}

if arguments.contains("--translate-test") {
    exit(MainActor.assumeIsolated { TranslateCommandLineTest.run(arguments: arguments) })
}

if arguments.contains("--snapshot-dictation") {
    exit(MainActor.assumeIsolated { DictationPillSnapshot.run(arguments: arguments) })
}

if arguments.contains("--snapshot-chat") || arguments.contains("--ai-test") || arguments.contains("--ai-tools-test") || arguments.contains("--custom-provider-test") || arguments.contains("--provider-test") {
    exit(MainActor.assumeIsolated { AIFeature.runCommandLine(arguments) })
}

if arguments.contains("--snapshot-notes") {
    exit(MainActor.assumeIsolated { NotesSnapshot.run(arguments: arguments) })
}

if arguments.contains("--snapshot") {
    exit(MainActor.assumeIsolated { Snapshot.run(arguments: arguments) })
}

if arguments.count >= 3, arguments[1] == "--calc" {
    // Interroge la calculatrice : `Prism --calc "10 ft in m"`.
    MainActor.assumeIsolated {
        CurrencyRates.shared.refreshIfNeeded()
        let deadline = Date().addingTimeInterval(6)
        while CurrencyRates.shared.rates.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let answer = Calculator.answer(for: arguments[2], context: Calculator.liveContext)
        print(answer.map { "\($0.expression) → \($0.result)  [\($0.leftCaption) | \($0.rightCaption)]" } ?? "aucun résultat")
    }
    exit(0)
}

if arguments.contains("--selftest") {
    exit(MainActor.assumeIsolated { SelfTest.run() })
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}
