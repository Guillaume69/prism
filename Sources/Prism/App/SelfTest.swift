import AppKit
import SwiftUI

/// Vérifications de la logique sans interface : `Prism --selftest`.
@MainActor
enum SelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print((condition ? "✓ " : "✗ ") + label)
            if !condition { failures += 1 }
        }
        func near(_ value: Double?, _ expected: Double) -> Bool {
            guard let value else { return false }
            return abs(value - expected) < 1e-9
        }

        print("— Calculatrice")
        check(near(Calculator.evaluate("2+2*3"), 8), "priorité des opérateurs")
        check(near(Calculator.evaluate("(1+2)^2"), 9), "parenthèses et puissance")
        check(near(Calculator.evaluate("-2^2"), -4), "moins unaire avant la puissance")
        check(near(Calculator.evaluate("10 % 3"), 1), "modulo")
        check(near(Calculator.evaluate("50%"), 0.5), "pourcentage")
        check(near(Calculator.evaluate("2 x 3"), 6), "x comme multiplication")
        check(near(Calculator.evaluate("3,5 * 2"), 7), "virgule décimale")
        check(near(Calculator.evaluate("sqrt(16) + sin(0)"), 4), "fonctions")
        check(near(Calculator.evaluate("2pi"), 2 * .pi), "multiplication implicite")
        check(near(Calculator.evaluate("(1+2"), 3), "parenthèse non fermée tolérée")
        check(Calculator.evaluate("2+") == nil, "expression incomplète refusée")
        check(Calculator.evaluate("safari") == nil, "mot inconnu refusé")
        check(!Calculator.looksLikeCalculation("42"), "un nombre seul n'est pas un calcul")
        check(!Calculator.looksLikeCalculation("e"), "une lettre seule n'est pas un calcul")
        check(Calculator.item(for: "12*3")?.title == "36", "résultat affiché")

        print("— Recherche floue")
        check(Fuzzy.score("saf", "Safari") != nil, "préfixe")
        check((Fuzzy.score("saf", "Safari") ?? 0) > (Fuzzy.score("saf", "Visual Safety") ?? 0), "le préfixe passe avant le mot")
        check(Fuzzy.score("vsc", "Visual Studio Code") != nil, "initiales")
        check(Fuzzy.score("reglages", "Réglages Système") != nil, "accents ignorés")
        check(Fuzzy.score("xyz", "Safari") == nil, "aucune correspondance")
        check(Fuzzy.score("tlgrm", "Telegram") != nil, "sous-séquence")

        print("— Applications")
        let apps = AppCatalog.scan()
        check(apps.count > 10, "\(apps.count) applications trouvées")
        check(apps.contains { $0.fileName == "Safari" }, "Safari trouvé")
        check(apps.contains { $0.fileName == "Finder" }, "Finder trouvé")

        print("— Emojis")
        check(EmojiCatalog.all.count > 1000, "\(EmojiCatalog.all.count) emojis")
        check(EmojiProvider.sections(query: "heart").first?.items.isEmpty == false, "recherche en anglais")
        check(EmojiProvider.sections(query: "coeur").first?.items.isEmpty == false, "recherche en français")

        print("— Gestion des fenêtres")
        // Écran principal 1440 × 900, barre des menus de 25 pt, Dock de 75 pt en bas ;
        // second écran 1920 × 1080 à droite, sans Dock.
        let screens: [(frame: CGRect, visible: CGRect)] = [
            (CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 0, y: 75, width: 1440, height: 800)),
            (CGRect(x: 1440, y: 0, width: 1920, height: 1080), CGRect(x: 1440, y: 0, width: 1920, height: 1055)),
        ]
        let sampleWindow = CGRect(x: 300, y: 200, width: 600, height: 400)
        func frame(_ layout: WindowLayout, _ current: CGRect = sampleWindow) -> CGRect {
            WindowManager.targetFrame(layout, current: current, screens: screens, primaryHeight: 900)
        }
        check(frame(.leftHalf) == CGRect(x: 0, y: 25, width: 720, height: 800), "moitié gauche sous la barre des menus, au-dessus du Dock")
        check(frame(.rightHalf) == CGRect(x: 720, y: 25, width: 720, height: 800), "moitié droite")
        check(frame(.topHalf) == CGRect(x: 0, y: 25, width: 1440, height: 400), "moitié haute")
        check(frame(.bottomHalf) == CGRect(x: 0, y: 425, width: 1440, height: 400), "moitié basse")
        check(frame(.maximize) == CGRect(x: 0, y: 25, width: 1440, height: 800), "agrandir")
        check(frame(.center) == CGRect(x: 420, y: 225, width: 600, height: 400), "centrer garde la taille")
        check(frame(.lastThird) == CGRect(x: 960, y: 25, width: 480, height: 800), "dernier tiers")
        let onSecond = CGRect(x: 2000, y: 100, width: 800, height: 600)
        check(frame(.leftHalf, onSecond) == CGRect(x: 1440, y: -155, width: 960, height: 1055), "moitié gauche sur le second écran")

        print("— Recherche principale")
        check(RootScreen.detectURL("github.com") != nil, "lien détecté")
        check(RootScreen.detectURL("deux mots") == nil, "phrase non prise pour un lien")
        let calcSections = RootScreen().sections(query: "2+2")
        check(calcSections.first?.id == "calculator", "la calculatrice passe en premier")
        let commands = RootScreen().sections(query: "presse")
        check(commands.first { $0.id == "results" }?.items.first?.id == "command:clipboard", "commande du presse-papiers trouvée")
        let window = RootScreen().sections(query: "moitie gauche")
        check(window.first { $0.id == "results" }?.items.first?.id == "command:window.leftHalf", "commande de fenêtre trouvée")

        print("— Raccourcis par double appui")
        var detector = ModifierTap.Detector()
        _ = detector.flagsChanged(.command, at: 0)
        _ = detector.flagsChanged([], at: 0.1)
        _ = detector.flagsChanged(.command, at: 0.2)
        check(detector.flagsChanged([], at: 0.28) == .command, "⌘⌘ reconnu")
        var slow = ModifierTap.Detector()
        _ = slow.flagsChanged(.option, at: 0)
        _ = slow.flagsChanged([], at: 0.1)
        _ = slow.flagsChanged(.option, at: 0.9)
        check(slow.flagsChanged([], at: 1.0) == nil, "deux appuis trop espacés ignorés")
        var chord = ModifierTap.Detector()
        _ = chord.flagsChanged(.command, at: 0)
        chord.keyDown()
        _ = chord.flagsChanged([], at: 0.1)
        _ = chord.flagsChanged(.command, at: 0.2)
        check(chord.flagsChanged([], at: 0.25) == nil, "⌘C puis ⌘ n’est pas un double appui")
        check(Hotkey.doubleTap(.option).label == "⌥⌥" && Hotkey.doubleTap(.option).isValid, "libellé ⌥⌥")
        check(HotkeyCoding.decode(HotkeyCoding.encode(Hotkey.doubleTap(.control)))?.tapModifier == .control, "double appui enregistré puis relu")

        print("— Fenêtre du lanceur")
        let launcherModel = LauncherModel()
        launcherModel.prepareForShow(reset: true)
        let launcherHost = NSHostingView(rootView: LauncherView(model: launcherModel) { _ in })
        launcherHost.frame = NSRect(x: 0, y: 0, width: LauncherLayout.width, height: LauncherLayout.height)
        let hostWindow = NSWindow(contentRect: launcherHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        hostWindow.contentView = launcherHost
        launcherHost.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        // La vue qui reçoit un clic, en un point compté depuis le haut à gauche.
        func hit(_ x: CGFloat, _ yFromTop: CGFloat) -> NSView? {
            let y = launcherHost.isFlipped ? yFromTop : launcherHost.bounds.height - yFromTop
            return launcherHost.hitTest(launcherHost.convert(NSPoint(x: x, y: y), to: launcherHost.superview))
        }
        let footerY = LauncherLayout.height - LauncherLayout.footerHeight / 2
        check(hit(LauncherLayout.width / 2, 6) is WindowDragArea.DragView, "le bord de la barre de recherche déplace la fenêtre")
        check(hit(LauncherLayout.width / 2, LauncherLayout.searchHeight / 2).map { !($0 is WindowDragArea.DragView) } == true, "le champ de recherche reste cliquable")
        check(hit(300, footerY) is WindowDragArea.DragView, "le pied déplace la fenêtre")
        check(hit(LauncherLayout.width - 30, footerY).map { !($0 is WindowDragArea.DragView) } == true, "le bouton Actions reste cliquable")

        for feature in Features.all {
            var printedHeader = false
            feature.selfTest { condition, label in
                if !printedHeader {
                    print("— \(String(describing: feature))")
                    printedHeader = true
                }
                check(condition, label)
            }
        }

        print(failures == 0 ? "\nTout est vert." : "\n\(failures) échec(s).")
        return failures == 0 ? 0 : 1
    }
}
