import AppKit
import ApplicationServices

/// L'accessibilité est-elle utilisable ? Jamais pendant `--selftest` ni `--snapshot` : ces chemins
/// n'interrogent aucune application et ne demandent aucune autorisation.
@MainActor
enum AccessibilityGate {
    static let isHeadless: Bool = {
        let arguments = CommandLine.arguments
        return arguments.contains("--snapshot") || arguments.contains("--selftest")
    }()

    static var isGranted: Bool { !isHeadless && Paster.isTrusted }

    /// Demande l'autorisation et ouvre le bon panneau des Réglages Système. Sur action de l'utilisateur uniquement.
    static func request() -> ActionOutcome {
        guard !isHeadless else { return .stay }
        Paster.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        return .close
    }

    /// L'action « Autoriser… » des écrans qui en ont besoin.
    static var requestAction: ItemAction {
        ItemAction(title: "Autoriser l’accès à l’accessibilité…", symbol: "lock.open") { request() }
    }

    static let explanation = "Autorisez-le dans Réglages Système › Confidentialité et sécurité › Accessibilité ; ↵ ouvre ce réglage."
}

/// Lecture et écriture des attributs d'accessibilité, sans `unsafeBitCast` dispersés dans le code.
enum AX {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let value = attribute(element, name), CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        return (value as? [AnyObject] ?? []).compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? unsafeBitCast(item, to: AXUIElement.self) : nil
        }
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        (attribute(element, name) as? NSNumber)?.boolValue
    }

    static func point(_ element: AXUIElement, _ name: String = kAXPositionAttribute) -> CGPoint? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = CGPoint.zero
        return AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgPoint, &result) ? result : nil
    }

    static func size(_ element: AXUIElement, _ name: String = kAXSizeAttribute) -> CGSize? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = CGSize.zero
        return AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &result) ? result : nil
    }

    /// Le cadre d'une fenêtre, dans le repère de l'accessibilité (origine en haut à gauche de l'écran principal).
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = point(element), let size = size(element) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    @discardableResult
    static func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(element, name as CFString, value) == .success
    }

    @discardableResult
    static func set(_ element: AXUIElement, _ name: String, bool: Bool) -> Bool {
        set(element, name, (bool ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    }

    /// Place une fenêtre. Position, taille, puis de nouveau la position : certaines apps bornent la taille
    /// à l'écran courant, et l'interface « enrichie » (Chrome, Electron) est coupée le temps du déplacement.
    static func setFrame(_ window: AXUIElement, _ frame: CGRect, pid: pid_t) {
        var origin = frame.origin
        var size = frame.size
        guard let originValue = AXValueCreate(.cgPoint, &origin), let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        let app = AXUIElementCreateApplication(pid)
        let enhanced = bool(app, "AXEnhancedUserInterface") == true
        if enhanced { set(app, "AXEnhancedUserInterface", bool: false) }
        set(window, kAXPositionAttribute, originValue)
        set(window, kAXSizeAttribute, sizeValue)
        set(window, kAXPositionAttribute, originValue)
        if enhanced { set(app, "AXEnhancedUserInterface", bool: true) }
    }

    @discardableResult
    static func perform(_ element: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }

    /// La fenêtre active d'une application, sinon sa fenêtre principale.
    static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        return element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
    }

    /// Les fenêtres d'une application, de la plus en avant à la plus en arrière.
    static func windows(of pid: pid_t, timeout: Float = 0.6) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        return elements(app, kAXWindowsAttribute)
    }

    /// Une vraie fenêtre de document, pas un panneau, une bulle ou une feuille.
    static func isStandardWindow(_ window: AXUIElement) -> Bool {
        let subrole = string(window, kAXSubroleAttribute)
        return subrole == nil || subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
    }
}
