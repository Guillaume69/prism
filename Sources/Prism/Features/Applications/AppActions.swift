import AppKit

/// Les réglages des applications, lus aussi hors du fil principal (recherche des apps) : préfixe « applications. ».
enum ApplicationsPreferences {
    private static var defaults: UserDefaults { .standard }

    /// Dossiers où chercher des apps en plus des emplacements habituels (parcourus sur 3 niveaux).
    static var extraFolders: [String] {
        get { defaults.stringArray(forKey: "applications.extraFolders") ?? [] }
        set { defaults.set(newValue, forKey: "applications.extraFolders") }
    }

    /// Raccourci d'une app déjà au premier plan : « toggle » la masque, « show » la laisse devant.
    static var hotkeyAction: String {
        get { defaults.string(forKey: "applications.hotkeyAction") ?? "toggle" }
        set { defaults.set(newValue, forKey: "applications.hotkeyAction") }
    }

    /// Fermeture automatique : identifiant de paquet → délai en minutes (0 : le délai par défaut).
    static var autoQuitApps: [String: Int] {
        get { defaults.dictionary(forKey: "applications.autoQuit") as? [String: Int] ?? [:] }
        set { defaults.set(newValue, forKey: "applications.autoQuit") }
    }

    /// Délai par défaut de la fermeture automatique, en minutes.
    static var autoQuitDelay: Int {
        get { defaults.object(forKey: "applications.autoQuitDelay") as? Int ?? 5 }
        set { defaults.set(newValue, forKey: "applications.autoQuitDelay") }
    }

    static let autoQuitDelays = [1, 3, 5, 10, 15, 30, 60]
}

/// Les actions d'une application dans la recherche : ouvrir, Finder, copier, piloter l'app ouverte,
/// fermeture automatique, mode jeu, désinstallation.
@MainActor
enum AppActions {
    /// Ce qui se lit une fois pour toutes les apps d'une recherche.
    struct Context {
        var autoQuit: [String: Int]
        var defaultDelay: Int
        var markedGames: Set<String>

        static func current() -> Context {
            Context(
                autoQuit: ApplicationsPreferences.autoQuitApps,
                defaultDelay: ApplicationsPreferences.autoQuitDelay,
                markedGames: Set(GameCatalog.markedApps)
            )
        }
    }

    static let newWindow = KeyShortcut(keyCode: 45, modifiers: [.command], label: "N")
    static let getInfo = KeyShortcut(keyCode: 34, modifiers: [.command], label: "I")
    static let hide = KeyShortcut(keyCode: 4, modifiers: [.command], label: "H")
    static let restart = KeyShortcut(keyCode: 15, modifiers: [.control, .option], label: "R")
    static let copyBundleID = KeyShortcut(keyCode: 8, modifiers: [.command, .control], label: "C")
    static let uninstall = KeyShortcut(keyCode: 51, modifiers: [.control, .option], label: "⌫")

    static func actions(for entry: AppEntry, running app: NSRunningApplication?, context: Context) -> [ItemAction] {
        let url = URL(fileURLWithPath: entry.path)
        let isPrism = entry.bundleID != nil && entry.bundleID == Bundle.main.bundleIdentifier
        var actions: [ItemAction] = [
            ItemAction(title: "Ouvrir l’application", symbol: "arrow.up.forward.app") {
                open(url)
                return .close
            },
            Actions.reveal(entry.path),
            ItemAction(title: "Ouvrir une nouvelle fenêtre", symbol: "macwindow.badge.plus", shortcut: newWindow) {
                openNewWindow(url, running: app)
            },
            ItemAction(title: "Fichiers récents…", symbol: "clock.arrow.circlepath", shortcut: KeyShortcut(keyCode: 15, modifiers: [.command, .option], label: "R")) {
                .push(RecentDocuments.screen(appName: entry.name, appURL: url))
            },
            ItemAction(title: "Lire les informations", symbol: "info.circle", shortcut: getInfo) {
                showInfo(entry.path)
                return .close
            },
            ItemAction(title: "Afficher le contenu du paquet", symbol: "shippingbox") {
                NSWorkspace.shared.open(url.appendingPathComponent("Contents", isDirectory: true))
                return .close
            },
            ItemAction(title: "Copier le chemin", symbol: "link", shortcut: .copyPath, section: "Copier") {
                Pasteboard.copy(entry.path)
                return .hud("Chemin copié")
            },
            ItemAction(title: "Copier le nom", symbol: "textformat", shortcut: .copyName, section: "Copier") {
                Pasteboard.copy(entry.name)
                return .hud("Nom copié")
            },
        ]
        if let bundleID = entry.bundleID {
            actions.append(ItemAction(title: "Copier l’identifiant de paquet", symbol: "barcode", shortcut: copyBundleID, section: "Copier") {
                Pasteboard.copy(bundleID)
                return .hud("Identifiant copié : \(bundleID)")
            })
        }

        if let app, !isPrism {
            actions += [
                ItemAction(title: "Masquer", symbol: "eye.slash", shortcut: hide, section: "Application ouverte") {
                    app.hide()
                    return .close
                },
                ItemAction(title: "Quitter l’application", symbol: "xmark.circle", shortcut: .quitApp, isDestructive: true, section: "Application ouverte") {
                    app.terminate()
                    return .hud("\(entry.name) a été quittée")
                },
                ItemAction(title: "Forcer à quitter", symbol: "xmark.octagon", shortcut: .forceQuit, isDestructive: true, section: "Application ouverte") {
                    app.forceTerminate()
                    return .hud("\(entry.name) a été forcée à quitter")
                },
                ItemAction(title: "Redémarrer l’application", symbol: "arrow.clockwise.circle", shortcut: restart, section: "Application ouverte") {
                    relaunch(app, url: url, name: entry.name)
                    return .close
                },
            ]
        }

        if let bundleID = entry.bundleID, !isPrism, !SystemActions.protectedBundleIDs.contains(bundleID) {
            if let delay = context.autoQuit[bundleID] {
                let minutes = delay > 0 ? delay : context.defaultDelay
                actions.append(ItemAction(title: "Désactiver la fermeture automatique (\(minutes) min)", symbol: "timer", section: "Gérer") {
                    AutoQuit.setEnabled(false, for: bundleID)
                    return .toast("Fermeture automatique désactivée pour \(entry.name)")
                })
            } else {
                actions.append(ItemAction(title: "Activer la fermeture automatique", symbol: "timer", section: "Gérer") {
                    AutoQuit.setEnabled(true, for: bundleID)
                    return .toast("\(entry.name) se fermera après \(context.defaultDelay) min d’inactivité")
                })
            }
        }
        let key = GameCatalog.key(bundleID: entry.bundleID, path: entry.path)
        if context.markedGames.contains(key) {
            actions.append(ItemAction(title: "Ne plus traiter comme un jeu", symbol: "gamecontroller", section: "Gérer") {
                GameCatalog.setMarked(false, key: key)
                return .toast("\(entry.name) n’est plus traitée comme un jeu")
            })
        } else if !entry.declaresGame {
            actions.append(ItemAction(title: "Traiter comme un jeu", symbol: "gamecontroller.fill", section: "Gérer") {
                GameCatalog.setMarked(true, key: key)
                return .toast("\(entry.name) est traitée comme un jeu")
            })
        }
        if !entry.isSystem, !isPrism, entry.bundleID != "com.apple.finder" {
            actions.append(ItemAction(title: "Désinstaller…", symbol: "trash", shortcut: uninstall, isDestructive: true, section: "Gérer") {
                .push(AppUninstaller.form(for: entry))
            })
        }
        return actions
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Active l'app, puis ⌘N. Une app fermée s'ouvre simplement : elle montre déjà une fenêtre.
    private static func openNewWindow(_ url: URL, running app: NSRunningApplication?) -> ActionOutcome {
        guard let app else {
            open(url)
            return .close
        }
        guard Paster.isTrusted else {
            Paster.requestTrust()
            open(url)
            return .hud("Autorisez Prism dans Accessibilité pour ouvrir une fenêtre")
        }
        app.unhide()
        open(url)
        waitUntilFrontmost(app, attempts: 15) {
            Keystrokes.send(45, flags: .maskCommand)
        }
        return .close
    }

    private static func waitUntilFrontmost(_ app: NSRunningApplication, attempts: Int, then work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated {
                if app.isActive || attempts <= 0 {
                    work()
                } else {
                    waitUntilFrontmost(app, attempts: attempts - 1, then: work)
                }
            }
        }
    }

    /// La fenêtre « Lire les informations » du Finder.
    private static func showInfo(_ path: String) {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        SystemActions.osascript("""
        tell application "Finder"
            open information window of (POSIX file "\(escaped)" as alias)
            activate
        end tell
        """)
    }

    /// Quitte l'app, attend qu'elle soit fermée (10 secondes au plus : elle peut demander d'enregistrer), puis la rouvre.
    private static func relaunch(_ app: NSRunningApplication, url: URL, name: String) {
        app.terminate()
        func poll(_ remaining: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated {
                    if app.isTerminated {
                        open(url)
                        HUD.shared.show("\(name) a redémarré", symbol: "arrow.clockwise.circle.fill")
                    } else if remaining > 0 {
                        poll(remaining - 1)
                    } else {
                        HUD.shared.show("\(name) ne s’est pas fermée", symbol: "exclamationmark.triangle.fill")
                    }
                }
            }
        }
        poll(50)
    }
}
