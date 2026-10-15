import AppKit

/// Une couleur sRGB (composantes 0…1) et ses écritures : HEX, RGB, HSL, HWB, Lab, LCH, Oklab, Oklch, NSColor, UIColor, SwiftUI.
struct CalcColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    // MARK: - Lecture

    static func parse(_ input: String) -> CalcColor? {
        let text = input.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("#") { return hex(String(text.dropFirst())) }
        guard let open = text.firstIndex(of: "("), text.hasSuffix(")") else { return nil }
        let name = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        let inner = text[text.index(after: open)..<text.index(before: text.endIndex)]
        let parts = inner
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ")
            .map(String.init)
        guard parts.count >= 3 else { return nil }
        func number(_ index: Int, percentScale: Double = 1) -> Double? {
            guard index < parts.count else { return nil }
            var part = parts[index]
            var isPercent = false
            if part.hasSuffix("%") { part.removeLast(); isPercent = true }
            for suffix in ["deg", "°"] where part.hasSuffix(suffix) { part.removeLast(suffix.count) }
            guard let value = Double(part) else { return nil }
            return isPercent ? value / 100 * percentScale : value
        }
        let alpha = parts.count > 3 ? (number(3, percentScale: 1) ?? 1) : 1
        switch name {
        case "rgb", "rgba":
            guard let r = number(0, percentScale: 255), let g = number(1, percentScale: 255), let b = number(2, percentScale: 255) else { return nil }
            return CalcColor(red: r / 255, green: g / 255, blue: b / 255, alpha: alpha).clamped
        case "hsl", "hsla":
            guard let h = number(0), let s = number(1, percentScale: 100), let l = number(2, percentScale: 100) else { return nil }
            return fromHSL(h, s / 100, l / 100, alpha: alpha)
        case "hwb":
            guard let h = number(0), let w = number(1, percentScale: 100), let b = number(2, percentScale: 100) else { return nil }
            return fromHWB(h, w / 100, b / 100, alpha: alpha)
        case "lab":
            guard let l = number(0, percentScale: 100), let a = number(1, percentScale: 125), let b = number(2, percentScale: 125) else { return nil }
            return fromLab(l, a, b, alpha: alpha)
        case "lch":
            guard let l = number(0, percentScale: 100), let c = number(1, percentScale: 150), let h = number(2) else { return nil }
            let radians = h * .pi / 180
            return fromLab(l, c * cos(radians), c * sin(radians), alpha: alpha)
        case "oklab":
            guard let l = number(0, percentScale: 1), let a = number(1, percentScale: 0.4), let b = number(2, percentScale: 0.4) else { return nil }
            return fromOklab(l > 1 ? l / 100 : l, a, b, alpha: alpha)
        case "oklch":
            guard let l = number(0, percentScale: 1), let c = number(1, percentScale: 0.4), let h = number(2) else { return nil }
            let radians = h * .pi / 180
            return fromOklab(l > 1 ? l / 100 : l, c * cos(radians), c * sin(radians), alpha: alpha)
        default:
            return nil
        }
    }

    static func hex(_ digits: String) -> CalcColor? {
        guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        let expanded = digits.count <= 4 ? digits.map { "\($0)\($0)" }.joined() : digits
        guard let value = UInt64(expanded, radix: 16) else { return nil }
        let hasAlpha = expanded.count == 8
        let shift: UInt64 = hasAlpha ? 8 : 0
        return CalcColor(
            red: Double((value >> (16 + shift)) & 0xFF) / 255,
            green: Double((value >> (8 + shift)) & 0xFF) / 255,
            blue: Double((value >> shift) & 0xFF) / 255,
            alpha: hasAlpha ? Double(value & 0xFF) / 255 : 1
        )
    }

    private var clamped: CalcColor {
        CalcColor(red: min(max(red, 0), 1), green: min(max(green, 0), 1), blue: min(max(blue, 0), 1), alpha: min(max(alpha, 0), 1))
    }

    static func fromHSL(_ hue: Double, _ saturation: Double, _ lightness: Double, alpha: Double = 1) -> CalcColor {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        func channel(_ n: Double) -> Double {
            let k = (n + h * 12).truncatingRemainder(dividingBy: 12)
            let a = saturation * min(lightness, 1 - lightness)
            return lightness - a * max(-1, min(k - 3, 9 - k, 1))
        }
        return CalcColor(red: channel(0), green: channel(8), blue: channel(4), alpha: alpha).clamped
    }

    static func fromHWB(_ hue: Double, _ white: Double, _ black: Double, alpha: Double = 1) -> CalcColor {
        if white + black >= 1 {
            let gray = white / (white + black)
            return CalcColor(red: gray, green: gray, blue: gray, alpha: alpha)
        }
        let pure = fromHSL(hue, 1, 0.5)
        func mix(_ c: Double) -> Double { c * (1 - white - black) + white }
        return CalcColor(red: mix(pure.red), green: mix(pure.green), blue: mix(pure.blue), alpha: alpha)
    }

    // MARK: - Espaces de couleur

    private static func toLinear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    private static func fromLinear(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }

    /// XYZ D65 depuis le sRGB linéaire.
    private var xyzD65: (Double, Double, Double) {
        let r = Self.toLinear(red), g = Self.toLinear(green), b = Self.toLinear(blue)
        return (
            0.4124564 * r + 0.3575761 * g + 0.1804375 * b,
            0.2126729 * r + 0.7151522 * g + 0.0721750 * b,
            0.0193339 * r + 0.1191920 * g + 0.9503041 * b
        )
    }

    private static func fromXYZD65(_ x: Double, _ y: Double, _ z: Double, alpha: Double) -> CalcColor {
        let r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let b = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
        return CalcColor(red: fromLinear(r), green: fromLinear(g), blue: fromLinear(b), alpha: alpha).clamped
    }

    /// CIE Lab (D50, comme en CSS), avec l'adaptation chromatique de Bradford.
    var lab: (l: Double, a: Double, b: Double) {
        let (x65, y65, z65) = xyzD65
        let x = 1.0478112 * x65 + 0.0228866 * y65 - 0.0501270 * z65
        let y = 0.0295424 * x65 + 0.9904844 * y65 - 0.0170491 * z65
        let z = -0.0092345 * x65 + 0.0150436 * y65 + 0.7521316 * z65
        let white = (0.96422, 1.0, 0.82521)
        func f(_ t: Double) -> Double { t > 216.0 / 24389.0 ? cbrt(t) : (24389.0 / 27.0 * t + 16) / 116 }
        let fx = f(x / white.0), fy = f(y / white.1), fz = f(z / white.2)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    static func fromLab(_ l: Double, _ a: Double, _ b: Double, alpha: Double = 1) -> CalcColor {
        let fy = (l + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
        func inverse(_ t: Double) -> Double { t * t * t > 216.0 / 24389.0 ? t * t * t : (116 * t - 16) / (24389.0 / 27.0) }
        let x = inverse(fx) * 0.96422, y = inverse(fy), z = inverse(fz) * 0.82521
        let x65 = 0.9555766 * x - 0.0230393 * y + 0.0631636 * z
        let y65 = -0.0282895 * x + 1.0099416 * y + 0.0210077 * z
        let z65 = 0.0122982 * x - 0.0204830 * y + 1.3299098 * z
        return fromXYZD65(x65, y65, z65, alpha: alpha)
    }

    var oklab: (l: Double, a: Double, b: Double) {
        let r = Self.toLinear(red), g = Self.toLinear(green), b = Self.toLinear(blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    static func fromOklab(_ l: Double, _ a: Double, _ b: Double, alpha: Double = 1) -> CalcColor {
        let l1 = l + 0.3963377774 * a + 0.2158037573 * b
        let m1 = l - 0.1055613458 * a - 0.0638541728 * b
        let s1 = l - 0.0894841775 * a - 1.2914855480 * b
        let l3 = l1 * l1 * l1, m3 = m1 * m1 * m1, s3 = s1 * s1 * s1
        let r = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3
        let g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3
        let bl = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
        return CalcColor(red: fromLinear(r), green: fromLinear(g), blue: fromLinear(bl), alpha: alpha).clamped
    }

    var hsl: (h: Double, s: Double, l: Double) {
        let maxValue = max(red, green, blue), minValue = min(red, green, blue)
        let l = (maxValue + minValue) / 2
        let delta = maxValue - minValue
        guard delta > 0 else { return (0, 0, l) }
        let s = delta / (1 - abs(2 * l - 1))
        var h: Double
        switch maxValue {
        case red: h = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        case green: h = (blue - red) / delta + 2
        default: h = (red - green) / delta + 4
        }
        h *= 60
        if h < 0 { h += 360 }
        return (h, s, l)
    }

    // MARK: - Écritures

    private func number(_ value: Double, _ digits: Int = 2) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.maximumFractionDigits = digits
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    var hexString: String {
        let base = String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
        return alpha < 1 ? base + String(format: "%02X", Int((alpha * 255).rounded())) : base
    }

    var rgbString: String { "rgb(\(Int((red * 255).rounded())) \(Int((green * 255).rounded())) \(Int((blue * 255).rounded()))\(alpha < 1 ? " / \(number(alpha))" : ""))" }
    var rgbaString: String { "rgba(\(Int((red * 255).rounded())), \(Int((green * 255).rounded())), \(Int((blue * 255).rounded())), \(number(alpha)))" }

    var hslString: String {
        let (h, s, l) = hsl
        return "hsl(\(number(h, 0)) \(number(s * 100, 0))% \(number(l * 100, 0))%\(alpha < 1 ? " / \(number(alpha))" : ""))"
    }

    var hwbString: String {
        let (h, _, _) = hsl
        let white = min(red, green, blue), black = 1 - max(red, green, blue)
        return "hwb(\(number(h, 0)) \(number(white * 100, 0))% \(number(black * 100, 0))%)"
    }

    var labString: String { let (l, a, b) = lab; return "lab(\(number(l))% \(number(a)) \(number(b)))" }

    var lchString: String {
        let (l, a, b) = lab
        var h = atan2(b, a) * 180 / .pi
        if h < 0 { h += 360 }
        return "lch(\(number(l))% \(number(sqrt(a * a + b * b))) \(number(h)))"
    }

    var oklabString: String { let (l, a, b) = oklab; return "oklab(\(number(l * 100))% \(number(a, 4)) \(number(b, 4)))" }

    var oklchString: String {
        let (l, a, b) = oklab
        var h = atan2(b, a) * 180 / .pi
        if h < 0 { h += 360 }
        return "oklch(\(number(l * 100))% \(number(sqrt(a * a + b * b), 4)) \(number(h)))"
    }

    var nsColorString: String { "NSColor(srgbRed: \(number(red, 3)), green: \(number(green, 3)), blue: \(number(blue, 3)), alpha: \(number(alpha, 3)))" }
    var uiColorString: String { "UIColor(red: \(number(red, 3)), green: \(number(green, 3)), blue: \(number(blue, 3)), alpha: \(number(alpha, 3)))" }
    var swiftUIString: String { "Color(red: \(number(red, 3)), green: \(number(green, 3)), blue: \(number(blue, 3)), opacity: \(number(alpha, 3)))" }

    /// Toutes les écritures, pour « Copier la couleur en… ».
    var formats: [(name: String, value: String)] {
        [
            ("HEX", hexString), ("RGB", rgbString), ("RGBA", rgbaString), ("HSL", hslString), ("HWB", hwbString),
            ("Lab", labString), ("LCH", lchString), ("Oklab", oklabString), ("Oklch", oklchString),
            ("NSColor", nsColorString), ("UIColor", uiColorString), ("SwiftUI", swiftUIString),
        ]
    }
}
