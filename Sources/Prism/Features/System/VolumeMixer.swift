import AppKit
import CoreAudio

/// Le mixeur de volume par app (Volume Mixer de Raycast), par les « process taps » de Core Audio (macOS 14.2) :
/// le son de l'app est capté par un tap qui coupe sa sortie d'origine, puis rejoué sur la sortie active
/// avec le gain choisi. Le premier usage demande l'autorisation d'enregistrer l'audio.
struct AudioProcess: Identifiable, Equatable {
    var id: AudioObjectID
    var pid: pid_t
    var bundleID: String
    var isPlaying: Bool

    @MainActor var app: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
}

enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func objectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default fallback: T) -> T {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var result = fallback
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return fallback }
        return result
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var result: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr, let result else { return nil }
        return result.takeRetainedValue() as String
    }
}

/// Le contrôle d'une app : son tap, l'appareil agrégé qui le lit, et le gain appliqué.
final class AppAudioControl: @unchecked Sendable {
    let process: AudioProcess
    private(set) var gain: Float
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init(process: AudioProcess, gain: Float) {
        self.process = process
        self.gain = gain
    }

    func setGain(_ value: Float) { gain = max(0, min(1, value)) }

    /// Crée le tap et l'appareil agrégé, puis lance la lecture. `nil` si tout va bien, sinon le problème.
    func start() -> String? {
        guard #available(macOS 14.2, *) else { return "Il faut macOS 14.2 ou plus récent." }
        let description = CATapDescription(stereoMixdownOfProcesses: [process.id])
        description.uuid = UUID()
        description.name = "Prism \(process.bundleID)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr, tap != kAudioObjectUnknown else {
            return "macOS a refusé la capture du son : autorisez Prism dans Réglages Système › Confidentialité › Enregistrement audio."
        }
        tapID = tap
        let output: AudioObjectID = CoreAudioProperty.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, default: AudioObjectID(kAudioObjectUnknown))
        guard let outputUID = CoreAudioProperty.string(output, kAudioDevicePropertyDeviceUID) else {
            stop()
            return "Aucune sortie audio."
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Prism Mixeur",
            kAudioAggregateDeviceUIDKey: "app.prism.mixer." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device) == noErr else {
            stop()
            return "Création de l’appareil audio impossible."
        }
        aggregateID = device
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { [weak self] _, input, _, output, _ in
            guard let self else { return }
            Self.mix(input, into: output, gain: self.gain)
        }
        guard status == noErr, let procID, AudioDeviceStart(device, procID) == noErr else {
            stop()
            return "Lecture du son impossible."
        }
        return nil
    }

    /// Recopie le son capté vers la sortie, multiplié par le gain (float 32 bits, entrelacé ou non).
    static func mix(_ input: UnsafePointer<AudioBufferList>, into output: UnsafeMutablePointer<AudioBufferList>, gain: Float) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for (index, buffer) in outputs.enumerated() {
            guard let destination = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard !inputs.isEmpty, let source = inputs[min(index, inputs.count - 1)].mData?.assumingMemoryBound(to: Float.self) else {
                destination.update(repeating: 0, count: count)
                continue
            }
            let available = min(count, Int(inputs[min(index, inputs.count - 1)].mDataByteSize) / MemoryLayout<Float>.size)
            for sample in 0..<available { destination[sample] = source[sample] * gain }
            if available < count { (destination + available).update(repeating: 0, count: count - available) }
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }
}

@MainActor
enum VolumeMixer {
    /// Les réglages en cours, par identifiant de paquet (le gain 1 retire le contrôle).
    private static var controls: [String: AppAudioControl] = [:]

    /// Les processus audio connus de Core Audio, ceux qui jouent en tête.
    static func processes() -> [AudioProcess] {
        guard #available(macOS 14.2, *) else { return [] }
        let ids = CoreAudioProperty.objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        let own = ProcessInfo.processInfo.processIdentifier
        return ids.compactMap { id -> AudioProcess? in
            let pid: pid_t = CoreAudioProperty.value(id, kAudioProcessPropertyPID, default: -1)
            guard pid > 0, pid != own, let bundleID = CoreAudioProperty.string(id, kAudioProcessPropertyBundleID), !bundleID.isEmpty else { return nil }
            let running: UInt32 = CoreAudioProperty.value(id, kAudioProcessPropertyIsRunningOutput, default: 0)
            return AudioProcess(id: id, pid: pid, bundleID: bundleID, isPlaying: running != 0)
        }
        .sorted { $0.isPlaying && !$1.isPlaying }
    }

    static func gain(for bundleID: String) -> Float { controls[bundleID]?.gain ?? 1 }

    /// Règle le volume d'une app (0 : coupée, 1 : normal).
    static func setGain(_ gain: Float, for process: AudioProcess) -> String? {
        if gain >= 0.999 {
            controls[process.bundleID]?.stop()
            controls[process.bundleID] = nil
            return nil
        }
        if let control = controls[process.bundleID] {
            control.setGain(gain)
            return nil
        }
        let control = AppAudioControl(process: process, gain: gain)
        if let problem = control.start() { return problem }
        controls[process.bundleID] = control
        return nil
    }

    static func name(of process: AudioProcess) -> String {
        process.app?.localizedName ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: process.bundleID)?.deletingPathExtension().lastPathComponent ?? process.bundleID
    }

    /// Le processus audio de l'app active (ou de l'une de ses aides, comme les onglets d'un navigateur).
    static func frontmostProcess() -> AudioProcess? {
        guard let app = AppContext.previousApp, let bundle = app.bundleIdentifier else { return nil }
        let candidates = processes().filter { $0.pid == app.processIdentifier || $0.bundleID.hasPrefix(bundle) }
        return candidates.first { $0.isPlaying } ?? candidates.first
    }

    static func screen() -> LauncherScreen {
        ListScreen(
            id: "system.volume-mixer", title: "Mixeur de volume", placeholder: "Rechercher une app…", icon: .symbol("slider.vertical.3", Palette.pink),
            empty: { _ in ("speaker.slash", "Aucune app ne joue de son pour l’instant.") }
        ) { query in
            let normalized = query.normalizedForSearch
            var seen = Set<String>()
            let items = processes()
                .filter { seen.insert($0.bundleID).inserted }
                .filter { normalized.isEmpty || name(of: $0).normalizedForSearch.contains(normalized) }
                .map { process -> ResultItem in
                    let current = gain(for: process.bundleID)
                    let percent = Int((current * 100).rounded())
                    var actions: [ItemAction] = [
                        ItemAction(title: current == 0 ? "Rétablir le son" : "Couper le son", symbol: current == 0 ? "speaker.wave.2" : "speaker.slash") {
                            setGain(current == 0 ? 1 : 0, for: process).map { .toast($0) } ?? .refresh
                        },
                    ]
                    for level in [100, 75, 50, 25, 10] {
                        actions.append(ItemAction(title: "Volume à \(level) %", symbol: "speaker.wave.\(level >= 50 ? 3 : 1)", section: "Volume") {
                            setGain(Float(level) / 100, for: process).map { .toast($0) } ?? .refresh
                        })
                    }
                    let icon: ItemIcon = process.app?.bundleURL.map { .file($0.path) } ?? .symbol("app", Palette.gray)
                    return ResultItem(
                        id: "mixer:" + process.bundleID,
                        title: name(of: process),
                        subtitle: process.isPlaying ? "Joue du son" : nil,
                        icon: icon,
                        accessory: current == 0 ? "Coupé" : "\(percent) %",
                        usageKey: "",
                        actions: actions
                    )
                }
            return items.isEmpty ? [] : [ResultSection(id: "apps", title: "Apps audio", items: items)]
        }
    }

    static var commands: [ResultItem] {
        [
            Command.screen("system.volume-mixer", "Mixeur de volume", subtitle: "Son", symbol: "slider.vertical.3", color: Palette.pink,
                           keywords: ["volume mixer", "mixeur", "volume par app", "son", "audio"], screen: screen),
            Command.run("system.mute-active-app", "Couper le son de l’app active", subtitle: "Son", symbol: "speaker.slash.circle.fill", color: Palette.pink,
                        keywords: ["toggle active app mute", "muet", "app", "son"]) {
                guard let process = frontmostProcess() else { return .hud("L’app active ne joue pas de son") }
                let muted = gain(for: process.bundleID) == 0
                if let problem = setGain(muted ? 1 : 0, for: process) { return .hud(problem) }
                return .hud(muted ? "Son de \(name(of: process)) rétabli" : "Son de \(name(of: process)) coupé")
            },
            Command.run("system.active-app-volume-down", "Baisser le son de l’app active", subtitle: "Son", symbol: "speaker.wave.1.fill", color: Palette.pink,
                        keywords: ["active app volume down", "volume app", "baisser"]) {
                guard let process = frontmostProcess() else { return .hud("L’app active ne joue pas de son") }
                let target = max(0, gain(for: process.bundleID) - 0.1)
                if let problem = setGain(target, for: process) { return .hud(problem) }
                return .hud("\(name(of: process)) : \(Int((target * 100).rounded())) %")
            },
            Command.run("system.active-app-volume-up", "Monter le son de l’app active", subtitle: "Son", symbol: "speaker.wave.3.fill", color: Palette.pink,
                        keywords: ["active app volume up", "volume app", "monter"]) {
                guard let process = frontmostProcess() else { return .hud("L’app active ne joue pas de son") }
                let target = min(1, gain(for: process.bundleID) + 0.1)
                if let problem = setGain(target, for: process) { return .hud(problem) }
                return .hud("\(name(of: process)) : \(Int((target * 100).rounded())) %")
            },
        ]
    }
}
