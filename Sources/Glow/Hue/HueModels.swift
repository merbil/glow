import Foundation

// MARK: - Hue API v2 (CLIP) resources
// Only the fields Glow needs are decoded; everything else is ignored.

struct HueResponse<T: Decodable>: Decodable {
    let data: [T]
}

struct ResourceRef: Codable, Hashable {
    let rid: String
    let rtype: String
}

/// Names come from the bridge: drop invisible formatting characters (e.g. right-to-left
/// overrides that could make a name display as something else) and cap the length.
func cleanName(_ name: String) -> String {
    let scalars = name.unicodeScalars.filter { $0.properties.generalCategory != .format && $0.properties.generalCategory != .control }
    return String(String.UnicodeScalarView(scalars)).prefix(64).trimmingCharacters(in: .whitespacesAndNewlines)
}

struct HueLightResource: Decodable {
    struct Metadata: Decodable {
        let name: String
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = cleanName(try c.decode(String.self, forKey: .name))
        }
        private enum CodingKeys: String, CodingKey { case name }
    }
    struct On: Decodable { let on: Bool }
    struct Dimming: Decodable { let brightness: Double }
    struct XY: Decodable { let x: Double; let y: Double }
    struct Color: Decodable { let xy: XY }
    struct ColorTemperature: Decodable {
        struct Schema: Decodable { let mirek_minimum: Int; let mirek_maximum: Int }
        let mirek: Int?
        let mirek_valid: Bool?
        let mirek_schema: Schema?
    }

    let id: String
    let owner: ResourceRef
    let metadata: Metadata
    let on: On
    let dimming: Dimming?
    let color: Color?
    let color_temperature: ColorTemperature?
    let mode: String?
    /// The v1 address ("/lights/3"); bridge timers can only target v1 resources.
    let id_v1: String?
}

struct HueRoomResource: Decodable {
    struct Metadata: Decodable {
        let name: String
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = cleanName(try c.decode(String.self, forKey: .name))
        }
        private enum CodingKeys: String, CodingKey { case name }
    }
    let id: String
    let metadata: Metadata
    let children: [ResourceRef]
    let services: [ResourceRef]?
    /// The v1 address ("/groups/2"); bridge timers can only target v1 resources.
    let id_v1: String?

    /// The room's grouped light: switches every lamp in the room with one command.
    var groupedLightID: String? { services?.first { $0.rtype == "grouped_light" }?.rid }
}

struct HueConnectivityResource: Decodable {
    let id: String
    let owner: ResourceRef
    let status: String
}

/// Partial update as delivered by the event stream. Every field is optional, and a field
/// with an unexpected shape (e.g. a scene's `status` object) is skipped instead of failing.
struct HueEventItem: Decodable {
    let id: String
    let type: String
    let owner: ResourceRef?
    let on: HueLightResource.On?
    let dimming: HueLightResource.Dimming?
    let color: HueLightResource.Color?
    let color_temperature: HueLightResource.ColorTemperature?
    let status: String?

    private enum Keys: String, CodingKey { case id, type, owner, on, dimming, color, color_temperature, status }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        owner = try? c.decodeIfPresent(ResourceRef.self, forKey: .owner)
        on = try? c.decodeIfPresent(HueLightResource.On.self, forKey: .on)
        dimming = try? c.decodeIfPresent(HueLightResource.Dimming.self, forKey: .dimming)
        color = try? c.decodeIfPresent(HueLightResource.Color.self, forKey: .color)
        color_temperature = try? c.decodeIfPresent(HueLightResource.ColorTemperature.self, forKey: .color_temperature)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
    }
}

struct HueEvent: Decodable {
    let type: String          // "update", "add", "delete", "error"
    let data: [HueEventItem]

    private enum Keys: String, CodingKey { case type, data }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        type = try c.decode(String.self, forKey: .type)
        // One malformed item must not drop the rest of the batch.
        data = try c.decode([Lossy<HueEventItem>].self, forKey: .data).compactMap(\.value)
    }
}

/// Decodes a value, or nil if it doesn't fit, without failing the surrounding array.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Hue API v1 (used for pairing and bridge-side timers)

struct BridgeConfig: Decodable {
    let name: String
    let bridgeid: String
}

struct PairingCredentials: Codable {
    let username: String
    let clientkey: String?
}

// MARK: - App-facing model

/// What a lamp can do with color, read from which fields the bridge reports.
enum LampCapability: Equatable {
    /// Full color (and usually whites too).
    case color(whites: ClosedRange<Int>?)
    /// White ambiance: warm to cool white only. Range is in mirek.
    case whites(ClosedRange<Int>)
    /// One fixed white.
    case single
}

struct Lamp: Identifiable, Equatable {
    let id: String
    let deviceID: String
    var hueName: String
    var isOn: Bool
    var brightness: Double          // 0...100
    var xy: (x: Double, y: Double)?
    var mirek: Int?
    var isReachable: Bool
    var capability: LampCapability = .single
    /// False for on/off-only devices such as smart plugs.
    var isDimmable = true
    /// The v1 address ("/lights/3"), for bridge timers.
    var v1Path: String? = nil

    static func == (a: Lamp, b: Lamp) -> Bool {
        a.id == b.id && a.hueName == b.hueName && a.isOn == b.isOn && a.capability == b.capability &&
        a.brightness == b.brightness && a.xy?.x == b.xy?.x && a.xy?.y == b.xy?.y &&
        a.mirek == b.mirek && a.isReachable == b.isReachable && a.isDimmable == b.isDimmable
    }
}

struct Room: Identifiable, Equatable {
    let id: String
    let name: String
    let deviceIDs: Set<String>
    var groupedLightID: String? = nil
    /// The v1 address ("/groups/2"), for bridge timers.
    var v1Path: String? = nil
}

/// Accepts a v1 address only in the expected shape ("/lights/3", "/groups/2"): it goes into a bridge URL.
func validV1Path(_ path: String?, kind: String) -> String? {
    guard let path, path.hasPrefix("/\(kind)/") else { return nil }
    let number = path.dropFirst(kind.count + 2)
    return !number.isEmpty && number.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) ? path : nil
}
