import AppKit
import Contacts
import SwiftUI

/// Une fiche de contact, recopiée du carnet d'adresses pour la recherche et l'affichage.
struct ContactCard: Identifiable {
    struct Entry {
        var label: String
        var value: String
    }

    let id: String
    var givenName: String
    var familyName: String
    var nickname = ""
    var organization = ""
    var jobTitle = ""
    var phones: [Entry] = []
    var emails: [Entry] = []
    var addresses: [Entry] = []
    var birthday: DateComponents?
    var imageData: Data?

    var fullName: String {
        let name = [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
        if !name.isEmpty { return name }
        return organization.isEmpty ? (emails.first?.value ?? phones.first?.value ?? "Sans nom") : organization
    }

    var initials: String {
        let letters = [givenName, familyName].compactMap(\.first).map(String.init)
        if !letters.isEmpty { return letters.joined().uppercased() }
        return String(fullName.prefix(1)).uppercased()
    }

    /// Le numéro à appeler : le portable s'il existe.
    var primaryPhone: Entry? {
        phones.first { $0.label.normalizedForSearch.contains("mobile") || $0.label.normalizedForSearch.contains("portable") || $0.label.contains("iPhone") } ?? phones.first
    }

    var subtitle: String {
        if !jobTitle.isEmpty, !organization.isEmpty { return "\(jobTitle) · \(organization)" }
        if !organization.isEmpty, organization != fullName { return organization }
        return emails.first?.value ?? phones.first?.value ?? ""
    }

    /// Les champs comparés à la saisie.
    var searchFields: [String] {
        [fullName, nickname, organization] + emails.map(\.value)
    }

    var digits: [String] { phones.map { $0.value.filter(\.isNumber) } }
}

/// Le carnet d'adresses : autorisation, chargement en arrière-plan, recherche.
/// Aucune demande d'autorisation sans geste de l'utilisateur.
@MainActor
final class ContactsService {
    static let shared = ContactsService()

    private(set) var cards: [ContactCard] = []
    private(set) var isLoaded = false
    private var loading = false
    private var observing = false
    var onChange: [String: @MainActor () -> Void] = [:]

    nonisolated static var status: CNAuthorizationStatus { CNContactStore.authorizationStatus(for: .contacts) }

    var isAuthorized: Bool { FeatureDemo.isActive || Self.status == .authorized }

    var statusDescription: String {
        if FeatureDemo.isActive { return "Démonstration" }
        switch Self.status {
        case .authorized: return "Autorisé"
        case .denied: return "Refusé"
        case .restricted: return "Restreint par le système"
        case .notDetermined: return "Pas encore demandé"
        default: return "Accès limité"
        }
    }

    func requestAccess(completion: @escaping @MainActor (Bool) -> Void) {
        guard Self.status == .notDetermined else {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
                NSWorkspace.shared.open(url)
            }
            completion(isAuthorized)
            return
        }
        CNContactStore().requestAccess(for: .contacts) { granted, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if granted { ContactsService.shared.load() }
                    completion(granted)
                }
            }
        }
    }

    func loadIfNeeded() {
        if !isLoaded { load() }
    }

    func load() {
        if FeatureDemo.isActive {
            cards = ContactsDemo.cards
            isLoaded = true
            return
        }
        guard Self.status == .authorized, !loading else { return }
        loading = true
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ContactsService.shared.load() }
            }
        }
        Task.detached(priority: .userInitiated) {
            let cards = ContactsService.fetchAll()
            await MainActor.run {
                let service = ContactsService.shared
                service.cards = cards
                service.isLoaded = true
                service.loading = false
                service.onChange.values.forEach { $0() }
            }
        }
    }

    nonisolated private static func fetchAll() -> [ContactCard] {
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
            CNContactOrganizationNameKey, CNContactJobTitleKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
            CNContactPostalAddressesKey, CNContactBirthdayKey, CNContactThumbnailImageDataKey,
        ].map { $0 as CNKeyDescriptor } + [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault
        let formatter = CNPostalAddressFormatter()
        var cards: [ContactCard] = []
        try? CNContactStore().enumerateContacts(with: request) { contact, _ in
            func label(_ raw: String?) -> String {
                raw.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? ""
            }
            cards.append(ContactCard(
                id: contact.identifier,
                givenName: contact.givenName,
                familyName: contact.familyName,
                nickname: contact.nickname,
                organization: contact.organizationName,
                jobTitle: contact.jobTitle,
                phones: contact.phoneNumbers.map { .init(label: label($0.label).isEmpty ? "Téléphone" : label($0.label), value: $0.value.stringValue) },
                emails: contact.emailAddresses.map { .init(label: label($0.label).isEmpty ? "E-mail" : label($0.label), value: $0.value as String) },
                addresses: contact.postalAddresses.map {
                    .init(label: label($0.label).isEmpty ? "Adresse" : label($0.label),
                          value: formatter.string(from: $0.value).replacingOccurrences(of: "\n", with: ", "))
                },
                birthday: contact.birthday,
                imageData: contact.thumbnailImageData
            ))
        }
        return cards
    }

    /// Les contacts qui correspondent à la saisie (nom, surnom, entreprise, e-mail, chiffres du numéro).
    func search(_ query: String, limit: Int = 200) -> [ContactCard] {
        let normalized = query.normalizedForSearch
        guard !normalized.isEmpty else { return Array(cards.prefix(limit)) }
        let digits = query.filter(\.isNumber)
        let scored: [(ContactCard, Double)] = cards.compactMap { card in
            var best = card.searchFields.compactMap { Fuzzy.score(normalized, $0) }.max()
            if digits.count >= 3, digits.count == query.filter({ !$0.isWhitespace && $0 != "+" }).count,
               card.digits.contains(where: { $0.contains(digits) }) {
                best = max(best ?? 0, 80)
            }
            guard let best, best >= 40 else { return nil }
            return (card, best)
        }
        return scored.sorted { $0.1 == $1.1 ? $0.0.fullName < $1.0.fullName : $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}

// MARK: - Avatars

/// Photo ronde du contact, ou ses initiales sur une pastille colorée.
@MainActor
enum ContactAvatar {
    private static var cache: [String: NSImage] = [:]

    static func image(for card: ContactCard, size: CGFloat = 64) -> NSImage {
        let key = "\(card.id)-\(Int(size))"
        if let cached = cache[key] { return cached }
        let photo = card.imageData.flatMap(NSImage.init(data:))
        let colors: [NSColor] = [.systemBlue, .systemPurple, .systemPink, .systemOrange, .systemTeal, .systemGreen, .systemIndigo, .systemBrown]
        let color = colors[abs(card.fullName.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }) % colors.count]
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect)
            if let photo {
                NSGraphicsContext.saveGraphicsState()
                circle.addClip()
                let side = min(photo.size.width, photo.size.height)
                let source = NSRect(x: (photo.size.width - side) / 2, y: (photo.size.height - side) / 2, width: side, height: side)
                photo.draw(in: rect, from: source, operation: .sourceOver, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                NSGradient(colors: [color.blended(withFraction: 0.25, of: .white) ?? color, color])?.draw(in: circle, angle: -90)
                let text = card.initials as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: size * 0.4, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ]
                let textSize = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
            }
            return true
        }
        cache[key] = image
        return image
    }

    /// L'avatar au centre d'une bande large : il garde une taille raisonnable en tête du détail.
    static func banner(for card: ContactCard) -> NSImage {
        let avatar = image(for: card, size: 160)
        return NSImage(size: NSSize(width: 420, height: 110), flipped: false) { rect in
            let side: CGFloat = 96
            avatar.draw(in: NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
            return true
        }
    }
}

// MARK: - Éléments et actions

@MainActor
enum ContactItems {
    static func telURL(_ scheme: String, _ number: String) -> URL? {
        let cleaned = number.filter { $0.isNumber || $0 == "+" }
        return URL(string: scheme + cleaned)
    }

    static func item(_ card: ContactCard, idPrefix: String = "contact:", withDetail: Bool = true) -> ResultItem {
        ResultItem(
            id: idPrefix + card.id,
            title: card.fullName,
            subtitle: card.subtitle,
            icon: .image(ContactAvatar.image(for: card)),
            accessory: withDetail ? nil : "Contact",
            keywords: [card.organization, card.nickname],
            detail: withDetail ? detail(card) : nil,
            usageKey: "",
            actions: actions(card)
        )
    }

    static func detail(_ card: ContactCard) -> ItemDetail {
        var lines = ["## \(card.fullName)"]
        if !card.subtitle.isEmpty, card.subtitle != card.emails.first?.value, card.subtitle != card.phones.first?.value {
            lines.append(card.subtitle)
        }
        if !card.nickname.isEmpty { lines.append("« \(card.nickname) »") }
        var metadata: [(label: String, value: String)] = []
        metadata += card.phones.map { ($0.label, $0.value) }
        metadata += card.emails.map { ($0.label, $0.value) }
        metadata += card.addresses.map { ($0.label, $0.value) }
        if !card.organization.isEmpty { metadata.append(("Entreprise", card.organization)) }
        if let birthday = card.birthday, let text = birthdayText(birthday) { metadata.append(("Anniversaire", text)) }
        return ItemDetail(text: lines.joined(separator: "\n\n"), metadata: metadata, image: ContactAvatar.banner(for: card), isMarkdown: true)
    }

    static func birthdayText(_ components: DateComponents) -> String? {
        guard let month = components.month, let day = components.day else { return nil }
        var calendarComponents = DateComponents(year: components.year ?? 2000, month: month, day: day)
        calendarComponents.calendar = Calendar(identifier: .gregorian)
        guard let date = calendarComponents.date else { return nil }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(components.year == nil ? "dMMMM" : "dMMMMyyyy")
        return formatter.string(from: date)
    }

    static func actions(_ card: ContactCard) -> [ItemAction] {
        var actions: [ItemAction] = [ItemAction(title: "Afficher dans Contacts", symbol: "person.crop.circle") {
            if let url = URL(string: "addressbook://\(card.id)") { NSWorkspace.shared.open(url) }
            return .close
        }]
        let phone = card.primaryPhone
        if let phone {
            actions.append(Actions.copy(phone.value, title: "Copier le numéro", symbol: "phone", shortcut: .copyText, hud: "Numéro copié"))
        } else if let email = card.emails.first {
            actions.append(Actions.copy(email.value, title: "Copier l’e-mail", symbol: "envelope", shortcut: .copyText, hud: "E-mail copié"))
        }
        func open(_ title: String, _ symbol: String, _ url: URL?, shortcut: KeyShortcut? = nil) {
            guard let url else { return }
            actions.append(ItemAction(title: title, symbol: symbol, shortcut: shortcut, section: "Contacter") {
                NSWorkspace.shared.open(url)
                return .close
            })
        }
        if let phone {
            open("Appeler \(phone.value)", "phone.fill", telURL("tel:", phone.value), shortcut: KeyShortcut(keyCode: 8, modifiers: [.command, .option], label: "C"))
            open("Appel audio FaceTime", "phone.badge.waveform", telURL("facetime-audio://", phone.value))
        }
        if let handle = phone.map({ $0.value.filter { $0.isNumber || $0 == "+" } }) ?? card.emails.first?.value {
            open("FaceTime", "video.fill", URL(string: "facetime://" + handle))
        }
        if let phone {
            open("Envoyer un message", "message.fill", telURL("imessage://", phone.value), shortcut: KeyShortcut(keyCode: 46, modifiers: [.command, .shift], label: "M"))
        } else if let email = card.emails.first {
            open("Envoyer un message", "message.fill", URL(string: "imessage://" + email.value))
        }
        if let email = card.emails.first {
            open("Envoyer un e-mail", "envelope.fill", URL(string: "mailto:" + email.value), shortcut: KeyShortcut(keyCode: 14, modifiers: [.command, .shift], label: "E"))
        }
        for entry in card.phones where phone == nil || card.phones.count > 1 {
            actions.append(Actions.copy(entry.value, title: "Copier \(entry.label.lowercased()) : \(entry.value)", symbol: "phone", hud: "Numéro copié"))
            actions[actions.count - 1].section = "Copier"
        }
        for entry in card.emails where card.primaryPhone != nil || card.emails.count > 1 {
            actions.append(Actions.copy(entry.value, title: "Copier l’e-mail \(entry.value)", symbol: "envelope", hud: "E-mail copié"))
            actions[actions.count - 1].section = "Copier"
        }
        for entry in card.addresses {
            actions.append(Actions.copy(entry.value, title: "Copier l’adresse (\(entry.label.lowercased()))", symbol: "mappin.and.ellipse", hud: "Adresse copiée"))
            actions[actions.count - 1].section = "Copier"
        }
        var name = Actions.copy(card.fullName, title: "Copier le nom", symbol: "textformat", shortcut: .copyName, hud: "Nom copié")
        name.section = "Copier"
        actions.append(name)
        return actions
    }

    static func accessItem(onGranted: @escaping @MainActor () -> Void) -> ResultItem {
        let denied = ContactsService.status == .denied || ContactsService.status == .restricted
        return ResultItem(
            id: "contacts.access",
            title: denied ? "Ouvrir les réglages de confidentialité" : "Autoriser l’accès aux contacts…",
            icon: .symbol("lock.fill", Palette.gray),
            detail: ItemDetail(
                text: denied
                    ? "## Accès refusé\nPrism n’a pas accès à vos contacts. Autorisez-le dans **Réglages Système › Confidentialité et sécurité › Contacts**."
                    : "## Vos contacts dans Prism\nCherchez un contact pour l’appeler, lui écrire ou copier ses coordonnées.\n\nVos contacts restent sur votre Mac.",
                metadata: [("État", ContactsService.shared.statusDescription)],
                isMarkdown: true
            ),
            usageKey: "",
            actions: [ItemAction(title: denied ? "Ouvrir les réglages" : "Autoriser l’accès…", symbol: "lock.open") {
                ContactsService.shared.requestAccess { granted in if granted { onGranted() } }
                return .stay
            }]
        )
    }
}

// MARK: - Écran et fonctionnalité

@MainActor
final class ContactsScreen: LauncherScreen {
    init() {
        super.init(id: "contacts", title: "Contacts", placeholder: "Rechercher des contacts…", icon: .symbol("person.crop.circle.fill", Palette.brown))
        layout = .split(listWidth: 300)
    }

    override func didAppear() {
        let service = ContactsService.shared
        service.onChange["screen"] = { [weak self] in
            self?.isLoading = false
            self?.reload()
        }
        if service.isAuthorized, !service.isLoaded {
            isLoading = !FeatureDemo.isActive
            service.load()
        }
    }

    override func didDisappear() {
        ContactsService.shared.onChange["screen"] = nil
    }

    override func sections(query: String) -> [ResultSection] {
        let service = ContactsService.shared
        guard service.isAuthorized else {
            return [ResultSection(id: "access", title: "Contacts", items: [ContactItems.accessItem { [weak self] in self?.reload() }])]
        }
        let cards = service.search(query)
        guard !cards.isEmpty else { return [] }
        return [ResultSection(id: "contacts", title: query.isEmpty ? "Tous les contacts" : "Contacts", items: cards.map { ContactItems.item($0) })]
    }

    override func emptyState(query: String) -> (symbol: String, message: String) {
        if isLoading { return ("hourglass", "Chargement des contacts…") }
        return query.isEmpty ? ("person.crop.circle", "Aucun contact.") : ("magnifyingglass", "Aucun contact pour « \(query) »")
    }
}

/// Réglages des contacts.
@MainActor
final class ContactsSettings: ObservableObject {
    static let shared = ContactsSettings()

    @Published var showInRoot: Bool {
        didSet { UserDefaults.standard.set(showInRoot, forKey: "contacts.showInRoot") }
    }

    private init() {
        showInRoot = UserDefaults.standard.object(forKey: "contacts.showInRoot") as? Bool ?? true
    }
}

@MainActor
enum ContactsFeature: PrismFeature {
    static func start() {
        ContactsService.shared.onChange["root"] = {
            guard let model = AppContext.launcher?.model, model.isRoot, !model.query.isEmpty else { return }
            model.root.reload()
        }
        // Le carnet n'est lu que si l'accès est déjà accordé.
        if ContactsService.status == .authorized { ContactsService.shared.load() }
    }

    static var commands: [ResultItem] {
        [Command.screen("contacts", "Rechercher des contacts", subtitle: "Contacts", symbol: "person.crop.circle.fill", color: Palette.brown, keywords: ["contacts", "search contacts", "carnet d'adresses", "telephone", "appeler"]) { ContactsScreen() }]
    }

    /// Trois contacts au plus sous les résultats, si l'accès est déjà accordé.
    static func extraSections(query: String) -> [ResultSection] {
        let service = ContactsService.shared
        guard ContactsSettings.shared.showInRoot, query.count >= 2, service.isAuthorized, !PathCompletion.isPathQuery(query) else { return [] }
        service.loadIfNeeded()
        let cards = service.search(query, limit: 3).filter { card in
            card.searchFields.contains { Fuzzy.score(query.normalizedForSearch, $0) ?? 0 >= 62 } || card.digits.contains { $0.contains(query.filter(\.isNumber)) && query.filter(\.isNumber).count >= 4 }
        }
        guard !cards.isEmpty else { return [] }
        return [ResultSection(id: "root-contacts", title: "Contacts", items: cards.map { ContactItems.item($0, idPrefix: "rootcontact:", withDetail: false) })]
    }

    static var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "contacts", title: "Contacts", symbol: "person.crop.circle.fill", color: Palette.brown, order: 46) { AnyView(ContactsSettingsView()) }]
    }

    /// `prism://contacts?q=nom`.
    static func handle(url: URL) -> Bool {
        guard url.host == "contacts", let launcher = AppContext.launcher else { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
        launcher.show(reset: true)
        launcher.model.push(ContactsScreen(), query: query)
        return true
    }

    static func selfTest(_ check: (Bool, String) -> Void) {
        let card = ContactCard(id: "1", givenName: "Léa", familyName: "Martin", organization: "Acme",
                               phones: [.init(label: "domicile", value: "01 42 00 00 00"), .init(label: "mobile", value: "+33 6 12 34 56 78")],
                               emails: [.init(label: "travail", value: "lea@acme.fr")])
        check(card.initials == "LM" && card.primaryPhone?.value == "+33 6 12 34 56 78", "contacts : initiales et numéro de portable")
        check(ContactItems.telURL("tel:", "+33 6 12 34 56 78")?.absoluteString == "tel:+33612345678", "contacts : numéro nettoyé pour l’appel")
        check(ContactItems.birthdayText(DateComponents(month: 3, day: 9)) != nil, "contacts : anniversaire sans année")
    }
}

struct ContactsSettingsView: View {
    @ObservedObject private var settings = ContactsSettings.shared
    @State private var status = ContactsService.shared.statusDescription
    @State private var authorized = ContactsService.shared.isAuthorized

    var body: some View {
        Form {
            Section {
                LabeledContent("Accès aux contacts") {
                    HStack(spacing: 10) {
                        if authorized {
                            Label(status, systemImage: "checkmark.circle.fill").foregroundStyle(Palette.green)
                        } else {
                            Text(status).foregroundStyle(.secondary)
                            Button("Autoriser l’accès…") {
                                ContactsService.shared.requestAccess { _ in
                                    status = ContactsService.shared.statusDescription
                                    authorized = ContactsService.shared.isAuthorized
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Autorisation")
            } footer: {
                Text("Prism lit votre carnet d’adresses sur votre Mac, sans rien envoyer sur le réseau.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Recherche principale") {
                Toggle("Proposer des contacts sous les résultats (trois au plus)", isOn: $settings.showInRoot)
            }
        }
        .formStyle(.grouped)
    }
}
