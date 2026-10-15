import AppKit
import CoreServices

/// Les extensions locales, comme « Import Extension » et `ray develop` dans Raycast :
/// - un dossier construit (package.json et un .js par commande) s'installe tel quel ;
/// - un dossier source (src/, node_modules) est construit par sa propre CLI `ray build -e dist` ;
/// - en mode développement, chaque modification des sources reconstruit l'extension et recharge la commande ouverte.
@MainActor
final class ExtensionDevelopment {
    static let shared = ExtensionDevelopment()

    private var streams: [String: FSEventStreamRef] = [:]
    private var pending: [String: DispatchWorkItem] = [:]
    private var building: Set<String> = []

    struct BuildError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Au lancement : surveille les extensions en développement.
    func restore() {
        for installed in ExtensionRegistry.shared.extensions where installed.origin.isDevelopment == true {
            if let source = installed.origin.sourcePath { watch(source) }
        }
    }

    static func isBuilt(_ folder: URL) -> Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("package.json")),
              let manifest = ExtensionManifest(data: data), !manifest.commands.isEmpty else { return false }
        return manifest.commands.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.name + ".js").path) }
    }

    /// Importe un dossier : construit ou source. `develop` : surveiller et reconstruire.
    func importFolder(_ folder: URL, develop: Bool) async throws -> InstalledExtension {
        let built: URL
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("prism-import-" + UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: work) }
        if Self.isBuilt(folder) {
            try manager.copyItem(at: folder, to: work)
            built = work
        } else {
            try await Self.build(source: folder, into: work)
            built = work
        }
        guard let data = try? Data(contentsOf: built.appendingPathComponent("package.json")), let manifest = ExtensionManifest(data: data) else {
            throw BuildError("package.json illisible")
        }
        let isSource = !Self.isBuilt(folder)
        let origin = InstalledExtension.Origin(owner: manifest.author.isEmpty ? "local" : manifest.author, name: manifest.name,
                                               sourcePath: folder.path, isDevelopment: develop && isSource)
        let installed = try ExtensionRegistry.shared.install(from: built, origin: origin)
        if develop && isSource { watch(folder.path) }
        return installed
    }

    /// `ray build -e dist -o <sortie>`, avec la CLI installée dans les node_modules de l'extension.
    static func build(source: URL, into output: URL) async throws {
        let ray = source.appendingPathComponent("node_modules/.bin/ray")
        guard FileManager.default.isExecutableFile(atPath: ray.path) else {
            throw BuildError("La CLI de Raycast est absente : lancez « npm install » dans \(source.path)")
        }
        guard let node = NodeRuntime.path else { throw ExtensionSession.LaunchError.noNode }
        let path = NodeRuntime.shellPATH
        let log = source.appendingPathComponent(".prism-build.log")
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = [ray.path, "build", "-e", "dist", "-o", output.path]
            process.currentDirectoryURL = source
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = (node as NSString).deletingLastPathComponent + ":" + path
            environment.removeValue(forKey: "PRISM_DEBUG")
            process.environment = environment
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try? FileHandle(forWritingTo: log)
            process.standardOutput = handle
            process.standardError = handle
            process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0, isBuilt(output) else {
            let tail = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").suffix(8).joined(separator: "\n") ?? ""
            throw BuildError("La construction a échoué :\n\(tail)")
        }
    }

    // MARK: - Surveillance des sources

    private func watch(_ path: String) {
        guard streams[path] == nil else { return }
        let watched = [URL(fileURLWithPath: path).appendingPathComponent("src").path, URL(fileURLWithPath: path).appendingPathComponent("package.json").path, URL(fileURLWithPath: path).appendingPathComponent("assets").path]
            .filter { FileManager.default.fileExists(atPath: $0) }
        var context = FSEventStreamContext()
        context.info = Unmanaged.passRetained(PathBox(path)).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let path = Unmanaged<PathBox>.fromOpaque(info).takeUnretainedValue().path
            DispatchQueue.main.async { MainActor.assumeIsolated { ExtensionDevelopment.shared.changed(path) } }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, watched as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        streams[path] = stream
    }

    func stopWatching(_ path: String) {
        guard let stream = streams.removeValue(forKey: path) else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func changed(_ path: String) {
        pending[path]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rebuild(path) }
        }
        pending[path] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Reconstruit une extension en développement et recharge sa commande si elle est à l'écran.
    func rebuild(_ path: String) {
        guard !building.contains(path) else { return }
        building.insert(path)
        Task { @MainActor in
            defer { self.building.remove(path) }
            do {
                let installed = try await importFolder(URL(fileURLWithPath: path), develop: true)
                HUD.shared.show("« \(installed.title) » reconstruite", symbol: "hammer.fill")
                if let launcher = AppContext.launcher, let screen = launcher.model.screen as? ExtensionScreen, screen.installed.id == installed.id,
                   let command = installed.manifest.commands.first(where: { $0.name == screen.session.command.name }) {
                    launcher.model.apply(ExtensionsFeature.launch(installed, command: command).replacingPush())
                }
            } catch {
                HUD.shared.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
            }
        }
    }
}

private final class PathBox {
    let path: String
    init(_ path: String) { self.path = path }
}

extension ActionOutcome {
    /// Le même écran, mais à la place de l'écran courant (rechargement).
    func replacingPush() -> ActionOutcome {
        if case .push(let screen, let query) = self { return .replace(screen, query: query) }
        return self
    }
}
