import AppKit
import SwiftUI

/// Petite pastille de confirmation en bas de l'écran (« Copié dans le presse-papiers »), comme Raycast.
@MainActor
final class HUD {
    static let shared = HUD()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, symbol: String = "checkmark.circle.fill") {
        let hosting = NSHostingView(rootView: HUDView(text: text, symbol: symbol))
        let size = hosting.fittingSize
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = hosting

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrame(
                NSRect(x: area.midX - size.width / 2, y: area.minY + area.height * 0.12, width: size.width, height: size.height),
                display: true
            )
        }
        hideWork?.cancel()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                panel?.animator().alphaValue = 0
            }, completionHandler: {
                panel?.orderOut(nil)
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }
}

private struct HUDView: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.green)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.82))
                .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(16)
    }
}

/// Icônes Finder mises en cache : `NSWorkspace.icon(forFile:)` coûte à chaque appel.
@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 64, height: 64)
        cache[path] = image
        return image
    }
}
