import AppKit
import CoreAudio
import SwiftUI

/// Les commandes du système, comme celles de Raycast : session et énergie, son et lecture, apparence,
/// Finder et disques, applications ouvertes, notifications, Wi-Fi et Bluetooth.
/// Celles qui agissent ferment le lanceur et confirment d'une pastille (« Volume à 50 % »).
@MainActor
enum SystemFeature: PrismFeature {
    /// Rendus et autotests : aucune autorisation demandée, aucun état modifié.
    static var isHeadless: Bool {
        CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--selftest")
    }

    static var commands: [ResultItem] {
        sessionCommands + soundCommands + displayCommands + finderCommands + appCommands + networkCommands + AirplaneMode.commands + VolumeMixer.commands + Camera.commands + HDR.commands
    }

    // MARK: - Session et énergie

    private static var sessionCommands: [ResultItem] {
        [
            system("lock", "Verrouiller l’écran", symbol: "lock.fill", color: Palette.gray, keywords: ["lock screen", "verrouiller", "verrou"]) {
                SystemActions.lockScreen()
                return .close
            },
            system("sleep", "Suspendre l’activité", symbol: "moon.zzz.fill", color: Palette.indigo, keywords: ["sleep", "veille", "suspendre"]) {
                // Laisse le lanceur se fermer avant que le Mac ne s'endorme.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { SystemActions.sleep() }
                return .close
            },
            system("hibernate", "Hiberner", symbol: "powersleep", color: Palette.indigo, keywords: ["hibernate", "hibernation", "veille profonde"]) {
                SystemActions.hibernate { success in
                    if !success { onMain { HUD.shared.show("Hibernation annulée", symbol: "xmark.circle.fill") } }
                }
                return .close
            },
            system("low-power", "Activer ou désactiver l’économiseur d’énergie", symbol: "bolt.badge.automatic.fill", color: Palette.yellow, keywords: ["low power mode", "economie d energie", "batterie", "energie"]) {
                let enable = !SystemActions.isLowPowerModeEnabled
                SystemActions.setLowPowerMode(enable) { success in
                    onMain {
                        if success {
                            HUD.shared.show(enable ? "Économiseur d’énergie activé" : "Économiseur d’énergie désactivé", symbol: "bolt.fill")
                        }
                    }
                }
                return .close
            },
            system("display-sleep", "Mettre les écrans en veille", symbol: "display", color: Palette.indigo, keywords: ["sleep displays", "ecran", "moniteur"]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { SystemActions.sleepDisplays() }
                return .close
            },
            system("screensaver", "Lancer l’économiseur d’écran", symbol: "sparkles.tv.fill", color: Palette.teal, keywords: ["screen saver", "economiseur d ecran"]) {
                SystemActions.startScreenSaver()
                return .close
            },
            system("restart", "Redémarrer", symbol: "arrow.clockwise", color: Palette.orange, keywords: ["restart", "reboot", "redemarrer"]) {
                SystemActions.restart()
                return .close
            },
            system("shutdown", "Éteindre", symbol: "power", color: Palette.red, keywords: ["shut down", "arreter", "eteindre"]) {
                SystemActions.shutDown()
                return .close
            },
            system("logout", "Fermer la session", symbol: "rectangle.portrait.and.arrow.right", color: Palette.orange, keywords: ["log out", "deconnexion", "session"]) {
                SystemActions.logOut()
                return .close
            },
        ]
    }

    // MARK: - Son et lecture

    private static var soundCommands: [ResultItem] {
        var items: [ResultItem] = [
            system("play-pause", "Lecture / Pause", symbol: "playpause.fill", color: Palette.pink, keywords: ["play pause", "musique", "lecture", "pause", "media"]) {
                media(MediaKeys.play, "Lecture / Pause", "playpause.fill")
            },
            system("next-track", "Piste suivante", symbol: "forward.fill", color: Palette.pink, keywords: ["next track", "suivant", "musique", "chanson"]) {
                media(MediaKeys.next, "Piste suivante", "forward.fill")
            },
            system("previous-track", "Piste précédente", symbol: "backward.fill", color: Palette.pink, keywords: ["previous track", "precedent", "musique", "chanson"]) {
                media(MediaKeys.previous, "Piste précédente", "backward.fill")
            },
            system("mute", "Couper ou rétablir le son", symbol: "speaker.slash.fill", color: Palette.pink, keywords: ["mute", "toggle mute", "volume", "son", "muet"]) {
                let muted = !(SystemAudio.isOutputMuted() ?? false)
                SystemAudio.setOutputMuted(muted)
                return notify(muted ? "Son coupé" : "Son rétabli", muted ? "speaker.slash.fill" : VolumeMath.symbol(SystemAudio.outputVolume() ?? 0.5))
            },
            system("volume-up", "Monter le volume", symbol: "speaker.wave.3.fill", color: Palette.pink, keywords: ["volume up", "plus fort", "son"]) {
                setVolume(VolumeMath.stepped(SystemAudio.outputVolume() ?? 0.5, up: true))
            },
            system("volume-down", "Baisser le volume", symbol: "speaker.wave.1.fill", color: Palette.pink, keywords: ["volume down", "moins fort", "son"]) {
                setVolume(VolumeMath.stepped(SystemAudio.outputVolume() ?? 0.5, up: false))
            },
            Command.make(
                "system.set-volume", "Régler le volume", subtitle: "Système",
                symbol: "speaker.wave.2.fill", color: Palette.pink,
                keywords: ["set volume", "volume", "son", "niveau"],
                arguments: [ItemArgument(name: "volume", placeholder: "0 à 100", defaultValue: SystemAudio.outputVolume().map { "\(VolumeMath.percent($0))" } ?? "")],
                runWithArguments: { values in
                    guard let volume = values.first.flatMap(VolumeMath.parse) else {
                        return .toast("Entrez un volume entre 0 et 100")
                    }
                    return setVolume(volume)
                },
                actions: [ItemAction(title: "Régler le volume", symbol: "speaker.wave.2") {
                    let item = commands.first { $0.id == "command:system.set-volume" }
                    return item.flatMap { ArgumentsForm.screen(for: $0) }.map { .push($0) } ?? .stay
                }]
            ),
        ]
        for level in [0, 25, 50, 75, 100] {
            items.append(system("volume-\(level)", "Volume à \(level)\u{A0}%", symbol: VolumeMath.symbol(Double(level) / 100), color: Palette.pink, keywords: ["volume \(level)", "set volume to \(level)", "son \(level)"]) {
                setVolume(Double(level) / 100)
            })
        }
        items.append(system("mute-microphone", "Couper ou rétablir le micro", symbol: "mic.slash.fill", color: Palette.red, keywords: ["mute microphone", "micro", "microphone", "input volume"]) {
            let current = SystemAudio.inputVolume() ?? 0
            if current < 0.01 {
                SystemAudio.setInputVolume(SystemPreferences.savedMicrophoneVolume)
                return notify("Micro rétabli", "mic.fill")
            }
            SystemPreferences.savedMicrophoneVolume = current
            SystemAudio.setInputVolume(0)
            return notify("Micro coupé", "mic.slash.fill")
        })
        return items
    }

    // MARK: - Apparence et bureau

    private static var displayCommands: [ResultItem] {
        [
            system("show-desktop", "Afficher le bureau", symbol: "menubar.dock.rectangle", color: Palette.blue, keywords: ["show desktop", "bureau", "desktop"]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { SystemActions.showDesktop() }
                return .close
            },
            system("dark-mode", "Basculer l’apparence (clair ou sombre)", symbol: "circle.lefthalf.filled", color: Palette.gray, keywords: ["toggle system appearance", "dark mode", "mode sombre", "mode clair", "theme"]) {
                let dark = SystemActions.toggleDarkMode()
                return notify(dark ? "Apparence sombre" : "Apparence claire", dark ? "moon.fill" : "sun.max.fill")
            },
            system("stage-manager", "Activer ou désactiver Stage Manager", symbol: "squares.leading.rectangle", color: Palette.indigo, keywords: ["stage manager", "organisateur", "fenetres"]) {
                let enable = !SystemActions.isStageManagerEnabled
                SystemActions.setStageManager(enable)
                return notify(enable ? "Stage Manager activé" : "Stage Manager désactivé", "squares.leading.rectangle")
            },
            system("night-shift", "Activer ou désactiver Night Shift", symbol: "moon.circle.fill", color: Palette.orange, keywords: ["night shift", "lumiere bleue", "couleurs chaudes", "nuit"]) {
                guard NightShift.isAvailable, let enabled = NightShift.isEnabled else {
                    return notify("Night Shift indisponible sur ce Mac", "exclamationmark.triangle.fill")
                }
                guard NightShift.setEnabled(!enabled) else {
                    return notify("Night Shift n’a pas pu être modifié", "exclamationmark.triangle.fill")
                }
                return notify(enabled ? "Night Shift désactivé" : "Night Shift activé", enabled ? "sun.max.fill" : "moon.fill")
            },
        ]
    }

    // MARK: - Finder et disques

    private static var finderCommands: [ResultItem] {
        [
            system("open-trash", "Ouvrir la corbeille", symbol: "trash", color: Palette.gray, keywords: ["open trash", "corbeille", "poubelle"]) {
                SystemActions.openTrash()
                return .close
            },
            system("empty-trash", "Vider la corbeille", symbol: "trash.fill", color: Palette.red, keywords: ["empty trash", "corbeille", "poubelle", "vider"]) {
                emptyTrash()
            },
            system("eject-all", "Éjecter tous les disques", symbol: "eject.fill", color: Palette.gray, keywords: ["eject all disks", "ejecter", "disque", "cle usb", "volume"]) {
                SystemActions.ejectAll { ejected, failed in
                    if let first = failed.first {
                        HUD.shared.show("« \(first) » est utilisé : éjection impossible", symbol: "exclamationmark.triangle.fill")
                    } else if ejected == 0 {
                        HUD.shared.show("Aucun disque à éjecter", symbol: "eject")
                    } else {
                        HUD.shared.show(ejected == 1 ? "1 disque éjecté" : "\(ejected) disques éjectés", symbol: "eject.fill")
                    }
                }
                return .close
            },
            system("hidden-files", "Afficher ou masquer les fichiers cachés", symbol: "eye.slash.fill", color: Palette.blue, keywords: ["toggle hidden files", "fichiers caches", "finder", "invisibles"]) {
                let shown = SystemActions.toggleHiddenFiles()
                return notify(shown ? "Fichiers cachés affichés" : "Fichiers cachés masqués", shown ? "eye.fill" : "eye.slash.fill")
            },
        ]
    }

    private static func emptyTrash() -> ActionOutcome {
        let count = SystemActions.trashItemCount
        if count == 0 { return notify("La corbeille est déjà vide", "trash") }
        let perform: @MainActor () -> ActionOutcome = {
            SystemActions.emptyTrash()
            return notify("Corbeille vidée", "trash.fill")
        }
        guard SystemPreferences.confirmEmptyTrash else { return perform() }
        let what = count.map { $0 == 1 ? "L’élément de la corbeille sera supprimé" : "Les \($0) éléments de la corbeille seront supprimés" }
            ?? "Les éléments de la corbeille seront supprimés"
        return .push(SystemConfirmation.screen(
            id: "empty-trash",
            title: "Vider la corbeille ?",
            icon: .symbol("trash.fill", Palette.red),
            confirmTitle: "Vider la corbeille",
            confirmSymbol: "trash.fill",
            message: what + " définitivement.",
            perform: perform
        ))
    }

    // MARK: - Applications et notifications

    private static var appCommands: [ResultItem] {
        [
            system("hide-others", "Masquer les autres applications", symbol: "eye.slash", color: Palette.violet, keywords: ["hide all apps", "hide others", "masquer"]) {
                let kept = AppContext.previousApp?.processIdentifier
                let others = SystemActions.regularApps().filter { $0.processIdentifier != kept && !$0.isHidden }
                others.forEach { $0.hide() }
                return notify(others.isEmpty ? "Aucune autre application à masquer" : "Autres applications masquées", "eye.slash.fill")
            },
            system("unhide-all", "Afficher toutes les applications", symbol: "eye", color: Palette.violet, keywords: ["unhide all apps", "show all", "afficher"]) {
                let hidden = SystemActions.regularApps().filter(\.isHidden)
                hidden.forEach { $0.unhide() }
                return notify(hidden.isEmpty ? "Aucune application masquée" : "Applications affichées", "eye.fill")
            },
            system("quit-all", "Quitter toutes les applications", symbol: "xmark.app.fill", color: Palette.red, keywords: ["quit all apps", "quitter", "fermer tout"]) {
                quitAll(keepingFrontmost: false)
            },
            system("quit-others", "Quitter les autres applications", symbol: "xmark.app", color: Palette.red, keywords: ["quit all except frontmost", "sauf premier plan"]) {
                quitAll(keepingFrontmost: true)
            },
            system("clear-notifications", "Effacer les notifications", symbol: "bell.slash.fill", color: Palette.red, keywords: ["dismiss notifications", "clear notifications", "notifications", "fermer"]) {
                guard Paster.isTrusted else {
                    Paster.requestTrust()
                    return notify("Autorisez Prism dans Accessibilité pour effacer les notifications", "exclamationmark.triangle.fill")
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let count = SystemActions.clearNotifications()
                    onMain {
                        switch count {
                        case 0: HUD.shared.show("Aucune notification à effacer", symbol: "bell")
                        case 1: HUD.shared.show("1 notification effacée", symbol: "bell.slash.fill")
                        default: HUD.shared.show("\(count) notifications effacées", symbol: "bell.slash.fill")
                        }
                    }
                }
                return .close
            },
        ]
    }

    private static func quitAll(keepingFrontmost: Bool) -> ActionOutcome {
        let running = SystemActions.regularApps()
        let kept = keepingFrontmost ? AppContext.previousApp?.bundleIdentifier : nil
        let indices = SystemActions.quitCandidates(
            bundleIDs: running.map(\.bundleIdentifier),
            excluded: Set(SystemPreferences.quitAllExcluded),
            keeping: kept
        )
        let apps = indices.map { running[$0] }
        guard !apps.isEmpty else { return notify("Aucune application à quitter", "checkmark.circle.fill") }
        let perform: @MainActor () -> ActionOutcome = {
            apps.forEach { $0.terminate() }
            return notify(apps.count == 1 ? "1 application quittée" : "\(apps.count) applications quittées", "xmark.app.fill")
        }
        guard SystemPreferences.confirmQuitAll else { return perform() }
        let details = apps.map { app in
            let name = app.localizedName ?? app.bundleIdentifier ?? "Application"
            return ResultItem(
                id: "quit-all.app.\(app.processIdentifier)",
                title: name,
                icon: app.bundleURL.map { .file($0.path) } ?? .symbol("app", Palette.gray),
                usageKey: "",
                actions: [ItemAction(title: "Quitter seulement \(name)", symbol: "xmark.circle", isDestructive: true) {
                    app.terminate()
                    return notify("\(name) a été quittée", "xmark.circle.fill")
                }]
            )
        }
        return .push(SystemConfirmation.screen(
            id: keepingFrontmost ? "quit-others" : "quit-all",
            title: "Quitter \(apps.count == 1 ? "1 application" : "\(apps.count) applications") ?",
            icon: .symbol("xmark.app.fill", Palette.red),
            confirmTitle: "Quitter les applications",
            confirmSymbol: "xmark.app.fill",
            message: "Les documents non enregistrés seront signalés par chaque application.",
            detailsTitle: "Applications à quitter",
            details: details,
            perform: perform
        ))
    }

    // MARK: - Wi-Fi et Bluetooth

    private static var networkCommands: [ResultItem] {
        [
            system("wifi", "Activer ou désactiver le Wi-Fi", symbol: "wifi", color: Palette.blue, keywords: ["toggle wi-fi", "wifi", "wi fi", "reseau", "internet"]) {
                DispatchQueue.global(qos: .userInitiated).async {
                    let enable = !(WiFi.isPowered() ?? true)
                    let success = WiFi.setPower(enable)
                    onMain {
                        if success {
                            HUD.shared.show(enable ? "Wi-Fi activé" : "Wi-Fi désactivé", symbol: enable ? "wifi" : "wifi.slash")
                        } else {
                            HUD.shared.show("Aucune interface Wi-Fi", symbol: "exclamationmark.triangle.fill")
                        }
                    }
                }
                return .close
            },
            Command.screen("system.wifi-networks", "Réseaux Wi-Fi", subtitle: "Système", symbol: "wifi.circle.fill", color: Palette.blue, keywords: ["wi-fi networks", "wifi", "reseaux", "se connecter", "ssid"]) {
                WiFiScreen()
            },
            system("bluetooth", "Activer ou désactiver le Bluetooth", symbol: "dot.radiowaves.left.and.right", color: Palette.blue, keywords: ["toggle bluetooth", "bluetooth", "sans fil"]) {
                guard Bluetooth.isControllable else { return notify("Bluetooth non pilotable sur ce Mac", "exclamationmark.triangle.fill") }
                DispatchQueue.global(qos: .userInitiated).async {
                    let enable = !(Bluetooth.isPowered ?? true)
                    let success = Bluetooth.setPower(enable)
                    onMain {
                        if success {
                            HUD.shared.show(enable ? "Bluetooth activé" : "Bluetooth désactivé", symbol: "dot.radiowaves.left.and.right")
                        } else {
                            HUD.shared.show("Le Bluetooth n’a pas répondu", symbol: "exclamationmark.triangle.fill")
                        }
                    }
                }
                return .close
            },
            Command.screen("system.bluetooth-devices", "Appareils Bluetooth", subtitle: "Système", symbol: "headphones.circle.fill", color: Palette.blue, keywords: ["bluetooth devices", "bluetooth", "casque", "airpods", "ecouteurs", "clavier", "souris"]) {
                BluetoothScreen()
            },
        ]
    }

    // MARK: - Outils

    static func system(
        _ id: String,
        _ title: String,
        symbol: String,
        color: Color,
        keywords: [String],
        perform: @escaping @MainActor () -> ActionOutcome
    ) -> ResultItem {
        Command.run("system." + id, title, subtitle: "Système", symbol: symbol, color: color, keywords: keywords, perform: perform)
    }

    /// Ferme le lanceur et confirme d'une pastille, avec un symbole parlant.
    static func notify(_ text: String, _ symbol: String) -> ActionOutcome {
        HUD.shared.show(text, symbol: symbol)
        return .close
    }

    private static func setVolume(_ volume: Double) -> ActionOutcome {
        SystemAudio.setOutputVolume(volume)
        return notify("Volume à \(VolumeMath.percent(volume))\u{A0}%", VolumeMath.symbol(volume))
    }

    /// Les touches multimédia demandent l'accessibilité, comme le collage.
    private static func media(_ key: Int, _ label: String, _ symbol: String) -> ActionOutcome {
        guard Paster.isTrusted else {
            Paster.requestTrust()
            return notify("Autorisez Prism dans Accessibilité pour piloter la lecture", "exclamationmark.triangle.fill")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MediaKeys.press(key) }
        return notify(label, symbol)
    }

    /// Revient sur le fil principal depuis une tâche de fond.
    nonisolated static func onMain(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    // MARK: - Réglages et autotests

    static var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "system", title: "Système", symbol: "gearshape.2.fill", color: Palette.gray, order: 60) { AnyView(SystemCommandsSettingsView()) }]
    }

    static func selfTest(_ check: (Bool, String) -> Void) {
        Camera.selfTest(check)
        HDR.selfTest(check)
        // Mixeur de volume : le gain appliqué au son capté, et la liste des processus audio (lecture seule).
        var input: [Float] = [0.5, -1, 0.25, 1]
        var output: [Float] = [9, 9, 9, 9, 9, 9]
        input.withUnsafeMutableBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(inputBytes.count), mData: inputBytes.baseAddress))
                var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(outputBytes.count), mData: outputBytes.baseAddress))
                AppAudioControl.mix(&inList, into: &outList, gain: 0.5)
            }
        }
        check(output == [0.25, -0.5, 0.125, 0.5, 0, 0], "mixeur : gain appliqué, reste du tampon mis à zéro")
        let audio = VolumeMixer.processes()
        check(audio.allSatisfy { $0.pid > 0 && !$0.bundleID.isEmpty }, "mixeur : \(audio.count) processus audio lus dans Core Audio")

        let ports = """
        Hardware Port: Ethernet Adapter (en4)
        Device: en4
        Ethernet Address: 7a:26:64:77:c8:bc

        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: 80:a9:97:0c:a3:6e
        """
        check(WiFi.interfaceName(fromHardwarePorts: ports) == "en0", "networksetup : interface Wi-Fi trouvée (en0)")
        check(WiFi.interfaceName(fromHardwarePorts: "Hardware Port: Ethernet\nDevice: en1\n") == nil, "networksetup : pas de Wi-Fi, pas d'interface")
        check(WiFi.power(fromOutput: "Wi-Fi Power (en0): On\n") == true && WiFi.power(fromOutput: "Wi-Fi Power (en0): Off") == false, "networksetup : alimentation lue")
        check(WiFi.preferredNetworks(fromOutput: "Preferred networks on en0:\n\tMaison\n\tBureau 5G\n") == ["Maison", "Bureau 5G"], "networksetup : réseaux connus")
        check(WiFi.joinError(fromOutput: "") == nil && WiFi.joinError(fromOutput: "Could not find network Café.") != nil, "networksetup : erreur de connexion détectée")

        check(abs(VolumeMath.stepped(0.5, up: true) - 0.5625) < 1e-9, "volume : +6,25 % depuis 50 %")
        check(abs(VolumeMath.stepped(0.53, up: false) - 0.4375) < 1e-9, "volume : le pas se cale sur la grille des 16 crans")
        check(VolumeMath.stepped(1, up: true) == 1 && VolumeMath.stepped(0, up: false) == 0, "volume : borné entre 0 et 100 %")
        check(VolumeMath.parse("50 %") == 0.5 && VolumeMath.parse("101") == nil && VolumeMath.parse("abc") == nil, "volume : saisie en pourcentage")
        check(VolumeMath.percent(0.5625) == 56, "volume : pourcentage affiché")
        check(MediaKeys.data1(key: MediaKeys.play, down: true) == 0x100A00 && MediaKeys.data1(key: MediaKeys.next, down: false) == 0x110B00, "touches multimédia : évènement systemDefined")

        check(SystemActions.pmsetValue("hibernatemode", in: " hibernatemode        3\n lowpowermode         0") == "3", "pmset : valeur lue")
        let volumes = [
            SystemActions.MountedVolume(url: URL(fileURLWithPath: "/"), name: "Macintosh HD", isEjectable: false, isRemovable: false, isInternal: true, isLocal: true),
            SystemActions.MountedVolume(url: URL(fileURLWithPath: "/Volumes/Clé"), name: "Clé", isEjectable: true, isRemovable: true, isInternal: false, isLocal: true),
            SystemActions.MountedVolume(url: URL(fileURLWithPath: "/Volumes/Installeur"), name: "Installeur", isEjectable: true, isRemovable: false, isInternal: true, isLocal: true),
            SystemActions.MountedVolume(url: URL(fileURLWithPath: "/Volumes/Données"), name: "Données", isEjectable: false, isRemovable: false, isInternal: true, isLocal: true),
        ]
        check(SystemActions.ejectable(volumes).map(\.name) == ["Clé", "Installeur"], "éjection : clés et images disque, jamais les disques internes")
        let candidates = SystemActions.quitCandidates(
            bundleIDs: ["com.apple.finder", "com.apple.Safari", SystemActions.protectedBundleIDs.first { $0 != "com.apple.finder" }, "com.spotify.client", "com.apple.mail"],
            excluded: ["com.spotify.client"],
            keeping: "com.apple.mail"
        )
        check(candidates == [1], "quitter tout : ni le Finder, ni Prism, ni les exclues, ni l'app gardée")
        check(SystemActions.isDismissAction("Name:Fermer\nTarget:0x0\nSelector:(null)") && SystemActions.isDismissAction("Close")
              && !SystemActions.isDismissAction("AXPress"), "notifications : actions de fermeture reconnues")

        check(Bluetooth.isControllable, "Bluetooth : fonctions privées présentes")
        check(Bluetooth.symbol(major: 0x04, minor: 0, name: "AirPods Pro de Léa") == "airpodspro", "Bluetooth : symbole d'un appareil")
        let ids = commands.map(\.id)
        check(Set(ids).count == ids.count, "\(ids.count) commandes système, identifiants uniques")
        let found = RootScreen().sections(query: "volume 50").first { $0.id == "results" }?.items.first?.id
        check(found == "command:system.volume-50", "« volume 50 » trouve « Volume à 50 % »")
    }
}
