import Foundation
import IoTCore

/// Wire encoding only. Callers must separately qualify model capabilities and delivery.
/// Absolute setters are used; toggles and arbitrary vendor command injection are unsupported.
public enum GoveeLANCommand: Equatable, Sendable {
    case power(Bool)
    case brightness(Int)
    case rgb(red: Int, green: Int, blue: Int)
    case temperature(kelvin: Int)

    public init(payload: CommandPayload) throws {
        switch payload {
        case .setPower(let value): self = .power(value)
        case .setLevel(let value): self = .brightness(value.percent)
        case .setAttribute(name: "colorTemperature", value: .integer(let value)):
            guard let kelvin = Int(exactly: value) else { throw IoTError.invalidResponse }
            self = .temperature(kelvin: kelvin)
        case .setAttribute(name: "color", value: .object(let value)):
            guard Set(value.keys) == ["r", "g", "b"],
                  case .integer(let r) = value["r"], case .integer(let g) = value["g"],
                  case .integer(let b) = value["b"],
                  let red = Int(exactly: r), let green = Int(exactly: g), let blue = Int(exactly: b)
            else { throw IoTError.invalidResponse }
            self = .rgb(red: red, green: green, blue: blue)
        default: throw IoTError.notSupported("Govee LAN command")
        }
        _ = try encoded()
    }

    public func encoded() throws -> Data {
        let name: String
        let fields: [String: Any]
        switch self {
        case .power(let value):
            name = "turn"; fields = ["value": value ? 1 : 0]
        case .brightness(let value):
            guard (0...100).contains(value) else { throw IoTError.invalidResponse }
            name = "brightness"; fields = ["value": value]
        case .rgb(let red, let green, let blue):
            guard [red, green, blue].allSatisfy({ (0...255).contains($0) }) else { throw IoTError.invalidResponse }
            name = "colorwc"
            fields = ["color": ["r": red, "g": green, "b": blue], "colorTemInKelvin": 0]
        case .temperature(let value):
            guard (2000...9000).contains(value) else { throw IoTError.invalidResponse }
            name = "colorwc"
            fields = ["color": ["r": 0, "g": 0, "b": 0], "colorTemInKelvin": value]
        }
        return try JSONSerialization.data(withJSONObject: ["msg": ["cmd": name, "data": fields]], options: [.sortedKeys])
    }

    /// Content comparison only: UDP has no transaction ID, so this is not proof that a
    /// particular command caused this state or that the observation is newer than dispatch.
    public func matches(_ status: GoveeLANMessage.Status) -> Bool {
        guard (try? encoded()) != nil else { return false }
        switch self {
        case .power(let value): return status.onOff == (value ? 1 : 0)
        case .brightness(let value): return status.brightness == value
        case .rgb(let r, let g, let b):
            return status.color?.r == r && status.color?.g == g && status.color?.b == b
                && status.colorTemInKelvin == 0
        case .temperature(let value): return status.colorTemInKelvin == value
        }
    }
}
