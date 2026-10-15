import AppKit
@preconcurrency import AVFoundation
import Combine
import CoreImage
import SwiftUI

extension Notification.Name {
    /// Le lanceur vient d'être masqué : la caméra s'arrête.
    static let prismLauncherDidHide = Notification.Name("PrismLauncherDidHide")
}

/// La caméra de la commande « Caméra » : un aperçu en miroir, image par image, et des photos.
/// Les images passent par `AVCaptureVideoDataOutput` plutôt que par une couche d'aperçu :
/// le dernier cliché est alors toujours disponible pour la photo.
final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum State: Equatable { case idle, starting, running, denied, unavailable }

    @MainActor static let shared = CameraController()

    @MainActor @Published private(set) var frame: CGImage?
    @MainActor @Published private(set) var state: State = .idle
    @MainActor @Published var isMirrored = true
    @MainActor @Published private(set) var deviceName = ""

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.prism.camera")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var configured = false

    @MainActor
    func start() {
        guard state != .running, state != .starting else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            state = .starting
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    let camera = CameraController.shared
                    if granted { camera.run() } else { camera.state = .denied }
                }
            }
        default:
            state = .denied
        }
    }

    @MainActor
    func stop() {
        guard state == .running || state == .starting else { return }
        state = .idle
        frame = nil
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    @MainActor
    private func run() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            state = .unavailable
            return
        }
        state = .starting
        deviceName = device.localizedName
        queue.async { [self] in
            if !configured {
                session.beginConfiguration()
                session.sessionPreset = .high
                if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                    session.addInput(input)
                }
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(output) { session.addOutput(output) }
                session.commitConfiguration()
                configured = true
            }
            session.startRunning()
            let running = session.isRunning
            Task { @MainActor in
                let camera = CameraController.shared
                if camera.state == .starting { camera.state = running ? .running : .unavailable }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
        Task { @MainActor in
            let camera = CameraController.shared
            guard camera.state == .running || camera.state == .starting else { return }
            camera.frame = cgImage
        }
    }

    /// La photo : l'image affichée, retournée comme l'aperçu si le miroir est actif.
    @MainActor
    func photo() -> NSImage? {
        guard let frame else { return nil }
        return Self.image(from: frame, mirrored: isMirrored)
    }

    static func image(from frame: CGImage, mirrored: Bool) -> NSImage {
        let size = NSSize(width: frame.width, height: frame.height)
        // Retournée dans un contexte à la taille de l'image : sans le facteur Retina de `lockFocus`.
        guard mirrored,
              let context = CGContext(data: nil, width: frame.width, height: frame.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return NSImage(cgImage: frame, size: size)
        }
        context.translateBy(x: size.width, y: 0)
        context.scaleBy(x: -1, y: 1)
        context.draw(frame, in: CGRect(origin: .zero, size: size))
        guard let flipped = context.makeImage() else { return NSImage(cgImage: frame, size: size) }
        return NSImage(cgImage: flipped, size: size)
    }

    /// Les données PNG d'une photo.
    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Le nom de fichier d'une photo, comme macOS nomme les captures.
    static func fileName(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "yyyy-MM-dd 'à' HH.mm.ss"
        return "Photo \(formatter.string(from: date)).png"
    }
}

/// L'écran « Caméra » : l'aperçu en grand ; ↵ prend une photo, enregistrée avec les captures et copiée.
@MainActor
final class CameraScreen: LauncherScreen {
    private var hideObserver: NSObjectProtocol?
    private var stateObserver: AnyCancellable?

    init() {
        super.init(id: "camera", title: "Caméra", icon: .symbol("camera.fill", Palette.gray))
        layout = .custom
        hidesSearchField = true
    }

    override func didAppear() {
        // Le pied de page suit l'état de la caméra (démarrage, refus, appareil).
        stateObserver = CameraController.shared.$state.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.host?.screenStateChanged() }
        }
        CameraController.shared.start()
        hideObserver = NotificationCenter.default.addObserver(forName: .prismLauncherDidHide, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CameraController.shared.stop() }
        }
    }

    override func didDisappear() {
        CameraController.shared.stop()
        stateObserver = nil
        if let hideObserver { NotificationCenter.default.removeObserver(hideObserver) }
        hideObserver = nil
    }

    override func customView() -> AnyView { AnyView(CameraView(camera: CameraController.shared)) }

    override var footerTitle: String? {
        let camera = CameraController.shared
        switch camera.state {
        case .running: return camera.deviceName
        case .starting: return "Démarrage de la caméra…"
        case .denied: return "Accès à la caméra refusé"
        case .unavailable: return "Aucune caméra"
        case .idle: return nil
        }
    }

    override var screenActions: [ItemAction] {
        [
            ItemAction(title: "Prendre une photo", symbol: "camera.shutter.button", shortcut: KeyShortcut(keyCode: 36, modifiers: [], label: "↵")) {
                Self.takePhoto()
            },
            ItemAction(title: "Copier la photo", symbol: "doc.on.doc", shortcut: KeyShortcut(keyCode: 8, modifiers: [.command, .shift], label: "⇧⌘C")) {
                guard let image = CameraController.shared.photo() else { return .toast("Pas encore d’image") }
                Pasteboard.copy(image: image)
                return .hud("Photo copiée")
            },
            ItemAction(title: CameraController.shared.isMirrored ? "Désactiver le miroir" : "Activer le miroir", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", shortcut: KeyShortcut(keyCode: 46, modifiers: [.command], label: "⌘M")) {
                CameraController.shared.isMirrored.toggle()
                return .stay
            },
            ItemAction(title: "Réglages de confidentialité", symbol: "hand.raised") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") { NSWorkspace.shared.open(url) }
                return .close
            },
        ]
    }

    override func handleKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard event.keyCode == 36 || event.keyCode == 76, modifiers.isEmpty else { return false }
        host?.apply(Self.takePhoto())
        return true
    }

    override var customViewHandlesNavigation: Bool { true }

    static func takePhoto() -> ActionOutcome {
        guard let image = CameraController.shared.photo(), let data = CameraController.png(image) else {
            return .toast("Pas encore d’image")
        }
        let file = ScreenshotLibrary.systemLocation.appendingPathComponent(CameraController.fileName())
        do {
            try data.write(to: file)
        } catch {
            return .toast("Enregistrement impossible : \(error.localizedDescription)")
        }
        Pasteboard.copy(image: image)
        NSSound(named: "Grab")?.play()
        return .hud("Photo enregistrée et copiée")
    }
}

private struct CameraView: View {
    @ObservedObject var camera: CameraController

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
            if let frame = camera.frame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(x: camera.isMirrored ? -1 : 1, y: 1)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(message).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if camera.state == .starting { ProgressView().controlSize(.small) }
                }
                .padding(24)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(12)
    }

    private var symbol: String {
        switch camera.state {
        case .denied: return "video.slash"
        case .unavailable: return "video.badge.exclamationmark"
        default: return "video"
        }
    }

    private var message: String {
        switch camera.state {
        case .denied: return "Prism n’a pas accès à la caméra.\nAutorisez-le dans Réglages Système › Confidentialité et sécurité › Caméra."
        case .unavailable: return "Aucune caméra n’est disponible."
        default: return "Démarrage de la caméra…"
        }
    }
}

@MainActor
enum Camera {
    static var commands: [ResultItem] {
        [Command.screen("system.camera", "Caméra", subtitle: "Système", symbol: "camera.fill", color: Palette.gray,
                        keywords: ["camera", "webcam", "miroir", "mirror", "photo", "selfie", "facetime"]) { CameraScreen() }]
    }

    static func selfTest(_ check: (Bool, String) -> Void) {
        check(CameraController.fileName(at: Date(timeIntervalSince1970: 0)).hasPrefix("Photo 1970-01-01 à ") && CameraController.fileName().hasSuffix(".png"), "caméra : nom de la photo")
        // Une image 2×1 rouge puis bleue : le miroir doit inverser les deux pixels.
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 0, 255, 255]
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let frame = CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            check(false, "caméra : image d’essai")
            return
        }
        func firstPixelIsBlue(_ image: NSImage) -> Bool {
            guard let data = CameraController.png(image), let bitmap = NSBitmapImageRep(data: data), let color = bitmap.colorAt(x: 0, y: 0) else { return false }
            return color.blueComponent > 0.8 && color.redComponent < 0.2
        }
        check(!firstPixelIsBlue(CameraController.image(from: frame, mirrored: false)) && firstPixelIsBlue(CameraController.image(from: frame, mirrored: true)), "caméra : photo retournée en miroir")
        let mirroredPNG = CameraController.png(CameraController.image(from: frame, mirrored: true)).flatMap { NSBitmapImageRep(data: $0) }
        check(mirroredPNG?.pixelsWide == 2 && mirroredPNG?.pixelsHigh == 1, "caméra : photo à la résolution de la caméra")
    }
}
