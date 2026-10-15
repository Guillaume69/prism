import AppKit
import QuartzCore

/// Pour le plaisir : des confettis, comme la commande de Raycast. `prism://fun/confetti`.
@MainActor
enum FunFeature: PrismFeature {
    static var commands: [ResultItem] {
        [Command.run("fun.confetti", "Confettis", subtitle: "Amusement", symbol: "party.popper.fill", color: Palette.pink, keywords: ["confetti", "fete", "bravo", "celebrer", "celebrate"]) {
            // Laisse le lanceur disparaître avant la pluie.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Confetti.fire() }
            return .close
        }]
    }

    static func handle(url: URL) -> Bool {
        guard url.host == "fun" else { return false }
        switch url.path {
        case "/confetti":
            Confetti.fire()
            return true
        default:
            return false
        }
    }

    static func selfTest(_ check: (Bool, String) -> Void) {
        check(Confetti.colors.count >= 6, "confettis : \(Confetti.colors.count) couleurs")
        check(Confetti.cells(colors: Confetti.colors).count == Confetti.colors.count * 2, "confettis : rubans et pastilles de chaque couleur")
    }
}

/// Une fenêtre transparente sur tout l'écran courant, qui laisse passer les clics : deux canons, en bas
/// à gauche et à droite, tirent des confettis vers le haut ; ils retombent puis la fenêtre disparaît.
@MainActor
enum Confetti {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.38, blue: 0.38, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.66, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.84, blue: 0.25, alpha: 1),
        NSColor(srgbRed: 0.30, green: 0.82, blue: 0.48, alpha: 1),
        NSColor(srgbRed: 0.24, green: 0.62, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.62, green: 0.42, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.42, blue: 0.72, alpha: 1),
    ]

    private static var windows: [NSWindow] = []

    static func fire() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        window.contentView = view
        let size = screen.frame.size
        let cells = cells(colors: colors)
        // Deux canons : coordonnées du calque, origine en bas à gauche.
        let cannons: [(x: CGFloat, angle: CGFloat)] = [(0, .pi / 2 - 0.55), (size.width, .pi / 2 + 0.55)]
        var emitters: [CAEmitterLayer] = []
        for cannon in cannons {
            let emitter = CAEmitterLayer()
            emitter.frame = view.bounds
            emitter.emitterPosition = CGPoint(x: cannon.x, y: -10)
            emitter.emitterShape = .point
            emitter.emitterSize = CGSize(width: 1, height: 1)
            emitter.beginTime = CACurrentMediaTime()
            emitter.emitterCells = cells.map { cell in
                let copy = cell.copy() as? CAEmitterCell ?? cell
                copy.emissionLongitude = cannon.angle
                // Plus l'écran est haut, plus les confettis partent vite.
                copy.velocity = size.height * 1.45
                copy.velocityRange = size.height * 0.45
                return copy
            }
            view.layer?.addSublayer(emitter)
            emitters.append(emitter)
        }
        window.orderFrontRegardless()
        windows.append(window)

        // Une rafale courte, puis la chute ; la fenêtre s'efface au bout de 3,5 secondes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            emitters.forEach { $0.birthRate = 0 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.5
                window.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    window.orderOut(nil)
                    windows.removeAll { $0 === window }
                }
            })
        }
    }

    /// Pour chaque couleur, un ruban et une pastille ronde qui tournent en tombant.
    static func cells(colors: [NSColor]) -> [CAEmitterCell] {
        let ribbon = image(size: CGSize(width: 12, height: 6), round: false)
        let dot = image(size: CGSize(width: 8, height: 8), round: true)
        return colors.flatMap { color in
            [ribbon, dot].map { shape in
                let cell = CAEmitterCell()
                cell.contents = shape
                cell.color = color.cgColor
                cell.birthRate = 28
                cell.lifetime = 4.5
                cell.emissionRange = 0.42
                cell.yAcceleration = -1_100
                cell.xAcceleration = 0
                cell.spin = 3.5
                cell.spinRange = 8
                cell.scale = 1
                cell.scaleRange = 0.45
                cell.alphaSpeed = -0.12
                return cell
            }
        }
    }

    /// Une forme blanche, teintée par la couleur de la cellule.
    private static func image(size: CGSize, round: Bool) -> CGImage? {
        let scale: CGFloat = 2
        guard let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(NSColor.white.cgColor)
        let rect = CGRect(origin: .zero, size: size)
        if round {
            context.fillEllipse(in: rect)
        } else {
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            context.fillPath()
        }
        return context.makeImage()
    }
}
