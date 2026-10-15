import Foundation
import Security
import SwiftUI
import UIKit

/// Les données de Prism sur l'iPhone : le fichier de synchronisation choisi dans iCloud Drive (ou un fichier local),
/// lu et réécrit à chaque modification. Les fichiers JSON sont modifiés en place : les champs inconnus restent intacts.
@MainActor
final class SyncStore: ObservableObject {
    @Published private(set) var archive: PrismArchive?
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published var needsPassphrase = false
    @Published private(set) var sourceName = ""
    @Published private(set) var lastLoaded: Date?

    private let bookmarkKey = "sync.bookmark"
    /// La phrase de passe de la session : le trousseau la garde pour les lancements suivants (s'il est accessible).
    private var passphrase: String? = Keychain.passphrase
    private var device: String { UIDevice.current.name }

    /// Le fichier local, dans les Documents de l'app (visible dans Fichiers) : sans iCloud, ou pour essayer.
    static var localFile: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Prism.prismconfig")
    }

    var hasSource: Bool { resolvedURL() != nil }

    // MARK: - Source

    /// Retient le fichier choisi dans Fichiers (iCloud Drive/Prism/Prism.prismconfig).
    func choose(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        if let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        }
        load()
    }

    func useLocalFile() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        if !FileManager.default.fileExists(atPath: Self.localFile.path) {
            archive = PrismArchive.empty(device: device)
            save()
        }
        load()
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        archive = nil
        sourceName = ""
    }

    private func resolvedURL() -> URL? {
        if let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                if stale, let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: bookmarkKey) }
                return url
            }
        }
        return FileManager.default.fileExists(atPath: Self.localFile.path) ? Self.localFile : nil
    }

    // MARK: - Lecture et écriture

    func load() {
        guard let url = resolvedURL() else {
            status = "Aucun fichier choisi"
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        var coordinationError: NSError?
        var data: Data?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            data = try? Data(contentsOf: readURL)
        }
        sourceName = url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
        guard let data else {
            error = coordinationError?.localizedDescription ?? "Fichier illisible (pas encore téléchargé d’iCloud ?)"
            return
        }
        do {
            archive = try PrismArchive.decode(data, passphrase: passphrase)
            needsPassphrase = false
            error = nil
            lastLoaded = Date()
            status = "Synchronisé avec « \(archive?.device ?? "") »"
        } catch PrismArchive.Failure.passphraseRequired {
            needsPassphrase = true
        } catch PrismArchive.Failure.wrongPassphrase {
            needsPassphrase = true
            error = PrismArchive.Failure.wrongPassphrase.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    func unlock(with passphrase: String) {
        self.passphrase = passphrase
        Keychain.passphrase = passphrase
        load()
    }

    func save() {
        guard var archive, let url = resolvedURL() ?? (UserDefaults.standard.data(forKey: bookmarkKey) == nil ? Self.localFile : nil) else { return }
        archive.device = device
        archive.created = Date()
        self.archive = archive
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            // Chiffré si le fichier l'était (ou si une phrase de passe est connue pour lui).
            let wasEncrypted = (try? Data(contentsOf: url)).map(PrismArchive.isEncrypted) ?? false
            let data = try archive.encoded(passphrase: wasEncrypted ? passphrase : nil)
            var coordinationError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
                do { try data.write(to: writeURL, options: .atomic) } catch { writeError = error }
            }
            if let failure = writeError ?? coordinationError { throw failure }
            error = nil
            status = "Enregistré"
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Données typées (dictionnaires du JSON, champs inconnus préservés)

    private func update(_ path: String, _ change: (inout Any) -> Void, defaultValue: Any) {
        if archive == nil { archive = PrismArchive.empty(device: device) }
        var value = archive?.json(path) ?? defaultValue
        change(&value)
        archive?.setJSON(value, for: path)
        objectWillChange.send()
        save()
    }

    // Notes : { "notes": [ { id, text, created, modified, … } ], "currentID" }

    var notes: [[String: Any]] {
        let root = archive?.json("notes.json") as? [String: Any]
        let all = root?["notes"] as? [[String: Any]] ?? []
        return all.filter { $0["deleted"] == nil }
            .sorted { (PrismDate.date($0["modified"]) ?? .distantPast) > (PrismDate.date($1["modified"]) ?? .distantPast) }
    }

    func saveNote(id: String?, text: String) {
        update("notes.json", { value in
            var root = value as? [String: Any] ?? [:]
            var all = root["notes"] as? [[String: Any]] ?? []
            let now = PrismDate.string()
            if let id, let index = all.firstIndex(where: { $0["id"] as? String == id }) {
                all[index]["text"] = text
                all[index]["modified"] = now
            } else {
                all.append(["id": UUID().uuidString, "text": text, "created": now, "modified": now])
            }
            root["notes"] = all
            value = root
        }, defaultValue: ["notes": []])
    }

    /// Comme sur le Mac : la note part dans « Récemment supprimées » (date `deleted`).
    func deleteNote(id: String) {
        update("notes.json", { value in
            var root = value as? [String: Any] ?? [:]
            var all = root["notes"] as? [[String: Any]] ?? []
            if let index = all.firstIndex(where: { $0["id"] as? String == id }) { all[index]["deleted"] = PrismDate.string() }
            root["notes"] = all
            value = root
        }, defaultValue: ["notes": []])
    }

    // Snippets : [ { id, name, text, keyword, tags, isPinned, createdAt, updatedAt } ]

    var snippets: [[String: Any]] {
        (archive?.json("snippets.json") as? [[String: Any]] ?? []).sorted { first, second in
            let pinned = (first["isPinned"] as? Bool ?? false, second["isPinned"] as? Bool ?? false)
            if pinned.0 != pinned.1 { return pinned.0 }
            return (first["name"] as? String ?? "").localizedCaseInsensitiveCompare(second["name"] as? String ?? "") == .orderedAscending
        }
    }

    func saveSnippet(id: String?, name: String, text: String, keyword: String) {
        update("snippets.json", { value in
            var all = value as? [[String: Any]] ?? []
            let now = PrismDate.string()
            if let id, let index = all.firstIndex(where: { $0["id"] as? String == id }) {
                all[index]["name"] = name
                all[index]["text"] = text
                all[index]["keyword"] = keyword.isEmpty ? nil : keyword
                all[index]["updatedAt"] = now
            } else {
                var snippet: [String: Any] = ["id": UUID().uuidString, "name": name, "text": text, "tags": [], "isPinned": false, "createdAt": now, "updatedAt": now]
                if !keyword.isEmpty { snippet["keyword"] = keyword }
                all.append(snippet)
            }
            value = all
        }, defaultValue: [])
    }

    // Liens rapides : [ { id, name, link, tags, isPinned, createdAt, updatedAt } ]

    var quicklinks: [[String: Any]] {
        (archive?.json("quicklinks.json") as? [[String: Any]] ?? []).sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    }

    func saveQuicklink(id: String?, name: String, link: String) {
        update("quicklinks.json", { value in
            var all = value as? [[String: Any]] ?? []
            let now = PrismDate.string()
            if let id, let index = all.firstIndex(where: { $0["id"] as? String == id }) {
                all[index]["name"] = name
                all[index]["link"] = link
                all[index]["updatedAt"] = now
            } else {
                all.append(["id": UUID().uuidString, "name": name, "link": link, "tags": [], "isPinned": false, "createdAt": now, "updatedAt": now])
            }
            value = all
        }, defaultValue: [])
    }

    // Conversations d'IA : [ { id, title, messages: [ { id, role, content, date, attachments } ], created, updated, pinned, origin } ]

    var conversations: [[String: Any]] {
        (archive?.json("ai-conversations.json") as? [[String: Any]] ?? [])
            .filter { $0["deletedAt"] == nil && ($0["archived"] as? Bool) != true }
            .sorted { (PrismDate.date($0["updated"]) ?? .distantPast) > (PrismDate.date($1["updated"]) ?? .distantPast) }
    }

    /// Ajoute des messages à une conversation (créée si besoin) ; rend son identifiant. Les messages déjà là
    /// (venus du Mac, avec leur modèle et leurs pièces jointes) ne sont pas réécrits.
    @discardableResult
    func appendToConversation(id: String?, title: String, messages: [(role: String, content: String)]) -> String {
        let conversationID = id ?? UUID().uuidString
        update("ai-conversations.json", { value in
            var all = value as? [[String: Any]] ?? []
            let now = PrismDate.string()
            let encoded: [[String: Any]] = messages.map { ["id": UUID().uuidString, "role": $0.role, "content": $0.content, "date": now, "attachments": []] }
            if let index = all.firstIndex(where: { $0["id"] as? String == conversationID }) {
                all[index]["messages"] = (all[index]["messages"] as? [[String: Any]] ?? []) + encoded
                all[index]["updated"] = now
            } else {
                all.append(["id": conversationID, "title": title, "isTitleManual": false, "messages": encoded, "created": now, "updated": now,
                            "pinned": false, "origin": "chat"])
            }
            value = all
        }, defaultValue: [])
        return conversationID
    }

    func deleteConversation(id: String) {
        update("ai-conversations.json", { value in
            var all = value as? [[String: Any]] ?? []
            all.removeAll { $0["id"] as? String == id }
            value = all
        }, defaultValue: [])
    }
}

/// La phrase de passe du fichier et les clés d'API, dans le trousseau de l'iPhone.
enum Keychain {
    private static let service = "app.prism.mobile"

    static var passphrase: String? {
        get { read("sync.passphrase") }
        set { write(newValue, "sync.passphrase") }
    }

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String?, _ account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
