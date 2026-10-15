import AppKit
import AudioToolbox
import CoreAudio
import CoreMediaIO

/// Le son par Core Audio, sur les périphériques par défaut ; AppleScript en secours
/// (certaines sorties, comme le HDMI, n'exposent pas de volume logiciel).
enum SystemAudio {
    // MARK: - Sortie

    /// Volume de sortie entre 0 et 1.
    static func outputVolume() -> Double? {
        guard let device = defaultDevice(input: false) else { return nil }
        if let value = float(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput) {
            return Double(value)
        }
        return float(device, kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput).map(Double.init)
    }

    @discardableResult
    static func setOutputVolume(_ volume: Double) -> Bool {
        let value = Float32(min(1, max(0, volume)))
        if let device = defaultDevice(input: false) {
            let done = setFloat(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput, value)
                || setFloat(device, kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, value)
            if done {
                // Comme les touches du clavier : régler le volume rétablit le son.
                if value > 0, isOutputMuted() == true { setOutputMuted(false) }
                return true
            }
        }
        SystemActions.osascript("set volume output volume \(Int((value * 100).rounded()))")
        return true
    }

    static func isOutputMuted() -> Bool? {
        guard let device = defaultDevice(input: false) else { return nil }
        return uint(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput).map { $0 != 0 }
    }

    static func setOutputMuted(_ muted: Bool) {
        if let device = defaultDevice(input: false),
           setUInt(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, muted ? 1 : 0) {
            return
        }
        SystemActions.osascript("set volume output muted \(muted)")
    }

    // MARK: - Entrée (micro)

    static func inputVolume() -> Double? {
        guard let device = defaultDevice(input: true) else { return nil }
        if let value = float(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeInput) {
            return Double(value)
        }
        return float(device, kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput).map(Double.init)
    }

    static func setInputVolume(_ volume: Double) {
        let value = Float32(min(1, max(0, volume)))
        if let device = defaultDevice(input: true),
           setFloat(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeInput, value)
            || setFloat(device, kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput, value) {
            return
        }
        SystemActions.osascript("set volume input volume \(Int((value * 100).rounded()))")
    }

    /// Un micro est-il en cours d'utilisation par une application (appel, enregistrement) ?
    static func isMicrophoneInUse() -> Bool {
        guard let device = defaultDevice(input: true) else { return false }
        return uint(device, kAudioDevicePropertyDeviceIsRunningSomewhere, scope: kAudioObjectPropertyScopeGlobal).map { $0 != 0 } ?? false
    }

    /// Une caméra est-elle allumée (visioconférence, enregistrement) ?
    static func isCameraInUse() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == noErr else { return false }
        for device in devices {
            var running = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
            )
            var value: UInt32 = 0
            var valueSize = UInt32(MemoryLayout<UInt32>.size)
            if CMIOObjectGetPropertyData(device, &running, 0, nil, valueSize, &valueSize, &value) == noErr, value != 0 {
                return true
            }
        }
        return false
    }

    // MARK: - Core Audio

    private static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func float(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> Float32? {
        var address = address(selector, scope)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func setFloat(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope, _ value: Float32) -> Bool {
        var address = address(selector, scope)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        var value = value
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    private static func uint(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> UInt32? {
        var address = address(selector, scope)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func setUInt(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope, _ value: UInt32) -> Bool {
        var address = address(selector, scope)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        var value = value
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}

/// Le calcul du volume : pas de 1/16 (6,25 %) comme les touches du clavier, saisie en pourcentage.
enum VolumeMath {
    static let step = 1.0 / 16

    /// Le cran suivant ou précédent, aligné sur la grille des 16 crans.
    static func stepped(_ current: Double, up: Bool) -> Double {
        let index = (current / step).rounded()
        return min(1, max(0, (index + (up ? 1 : -1)) * step))
    }

    static func percent(_ volume: Double) -> Int { Int((volume * 100).rounded()) }

    /// « 50 », « 50 % », « 50% » : un volume entre 0 et 1, ou `nil` hors de 0–100.
    static func parse(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), (0...100).contains(value) else { return nil }
        return value / 100
    }

    /// Le symbole du haut-parleur selon le niveau.
    static func symbol(_ volume: Double, muted: Bool = false) -> String {
        if muted || volume <= 0 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

/// Les touches multimédia (lecture, piste suivante…), simulées comme celles du clavier :
/// elles pilotent l'app qui a la main sur la lecture (Musique, Spotify, un onglet du navigateur).
enum MediaKeys {
    static let play: Int = 16      // NX_KEYTYPE_PLAY
    static let next: Int = 17      // NX_KEYTYPE_NEXT
    static let previous: Int = 18  // NX_KEYTYPE_PREVIOUS

    /// Le champ `data1` de l'évènement `systemDefined` (sous-type 8) : touche, puis état (0xA enfoncée, 0xB relâchée).
    static func data1(key: Int, down: Bool) -> Int {
        (key << 16) | ((down ? 0xA : 0xB) << 8)
    }

    static func press(_ key: Int) {
        for down in [true, false] {
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1(key: key, down: down),
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
