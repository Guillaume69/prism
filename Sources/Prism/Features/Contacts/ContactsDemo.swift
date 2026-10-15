import Foundation

/// Carnet d'adresses factice des rendus de démonstration (`--snapshot --demo`).
enum ContactsDemo {
    static let cards: [ContactCard] = [
        ContactCard(id: "demo-1", givenName: "Léa", familyName: "Martin", organization: "Studio Nord", jobTitle: "Directrice artistique",
                    phones: [.init(label: "Portable", value: "+33 6 12 34 56 78"), .init(label: "Travail", value: "+33 1 42 00 11 22")],
                    emails: [.init(label: "Travail", value: "lea.martin@studionord.fr"), .init(label: "Domicile", value: "lea.m@exemple.fr")],
                    addresses: [.init(label: "Travail", value: "12 rue des Petites-Écuries, 75010 Paris")],
                    birthday: DateComponents(month: 10, day: 14)),
        ContactCard(id: "demo-2", givenName: "Hugo", familyName: "Bernard", organization: "Prism", jobTitle: "Développeur",
                    phones: [.init(label: "Portable", value: "+33 7 81 22 45 90")],
                    emails: [.init(label: "Travail", value: "hugo@prism.app")]),
        ContactCard(id: "demo-3", givenName: "Inès", familyName: "Dubois", organization: "Acme",
                    phones: [.init(label: "Portable", value: "+33 6 45 10 77 31")],
                    emails: [.init(label: "Travail", value: "ines.dubois@acme.com")],
                    addresses: [.init(label: "Domicile", value: "8 quai Saint-Vincent, 69001 Lyon")],
                    birthday: DateComponents(year: 1991, month: 2, day: 3)),
        ContactCard(id: "demo-4", givenName: "Karim", familyName: "Haddad", jobTitle: "Photographe",
                    phones: [.init(label: "Portable", value: "+33 6 98 76 54 32")]),
        ContactCard(id: "demo-5", givenName: "", familyName: "", organization: "Boulangerie Lemoine",
                    phones: [.init(label: "Travail", value: "+33 1 48 78 12 34")],
                    addresses: [.init(label: "Travail", value: "74 rue Saint-Dominique, 75007 Paris")]),
        ContactCard(id: "demo-6", givenName: "Camille", familyName: "Roux", nickname: "Cam",
                    emails: [.init(label: "Domicile", value: "camille.roux@exemple.fr")]),
        ContactCard(id: "demo-7", givenName: "Paul", familyName: "Garnier", organization: "Acme", jobTitle: "Directeur commercial",
                    phones: [.init(label: "Travail", value: "+1 415 555 0132")],
                    emails: [.init(label: "Travail", value: "paul@acme.com")]),
    ]
}
