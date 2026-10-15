import AppKit
import SwiftUI

/// La pilule flottante de la dictée : onde du micro, transcription en direct, minuteur.
struct DictationPillView: View {
    static let pillSize = CGSize(width: 440, height: 50)
    /// La marge laisse la place à l'ombre.
    static let panelSize = CGSize(width: pillSize.width + 40, height: pillSize.height + 40)

    @ObservedObject var model: DictationPillModel
    var onTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            leading
            transcript
            trailing
        }
        .padding(.horizontal, 16)
        .frame(width: Self.pillSize.width, height: Self.pillSize.height)
        .background(
            Capsule(style: .circular)
                .fill(Color.black.opacity(0.86))
                .overlay(Capsule(style: .circular).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .contentShape(Capsule())
        .onTapGesture(perform: onTap)
        .environment(\.colorScheme, .dark)
        .help("Cliquez ou appuyez de nouveau sur le raccourci pour valider, Échap pour annuler")
    }

    @ViewBuilder
    private var leading: some View {
        switch model.phase {
        case .processing:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
                .frame(width: 18)
        case .starting, .recording:
            RecordingDot()
        }
        Waveform(levels: model.levels, isActive: model.phase == .recording)
            .frame(width: 92, height: 26)
            .opacity(model.phase == .recording ? 1 : 0.35)
    }

    private var transcript: some View {
        Group {
            switch model.phase {
            case .processing(let label):
                Text(label)
                    .foregroundStyle(.white.opacity(0.75))
            case .starting, .recording:
                if model.transcript.isEmpty {
                    Text(model.isNote ? "Dictez votre note…" : "Parlez…")
                        .foregroundStyle(.white.opacity(0.45))
                } else {
                    Text(model.transcript)
                        .foregroundStyle(.white.opacity(0.92))
                        .truncationMode(.head)
                }
            }
        }
        .font(.system(size: 13, weight: .medium))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var trailing: some View {
        if model.style != .standard || model.isNote {
            Text(model.isNote ? "Note" : model.style.title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(Color.white.opacity(0.12)))
        }
        Text(DictationStats.clock(model.elapsed))
            .font(.system(size: 12.5, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.6))
    }
}

/// Point rouge qui pulse pendant l'enregistrement.
private struct RecordingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Palette.red)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(Palette.red.opacity(0.45), lineWidth: 4).scaleEffect(pulse ? 1.9 : 1).opacity(pulse ? 0 : 1))
            .frame(width: 18)
            .onAppear {
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true }
            }
    }
}

/// Onde du micro : les derniers niveaux, en barres symétriques arrondies.
private struct Waveform: View {
    let levels: [CGFloat]
    let isActive: Bool

    var body: some View {
        GeometryReader { geometry in
            let count = max(levels.count, 1)
            let spacing: CGFloat = 1.5
            let width = max(1.5, (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    // Les barres du bord s'atténuent, comme une onde qui défile.
                    let edge = min(CGFloat(index + 1), CGFloat(count - index)) / 4
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.35 + 0.6 * min(1, edge)))
                        .frame(width: width, height: max(3, geometry.size.height * min(1, level * 1.15)))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(isActive ? .linear(duration: 0.08) : nil, value: levels)
        }
    }
}

/// `Prism --snapshot-dictation sortie.png [--light]` : rendu hors écran de la pilule (enregistrement, style, traitement),
/// sans micro ni autorisation.
@MainActor
enum DictationPillSnapshot {
    static func run(arguments: [String]) -> Int32 {
        guard let index = arguments.firstIndex(of: "--snapshot-dictation"), index + 1 < arguments.count else { return 1 }
        let output = arguments[index + 1]
        let dark = !arguments.contains("--light")
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        func model(_ configure: (DictationPillModel) -> Void) -> DictationPillModel {
            let model = DictationPillModel()
            let count = DictationPillModel.barCount
            model.levels = (0..<count).map { index in
                let x = Double(index)
                let wave = abs(sin(x * 0.55) * 0.55 + sin(x * 1.7) * 0.3)
                return CGFloat(wave) * (0.4 + 0.6 * CGFloat(index) / CGFloat(count))
            }
            configure(model)
            return model
        }
        let recording = model {
            $0.phase = .recording
            $0.elapsed = 42
            $0.transcript = "Bonjour à tous, je voulais vous proposer de décaler la réunion de demain à quinze heures"
        }
        let email = model {
            $0.phase = .recording
            $0.elapsed = 7
            $0.style = .email
        }
        let processing = model {
            $0.phase = .processing("Nettoyage par l’IA…")
            $0.elapsed = 65
            $0.style = .message
        }

        let size = NSSize(width: 620, height: 3 * DictationPillView.panelSize.height + 40)
        let content = VStack(spacing: 0) {
            DictationPillView(model: recording)
            DictationPillView(model: email)
            DictationPillView(model: processing)
        }
        .frame(width: size.width, height: size.height)
        .background(
            LinearGradient(
                colors: dark
                    ? [Color(red: 0.16, green: 0.20, blue: 0.33), Color(red: 0.36, green: 0.18, blue: 0.30)]
                    : [Color(red: 0.62, green: 0.74, blue: 0.92), Color(red: 0.93, green: 0.78, blue: 0.84)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )

        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 1 }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        do {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        } catch {
            print("Écriture impossible : \(error)")
            return 1
        }
        print("✓ \(output)")
        return 0
    }
}
