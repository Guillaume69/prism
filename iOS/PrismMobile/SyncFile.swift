import CommonCrypto
import CryptoKit
import Foundation

/// Le fichier de synchronisation de Prism (`Prism.prismconfig`), au même format que sur le Mac :
/// les fichiers JSON des données, chacun avec sa date de modification, en clair ou chiffrés (AES-GCM, PBKDF2-HMAC-SHA256).
struct PrismArchive: Codable {
    struct File: Codable {
        var modified: Date
        var data: Data
    }

    static let formatName = "prism-config"
    static let iterations = 200_000

    var format = PrismArchive.formatName
    var version = 1
    var created: Date
    var device: String
    var categories: [String]
    var files: [String: File]
    var preferences: Data?
    var preferencesModified: Date?

    static func empty(device: String) -> PrismArchive {
        PrismArchive(created: Date(), device: device, categories: ["notes", "snippets", "quicklinks", "ai"], files: [:])
    }

    enum Failure: LocalizedError, Equatable {
        case invalidFormat, unsupportedVersion(Int), passphraseRequired, wrongPassphrase, passphraseTooShort

        var errorDescription: String? {
            switch self {
            case .invalidFormat: "Ce fichier n’est pas un fichier de synchronisation de Prism."
            case .unsupportedVersion(let version): "Format \(version) inconnu : mettez Prism à jour."
            case .passphraseRequired: "Ce fichier est chiffré : saisissez sa phrase de passe."
            case .wrongPassphrase: "Phrase de passe incorrecte."
            case .passphraseTooShort: "La phrase de passe doit compter au moins 8 caractères."
            }
        }
    }

    private struct Probe: Codable {
        var format: String?
        var version: Int?
        var encrypted: Bool?
    }

    private struct Envelope: Codable {
        var format = PrismArchive.formatName
        var version = 1
        var encrypted = true
        var kdf = "PBKDF2-HMAC-SHA256"
        var iterations: Int
        var salt: Data
        var payload: Data
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    static func isEncrypted(_ data: Data) -> Bool {
        (try? decoder.decode(Probe.self, from: data))?.encrypted == true
    }

    static func decode(_ data: Data, passphrase: String?) throws -> PrismArchive {
        guard let probe = try? decoder.decode(Probe.self, from: data), probe.format == formatName else { throw Failure.invalidFormat }
        if let version = probe.version, version > 1 { throw Failure.unsupportedVersion(version) }
        var plain = data
        if probe.encrypted == true {
            guard let passphrase, !passphrase.isEmpty else { throw Failure.passphraseRequired }
            guard let envelope = try? decoder.decode(Envelope.self, from: data) else { throw Failure.invalidFormat }
            let key = try deriveKey(passphrase: passphrase, salt: envelope.salt, iterations: envelope.iterations)
            do {
                plain = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.payload), using: key)
            } catch {
                throw Failure.wrongPassphrase
            }
        }
        guard let archive = try? decoder.decode(PrismArchive.self, from: plain) else { throw Failure.invalidFormat }
        return archive
    }

    func encoded(passphrase: String?) throws -> Data {
        let plain = try Self.encoder.encode(self)
        guard let passphrase, !passphrase.isEmpty else { return plain }
        guard passphrase.count >= 8 else { throw Failure.passphraseTooShort }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 16, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw Failure.invalidFormat }
        let key = try Self.deriveKey(passphrase: passphrase, salt: salt, iterations: Self.iterations)
        guard let combined = try AES.GCM.seal(plain, using: key).combined else { throw Failure.invalidFormat }
        return try Self.encoder.encode(Envelope(iterations: Self.iterations, salt: salt, payload: combined))
    }

    static func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let length = passphrase.utf8.count
        let status = salt.withUnsafeBytes { saltBuffer in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), passphrase, length,
                saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                &derived, derived.count
            )
        }
        guard status == kCCSuccess else { throw Failure.invalidFormat }
        return SymmetricKey(data: derived)
    }

    // MARK: - Les fichiers JSON qu'il contient

    /// Le contenu JSON d'un fichier de données (« notes.json »…).
    func json(_ path: String) -> Any? {
        files[path].flatMap { try? JSONSerialization.jsonObject(with: $0.data) }
    }

    /// Remplace un fichier de données, daté de maintenant : le Mac le reprendra à sa prochaine synchronisation.
    mutating func setJSON(_ value: Any, for path: String, now: Date = Date()) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        files[path] = File(modified: now, data: data)
    }
}

/// Les dates des fichiers de données de Prism : ISO 8601 sans fractions de seconde.
enum PrismDate {
    static func string(_ date: Date = Date()) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
