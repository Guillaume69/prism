import Carbon.HIToolbox
import Foundation

/// Raccourci global par l'API Carbon `RegisterEventHotKey` : aucune autorisation d'accessibilité requise.
final class HotKey {
    nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var nextID: UInt32 = 1
    nonisolated(unsafe) private static var handlerInstalled = false

    private var reference: EventHotKeyRef?
    private let id: UInt32
    let isRegistered: Bool
    /// Le raccourci enregistré, pour savoir s'il faut le réenregistrer.
    var binding: Hotkey?

    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        Self.handlers[id] = handler
        let hotKeyID = EventHotKeyID(signature: OSType(0x5052_534D), id: id) // « PRSM »
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
        self.reference = reference
        isRegistered = status == noErr
    }

    /// Envoie à l'app l'événement Carbon « raccourci pressé », le même que l'appui réel (essais).
    func simulatePress() -> OSStatus {
        var event: EventRef?
        var status = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, EventAttributes(kEventAttributeNone), &event)
        guard status == noErr, let event else { return status }
        defer { ReleaseEvent(event) }
        var hotKeyID = EventHotKeyID(signature: OSType(0x5052_534D), id: id)
        status = SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &hotKeyID)
        guard status == noErr else { return status }
        return SendEventToEventTarget(event, GetApplicationEventTarget())
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        Self.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if status == noErr {
                let id = hotKeyID.id
                DispatchQueue.main.async { HotKey.handlers[id]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
