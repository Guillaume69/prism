import AppKit

extension NSAttributedString.Key {
    /// Bloc dessiné derrière le texte : « code », « quote » ou « rule ».
    static let notesBlock = NSAttributedString.Key("PrismNotesBlock")
    /// Code en ligne, sur un fond arrondi.
    static let notesInlineCode = NSAttributedString.Key("PrismNotesInlineCode")
    /// Case d'une tâche (« [ ] »), cochée ou non.
    static let notesCheckbox = NSAttributedString.Key("PrismNotesCheckbox")
    /// Tiret d'une liste à puces, dessiné en point.
    static let notesBullet = NSAttributedString.Key("PrismNotesBullet")
    /// Adresse d'un lien, ouverte par ⌘-clic.
    static let notesLink = NSAttributedString.Key("PrismNotesLink")
}

/// La mise en forme Markdown en direct : la syntaxe reste du texte, stylée ou atténuée.
@MainActor
enum NotesHighlighter {
    static func apply(to storage: NSTextStorage, style: NotesStyle) {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        guard full.length > 0 else { return }
        let body = style.bodyFont()
        let lineSpacing = (style.baseSize * 0.28).rounded()
        let base = NSMutableParagraphStyle()
        base.lineSpacing = lineSpacing
        base.paragraphSpacing = (style.baseSize * 0.3).rounded()
        storage.setAttributes([.font: body, .foregroundColor: style.text, .paragraphStyle: base], range: full)

        let lines = NotesMarkdown.lines(in: text)
        for (index, line) in lines.enumerated() {
            // Les attributs de paragraphe couvrent la ligne et son saut de ligne.
            let paragraph = NSRange(location: line.range.location, length: min(text.length, NSMaxRange(line.range) + 1) - line.range.location)
            guard paragraph.length > 0 else { continue }
            let markerEnd = NSMaxRange(line.marker)
            let content = NSRange(location: markerEnd, length: max(0, NSMaxRange(line.range) - markerEnd))

            // Les lignes repliées d'une liste s'alignent sur le texte, pas sur la puce.
            func hanging(_ width: CGFloat) {
                let indented = base.mutableCopy() as! NSMutableParagraphStyle
                indented.headIndent = width
                storage.addAttribute(.paragraphStyle, value: indented, range: paragraph)
            }
            func markerWidth() -> CGFloat {
                NSAttributedString(string: text.substring(with: line.marker), attributes: [.font: body]).size().width
            }

            switch line.kind {
            case .heading(let level):
                let scale: CGFloat = [1.6, 1.32, 1.14][min(level, 3) - 1]
                let font = style.bodyFont(scale: scale, weight: level == 1 ? .bold : .semibold)
                let heading = base.mutableCopy() as! NSMutableParagraphStyle
                heading.paragraphSpacingBefore = index == 0 ? 0 : (style.baseSize * (level == 1 ? 0.7 : 0.5)).rounded()
                heading.paragraphSpacing = (style.baseSize * 0.25).rounded()
                storage.addAttributes([.font: font, .paragraphStyle: heading], range: paragraph)
                storage.addAttribute(.foregroundColor, value: style.tertiary, range: line.marker)
            case .bullet:
                let dash = NSRange(location: line.marker.location + line.indent, length: 1)
                storage.addAttributes([.foregroundColor: NSColor.clear, .notesBullet: line.indent], range: dash)
                hanging(markerWidth())
            case .ordered:
                storage.addAttribute(.foregroundColor, value: style.secondary, range: line.marker)
                hanging(markerWidth())
            case .task(let checked):
                let dash = NSRange(location: line.marker.location + line.indent, length: 2)
                let box = NSRange(location: line.marker.location + line.indent + 2, length: 3)
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: dash)
                storage.addAttributes([.foregroundColor: NSColor.clear, .notesCheckbox: checked], range: box)
                if checked, content.length > 0 {
                    storage.addAttributes([
                        .foregroundColor: style.secondary,
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .strikethroughColor: style.tertiary,
                    ], range: content)
                }
                hanging(markerWidth())
            case .quote:
                let chevron = NSRange(location: line.marker.location + line.indent, length: 1)
                storage.addAttribute(.notesBlock, value: "quote", range: paragraph)
                storage.addAttribute(.foregroundColor, value: style.secondary, range: line.range)
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: chevron)
                hanging(markerWidth())
            case .fence, .code:
                let code = base.mutableCopy() as! NSMutableParagraphStyle
                let inset = (style.baseSize * 0.85).rounded()
                code.firstLineHeadIndent = inset
                code.headIndent = inset
                code.tailIndent = -inset
                code.lineSpacing = (style.baseSize * 0.18).rounded()
                code.paragraphSpacing = 0
                if line.kind == .fence {
                    if isOpening(lines, index) {
                        code.paragraphSpacingBefore = (style.baseSize * 0.6).rounded()
                    } else {
                        code.paragraphSpacing = (style.baseSize * 0.7).rounded()
                    }
                }
                storage.addAttributes([
                    .font: style.codeFont(),
                    .paragraphStyle: code,
                    .notesBlock: "code",
                    .foregroundColor: line.kind == .fence ? style.tertiary : style.text,
                ], range: paragraph)
            case .rule:
                storage.addAttributes([.foregroundColor: NSColor.clear, .notesBlock: "rule"], range: line.range)
            case .paragraph, .blank:
                break
            }

            switch line.kind {
            case .code, .fence, .rule, .blank:
                continue
            default:
                applyInline(to: storage, text: text, range: content, style: style)
            }
        }
    }

    /// Le bloc de code qui commence à la ligne `index` s'ouvre-t-il ici ?
    private static func isOpening(_ lines: [NoteLine], _ index: Int) -> Bool {
        lines[...index].filter { $0.kind == .fence }.count % 2 == 1
    }

    private static func applyInline(to storage: NSTextStorage, text: NSString, range: NSRange, style: NotesStyle) {
        guard range.length > 0 else { return }
        for span in NotesMarkdown.inlineSpans(in: text, range: range) {
            switch span.kind {
            case .bold:
                transformFont(storage, span.content) { $0.adding(.bold) }
            case .italic:
                transformFont(storage, span.content) { $0.adding(.italic) }
            case .strike:
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: style.secondary], range: span.content)
            case .underline:
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: span.content)
            case .code:
                let size = (storage.attribute(.font, at: span.content.location, effectiveRange: nil) as? NSFont)?.pointSize ?? style.baseSize
                storage.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: (size * 0.88).rounded(), weight: .regular),
                    .notesInlineCode: true,
                ], range: NSUnionRange(span.content, NSUnionRange(span.markers[0], span.markers[1])))
            case .link(let url):
                storage.addAttributes([
                    .foregroundColor: style.accent,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: style.accent.withAlphaComponent(0.35),
                    .notesLink: url,
                ], range: span.content)
                for marker in span.markers { storage.addAttribute(.notesLink, value: url, range: marker) }
            }
            for marker in span.markers where marker.length > 0 {
                storage.addAttribute(.foregroundColor, value: style.tertiary, range: marker)
            }
        }
    }

    private static func transformFont(_ storage: NSTextStorage, _ range: NSRange, _ transform: (NSFont) -> NSFont) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            guard let font = value as? NSFont else { return }
            storage.addAttribute(.font, value: transform(font), range: subrange)
        }
    }
}

/// Dessine ce que le texte seul ne montre pas : fonds des blocs de code, barres des citations,
/// cases des tâches, puces et séparateurs.
final class NotesLayoutManager: NSLayoutManager {
    var style: NotesStyle?

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let style, let storage = textStorage, let container = textContainers.first else {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let whole = NSRange(location: 0, length: storage.length)

        // Sous la sélection : blocs de code et code en ligne.
        var drawnBlocks = Set<Int>()
        storage.enumerateAttribute(.notesBlock, in: characters) { value, range, _ in
            guard value as? String == "code" else { return }
            var block = NSRange()
            storage.attribute(.notesBlock, at: range.location, longestEffectiveRange: &block, in: whole)
            guard drawnBlocks.insert(block.location).inserted, let rect = usedRect(of: block, origin: origin) else { return }
            let lineRect = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: block.location), effectiveRange: nil)
            let box = NSRect(x: lineRect.minX + origin.x + 2, y: rect.minY - 4, width: lineRect.width - 4, height: rect.height + 8)
            let path = NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7)
            style.fill.setFill()
            path.fill()
            style.separator.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        storage.enumerateAttribute(.notesInlineCode, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? style.codeFont()
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                let baseline = self.baseline(ofGlyph: glyphs.location)
                let top = baseline - font.ascender - 1.5
                let height = font.ascender - font.descender + 3
                let box = NSRect(x: rect.minX + origin.x - 1, y: top + origin.y, width: rect.width + 2, height: height)
                style.fill.blended(withFraction: 0.5, of: style.separator)?.setFill()
                NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            }
        }

        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)

        // Au-dessus de la sélection : cases, puces, séparateurs, citations.
        storage.enumerateAttribute(.notesCheckbox, in: characters) { value, range, _ in
            guard let checked = value as? Bool else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = boundingRect(forGlyphRange: glyphs, in: container)
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? style.bodyFont()
            let side = (font.pointSize * 0.98).rounded()
            let centerY = baseline(ofGlyph: glyphs.location) - font.capHeight / 2 + origin.y
            let box = NSRect(x: (rect.midX + origin.x - side / 2).rounded(), y: (centerY - side / 2).rounded(), width: side, height: side)
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: side * 0.27, yRadius: side * 0.27)
            if checked {
                style.accent.setFill()
                path.fill()
                let check = NSBezierPath()
                check.move(to: NSPoint(x: box.minX + side * 0.26, y: box.minY + side * 0.53))
                check.line(to: NSPoint(x: box.minX + side * 0.43, y: box.minY + side * 0.70))
                check.line(to: NSPoint(x: box.minX + side * 0.75, y: box.minY + side * 0.32))
                check.lineWidth = max(1.5, side * 0.12)
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor.white.setStroke()
                check.stroke()
            } else {
                style.secondary.withAlphaComponent(0.75).setStroke()
                path.lineWidth = 1.3
                path.stroke()
            }
        }
        storage.enumerateAttribute(.notesBullet, in: characters) { value, range, _ in
            guard let indent = value as? Int else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = boundingRect(forGlyphRange: glyphs, in: container)
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? style.bodyFont()
            let diameter = max(4, (font.pointSize * 0.34).rounded())
            let centerY = baseline(ofGlyph: glyphs.location) - font.xHeight / 2 + origin.y
            let dot = NSRect(x: rect.midX + origin.x - diameter / 2, y: centerY - diameter / 2, width: diameter, height: diameter)
            let path = NSBezierPath(ovalIn: dot)
            if indent > 0 {
                style.secondary.setStroke()
                path.lineWidth = 1.2
                NSBezierPath(ovalIn: dot.insetBy(dx: 0.6, dy: 0.6)).stroke()
            } else {
                style.secondary.setFill()
                path.fill()
            }
        }
        storage.enumerateAttribute(.notesBlock, in: characters) { value, range, _ in
            guard let kind = value as? String, kind == "rule" || kind == "quote" else { return }
            guard let rect = usedRect(of: range, origin: origin) else { return }
            let lineRect = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: range.location), effectiveRange: nil)
            if kind == "rule" {
                let line = NSRect(x: lineRect.minX + origin.x + 4, y: (rect.midY).rounded() - 0.5, width: lineRect.width - 8, height: 1)
                style.separator.blended(withFraction: 0.4, of: style.tertiary)?.setFill()
                line.fill()
            } else {
                let glyph = boundingRect(forGlyphRange: glyphRange(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil), in: container)
                let bar = NSRect(x: glyph.minX + origin.x + 1, y: rect.minY + 1, width: 3, height: rect.height - 2)
                style.accent.withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }

    /// La ligne de base d'un glyphe, dans le repère du conteneur.
    private func baseline(ofGlyph glyph: Int) -> CGFloat {
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return fragment.minY + location(forGlyphAt: glyph).y
    }

    /// L'étendue verticale des lignes d'une plage, sans les espacements entre paragraphes.
    private func usedRect(of characters: NSRange, origin: NSPoint) -> NSRect? {
        let glyphs = glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        var result = NSRect.null
        enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            result = result.union(used)
        }
        guard !result.isNull else { return nil }
        return result.offsetBy(dx: origin.x, dy: origin.y)
    }
}

/// L'éditeur : un NSTextView en TextKit 1, pour dessiner les décorations du Markdown.
final class NotesTextView: NSTextView {
    var onToggleCheckbox: ((Int) -> Void)?
    var onOpenLink: ((String) -> Void)?
    var placeholder = "Commencez à écrire…"
    var placeholderColor = NSColor.tertiaryLabelColor

    static func make() -> NotesTextView {
        let storage = NSTextStorage()
        let layout = NotesLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = NotesTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.smartInsertDeleteEnabled = false
        view.textContainerInset = NSSize(width: 14, height: 10)
        return view
    }

    var notesLayoutManager: NotesLayoutManager? { layoutManager as? NotesLayoutManager }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = characterIndex(at: point), let storage = textStorage {
            if storage.attribute(.notesCheckbox, at: index, effectiveRange: nil) != nil {
                onToggleCheckbox?(index)
                return
            }
            if event.modifierFlags.contains(.command), let url = storage.attribute(.notesLink, at: index, effectiveRange: nil) as? String {
                onOpenLink?(url)
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// Le caractère exactement sous le pointeur (pas le plus proche).
    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.insetBy(dx: -2, dy: 0).contains(local) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        return index < storage.length ? index : nil
    }

    /// Une main au-dessus des cases à cocher.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return }
        let visible = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: visible, actualGlyphRange: nil)
        storage.enumerateAttribute(.notesCheckbox, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            addCursorRect(rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y), cursor: .pointingHand)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let font = typingAttributes[.font] as? NSFont ?? .systemFont(ofSize: 14)
        let padding = textContainer?.lineFragmentPadding ?? 5
        NSAttributedString(string: placeholder, attributes: [.font: font, .foregroundColor: placeholderColor])
            .draw(at: NSPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y))
    }
}
