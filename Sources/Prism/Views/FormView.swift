import AppKit
import SwiftUI

/// Un formulaire du lanceur, à la manière de Raycast : libellés à gauche, champs à droite, ⌘↵ pour valider.
struct FormScreenView: View {
    let screen: FormScreen
    @ObservedObject private var state: FormState
    @FocusState private var focused: String?

    init(screen: FormScreen) {
        self.screen = screen
        state = screen.state
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(screen.fields) { field in
                    row(field)
                }
                if let error = state.error {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                        Text(error)
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.red)
                    .padding(.leading, labelWidth + 14)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
        }
        .scrollIndicators(.never)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = screen.initialFocus }
        }
    }

    private let labelWidth: CGFloat = 150

    @ViewBuilder
    private func row(_ field: FormField) -> some View {
        HStack(alignment: alignment(for: field), spacing: 14) {
            Text(field.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
                .padding(.top, isTall(field) ? 6 : 0)
            VStack(alignment: .leading, spacing: 5) {
                control(field)
                if let info = field.info {
                    Text(info)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func isTall(_ field: FormField) -> Bool {
        if case .textArea = field.kind { return true }
        return false
    }

    private func alignment(for field: FormField) -> VerticalAlignment {
        isTall(field) || field.info != nil ? .top : .center
    }

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { state[id] }, set: { state[id] = $0; state.error = nil })
    }

    @ViewBuilder
    private func control(_ field: FormField) -> some View {
        switch field.kind {
        case .text:
            TextField(field.placeholder, text: binding(field.id))
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($focused, equals: field.id)
                .modifier(FieldBackground())
        case .secure:
            SecureField(field.placeholder, text: binding(field.id))
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($focused, equals: field.id)
                .modifier(FieldBackground())
        case .textArea(let lines):
            TextEditor(text: binding(field.id))
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .focused($focused, equals: field.id)
                .frame(height: CGFloat(lines) * 18 + 12)
                .modifier(FieldBackground(padding: 4))
        case .dropdown(let options):
            Picker("", selection: binding(field.id)) {
                ForEach(options, id: \.value) { option in
                    Text(option.title).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        case .checkbox(let label):
            Toggle(label, isOn: Binding(get: { state.bool(field.id) }, set: { state[field.id] = $0 ? "true" : "false" }))
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
        case .date(let includesTime):
            DatePicker("", selection: Binding(
                get: { ISO8601DateFormatter().date(from: state[field.id]) ?? Date() },
                set: { state[field.id] = ISO8601DateFormatter().string(from: $0) }
            ), displayedComponents: includesTime ? [.date, .hourAndMinute] : [.date])
            .labelsHidden()
            .datePickerStyle(.field)
            .fixedSize()
        case .info:
            Text(field.value)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .hotkey:
            HotkeyRecorder(value: binding(field.id))
                .frame(width: 200, height: 28)
        case .color:
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: NSColor(hex: state[field.id]) ?? .systemBlue) },
                set: { state[field.id] = NSColor($0).hexString }
            ), supportsOpacity: false)
            .labelsHidden()
        }
    }
}

private struct FieldBackground: ViewModifier {
    var padding: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, padding)
            .padding(.vertical, padding == 8 ? 6 : padding)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.keycap))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.separator))
    }
}

/// Enregistre un raccourci : cliquer, puis appuyer sur la combinaison. ⌫ efface.
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var value: String

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onChange = { value = $0 }
        view.value = value
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onChange = { value = $0 }
        if view.value != value {
            view.value = value
            view.needsDisplay = true
        }
    }

    final class RecorderView: NSView {
        var value = ""
        var onChange: ((String) -> Void)?
        private var isRecording = false

        override var acceptsFirstResponder: Bool { true }
        override var focusRingMaskBounds: NSRect { bounds }

        override func drawFocusRingMask() {
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            isRecording = true
            needsDisplay = true
        }

        override func becomeFirstResponder() -> Bool {
            isRecording = true
            needsDisplay = true
            return true
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            needsDisplay = true
            return true
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording, window?.firstResponder === self else { return false }
            keyDown(with: event)
            return true
        }

        private var detector = ModifierTap.Detector()

        /// Double appui sur ⌘, ⌥, ⌃ ou ⇧ : un raccourci à lui seul, comme dans Raycast.
        override func flagsChanged(with event: NSEvent) {
            guard isRecording else { return super.flagsChanged(with: event) }
            if let modifier = detector.flagsChanged(event.modifierFlags, at: event.timestamp) {
                value = HotkeyCoding.encode(Hotkey.doubleTap(modifier))
                onChange?(value)
                needsDisplay = true
            }
        }

        override func keyDown(with event: NSEvent) {
            detector.keyDown()
            guard isRecording else { return super.keyDown(with: event) }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if flags.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
                value = ""
                onChange?("")
            } else if flags.isEmpty, event.keyCode == 53 {
                window?.makeFirstResponder(nil)
                return
            } else {
                let hotkey = Hotkey(event: event)
                value = HotkeyCoding.encode(hotkey)
                onChange?(value)
            }
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.labelColor.withAlphaComponent(0.06)).setFill()
            path.fill()
            (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.stroke()
            let text: String
            if let hotkey = HotkeyCoding.decode(value) {
                text = hotkey.symbols.joined(separator: " ")
            } else {
                text = isRecording ? "Raccourci, ou double appui sur ⌘ ⌥ ⌃ ⇧…" : "Cliquez pour enregistrer"
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                .foregroundColor: HotkeyCoding.decode(value) == nil ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        }
    }
}
