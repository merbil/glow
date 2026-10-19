import SwiftUI

/// Converts Hue color values into colors for the lamp tiles.
enum HueColor {
    /// Warm white used for lamps that don't report a color.
    static let defaultWarm = RGB(r: 1.0, g: 0.80, b: 0.55)

    struct RGB: Equatable {
        var r, g, b: Double

        var color: Color { Color(red: r, green: g, blue: b) }

        func mixed(with other: RGB, _ amount: Double) -> RGB {
            RGB(r: r + (other.r - r) * amount,
                g: g + (other.g - g) * amount,
                b: b + (other.b - b) * amount)
        }

        static let white = RGB(r: 1, g: 1, b: 1)
        static let slate = RGB(r: 0.23, g: 0.23, b: 0.27)
        /// The dark text color used on lit tiles.
        static let ink = RGB(r: 0.11, g: 0.11, b: 0.11)

        /// WCAG relative luminance.
        var luminance: Double {
            func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }

        /// WCAG contrast ratio (1...21).
        func contrast(with other: RGB) -> Double {
            let (a, b) = (luminance, other.luminance)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }

        /// Lightens a background just enough that `ink` text, including the secondary line
        /// drawn at `secondaryOpacity`, stays readable (WCAG AA, 4.5:1). Light colors are unchanged.
        func readableBehindInk(secondaryOpacity: Double = 0.72, minimum: Double = 4.5) -> RGB {
            var color = self
            for step in 0...20 {
                color = mixed(with: .white, Double(step) * 0.05)
                let secondary = color.mixed(with: .ink, secondaryOpacity)
                if secondary.contrast(with: color) >= minimum { break }
            }
            return color
        }
    }

    static func rgb(for lamp: Lamp) -> RGB {
        if let xy = lamp.xy, lamp.mirek == nil { return fromXY(x: xy.x, y: xy.y) }
        if let mirek = lamp.mirek { return fromMirek(mirek) }
        if let xy = lamp.xy { return fromXY(x: xy.x, y: xy.y) }
        return defaultWarm
    }

    /// CIE 1931 xy → sRGB at full brightness (Philips' recommended conversion).
    static func fromXY(x: Double, y: Double) -> RGB {
        guard y > 0 else { return defaultWarm }
        let z = 1.0 - x - y
        let Y = 1.0
        let X = (Y / y) * x
        let Z = (Y / y) * z

        var r = X * 1.656492 - Y * 0.354851 - Z * 0.255038
        var g = -X * 0.707196 + Y * 1.655397 + Z * 0.036152
        var b = X * 0.051713 - Y * 0.121364 + Z * 1.011530

        func gamma(_ v: Double) -> Double {
            v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055
        }
        r = gamma(max(0, r)); g = gamma(max(0, g)); b = gamma(max(0, b))
        let peak = max(r, g, b, 1e-6)
        return RGB(r: r / peak, g: g / peak, b: b / peak)
    }

    /// sRGB → CIE 1931 xy (Philips' recommended conversion). The bridge clamps to each lamp's gamut.
    static func xy(from rgb: RGB) -> (x: Double, y: Double) {
        func linear(_ v: Double) -> Double {
            v > 0.04045 ? pow((v + 0.055) / 1.055, 2.4) : v / 12.92
        }
        let r = linear(rgb.r), g = linear(rgb.g), b = linear(rgb.b)
        let X = r * 0.664511 + g * 0.154324 + b * 0.162028
        let Y = r * 0.283881 + g * 0.668433 + b * 0.047685
        let Z = r * 0.000088 + g * 0.072310 + b * 0.986039
        let sum = X + Y + Z
        guard sum > 0 else { return (0.3227, 0.329) }
        return (X / sum, Y / sum)
    }

    /// Color temperature (mirek) → approximate RGB (Tanner Helland's fit).
    static func fromMirek(_ mirek: Int) -> RGB {
        let kelvin = 1_000_000.0 / Double(max(mirek, 1))
        let t = kelvin / 100
        let r: Double, g: Double, b: Double
        if t <= 66 {
            r = 255
            g = 99.4708025861 * log(t) - 161.1195681661
            b = t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307
        } else {
            r = 329.698727446 * pow(t - 60, -0.1332047592)
            g = 288.1221695283 * pow(t - 60, -0.0755148492)
            b = 255
        }
        func clamp(_ v: Double) -> Double { min(max(v, 0), 255) / 255 }
        return RGB(r: clamp(r), g: clamp(g), b: clamp(b))
    }
}
