import AppKit

/// L'icône de Prism : un prisme qui décompose un rayon de lumière, sur un carré sombre arrondi.
/// Dessinée en code pour servir à la fois à l'icône de l'app (`--render-icon`) et au logo de l'interface.
enum IconRenderer {
    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
    }

    static func draw(in rect: NSRect) {
        let s = rect.width
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }
        func lerp(_ a: NSPoint, _ b: NSPoint, _ t: CGFloat) -> NSPoint {
            NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }

        // Grille des icônes macOS : un corps de 824 sur 1024, centré.
        let inset = s * 100 / 1024
        let body = rect.insetBy(dx: inset, dy: inset)
        let radius = body.width * 0.225
        let squircle = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = s * 0.025
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
        shadow.set()
        NSColor.black.setFill()
        squircle.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(colors: [
            NSColor(srgbRed: 0.22, green: 0.22, blue: 0.26, alpha: 1),
            NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1),
        ])?.draw(in: squircle, angle: -90)

        NSGraphicsContext.saveGraphicsState()
        squircle.addClip()

        // Halo coloré discret derrière le prisme.
        let glow = NSGradient(colors: [
            NSColor(srgbRed: 1.0, green: 0.36, blue: 0.42, alpha: 0.30),
            NSColor(srgbRed: 1.0, green: 0.36, blue: 0.42, alpha: 0.0),
        ])
        glow?.draw(fromCenter: p(0.56, 0.48), radius: 0, toCenter: p(0.56, 0.48), radius: s * 0.42, options: [])

        let top = p(0.47, 0.71)
        let left = p(0.285, 0.375)
        let right = p(0.655, 0.375)
        let entry = lerp(left, top, 0.45)
        let exit = lerp(right, top, 0.52)

        // Le spectre : six bandes qui partent de la face droite.
        let colors: [NSColor] = [
            NSColor(srgbRed: 1.00, green: 0.27, blue: 0.33, alpha: 1),
            NSColor(srgbRed: 1.00, green: 0.55, blue: 0.20, alpha: 1),
            NSColor(srgbRed: 1.00, green: 0.84, blue: 0.25, alpha: 1),
            NSColor(srgbRed: 0.30, green: 0.85, blue: 0.45, alpha: 1),
            NSColor(srgbRed: 0.25, green: 0.60, blue: 1.00, alpha: 1),
            NSColor(srgbRed: 0.62, green: 0.38, blue: 1.00, alpha: 1),
        ]
        let edgeX: CGFloat = 0.95
        let spreadTop: CGFloat = 0.60
        let spreadBottom: CGFloat = 0.30
        let band = (spreadTop - spreadBottom) / CGFloat(colors.count)
        for (index, color) in colors.enumerated() {
            let y0 = spreadTop - CGFloat(index) * band
            let y1 = y0 - band
            let path = NSBezierPath()
            path.move(to: lerp(exit, top, -0.01 * CGFloat(index)))
            path.line(to: p(edgeX, y0))
            path.line(to: p(edgeX, y1))
            path.close()
            let gradient = NSGradient(colors: [color.withAlphaComponent(0.95), color.withAlphaComponent(0.55)])
            gradient?.draw(in: path, angle: 0)
        }

        // Le rayon blanc qui entre dans le prisme, avec sa lueur.
        NSGraphicsContext.saveGraphicsState()
        let beamGlow = NSShadow()
        beamGlow.shadowColor = NSColor.white.withAlphaComponent(0.8)
        beamGlow.shadowBlurRadius = s * 0.02
        beamGlow.set()
        let beam = NSBezierPath()
        beam.move(to: p(0.05, 0.43))
        beam.line(to: entry)
        beam.lineWidth = s * 0.018
        beam.lineCapStyle = .round
        NSColor.white.setStroke()
        beam.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // Réfraction à l'intérieur du prisme.
        let inner = NSBezierPath()
        inner.move(to: entry)
        inner.line(to: exit)
        inner.lineWidth = s * 0.012
        NSColor.white.withAlphaComponent(0.55).setStroke()
        inner.stroke()

        // Le prisme : verre légèrement teinté, arêtes claires.
        let prism = NSBezierPath()
        prism.move(to: top)
        prism.line(to: right)
        prism.line(to: left)
        prism.close()
        prism.lineJoinStyle = .round
        NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.20),
            NSColor.white.withAlphaComponent(0.04),
        ])?.draw(in: prism, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        let edgeGlow = NSShadow()
        edgeGlow.shadowColor = NSColor.white.withAlphaComponent(0.5)
        edgeGlow.shadowBlurRadius = s * 0.012
        edgeGlow.set()
        prism.lineWidth = s * 0.024
        NSColor.white.withAlphaComponent(0.95).setStroke()
        prism.stroke()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.restoreGraphicsState()

        // Liseré intérieur pour détacher l'icône des fonds sombres.
        let rim = NSBezierPath(roundedRect: body.insetBy(dx: s * 0.002, dy: s * 0.002), xRadius: radius, yRadius: radius)
        rim.lineWidth = s * 0.004
        NSColor.white.withAlphaComponent(0.10).setStroke()
        rim.stroke()
    }

    /// Icône monochrome de la barre des menus.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let s = rect.width
            let prism = NSBezierPath()
            prism.move(to: NSPoint(x: s * 0.46, y: s * 0.86))
            prism.line(to: NSPoint(x: s * 0.80, y: s * 0.22))
            prism.line(to: NSPoint(x: s * 0.12, y: s * 0.22))
            prism.close()
            prism.lineWidth = 1.6
            prism.lineJoinStyle = .round
            NSColor.black.setStroke()
            prism.stroke()
            let ray = NSBezierPath()
            ray.move(to: NSPoint(x: s * 0.62, y: s * 0.52))
            ray.line(to: NSPoint(x: s * 0.98, y: s * 0.62))
            ray.move(to: NSPoint(x: s * 0.64, y: s * 0.46))
            ray.line(to: NSPoint(x: s * 0.98, y: s * 0.44))
            ray.lineWidth = 1.3
            ray.lineCapStyle = .round
            ray.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Écrit le jeu d'icônes attendu par `iconutil`.
    static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = base * scale
                guard let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                ) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
                NSGraphicsContext.restoreGraphicsState()
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
            }
        }
    }
}
