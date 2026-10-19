import Foundation

/// The simplified choices offered in the color picker.
enum ColorPalette {
    struct Swatch: Identifiable, Equatable {
        let id: String
        let name: String
        let rgb: HueColor.RGB
        var xy: (x: Double, y: Double) { HueColor.xy(from: rgb) }

        static func == (a: Swatch, b: Swatch) -> Bool { a.id == b.id }
    }

    struct White: Identifiable, Equatable {
        let id: String
        let name: String
        let mirek: Int
        var kelvin: Int { 1_000_000 / mirek }
        var rgb: HueColor.RGB { HueColor.fromMirek(mirek) }

        init(id: String, name: String, mirek: Int) {
            self.id = id; self.name = name; self.mirek = mirek
        }

        init(id: String, name: String, kelvin: Int) {
            self.init(id: id, name: name, mirek: 1_000_000 / kelvin)
        }
    }

    private static func swatch(_ name: String, _ hex: UInt32) -> Swatch {
        Swatch(id: name, name: name, rgb: HueColor.RGB(
            r: Double((hex >> 16) & 0xFF) / 255,
            g: Double((hex >> 8) & 0xFF) / 255,
            b: Double(hex & 0xFF) / 255))
    }

    /// 16 colors, laid out as two rows of eight around the color wheel.
    static let colors: [Swatch] = [
        swatch("Red", 0xFF3B30), swatch("Orange", 0xFF7A1A), swatch("Amber", 0xFFA41B), swatch("Yellow", 0xFFD60A),
        swatch("Lime", 0xB5E61D), swatch("Green", 0x34C759), swatch("Mint", 0x2EE6A8), swatch("Teal", 0x1FC7C1),
        swatch("Cyan", 0x32D2FF), swatch("Sky", 0x3A9BFF), swatch("Blue", 0x1F4BFF), swatch("Indigo", 0x5E3BFF),
        swatch("Violet", 0x8A3BFF), swatch("Purple", 0xBF40FF), swatch("Magenta", 0xFF2EC4), swatch("Pink", 0xFF5C8A),
    ]

    static let whites: [White] = [
        White(id: "warm", name: "Warm", kelvin: 2700),
        White(id: "daylight", name: "Daylight", kelvin: 4000),
        White(id: "bright", name: "Bright white", kelvin: 6500),
    ]

    /// Whites a lamp can actually show, with mirek clamped to its supported range.
    static func whites(for range: ClosedRange<Int>) -> [White] {
        whites.map { White(id: $0.id, name: $0.name, mirek: min(max($0.mirek, range.lowerBound), range.upperBound)) }
    }

    /// The swatch closest to the lamp's current color, if it's close enough to call it "selected".
    static func selectedColor(for lamp: Lamp) -> Swatch? {
        guard lamp.mirek == nil, let xy = lamp.xy else { return nil }
        let best = colors.min { distance($0.xy, xy) < distance($1.xy, xy) }
        return best.flatMap { distance($0.xy, xy) < 0.06 ? $0 : nil }
    }

    /// The preset white closest to the lamp's current color temperature.
    static func selectedWhite(for lamp: Lamp) -> White? {
        guard let mirek = lamp.mirek else { return nil }
        let best = whites.min { abs($0.mirek - mirek) < abs($1.mirek - mirek) }
        return best.flatMap { abs($0.mirek - mirek) < 40 ? $0 : nil }
    }

    private static func distance(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}
