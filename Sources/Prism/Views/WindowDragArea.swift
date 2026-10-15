import AppKit
import SwiftUI

/// Une zone qui déplace une fenêtre sans barre de titre (notes, lanceur), placée derrière une barre.
/// Double-clic : le zoom de la fenêtre, comme une barre de titre, ou l'action donnée.
struct WindowDragArea: NSViewRepresentable {
    var onDoubleClick: (@MainActor (NSWindow) -> Void)?

    final class DragView: NSView {
        var onDoubleClick: (@MainActor (NSWindow) -> Void)?
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                if let onDoubleClick { onDoubleClick(window) } else { window.performZoom(nil) }
            } else {
                window.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) { nsView.onDoubleClick = onDoubleClick }
}
