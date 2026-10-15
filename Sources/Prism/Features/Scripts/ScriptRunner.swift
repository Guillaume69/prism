import Foundation

/// Une exécution de script : sortie lue au fil de l'eau, code de sortie à la fin.
/// Les rappels arrivent sur le fil principal.
final class ScriptExecution: ObservableObject, @unchecked Sendable {
    @Published private(set) var output = ""
    @Published private(set) var errorOutput = ""
    @Published private(set) var isRunning = false
    @Published private(set) var exitCode: Int32?
    @Published private(set) var launchError: String?
    private(set) var startDate = Date()
    private(set) var endDate: Date?

    let command: ScriptCommand
    let arguments: [String]
    private var process: Process?
    private var completion: ((ScriptExecution) -> Void)?

    init(command: ScriptCommand, arguments: [String]) {
        self.command = command
        self.arguments = arguments
    }

    var succeeded: Bool { launchError == nil && exitCode == 0 }

    /// La sortie lisible : stdout, puis stderr s'il y en a.
    var cleanOutput: String {
        let out = TerminalText.clean(output)
        let err = TerminalText.clean(errorOutput)
        if err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return out }
        if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return err }
        return out + (out.hasSuffix("\n") ? "" : "\n") + err
    }

    /// La ligne à montrer : la dernière de stdout ; en cas d'échec, celle de stderr d'abord.
    var lastLine: String? {
        if let launchError { return launchError }
        if !succeeded, let line = TerminalText.lastLine(errorOutput) { return line }
        return TerminalText.lastLine(output) ?? TerminalText.lastLine(errorOutput)
    }

    /// Le PATH de l'utilisateur, enrichi des dossiers de Homebrew : une app lancée par le Finder ne les a pas.
    static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let current = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var parts = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"] + current.split(separator: ":").map(String.init)
        for system in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] where !parts.contains(system) { parts.append(system) }
        var seen = Set<String>()
        environment["PATH"] = parts.filter { seen.insert($0).inserted }.joined(separator: ":")
        environment["LANG"] = environment["LANG"] ?? "fr_FR.UTF-8"
        environment["PRISM"] = "1"
        return environment
    }

    /// Lance le script. `timeout` : arrêt forcé après ce délai (scripts en ligne).
    func start(timeout: TimeInterval? = nil, completion: ((ScriptExecution) -> Void)? = nil) {
        self.completion = completion
        let firstLine = (try? String(contentsOfFile: command.path, encoding: .utf8))?
            .split(separator: "\n", maxSplits: 1).first.map(String.init)
        let invocation = ScriptCommand.invocation(path: command.path, firstLine: firstLine, arguments: arguments)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: command.workingDirectory, isDirectory: true)
        process.environment = Self.environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.output += text }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.errorOutput += text }
        }
        process.terminationHandler = { [weak self] finished in
            // Le reste des tubes, puis la fin, dans l'ordre sur le fil principal.
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let restOut = String(decoding: (try? out.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
            let restErr = String(decoding: (try? err.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                guard let self else { return }
                self.output += restOut
                self.errorOutput += restErr
                self.finish(code: status)
            }
        }
        startDate = Date()
        isRunning = true
        do {
            try process.run()
            self.process = process
        } catch {
            launchError = "Lancement impossible : \(error.localizedDescription)"
            finish(code: -1)
            return
        }
        if let timeout {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.isRunning else { return }
                self.errorOutput += "\nArrêté après \(Int(timeout)) secondes."
                self.stop()
            }
        }
    }

    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    private func finish(code: Int32) {
        guard isRunning else { return }
        exitCode = code
        endDate = Date()
        isRunning = false
        process = nil
        completion?(self)
        completion = nil
    }

    /// Exécution bloquante, pour les autotests.
    static func runSynchronously(_ command: ScriptCommand, arguments: [String] = [], timeout: TimeInterval = 10) -> ScriptExecution {
        let execution = ScriptExecution(command: command, arguments: arguments)
        var done = false
        execution.start(timeout: timeout) { _ in done = true }
        let limit = Date().addingTimeInterval(timeout + 2)
        while !done, Date() < limit {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return execution
    }
}
