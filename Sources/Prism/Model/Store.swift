import Foundation

/// Le dossier des données de Prism : `~/Library/Application Support/Prism`.
enum StoreLocation {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Prism", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func file(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func subdirectory(_ name: String) -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Une valeur `Codable` gardée en JSON dans Application Support, publiée pour SwiftUI.
/// Chaque modification est écrite en arrière-plan et signalée au lanceur (`prismDataDidChange`).
@MainActor
final class JSONStore<Value: Codable>: ObservableObject {
    @Published var value: Value {
        didSet { scheduleSave() }
    }

    let fileName: String
    private var pending: DispatchWorkItem?

    init(_ fileName: String, default defaultValue: Value) {
        self.fileName = fileName
        let url = StoreLocation.file(fileName)
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder.prism.decode(Value.self, from: data) {
            value = decoded
        } else {
            value = defaultValue
        }
    }

    var url: URL { StoreLocation.file(fileName) }

    /// Relit le fichier (après une synchronisation ou un import).
    func reload() {
        guard let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder.prism.decode(Value.self, from: data) else { return }
        pending?.cancel()
        value = decoded
        pending?.cancel()
    }

    private func scheduleSave() {
        pending?.cancel()
        let snapshot = value
        let url = url
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder.prism.encode(snapshot) {
                try? data.write(to: url, options: [.atomic])
            }
        }
        pending = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2, execute: work)
        // Au tour suivant : une donnée modifiée pendant l'initialisation d'un magasin ne doit pas
        // faire relire ce magasin avant qu'il existe (réentrance de `static let shared`).
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .prismDataDidChange, object: nil)
        }
    }

    /// Écrit tout de suite (avant de quitter, avant un export).
    func flush() {
        pending?.cancel()
        if let data = try? JSONEncoder.prism.encode(value) {
            try? data.write(to: url, options: [.atomic])
        }
    }
}

extension JSONEncoder {
    static let prism: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let prism: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
