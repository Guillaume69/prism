import AppKit

/// Un rangement calculé à partir de l'écran et du cadre actuel : moitiés, tiers, quarts, sixièmes,
/// agrandissements, déplacements, changement d'écran. L'identifiant brut devient « command:window.<brut> ».
enum WindowLayout: String, CaseIterable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
    case firstFourth, secondFourth, thirdFourth, lastFourth
    case topLeftQuarter, topRightQuarter, bottomLeftQuarter, bottomRightQuarter
    case topLeftSixth, topCenterSixth, topRightSixth, bottomLeftSixth, bottomCenterSixth, bottomRightSixth
    case maximize, maximizeHeight, maximizeWidth, almostMaximize, reasonableSize, center
    case makeLarger, makeSmaller
    case moveUp, moveDown, moveLeft, moveRight
    case nextDisplay, previousDisplay

    var title: String {
        switch self {
        case .leftHalf: "Moitié gauche"
        case .rightHalf: "Moitié droite"
        case .topHalf: "Moitié haute"
        case .bottomHalf: "Moitié basse"
        case .firstThird: "Premier tiers"
        case .centerThird: "Tiers central"
        case .lastThird: "Dernier tiers"
        case .firstTwoThirds: "Deux premiers tiers"
        case .lastTwoThirds: "Deux derniers tiers"
        case .firstFourth: "Premier quart"
        case .secondFourth: "Deuxième quart"
        case .thirdFourth: "Troisième quart"
        case .lastFourth: "Dernier quart"
        case .topLeftQuarter: "Quart supérieur gauche"
        case .topRightQuarter: "Quart supérieur droit"
        case .bottomLeftQuarter: "Quart inférieur gauche"
        case .bottomRightQuarter: "Quart inférieur droit"
        case .topLeftSixth: "Sixième supérieur gauche"
        case .topCenterSixth: "Sixième supérieur central"
        case .topRightSixth: "Sixième supérieur droit"
        case .bottomLeftSixth: "Sixième inférieur gauche"
        case .bottomCenterSixth: "Sixième inférieur central"
        case .bottomRightSixth: "Sixième inférieur droit"
        case .maximize: "Agrandir"
        case .maximizeHeight: "Agrandir en hauteur"
        case .maximizeWidth: "Agrandir en largeur"
        case .almostMaximize: "Presque plein écran"
        case .reasonableSize: "Taille raisonnable"
        case .center: "Centrer"
        case .makeLarger: "Augmenter la taille"
        case .makeSmaller: "Diminuer la taille"
        case .moveUp: "Déplacer en haut"
        case .moveDown: "Déplacer en bas"
        case .moveLeft: "Déplacer à gauche"
        case .moveRight: "Déplacer à droite"
        case .nextDisplay: "Écran suivant"
        case .previousDisplay: "Écran précédent"
        }
    }

    var symbol: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .topHalf: "rectangle.tophalf.filled"
        case .bottomHalf: "rectangle.bottomhalf.filled"
        case .firstThird: "rectangle.leftthird.inset.filled"
        case .centerThird: "rectangle.split.3x1.fill"
        case .lastThird: "rectangle.rightthird.inset.filled"
        case .firstTwoThirds: "rectangle.lefthalf.inset.filled"
        case .lastTwoThirds: "rectangle.righthalf.inset.filled"
        case .firstFourth: "rectangle.leadingthird.inset.filled"
        case .secondFourth, .thirdFourth: "rectangle.split.3x1"
        case .lastFourth: "rectangle.trailingthird.inset.filled"
        case .topLeftQuarter: "rectangle.inset.topleft.filled"
        case .topRightQuarter: "rectangle.inset.topright.filled"
        case .bottomLeftQuarter: "rectangle.inset.bottomleft.filled"
        case .bottomRightQuarter: "rectangle.inset.bottomright.filled"
        case .topLeftSixth, .topCenterSixth, .topRightSixth: "square.grid.3x2"
        case .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth: "square.grid.3x2.fill"
        case .maximize: "rectangle.fill"
        case .maximizeHeight: "rectangle.expand.vertical"
        case .maximizeWidth: "arrow.left.and.right"
        case .almostMaximize: "rectangle.inset.filled"
        case .reasonableSize: "aspectratio"
        case .center: "rectangle.center.inset.filled"
        case .makeLarger: "arrow.up.backward.and.arrow.down.forward.rectangle"
        case .makeSmaller: "arrow.down.right.and.arrow.up.left.rectangle"
        case .moveUp: "arrow.up.to.line"
        case .moveDown: "arrow.down.to.line"
        case .moveLeft: "arrow.left.to.line"
        case .moveRight: "arrow.right.to.line"
        case .nextDisplay: "rectangle.righthalf.inset.filled.arrow.right"
        case .previousDisplay: "rectangle.lefthalf.inset.filled.arrow.left"
        }
    }

    /// Mots-clés anglais (ceux de Raycast) et français, sans accents.
    var keywords: [String] {
        switch self {
        case .leftHalf: ["left half", "moitie gauche", "gauche"]
        case .rightHalf: ["right half", "moitie droite", "droite"]
        case .topHalf: ["top half", "moitie haute", "haut"]
        case .bottomHalf: ["bottom half", "moitie basse", "bas"]
        case .firstThird: ["first third", "premier tiers", "tiers gauche"]
        case .centerThird: ["center third", "tiers central", "tiers milieu"]
        case .lastThird: ["last third", "dernier tiers", "tiers droit"]
        case .firstTwoThirds: ["first two thirds", "deux premiers tiers", "deux tiers gauche"]
        case .lastTwoThirds: ["last two thirds", "deux derniers tiers", "deux tiers droite"]
        case .firstFourth: ["first fourth", "first quarter", "premier quart"]
        case .secondFourth: ["second fourth", "second quarter", "deuxieme quart"]
        case .thirdFourth: ["third fourth", "third quarter", "troisieme quart"]
        case .lastFourth: ["last fourth", "last quarter", "dernier quart"]
        case .topLeftQuarter: ["top left quarter", "quart haut gauche", "coin haut gauche"]
        case .topRightQuarter: ["top right quarter", "quart haut droit", "coin haut droit"]
        case .bottomLeftQuarter: ["bottom left quarter", "quart bas gauche", "coin bas gauche"]
        case .bottomRightQuarter: ["bottom right quarter", "quart bas droit", "coin bas droit"]
        case .topLeftSixth: ["top left sixth", "sixieme haut gauche"]
        case .topCenterSixth: ["top center sixth", "sixieme haut centre", "sixieme haut milieu"]
        case .topRightSixth: ["top right sixth", "sixieme haut droit"]
        case .bottomLeftSixth: ["bottom left sixth", "sixieme bas gauche"]
        case .bottomCenterSixth: ["bottom center sixth", "sixieme bas centre", "sixieme bas milieu"]
        case .bottomRightSixth: ["bottom right sixth", "sixieme bas droit"]
        case .maximize: ["maximize", "maximiser", "plein ecran", "agrandir"]
        case .maximizeHeight: ["maximize height", "hauteur", "vertical"]
        case .maximizeWidth: ["maximize width", "largeur", "horizontal"]
        case .almostMaximize: ["almost maximize", "presque plein ecran", "presque agrandir"]
        case .reasonableSize: ["reasonable size", "taille raisonnable", "taille normale"]
        case .center: ["center", "centrer", "milieu"]
        case .makeLarger: ["make larger", "plus grand", "agrandir un peu"]
        case .makeSmaller: ["make smaller", "plus petit", "retrecir"]
        case .moveUp: ["move up", "monter", "haut"]
        case .moveDown: ["move down", "descendre", "bas"]
        case .moveLeft: ["move left", "gauche"]
        case .moveRight: ["move right", "droite"]
        case .nextDisplay: ["next display", "next screen", "ecran suivant", "moniteur"]
        case .previousDisplay: ["previous display", "previous screen", "ecran precedent", "moniteur"]
        }
    }

    /// La part de l'écran occupée, en fractions (x, y, largeur, hauteur ; y compté depuis le haut),
    /// pour les rangements en grille.
    var unitRect: CGRect? {
        let third = 1.0 / 3
        switch self {
        case .leftHalf: return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topHalf: return CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottomHalf: return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .firstThird: return CGRect(x: 0, y: 0, width: third, height: 1)
        case .centerThird: return CGRect(x: third, y: 0, width: third, height: 1)
        case .lastThird: return CGRect(x: 2 * third, y: 0, width: third, height: 1)
        case .firstTwoThirds: return CGRect(x: 0, y: 0, width: 2 * third, height: 1)
        case .lastTwoThirds: return CGRect(x: third, y: 0, width: 2 * third, height: 1)
        case .firstFourth: return CGRect(x: 0, y: 0, width: 0.25, height: 1)
        case .secondFourth: return CGRect(x: 0.25, y: 0, width: 0.25, height: 1)
        case .thirdFourth: return CGRect(x: 0.5, y: 0, width: 0.25, height: 1)
        case .lastFourth: return CGRect(x: 0.75, y: 0, width: 0.25, height: 1)
        case .topLeftQuarter: return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRightQuarter: return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeftQuarter: return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRightQuarter: return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .topLeftSixth: return CGRect(x: 0, y: 0, width: third, height: 0.5)
        case .topCenterSixth: return CGRect(x: third, y: 0, width: third, height: 0.5)
        case .topRightSixth: return CGRect(x: 2 * third, y: 0, width: third, height: 0.5)
        case .bottomLeftSixth: return CGRect(x: 0, y: 0.5, width: third, height: 0.5)
        case .bottomCenterSixth: return CGRect(x: third, y: 0.5, width: third, height: 0.5)
        case .bottomRightSixth: return CGRect(x: 2 * third, y: 0.5, width: third, height: 0.5)
        case .maximize: return CGRect(x: 0, y: 0, width: 1, height: 1)
        default: return nil
        }
    }

    /// Groupe de la liste « Rechercher les commandes de fenêtre ».
    var group: String {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: "Moitiés"
        case .firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds: "Tiers"
        case .firstFourth, .secondFourth, .thirdFourth, .lastFourth,
             .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter: "Quarts"
        case .topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth: "Sixièmes"
        case .maximize, .maximizeHeight, .maximizeWidth, .almostMaximize, .reasonableSize, .center, .makeLarger, .makeSmaller: "Taille"
        case .moveUp, .moveDown, .moveLeft, .moveRight: "Déplacement"
        case .nextDisplay, .previousDisplay: "Écrans"
        }
    }
}

/// « Moitié gauche » répétée sur une fenêtre déjà rangée ainsi.
enum RepeatHalfBehavior: String, CaseIterable {
    /// 1/2 → 2/3 → 1/3 → 1/2…
    case cycle
    /// La moitié opposée de l'écran voisin.
    case display
    case none

    var title: String {
        switch self {
        case .cycle: "Parcourir 1/2, 2/3 puis 1/3"
        case .display: "Passer à l’écran voisin"
        case .none: "Ne rien faire de plus"
        }
    }
}

/// Réglages qui influent sur les cadres calculés.
struct WindowOptions: Equatable {
    /// Écart entre les fenêtres et avec les bords de l'écran, en points.
    var gap: CGFloat = 0
    var repeatHalf: RepeatHalfBehavior = .none
    /// Place laissée à gauche pour la bande de Stage Manager (0 : aucune).
    var stageManagerMargin: CGFloat = 0
}

/// Une longueur en pourcentage de l'écran ou en points : « 50 % », « 800 », « -10% ».
struct WindowDimension: Codable, Equatable {
    enum Unit: String, Codable, CaseIterable {
        case percent, points

        var symbol: String { self == .percent ? "%" : "pt" }
    }

    var value: Double
    var unit: Unit

    static func percent(_ value: Double) -> WindowDimension { WindowDimension(value: value, unit: .percent) }
    static func points(_ value: Double) -> WindowDimension { WindowDimension(value: value, unit: .points) }

    func resolve(_ length: CGFloat) -> CGFloat {
        unit == .percent ? length * value / 100 : value
    }

    /// « 50 % », « 800 pt ».
    var label: String {
        let number = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
        return unit == .percent ? "\(number) %" : "\(number) pt"
    }

    /// Lit « 50% », « 50 % », « 800 », « 800pt », « 800 px », « -12,5 % ». Les points par défaut.
    static func parse(_ text: String, defaultUnit: Unit = .points) -> WindowDimension? {
        var text = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: ".")
        var unit = defaultUnit
        for (suffix, kind) in [("%", Unit.percent), ("pt", .points), ("px", .points)] where text.hasSuffix(suffix) {
            unit = kind
            text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        text = text.replacingOccurrences(of: "\u{2212}", with: "-")
        guard let value = Double(text), value.isFinite else { return nil }
        return WindowDimension(value: value, unit: unit)
    }
}

/// Les neuf points d'ancrage d'une commande personnalisée.
enum WindowAnchor: String, Codable, CaseIterable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    var title: String {
        switch self {
        case .topLeft: "En haut à gauche"
        case .top: "En haut au centre"
        case .topRight: "En haut à droite"
        case .left: "Au centre à gauche"
        case .center: "Au centre"
        case .right: "Au centre à droite"
        case .bottomLeft: "En bas à gauche"
        case .bottom: "En bas au centre"
        case .bottomRight: "En bas à droite"
        }
    }

    var symbol: String {
        switch self {
        case .topLeft: "rectangle.inset.topleft.filled"
        case .top: "rectangle.tophalf.inset.filled"
        case .topRight: "rectangle.inset.topright.filled"
        case .left: "rectangle.lefthalf.inset.filled"
        case .center: "rectangle.center.inset.filled"
        case .right: "rectangle.righthalf.inset.filled"
        case .bottomLeft: "rectangle.inset.bottomleft.filled"
        case .bottom: "rectangle.bottomhalf.inset.filled"
        case .bottomRight: "rectangle.inset.bottomright.filled"
        }
    }

    /// Colonne et ligne : 0, 0,5 ou 1.
    var unit: (x: CGFloat, y: CGFloat) {
        switch self {
        case .topLeft: (0, 0)
        case .top: (0.5, 0)
        case .topRight: (1, 0)
        case .left: (0, 0.5)
        case .center: (0.5, 0.5)
        case .right: (1, 0.5)
        case .bottomLeft: (0, 1)
        case .bottom: (0.5, 1)
        case .bottomRight: (1, 1)
        }
    }

    /// Lit « top-left », « topLeft », « top_left », « haut-gauche », « centre ».
    static func parse(_ text: String) -> WindowAnchor? {
        let key = text.normalizedForSearch.filter { $0.isLetter }
        let aliases: [String: WindowAnchor] = [
            "topleft": .topLeft, "hautgauche": .topLeft,
            "top": .top, "topcenter": .top, "haut": .top, "hautcentre": .top,
            "topright": .topRight, "hautdroite": .topRight, "hautdroit": .topRight,
            "left": .left, "centerleft": .left, "gauche": .left, "centregauche": .left,
            "center": .center, "centre": .center, "middle": .center, "milieu": .center,
            "right": .right, "centerright": .right, "droite": .right, "droit": .right, "centredroite": .right,
            "bottomleft": .bottomLeft, "basgauche": .bottomLeft,
            "bottom": .bottom, "bottomcenter": .bottom, "bas": .bottom, "bascentre": .bottom,
            "bottomright": .bottomRight, "basdroite": .bottomRight, "basdroit": .bottomRight,
        ]
        return aliases[key]
    }
}

/// La géométrie d'une commande personnalisée : taille, ancrage, décalage.
struct CustomWindowSpec: Codable, Equatable {
    var width: WindowDimension
    var height: WindowDimension
    var anchor: WindowAnchor
    var offsetX: WindowDimension = .percent(0)
    var offsetY: WindowDimension = .percent(0)

    /// « 50 % × 100 %, en haut à gauche, décalé de 10 % ».
    var summary: String {
        var text = "\(width.label) × \(height.label), \(anchor.title.lowercased())"
        if offsetX.value != 0 || offsetY.value != 0 {
            text += ", décalé de \(offsetX.label) ; \(offsetY.label)"
        }
        return text
    }
}

/// Les calculs de cadres, purs : tout se teste sans écran ni fenêtre.
/// Tout est exprimé dans le repère de l'accessibilité (origine en haut à gauche de l'écran principal, y vers le bas).
enum WindowGeometry {
    typealias Screen = (frame: CGRect, visible: CGRect)

    /// Cocoa (origine en bas à gauche) ⇄ accessibilité : la même opération dans les deux sens.
    static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Les écrans, convertis dans le repère de l'accessibilité.
    static func axScreens(_ screens: [Screen], primaryHeight: CGFloat) -> [Screen] {
        screens.map { (flip($0.frame, primaryHeight: primaryHeight), flip($0.visible, primaryHeight: primaryHeight)) }
    }

    /// L'écran qui contient la plus grande part de la fenêtre ; à défaut, le plus proche de son centre.
    static func screenIndex(for window: CGRect, in screens: [Screen]) -> Int? {
        guard !screens.isEmpty else { return nil }
        let areas = screens.map { $0.frame.intersection(window).surface }
        if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 { return best }
        let center = CGPoint(x: window.midX, y: window.midY)
        return screens.indices.min { distance(center, screens[$0].frame) < distance(center, screens[$1].frame) }
    }

    /// La zone où ranger : zone utile de l'écran, moins la bande de Stage Manager.
    static func workArea(_ visible: CGRect, options: WindowOptions) -> CGRect {
        var area = visible
        if options.stageManagerMargin > 0, options.stageManagerMargin < area.width / 2 {
            area.origin.x += options.stageManagerMargin
            area.size.width -= options.stageManagerMargin
        }
        return area
    }

    /// Une case de la grille, avec l'écart entre les cases et sur les bords.
    static func cell(_ unit: CGRect, in area: CGRect, gap: CGFloat) -> CGRect {
        let inner = area.insetBy(dx: gap, dy: gap)
        let x0 = inner.minX + unit.minX * (inner.width + gap)
        let x1 = inner.minX + unit.maxX * (inner.width + gap) - gap
        let y0 = inner.minY + unit.minY * (inner.height + gap)
        let y1 = inner.minY + unit.maxY * (inner.height + gap) - gap
        return rounded(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
    }

    /// Le cadre cible d'un rangement. `current` et le résultat sont dans le repère de l'accessibilité,
    /// `screens` dans celui de Cocoa (`NSScreen.frame` et `visibleFrame`).
    static func targetFrame(
        _ layout: WindowLayout,
        current: CGRect,
        screens cocoaScreens: [Screen],
        primaryHeight: CGFloat,
        options: WindowOptions = WindowOptions()
    ) -> CGRect {
        let screens = axScreens(cocoaScreens, primaryHeight: primaryHeight)
        guard let index = screenIndex(for: current, in: screens) else { return current }
        let visible = screens[index].visible
        let area = workArea(visible, options: options)
        let inner = area.insetBy(dx: options.gap, dy: options.gap)

        switch layout {
        case .leftHalf, .rightHalf:
            return half(layout == .leftHalf, current: current, screens: screens, index: index, options: options)
        case .center:
            let size = CGSize(width: min(current.width, inner.width), height: min(current.height, inner.height))
            return centered(size, in: inner)
        case .almostMaximize:
            return rounded(area.insetBy(dx: area.width * 0.05, dy: area.height * 0.05))
        case .reasonableSize:
            return centered(CGSize(width: min(area.width * 0.6, 1025), height: min(area.height * 0.6, 900)), in: area)
        case .maximizeHeight:
            let width = min(current.width, inner.width)
            return rounded(CGRect(x: clamp(current.minX, inner.minX, inner.maxX - width), y: inner.minY, width: width, height: inner.height))
        case .maximizeWidth:
            let height = min(current.height, inner.height)
            return rounded(CGRect(x: inner.minX, y: clamp(current.minY, inner.minY, inner.maxY - height), width: inner.width, height: height))
        case .moveUp, .moveDown, .moveLeft, .moveRight:
            let size = CGSize(width: min(current.width, inner.width), height: min(current.height, inner.height))
            var x = clamp(current.minX, inner.minX, inner.maxX - size.width)
            var y = clamp(current.minY, inner.minY, inner.maxY - size.height)
            switch layout {
            case .moveUp: y = inner.minY
            case .moveDown: y = inner.maxY - size.height
            case .moveLeft: x = inner.minX
            default: x = inner.maxX - size.width
            }
            return rounded(CGRect(origin: CGPoint(x: x, y: y), size: size))
        case .makeLarger, .makeSmaller:
            let sign: CGFloat = layout == .makeLarger ? 1 : -1
            let width = clamp(current.width + sign * inner.width * 0.1, min(240, inner.width), inner.width)
            let height = clamp(current.height + sign * inner.height * 0.1, min(160, inner.height), inner.height)
            let x = clamp(current.midX - width / 2, inner.minX, inner.maxX - width)
            let y = clamp(current.midY - height / 2, inner.minY, inner.maxY - height)
            return rounded(CGRect(x: x, y: y, width: width, height: height))
        case .nextDisplay, .previousDisplay:
            return otherDisplay(current: current, screens: screens, step: layout == .nextDisplay ? 1 : -1)
        default:
            guard let unit = layout.unitRect else { return current }
            return cell(unit, in: area, gap: options.gap)
        }
    }

    /// Moitié gauche ou droite, avec le comportement choisi quand on la répète.
    private static func half(_ left: Bool, current: CGRect, screens: [Screen], index: Int, options: WindowOptions) -> CGRect {
        let area = workArea(screens[index].visible, options: options)
        func part(_ fraction: CGFloat, in area: CGRect, left: Bool) -> CGRect {
            cell(CGRect(x: left ? 0 : 1 - fraction, y: 0, width: fraction, height: 1), in: area, gap: options.gap)
        }
        let halfFrame = part(0.5, in: area, left: left)
        switch options.repeatHalf {
        case .none:
            return halfFrame
        case .cycle:
            let steps: [CGFloat] = [0.5, 2.0 / 3, 1.0 / 3]
            if let position = steps.firstIndex(where: { matches(current, part($0, in: area, left: left)) }) {
                return part(steps[(position + 1) % steps.count], in: area, left: left)
            }
            return halfFrame
        case .display:
            guard matches(current, halfFrame), let neighbor = neighbor(of: index, in: screens, toLeft: left) else { return halfFrame }
            return part(0.5, in: workArea(screens[neighbor].visible, options: options), left: !left)
        }
    }

    /// L'écran voisin à gauche (ou à droite), le plus proche, qui chevauche verticalement.
    static func neighbor(of index: Int, in screens: [Screen], toLeft: Bool) -> Int? {
        let source = screens[index].frame
        let candidates = screens.indices.filter { other in
            guard other != index else { return false }
            let frame = screens[other].frame
            let beside = toLeft ? frame.midX < source.midX : frame.midX > source.midX
            return beside && frame.maxY > source.minY && frame.minY < source.maxY
        }
        return candidates.min { abs(screens[$0].frame.midX - source.midX) < abs(screens[$1].frame.midX - source.midX) }
    }

    /// L'écran suivant (de gauche à droite, puis de haut en bas), en gardant la place relative de la fenêtre.
    static func otherDisplay(current: CGRect, screens: [Screen], step: Int) -> CGRect {
        guard screens.count > 1, let source = screenIndex(for: current, in: screens) else { return current }
        let order = screens.indices.sorted {
            screens[$0].frame.minX == screens[$1].frame.minX ? screens[$0].frame.minY < screens[$1].frame.minY : screens[$0].frame.minX < screens[$1].frame.minX
        }
        guard let position = order.firstIndex(of: source) else { return current }
        let target = order[(position + step + order.count) % order.count]
        return transpose(current, from: screens[source].visible, to: screens[target].visible)
    }

    /// Même proportion, même place relative, d'une zone à l'autre ; la fenêtre reste dans la zone d'arrivée.
    static func transpose(_ frame: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        let relative = relativeFrame(frame, in: source)
        return absoluteFrame(relative, in: target)
    }

    /// Le cadre en fractions de la zone (0 à 1).
    static func relativeFrame(_ frame: CGRect, in area: CGRect) -> CGRect {
        guard area.width > 0, area.height > 0 else { return .zero }
        return CGRect(
            x: (frame.minX - area.minX) / area.width,
            y: (frame.minY - area.minY) / area.height,
            width: frame.width / area.width,
            height: frame.height / area.height
        )
    }

    /// Fractions → cadre, ramené dans la zone.
    static func absoluteFrame(_ relative: CGRect, in area: CGRect) -> CGRect {
        let width = min(relative.width * area.width, area.width)
        let height = min(relative.height * area.height, area.height)
        let x = clamp(area.minX + relative.minX * area.width, area.minX, area.maxX - width)
        let y = clamp(area.minY + relative.minY * area.height, area.minY, area.maxY - height)
        return rounded(CGRect(x: x, y: y, width: width, height: height))
    }

    /// Le cadre d'une commande personnalisée : taille, ancrage sur l'un des neuf points, puis décalage
    /// (positif : vers la droite et vers le bas).
    static func customFrame(
        _ spec: CustomWindowSpec,
        current: CGRect,
        screens cocoaScreens: [Screen],
        primaryHeight: CGFloat,
        options: WindowOptions = WindowOptions()
    ) -> CGRect {
        let screens = axScreens(cocoaScreens, primaryHeight: primaryHeight)
        guard let index = screenIndex(for: current, in: screens) else { return current }
        let inner = workArea(screens[index].visible, options: options).insetBy(dx: options.gap, dy: options.gap)
        let width = clamp(spec.width.resolve(inner.width), 1, inner.width)
        let height = clamp(spec.height.resolve(inner.height), 1, inner.height)
        let anchor = spec.anchor.unit
        let x = inner.minX + (inner.width - width) * anchor.x + spec.offsetX.resolve(inner.width)
        let y = inner.minY + (inner.height - height) * anchor.y + spec.offsetY.resolve(inner.height)
        return rounded(CGRect(x: x, y: y, width: width, height: height))
    }

    /// Deux cadres sont-ils le même rangement ? Tolérant pour les apps qui arrondissent leur taille
    /// (Terminal, éditeurs : par pas d'un caractère).
    static func matches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 4 && abs(lhs.minY - rhs.minY) <= 4
            && abs(lhs.width - rhs.width) <= 24 && abs(lhs.height - rhs.height) <= 24
    }

    static func centered(_ size: CGSize, in area: CGRect) -> CGRect {
        rounded(CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height))
    }

    /// Bords arrondis au point : deux fenêtres voisines ne se chevauchent pas.
    static func rounded(_ rect: CGRect) -> CGRect {
        let x0 = rect.minX.rounded(), y0 = rect.minY.rounded()
        return CGRect(x: x0, y: y0, width: rect.maxX.rounded() - x0, height: rect.maxY.rounded() - y0)
    }

    static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        high < low ? low : min(max(value, low), high)
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

extension CGRect {
    /// Aire, nulle pour un rectangle vide (`intersection` sans recouvrement).
    var surface: CGFloat { isNull || isEmpty ? 0 : width * height }
}
