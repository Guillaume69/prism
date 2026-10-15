import AppKit

/// Autotests de la gestion des fenêtres : uniquement la géométrie pure et les analyses de texte,
/// sans fenêtre, sans écran réel, sans accessibilité.
@MainActor
enum WindowSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        // Écran externe au-dessus d'un écran de 982 pt, qui déclare toute sa hauteur utile : macOS repousse la fenêtre de 30 pt.
        MenuBarInsets.reset()
        let external = CGRect(x: -563, y: 982, width: 2560, height: 1440)
        let wanted = CGRect(x: -563, y: -1440, width: 1280, height: 1440)
        check(MenuBarInsets.learn(frame: external, visible: external, primaryHeight: 982, wanted: wanted, actualTop: -1410), "fenêtres : barre des menus d’un écran secondaire apprise")
        check(MenuBarInsets.usable(frame: external, visible: external).height == 1410, "fenêtres : zone utile sans cette barre")
        check(!MenuBarInsets.learn(frame: external, visible: external, primaryHeight: 982, wanted: wanted, actualTop: -1410), "fenêtres : barre apprise une seule fois")
        let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
        check(!MenuBarInsets.learn(frame: builtIn, visible: CGRect(x: 0, y: 77, width: 1512, height: 872), primaryHeight: 982, wanted: CGRect(x: 0, y: 33, width: 756, height: 872), actualTop: 40), "fenêtres : un écran qui déclare sa barre n’apprend rien")
        MenuBarInsets.reset()

        // Écran principal 1440 × 900 (barre des menus de 25 pt, Dock de 75 pt) ; second écran 1920 × 1080 à droite.
        let screens: [(frame: CGRect, visible: CGRect)] = [
            (CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 0, y: 75, width: 1440, height: 800)),
            (CGRect(x: 1440, y: 0, width: 1920, height: 1080), CGRect(x: 1440, y: 0, width: 1920, height: 1055)),
        ]
        let window = CGRect(x: 300, y: 200, width: 600, height: 400)
        let onSecond = CGRect(x: 2000, y: 100, width: 800, height: 600)
        func frame(_ layout: WindowLayout, _ current: CGRect = window, _ options: WindowOptions = WindowOptions()) -> CGRect {
            WindowManager.targetFrame(layout, current: current, screens: screens, primaryHeight: 900, options: options)
        }
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

        // Tiers et quarts.
        check(frame(.firstThird) == r(0, 25, 480, 800), "premier tiers")
        check(frame(.centerThird) == r(480, 25, 480, 800), "tiers central")
        check(frame(.firstTwoThirds) == r(0, 25, 960, 800), "deux premiers tiers")
        check(frame(.lastTwoThirds) == r(480, 25, 960, 800), "deux derniers tiers")
        check(frame(.secondFourth) == r(360, 25, 360, 800), "deuxième quart")
        check(frame(.lastFourth) == r(1080, 25, 360, 800), "dernier quart")
        check(frame(.topRightQuarter) == r(720, 25, 720, 400), "quart supérieur droit")
        check(frame(.bottomLeftQuarter) == r(0, 425, 720, 400), "quart inférieur gauche")
        check(frame(.bottomRightQuarter, onSecond) == r(2400, 373, 960, 527), "quart inférieur droit sur le second écran")

        // Sixièmes.
        check(frame(.topLeftSixth) == r(0, 25, 480, 400), "sixième supérieur gauche")
        check(frame(.topCenterSixth) == r(480, 25, 480, 400), "sixième supérieur central")
        check(frame(.bottomRightSixth) == r(960, 425, 480, 400), "sixième inférieur droit")
        check(frame(.bottomCenterSixth, onSecond) == r(2080, 373, 640, 527), "sixième inférieur central sur le second écran")

        // Écart.
        let gap = WindowOptions(gap: 10)
        check(frame(.leftHalf, window, gap) == r(10, 35, 705, 780), "moitié gauche avec un écart de 10 pt")
        check(frame(.rightHalf, window, gap) == r(725, 35, 705, 780), "moitié droite avec écart : 10 pt entre les deux")
        check(frame(.maximize, window, gap) == r(10, 35, 1420, 780), "agrandir avec écart")
        check(frame(.topCenterSixth, window, WindowOptions(gap: 8)) == r(485, 33, 470, 388), "sixième avec un écart de 8 pt")
        check(frame(.bottomCenterSixth, window, WindowOptions(gap: 8)).minY == 429, "écart de 8 pt entre les deux rangées de sixièmes")

        // Tailles et déplacements.
        check(frame(.maximizeHeight) == r(300, 25, 600, 800), "agrandir en hauteur garde la largeur")
        check(frame(.maximizeWidth) == r(0, 200, 1440, 400), "agrandir en largeur garde la hauteur")
        check(frame(.almostMaximize) == r(72, 65, 1296, 720), "presque plein écran : 90 %")
        check(frame(.reasonableSize) == r(288, 185, 864, 480), "taille raisonnable : 60 % de l’écran")
        let reasonableLarge = frame(.reasonableSize, onSecond)
        check(reasonableLarge.width == 1025 && reasonableLarge.height == 633, "taille raisonnable bornée à 1025 pt de large")
        check(frame(.moveUp) == r(300, 25, 600, 400), "monter garde la taille")
        check(frame(.moveDown) == r(300, 425, 600, 400), "descendre colle au bas")
        check(frame(.moveRight) == r(840, 200, 600, 400), "coller à droite")
        check(frame(.moveLeft, onSecond) == r(1440, 100, 800, 600), "coller à gauche sur le second écran")
        check(frame(.makeLarger).width == 744 && frame(.makeLarger).midX == window.midX, "augmenter la taille autour du centre")
        check(frame(.makeSmaller).height == 320, "diminuer la taille")

        // Écrans voisins, en proportion.
        check(frame(.nextDisplay) == r(1840, 76, 800, 527), "écran suivant : même place relative")
        check(frame(.previousDisplay, onSecond) == r(420, 218, 600, 455), "écran précédent : même place relative")
        check(WindowGeometry.otherDisplay(current: window, screens: [screens[0]], step: 1) == window, "un seul écran : rien ne bouge")

        // Moitiés répétées.
        let cycle = WindowOptions(repeatHalf: .cycle)
        check(frame(.leftHalf, r(0, 25, 720, 800), cycle) == r(0, 25, 960, 800), "cycle : 1/2 → 2/3")
        check(frame(.leftHalf, r(0, 25, 960, 800), cycle) == r(0, 25, 480, 800), "cycle : 2/3 → 1/3")
        check(frame(.leftHalf, r(0, 25, 480, 800), cycle) == r(0, 25, 720, 800), "cycle : 1/3 → 1/2")
        check(frame(.rightHalf, r(720, 25, 714, 792), cycle) == r(480, 25, 960, 800), "cycle à droite, taille arrondie par l’app tolérée")
        check(frame(.leftHalf, window, cycle) == r(0, 25, 720, 800), "cycle : une fenêtre libre va d’abord à la moitié")
        let display = WindowOptions(repeatHalf: .display)
        check(frame(.leftHalf, r(1440, -155, 960, 1055), display) == r(720, 25, 720, 800), "moitié gauche répétée : moitié droite de l’écran de gauche")
        check(frame(.rightHalf, r(720, 25, 720, 800), display) == r(1440, -155, 960, 1055), "moitié droite répétée : moitié gauche de l’écran de droite")
        check(frame(.leftHalf, r(0, 25, 720, 800), display) == r(0, 25, 720, 800), "pas d’écran à gauche : la fenêtre reste")

        // Stage Manager.
        check(frame(.leftHalf, window, WindowOptions(stageManagerMargin: 190)) == r(190, 25, 625, 800), "marge de Stage Manager à gauche")

        // Commandes personnalisées.
        func custom(_ spec: CustomWindowSpec, _ current: CGRect = window) -> CGRect {
            WindowGeometry.customFrame(spec, current: current, screens: screens, primaryHeight: 900)
        }
        check(custom(CustomWindowSpec(width: .percent(50), height: .percent(50), anchor: .bottomRight)) == r(720, 425, 720, 400), "personnalisée : quart en bas à droite")
        check(custom(CustomWindowSpec(width: .points(800), height: .percent(100), anchor: .top, offsetY: .percent(10))) == r(320, 105, 800, 800), "personnalisée : ancrage en haut au centre, décalage de 10 %")
        check(custom(CustomWindowSpec(width: .points(1000), height: .points(600), anchor: .center, offsetX: .percent(-10))) == r(76, 125, 1000, 600), "personnalisée : centrée, décalage négatif")
        check(custom(CustomWindowSpec(width: .points(5000), height: .percent(30), anchor: .topLeft)).width == 1440, "personnalisée : largeur bornée à l’écran")
        check(custom(CustomWindowSpec(width: .percent(50), height: .percent(100), anchor: .right), onSecond) == r(2400, -155, 960, 1055), "personnalisée : sur le second écran")

        // Analyses de texte.
        check(WindowDimension.parse("50%") == .percent(50), "« 50% » : pourcentage")
        check(WindowDimension.parse("800") == .points(800), "« 800 » : points")
        check(WindowDimension.parse("800 px") == .points(800), "« 800 px » : points")
        check(WindowDimension.parse("-12,5 %") == .percent(-12.5), "« -12,5 % » : virgule et signe")
        check(WindowDimension.parse("abc") == nil, "texte refusé")
        check(WindowAnchor.parse("top-left") == .topLeft && WindowAnchor.parse("bas-droite") == .bottomRight && WindowAnchor.parse("Centre") == .center, "ancrages en anglais et en français")
        let deeplink = DeeplinkSpec.parse([URLQueryItem(name: "position", value: "top-right"), URLQueryItem(name: "width", value: "40%"), URLQueryItem(name: "height", value: "600")])
        check(deeplink == CustomWindowSpec(width: .percent(40), height: .points(600), anchor: .topRight), "lien profond : commande temporaire")
        check(DeeplinkSpec.parse([URLQueryItem(name: "position", value: "nulle part")]) == nil, "lien profond : position inconnue refusée")

        func form(_ values: [String: String]) -> CustomWindowSpec? {
            if case .success(let spec) = CustomCommandScreens.spec(from: values) { return spec }
            return nil
        }
        let base = ["anchor": "left", "width": "50", "widthUnit": "percent", "height": "100", "heightUnit": "percent", "offsetX": "", "offsetXUnit": "percent", "offsetY": "20", "offsetYUnit": "points"]
        check(form(base) == CustomWindowSpec(width: .percent(50), height: .percent(100), anchor: .left, offsetX: .percent(0), offsetY: .points(20)), "formulaire : valeurs lues")
        check(form(base.merging(["width": "150"]) { $1 }) == nil, "formulaire : largeur au-delà de 100 % refusée")
        check(form(base.merging(["offsetX": "-120"]) { $1 }) == nil, "formulaire : décalage au-delà de −100 % refusé")
        check(form(base.merging(["height": "0"]) { $1 }) == nil, "formulaire : hauteur nulle refusée")

        // Dispositions.
        let area = r(0, 25, 1440, 800)
        let relative = WindowGeometry.relativeFrame(window, in: area)
        check(WindowGeometry.absoluteFrame(relative, in: area) == window, "disposition : cadre relatif aller-retour")
        check(WindowGeometry.absoluteFrame(relative, in: r(1440, -155, 1920, 1055)) == r(1840, 76, 800, 527), "disposition : même place sur un autre écran")
        func saved(_ screen: Int, _ title: String = "", name: String? = nil) -> SavedWindow {
            SavedWindow(appName: "App", bundleID: nil, appPath: nil, title: title, relative: .zero, screenIndex: screen, screenName: name)
        }
        let many = (0..<10).map { saved(0, "w\($0)") } + [saved(1), saved(1)]
        let limited = LayoutEngine.limitPerScreen(many)
        check(limited.count == 10 && limited.filter { $0.screenIndex == 0 }.count == 8, "disposition : huit fenêtres au plus par écran")
        check(LayoutEngine.screenIndex(for: saved(1, name: "LG"), screenNames: ["LG", "Écran intégré"]) == 0, "disposition : écran retrouvé par son nom")
        check(LayoutEngine.screenIndex(for: saved(3, name: "Absent"), screenNames: ["Écran intégré"]) == 0, "disposition : écran disparu → écran principal")
        check(LayoutEngine.match(saved: ["B", "A", "Z"], open: ["A", "B", "C"]) == [1, 0, 2], "disposition : fenêtres associées par titre, puis dans l’ordre")

        // Commandes.
        let items = WindowsFeature.builtInItems
        check(Set(items.map(\.id)).count == items.count, "\(items.count) commandes de fenêtre, identifiants uniques")
        check(items.allSatisfy { $0.subtitle?.hasPrefix(WindowsFeature.subtitle) == true }, "sous-titre « Gestion des fenêtres » partout")
        let symbols = items.compactMap { item -> String? in if case .symbol(let name, _) = item.icon { return name }; return nil }
            + WindowAnchor.allCases.map(\.symbol)
        let missing = symbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        check(missing.isEmpty, "symboles SF présents" + (missing.isEmpty ? "" : " (manquent : \(missing.joined(separator: ", ")))"))
        check(items.allSatisfy { $0.keywords.contains("window") && $0.keywords.contains("fenetre") }, "mots-clés anglais et français")
        let halves = RootScreen().sections(query: "moitié").first { $0.id == "results" }?.items.prefix(4).map(\.id) ?? []
        check(Set(halves) == ["command:window.leftHalf", "command:window.rightHalf", "command:window.topHalf", "command:window.bottomHalf"], "« moitié » trouve les quatre moitiés")
        let sixths = RootScreen().sections(query: "sixième").first { $0.id == "results" }?.items.prefix(6).map(\.id) ?? []
        check(sixths.allSatisfy { $0.hasSuffix("Sixth") } && sixths.count == 6, "« sixième » trouve les six sixièmes")
        let english = RootScreen().sections(query: "top left quarter").first { $0.id == "results" }?.items.first?.id
        check(english == "command:window.topLeftQuarter", "recherche en anglais : « top left quarter »")
    }
}
