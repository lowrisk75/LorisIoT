import Foundation
import IoTCore

#if canImport(Darwin)
struct MerossEncodedCommand: Hashable, Sendable {
    let namespace: String
    let payload: MerossJSON
    /// Attribute → value the post-SET re-read must show for the receipt to be `.applied`.
    let readBack: [String: StateValue]
}

/// Pure translation. Anything the profile does not declare is refused before any network traffic.
enum MerossCommandEncoder {
    static func encode(_ payload: CommandPayload, channel: Int, profile: MerossProfile, current: DeviceState?) throws -> MerossEncodedCommand {
        guard profile.canControl else { throw IoTError.notSupported("Meross control") }
        let ch = MerossJSON.number(Double(channel))
        switch (profile.family, payload) {
        case (.toggleX, .setPower(let on)), (.light, .setPower(let on)):
            return .init(namespace: MerossNamespace.toggleX, payload: .object(["togglex": .object(["channel": ch, "onoff": .number(on ? 1 : 0)])]), readBack: ["power": .bool(on)])
        case (.toggle, .setPower(let on)):
            return .init(namespace: MerossNamespace.toggle, payload: .object(["toggle": .object(["channel": ch, "onoff": .number(on ? 1 : 0)])]), readBack: ["power": .bool(on)])

        case (.thermostat, .setPower(let on)):
            return .init(namespace: MerossNamespace.thermostatMode, payload: .object(["mode": .array([.object(["channel": ch, "onoff": .number(on ? 1 : 0)])])]), readBack: ["power": .bool(on)])
        case (.thermostat, .setAttribute("targetTemperature", let value)):
            guard let celsius = number(value), celsius >= 5, celsius <= 35 else { throw IoTError.notSupported("Meross targetTemperature 5…35 °C") }
            let half = (celsius * 2).rounded() / 2
            return .init(namespace: MerossNamespace.thermostatMode,
                         payload: .object(["mode": .array([.object(["channel": ch, "manualTemp": .number((half * 10).rounded()), "mode": .number(4)])])]),
                         readBack: ["targetTemperature": .decimal(half), "mode": .string("manual")])
        case (.thermostat, .setAttribute("mode", .string(let name))):
            guard let raw = MerossStateMapper.thermostatModes.first(where: { $0.value == name })?.key else { throw IoTError.notSupported("Meross thermostat mode \(name)") }
            return .init(namespace: MerossNamespace.thermostatMode, payload: .object(["mode": .array([.object(["channel": ch, "mode": .number(Double(raw))])])]), readBack: ["mode": .string(name)])

        case (.diffuser, .setPower(let on)):
            return .init(namespace: MerossNamespace.diffuserSpray, payload: .object(["spray": .array([.object(["channel": ch, "mode": .number(on ? 1 : 0)])])]), readBack: ["power": .bool(on)])
        case (.diffuser, .setAttribute("sprayMode", .string(let name))):
            guard let raw = MerossStateMapper.sprayModes.first(where: { $0.value == name })?.key else { throw IoTError.notSupported("Meross spray mode \(name)") }
            return .init(namespace: MerossNamespace.diffuserSpray, payload: .object(["spray": .array([.object(["channel": ch, "mode": .number(Double(raw))])])]), readBack: ["sprayMode": .string(name)])
        case (.diffuser, .setAttribute("light", .bool(let on))) where profile.abilities.contains(MerossNamespace.diffuserLight):
            return .init(namespace: MerossNamespace.diffuserLight, payload: .object(["light": .array([.object(["channel": ch, "onoff": .number(on ? 1 : 0)])])]), readBack: ["light": .bool(on)])

        case (.light, .setLevel(let level)):
            return .init(namespace: MerossNamespace.light, payload: .object(["light": .object(["channel": ch, "luminance": .number(Double(level.percent)), "capacity": .number(4)])]), readBack: ["brightness": .integer(Int64(level.percent))])
        case (.light, .setAttribute("colorTemperature", let value)):
            guard let t = number(value), t >= 1, t <= 100 else { throw IoTError.notSupported("Meross colorTemperature 1…100") }
            return .init(namespace: MerossNamespace.light, payload: .object(["light": .object(["channel": ch, "temperature": .number(t.rounded()), "capacity": .number(2)])]), readBack: ["colorTemperature": .integer(Int64(t.rounded()))])
        case (.light, .setAttribute("color", .object(let rgb))):
            guard let r = component(rgb["r"]), let g = component(rgb["g"]), let b = component(rgb["b"]) else { throw IoTError.notSupported("Meross color r/g/b 0…255") }
            let packed = (r << 16) | (g << 8) | b
            return .init(namespace: MerossNamespace.light, payload: .object(["light": .object(["channel": ch, "rgb": .number(Double(packed)), "capacity": .number(1)])]),
                         readBack: ["color": .object(["r": .integer(Int64(r)), "g": .integer(Int64(g)), "b": .integer(Int64(b))])])

        case (.garage, .invokeAction("open", _)), (.garage, .invokeAction("close", _)):
            let open = { if case .invokeAction("open", _) = payload { return true }; return false }()
            return .init(namespace: MerossNamespace.garageState, payload: .object(["state": .object(["channel": ch, "open": .number(open ? 1 : 0), "uuid": .string("")])]), readBack: ["open": .bool(open)])

        case (.shutter, .setLevel(let level)) where profile.abilities.contains(MerossNamespace.shutterPosition):
            return .init(namespace: MerossNamespace.shutterPosition, payload: .object(["position": .object(["channel": ch, "position": .number(Double(level.percent))])]), readBack: ["position": .integer(Int64(level.percent))])
        case (.shutter, .invokeAction("open", _)):
            return .init(namespace: MerossNamespace.shutterPosition, payload: .object(["position": .object(["channel": ch, "position": .number(100)])]), readBack: ["position": .integer(100)])
        case (.shutter, .invokeAction("close", _)):
            return .init(namespace: MerossNamespace.shutterPosition, payload: .object(["position": .object(["channel": ch, "position": .number(0)])]), readBack: ["position": .integer(0)])
        case (.shutter, .invokeAction("stop", _)):
            return .init(namespace: MerossNamespace.shutterPosition, payload: .object(["position": .object(["channel": ch, "position": .number(-1)])]), readBack: [:])

        case (_, .setPower): throw IoTError.notSupported("Meross setPower")
        case (_, .setLevel): throw IoTError.notSupported("Meross setLevel")
        case (_, .setAttribute(let name, _)): throw IoTError.notSupported("Meross attribute \(name)")
        case (_, .invokeAction(let name, _)): throw IoTError.notSupported("Meross action \(name)")
        }
    }

    private static func number(_ value: StateValue) -> Double? {
        switch value { case .decimal(let d): d; case .integer(let i): Double(i); default: nil }
    }
    private static func component(_ value: StateValue?) -> Int? {
        guard let value, let n = number(value), n >= 0, n <= 255 else { return nil }
        return Int(n.rounded())
    }
}
#endif
