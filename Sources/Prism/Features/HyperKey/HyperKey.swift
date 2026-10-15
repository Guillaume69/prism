import AppKit
import Carbon.HIToolbox
import IOKit.hidsystem
import SwiftUI

// MARK: - Réglages

/// La touche qui devient Hyper (⌃⌥⌘, et ⇧ si demandé).
enum HyperSourceKey: String, CaseIterable {
    case none, capsLock, rightCommand, rightOption, rightControl, rightShift, f18, f19

    var title: String {
        switch self {
        case .none: "Aucune"
        case .capsLock: "⇪ Verrouillage des majuscules"
        case .rightCommand: "⌘ Commande de droite"
        case .rightOption: "⌥ Option de droite"
        case .rightControl: "⌃ Contrôle de droite"
        case .rightShift: "⇧ Majuscule de droite"
        case .f18: "F18"
        case .f19: "F19"
        }
    }

    /// L'usage HID de la touche (page clavier 0x07), tel que `hidutil` l'attend.
    var hidUsage: UInt64? {
        switch self {
        case .none: nil
        case .capsLock: HyperKeyMapping.usage(0x39)
        case .rightCommand: HyperKeyMapping.usage(0xE7)
        case .rightOption: HyperKeyMapping.usage(0xE6)
        case .rightControl: HyperKeyMapping.usage(0xE4)
        case .rightShift: HyperKeyMapping.usage(0xE5)
        case .f18: nil // déjà la touche suivie : rien à remapper
        case .f19: HyperKeyMapping.usage(0x6E)
        }
    }
}

/// Ce que fait un appui bref, sans autre touche, sur Verr. Maj devenue Hyper.
enum HyperTapAction: String, CaseIterable {
    case nothing, escape, capsLock

    var title: String {
        switch self {
        case .nothing: "Rien"
        case .escape: "Échap"
        case .capsLock: "Verrouillage des majuscules"
        }
    }
}

@MainActor
final class HyperKeyPreferences: ObservableObject {
    static let shared = HyperKeyPreferences()
    private let defaults = UserDefaults.standard

    @Published var key: HyperSourceKey {
        didSet { defaults.set(key.rawValue, forKey: "hyper.key"); HyperKey.shared.apply() }
    }

    /// Ajoute ⇧ : la touche donne ⌃⌥⇧⌘ au lieu de ⌃⌥⌘.
    @Published var includeShift: Bool {
        didSet { defaults.set(includeShift, forKey: "hyper.includeShift") }
    }

    @Published var tapAction: HyperTapAction {
        didSet { defaults.set(tapAction.rawValue, forKey: "hyper.tapAction") }
    }

    private init() {
        key = HyperSourceKey(rawValue: defaults.string(forKey: "hyper.key") ?? "") ?? .none
        includeShift = defaults.bool(forKey: "hyper.includeShift")
        tapAction = HyperTapAction(rawValue: defaults.string(forKey: "hyper.tapAction") ?? "") ?? .escape
    }
}

// MARK: - Remappage (logique pure, testée sans rien appliquer)

/// Une entrée `UserKeyMapping` de `hidutil`.
struct KeyMappingEntry: Equatable, Codable {
    var source: UInt64
    var destination: UInt64
}

enum HyperKeyMapping {
    static let srcKey = "HIDKeyboardModifierMappingSrc"
    static let dstKey = "HIDKeyboardModifierMappingDst"
    /// F18 : la touche intermédiaire que Prism suit pendant l'appui.
    static let f18 = usage(0x6D)

    static func usage(_ code: UInt64) -> UInt64 { 0x7_0000_0000 | code }

    /// Lit la sortie de `hidutil property --get UserKeyMapping` : « (null) », un tableau au format plist OpenStep, ou du JSON.
    static func parse(_ output: String) -> [KeyMappingEntry] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "(null)", let data = trimmed.data(using: .utf8) else { return [] }
        let object = (try? PropertyListSerialization.propertyList(from: data, format: nil)) ?? (try? JSONSerialization.jsonObject(with: data))
        guard let array = object as? [[String: Any]] else { return [] }
        return array.compactMap { dictionary in
            guard let source = number(dictionary[srcKey]), let destination = number(dictionary[dstKey]) else { return nil }
            return KeyMappingEntry(source: source, destination: destination)
        }
    }

    private static func number(_ value: Any?) -> UInt64? {
        switch value {
        case let number as NSNumber: return number.uint64Value
        case let text as String:
            let cleaned = text.trimmingCharacters(in: .whitespaces)
            if cleaned.lowercased().hasPrefix("0x") { return UInt64(cleaned.dropFirst(2), radix: 16) }
            return UInt64(cleaned)
        default: return nil
        }
    }

    /// Les remappages existants, où seule l'entrée de la touche choisie est remplacée par « touche → F18 ».
    static func merged(existing: [KeyMappingEntry], source: UInt64?, previousSource: UInt64?) -> [KeyMappingEntry] {
        var result = existing.filter { entry in
            !(entry.destination == f18 && (entry.source == previousSource || entry.source == source)) && entry.source != source
        }
        if let source { result.append(KeyMappingEntry(source: source, destination: f18)) }
        return result
    }

    /// Retire l'entrée de Prism et remet celle qu'elle avait remplacée.
    static func restored(current: [KeyMappingEntry], prismSource: UInt64, replaced: KeyMappingEntry?) -> [KeyMappingEntry] {
        var result = current.filter { !($0.source == prismSource && $0.destination == f18) }
        if let replaced, !result.contains(where: { $0.source == replaced.source }) { result.append(replaced) }
        return result
    }

    /// Le JSON passé à `hidutil property --set`.
    static func json(_ entries: [KeyMappingEntry]) -> String {
        let items = entries.map { "{\"\(srcKey)\":\($0.source),\"\(dstKey)\":\($0.destination)}" }
        return "{\"UserKeyMapping\":[" + items.joined(separator: ",") + "]}"
    }
}

// MARK: - Application du remappage et suivi de la touche

@MainActor
final class HyperKey: ObservableObject {
    static let shared = HyperKey()

    /// Le remappage est en place et la touche suivie.
    @Published private(set) var isActive = false
    @Published private(set) var lastError: String?

    private let defaults = UserDefaults.standard
    private var tap: HyperKeyTap?
    private var started = false

    /// Prism a-t-il posé un remappage qu'il n'a pas encore retiré (même après un plantage) ?
    private var appliedSource: UInt64? {
        get { (defaults.object(forKey: "hyper.appliedSource") as? NSNumber)?.uint64Value }
        set { defaults.set(newValue.map { NSNumber(value: $0) }, forKey: "hyper.appliedSource") }
    }

    /// L'entrée d'origine que le remappage de Prism a remplacée (Verr. Maj → Échap, par exemple).
    private var replacedEntry: KeyMappingEntry? {
        get { defaults.data(forKey: "hyper.replacedEntry").flatMap { try? JSONDecoder().decode(KeyMappingEntry.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "hyper.replacedEntry") }
    }

    func start() {
        started = true
        // Rétablit le clavier en quittant ; au lancement suivant, `apply()` rattrape un éventuel plantage.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HyperKey.shared.deactivate() }
        }
        apply()
    }

    /// Met le remappage et le suivi en accord avec le réglage.
    func apply() {
        guard started else { return }
        let key = HyperKeyPreferences.shared.key
        guard key != .none else {
            deactivate()
            return
        }
        guard AXIsProcessTrusted() else {
            // Sans accessibilité, la touche remappée ne donnerait que F18 : on ne touche à rien.
            deactivate()
            lastError = "Autorisez Prism dans Accessibilité pour activer la touche Hyper."
            return
        }
        let system = HyperKeyMapping.parse(Self.hidutil(["property", "--get", "UserKeyMapping"]) ?? "")
        var current = system
        if let source = key.hidUsage {
            // Changement de touche : l'ancienne retrouve d'abord son remappage d'origine.
            if let previous = appliedSource, previous != source {
                current = HyperKeyMapping.restored(current: current, prismSource: previous, replaced: replacedEntry)
                appliedSource = nil
            }
            // L'entrée remplacée n'est mémorisée qu'à la première pose, pas à chaque réapplication.
            if appliedSource == nil {
                replacedEntry = current.first { $0.source == source && $0.destination != HyperKeyMapping.f18 }
            }
            let merged = HyperKeyMapping.merged(existing: current, source: source, previousSource: appliedSource)
            if merged != system {
                guard Self.hidutil(["property", "--set", HyperKeyMapping.json(merged)]) != nil else {
                    lastError = "hidutil a refusé le remappage."
                    return
                }
            }
            appliedSource = source
        } else if let previous = appliedSource {
            restore(previous, current: current)
        }
        if tap == nil { tap = HyperKeyTap() }
        let installed = tap?.install() ?? false
        isActive = installed
        lastError = installed ? nil : "Le suivi du clavier n’a pas pu démarrer."
    }

    /// Retire le suivi et rend au clavier ses remappages d'origine.
    func deactivate() {
        tap?.uninstall()
        tap = nil
        isActive = false
        lastError = nil
        if let previous = appliedSource {
            restore(previous, current: HyperKeyMapping.parse(Self.hidutil(["property", "--get", "UserKeyMapping"]) ?? ""))
        }
    }

    private func restore(_ source: UInt64, current: [KeyMappingEntry]) {
        let restored = HyperKeyMapping.restored(current: current, prismSource: source, replaced: replacedEntry)
        if restored != current {
            _ = Self.hidutil(["property", "--set", HyperKeyMapping.json(restored)])
        }
        appliedSource = nil
        replacedEntry = nil
    }

    /// Lance `hidutil` et rend sa sortie (nil en cas d'échec).
    private static func hidutil(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

/// Le suivi de F18 par un CGEventTap de session : tant qu'elle est enfoncée, les touches reçoivent ⌃⌥⌘ (+⇧) ;
/// relâchée sans autre touche, elle peut valoir Échap ou basculer le verrouillage des majuscules.
/// Tout se passe sur le fil principal (source ajoutée à sa boucle).
final class HyperKeyTap: @unchecked Sendable {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false
    private var usedAsModifier = false
    private var downDate = Date.distantPast

    static let f18KeyCode = Int64(kVK_F18)

    func install() -> Bool {
        if port != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<HyperKeyTap>.fromOpaque(info).takeUnretainedValue()
                return tap.handle(type: type, event: event)
            },
            userInfo: info
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        return true
    }

    func uninstall() {
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
        isDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == Self.f18KeyCode {
                if type == .keyDown {
                    if !isDown {
                        isDown = true
                        usedAsModifier = false
                        downDate = Date()
                    }
                } else {
                    isDown = false
                    if !usedAsModifier, Date().timeIntervalSince(downDate) < 0.35 { tapped() }
                }
                return nil
            }
            if isDown {
                usedAsModifier = true
                event.flags.formUnion(Self.hyperFlags)
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// ⌃⌥⌘, avec ⇧ si le réglage le demande. Lu depuis les préférences : le rappel n'est pas sur l'acteur principal.
    static var hyperFlags: CGEventFlags {
        var flags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
        if UserDefaults.standard.bool(forKey: "hyper.includeShift") { flags.insert(.maskShift) }
        return flags
    }

    private func tapped() {
        guard UserDefaults.standard.string(forKey: "hyper.key") == HyperSourceKey.capsLock.rawValue else { return }
        switch HyperTapAction(rawValue: UserDefaults.standard.string(forKey: "hyper.tapAction") ?? "") ?? .escape {
        case .nothing:
            break
        case .escape:
            let source = CGEventSource(stateID: .hidSystemState)
            CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Escape), keyDown: true)?.post(tap: .cgSessionEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Escape), keyDown: false)?.post(tap: .cgSessionEventTap)
        case .capsLock:
            Self.toggleCapsLock()
        }
    }

    /// Bascule le verrouillage des majuscules (et son voyant) par IOKit.
    static func toggleCapsLock() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else { return }
        defer { IOServiceClose(connect) }
        var state = false
        IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &state)
        IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), !state)
    }
}

// MARK: - Fonctionnalité

@MainActor
enum HyperKeyFeature: PrismFeature {
    static func start() {
        HyperKey.shared.start()
    }

    static var commands: [ResultItem] {
        [Command.run("hyper.toggle", "Activer ou désactiver la touche Hyper", subtitle: "Touche Hyper", symbol: "sparkle", color: Palette.indigo,
                     keywords: ["hyper key", "caps lock", "verr maj", "clavier"]) {
            let preferences = HyperKeyPreferences.shared
            if preferences.key == .none {
                NotificationCenter.default.post(name: .prismOpenSettings, object: "hyper")
                return .close
            }
            if HyperKey.shared.isActive {
                HyperKey.shared.deactivate()
                return .toast("Touche Hyper désactivée jusqu’au prochain lancement")
            }
            HyperKey.shared.apply()
            return .toast(HyperKey.shared.isActive ? "Touche Hyper activée" : (HyperKey.shared.lastError ?? "Touche Hyper indisponible"))
        }]
    }

    static var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "hyper", title: "Touche Hyper", symbol: "sparkle", color: Palette.indigo, order: 50) { AnyView(HyperKeySettingsView()) }]
    }

    static func selfTest(_ check: (Bool, String) -> Void) {
        let output = """
        (
                {
                HIDKeyboardModifierMappingDst = 30064771113;
                HIDKeyboardModifierMappingSrc = 30064771129;
            },
                {
                HIDKeyboardModifierMappingDst = 30064771300;
                HIDKeyboardModifierMappingSrc = 30064771296;
            }
        )
        """
        let existing = HyperKeyMapping.parse(output)
        let capsToEscape = KeyMappingEntry(source: HyperKeyMapping.usage(0x39), destination: HyperKeyMapping.usage(0x29))
        let leftControlToRight = KeyMappingEntry(source: HyperKeyMapping.usage(0xE0), destination: HyperKeyMapping.usage(0xE4))
        check(existing == [capsToEscape, leftControlToRight], "sortie de hidutil lue (plist OpenStep)")
        check(HyperKeyMapping.parse("(null)").isEmpty && HyperKeyMapping.parse("").isEmpty, "aucun remappage : « (null) »")

        let caps = HyperSourceKey.capsLock.hidUsage
        let merged = HyperKeyMapping.merged(existing: existing, source: caps, previousSource: nil)
        check(merged == [leftControlToRight, KeyMappingEntry(source: HyperKeyMapping.usage(0x39), destination: HyperKeyMapping.f18)],
              "Verr. Maj → F18 remplace seulement l'entrée de Verr. Maj, les autres restent")
        let json = HyperKeyMapping.json(merged)
        check(json == "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":30064771296,\"HIDKeyboardModifierMappingDst\":30064771300},"
              + "{\"HIDKeyboardModifierMappingSrc\":30064771129,\"HIDKeyboardModifierMappingDst\":30064771181}]}", "JSON pour hidutil")
        let reparsed = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: [[String: UInt64]]]
        check(reparsed?["UserKeyMapping"]?.count == 2, "JSON valide")

        let switched = HyperKeyMapping.merged(existing: merged, source: HyperSourceKey.rightCommand.hidUsage, previousSource: caps)
        check(switched == [leftControlToRight, KeyMappingEntry(source: HyperKeyMapping.usage(0xE7), destination: HyperKeyMapping.f18)],
              "changer de touche retire l'ancienne entrée de Prism")
        check(HyperKeyMapping.merged(existing: merged, source: caps, previousSource: caps) == merged, "réappliquer ne change rien")

        let restored = HyperKeyMapping.restored(current: merged, prismSource: HyperKeyMapping.usage(0x39), replaced: capsToEscape)
        check(restored == [leftControlToRight, capsToEscape], "désactiver rend Verr. Maj → Échap d'origine")
        check(HyperKeyMapping.restored(current: [KeyMappingEntry(source: HyperKeyMapping.usage(0x39), destination: HyperKeyMapping.f18)],
                                       prismSource: HyperKeyMapping.usage(0x39), replaced: nil).isEmpty, "désactiver sans remappage d'origine vide la liste")
        check(HyperSourceKey.f18.hidUsage == nil && HyperSourceKey.none.hidUsage == nil, "F18 et « Aucune » ne remappent rien")
        check(Hotkey(keyCode: 0, modifiers: UInt32(cmdKey | optionKey | controlKey)).symbols.first == "✦", "les raccourcis Hyper s'affichent ✦")
    }
}

// MARK: - Réglages

struct HyperKeySettingsView: View {
    @ObservedObject private var preferences = HyperKeyPreferences.shared
    @ObservedObject private var hyper = HyperKey.shared
    @State private var trusted = AXIsProcessTrusted()
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Picker("Touche Hyper", selection: $preferences.key) {
                    ForEach(HyperSourceKey.allCases, id: \.self) { key in
                        Text(key.title).tag(key)
                    }
                }
                Toggle("Inclure ⇧ (la touche donne ⌃⌥⇧⌘)", isOn: $preferences.includeShift)
                    .disabled(preferences.key == .none)
                if preferences.key == .capsLock {
                    Picker("Appui bref sur Verr. Maj", selection: $preferences.tapAction) {
                        ForEach(HyperTapAction.allCases, id: \.self) { action in
                            Text(action.title).tag(action)
                        }
                    }
                }
                LabeledContent("État") {
                    if preferences.key == .none {
                        Text("Désactivée").foregroundStyle(.secondary)
                    } else if hyper.isActive {
                        Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.green)
                    } else {
                        Label(hyper.lastError ?? "Inactive", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.orange)
                    }
                }
            } header: {
                Text("Touche Hyper")
            } footer: {
                Text("Maintenue, la touche choisie vaut ⌃⌥⌘ (✦) : de quoi créer des raccourcis qui n’entrent en conflit avec aucune application, par exemple ✦ T pour le Terminal dans Commandes. Prism ne remplace que l’entrée de cette touche dans les remappages du clavier (hidutil) et les rétablit en quittant.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if preferences.key != .none, !trusted {
                Section {
                    Label("La touche Hyper a besoin de l’autorisation Accessibilité pour suivre le clavier.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.orange)
                    Button("Ouvrir Confidentialité et sécurité…") {
                        Paster.requestTrust()
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } header: {
                    Text("Autorisation")
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            let now = AXIsProcessTrusted()
            // L'autorisation vient d'être accordée : la touche s'active sans redémarrer.
            if now, !trusted, preferences.key != .none, !hyper.isActive { HyperKey.shared.apply() }
            trusted = now
        }
    }
}
