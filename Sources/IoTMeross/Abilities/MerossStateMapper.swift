import Foundation
import IoTCore

#if canImport(Darwin)
struct MerossSnapshot: Hashable, Sendable {
    let all: MerossJSON
    let extras: [String: MerossJSON]
}

enum MerossStateMapper {
    static let thermostatModes: [Int: String] = [0: "heat", 1: "cool", 2: "eco", 3: "auto", 4: "manual"]
    static let sprayModes: [Int: String] = [0: "off", 1: "continuous", 2: "intermittent"]

    static func identity(all: MerossJSON) -> (uuid: String, firmware: String?, innerIp: String?, mac: String?, online: Bool?)? {
        let system = all["all"]?["system"]
        guard let uuid = system?["hardware"]?["uuid"]?.stringValue, !uuid.isEmpty else { return nil }
        let online = system?["online"]?["status"]?.intValue
        return (uuid, system?["firmware"]?["version"]?.stringValue, system?["firmware"]?["innerIp"]?.stringValue,
                system?["hardware"]?["macAddress"]?.stringValue, online.map { $0 == 1 })
    }

    static func state(deviceID: DeviceID, channel: Int, profile: MerossProfile, snapshot: MerossSnapshot,
                      sequence: UInt64, now: Date) -> DeviceState {
        let digest = snapshot.all["all"]?["digest"]
        var attributes: [String: StateAttribute] = [:]
        var primary: StateValue?
        var unit: UnitSymbol?
        let availability: DeviceAvailability = identity(all: snapshot.all)?.online == false ? .offline : .online

        func entry(_ list: MerossJSON?, key: String = "channel") -> MerossJSON? {
            if let array = list?.arrayValue { return array.first { $0[key]?.intValue == channel } ?? (channel == 0 ? array.first : nil) }
            if let object = list?.objectValue, (object[key]?.intValue ?? 0) == channel { return list }
            return nil
        }
        func tenths(_ value: MerossJSON?) -> Double? { value?.doubleValue.map { $0 / 10 } }
        func rgb(_ value: MerossJSON?) -> StateValue? {
            guard let packed = value?.intValue, packed >= 0, packed <= 0xFFFFFF else { return nil }
            return .object(["r": .integer(Int64((packed >> 16) & 0xFF)), "g": .integer(Int64((packed >> 8) & 0xFF)), "b": .integer(Int64(packed & 0xFF))])
        }

        switch profile.family {
        case .toggleX, .toggle, .light:
            let toggle = entry(digest?["togglex"]) ?? entry(digest?["toggle"])
            if let on = toggle?["onoff"]?.intValue { primary = .bool(on == 1); attributes["power"] = .init(value: .bool(on == 1)) }
            if profile.family == .light, let light = entry(snapshot.extras[MerossNamespace.light]?["light"]) ?? entry(digest?["light"]) {
                if let on = light["onoff"]?.intValue { primary = .bool(on == 1); attributes["power"] = .init(value: .bool(on == 1)) }
                if let level = light["luminance"]?.intValue { attributes["brightness"] = .init(value: .integer(Int64(level)), unit: .percent) }
                if let temperature = light["temperature"]?.intValue { attributes["colorTemperature"] = .init(value: .integer(Int64(temperature)), unit: .percent) }
                if let color = rgb(light["rgb"]) { attributes["color"] = .init(value: color) }
            }
        case .thermostat:
            let mode = entry(snapshot.extras[MerossNamespace.thermostatMode]?["mode"]) ?? entry(digest?["thermostat"]?["mode"])
            if let on = mode?["onoff"]?.intValue { attributes["power"] = .init(value: .bool(on == 1)) }
            if let current = tenths(mode?["currentTemp"]) { attributes["temperature"] = .init(value: .decimal(current), unit: .celsius) }
            if let target = tenths(mode?["targetTemp"]) { attributes["targetTemperature"] = .init(value: .decimal(target), unit: .celsius); primary = .decimal(target); unit = .celsius }
            if let raw = mode?["mode"]?.intValue { attributes["mode"] = .init(value: .string(thermostatModes[raw] ?? "mode-\(raw)")) }
            if let heating = mode?["state"]?.intValue { attributes["heating"] = .init(value: .bool(heating == 1)) }
            if let min = tenths(mode?["min"]) { attributes["minTemperature"] = .init(value: .decimal(min), unit: .celsius) }
            if let max = tenths(mode?["max"]) { attributes["maxTemperature"] = .init(value: .decimal(max), unit: .celsius) }
            if let window = entry(snapshot.extras[MerossNamespace.thermostatWindow]?["windowOpened"])?["status"]?.intValue {
                attributes["windowOpen"] = .init(value: .bool(window == 1))
            }
        case .diffuser:
            let spray = entry(snapshot.extras[MerossNamespace.diffuserSpray]?["spray"]) ?? entry(digest?["diffuser"]?["spray"])
            if let raw = spray?["mode"]?.intValue {
                attributes["sprayMode"] = .init(value: .string(sprayModes[raw] ?? "mode-\(raw)"))
                primary = .bool(raw != 0); attributes["power"] = .init(value: .bool(raw != 0))
            }
            if let light = entry(snapshot.extras[MerossNamespace.diffuserLight]?["light"]) ?? entry(digest?["diffuser"]?["light"]) {
                if let on = light["onoff"]?.intValue { attributes["light"] = .init(value: .bool(on == 1)) }
                if let level = light["luminance"]?.intValue { attributes["brightness"] = .init(value: .integer(Int64(level)), unit: .percent) }
                if let color = rgb(light["rgb"]) { attributes["color"] = .init(value: color) }
            }
        case .garage:
            let door = entry(snapshot.extras[MerossNamespace.garageState]?["state"]) ?? entry(digest?["garageDoor"])
            if let open = door?["open"]?.intValue { primary = .bool(open == 1); attributes["open"] = .init(value: .bool(open == 1)) }
        case .shutter:
            if let position = entry(snapshot.extras[MerossNamespace.shutterPosition]?["position"])?["position"]?.intValue {
                primary = .integer(Int64(position)); unit = .percent
                attributes["position"] = .init(value: .integer(Int64(position)), unit: .percent)
            }
            if let state = entry(snapshot.extras[MerossNamespace.shutterState]?["state"])?["state"]?.intValue {
                attributes["motion"] = .init(value: .string(state == 0 ? "idle" : state == 1 ? "opening" : "closing"))
            }
        case .hub, .unknown:
            if let digest { attributes["digest"] = .init(value: digest.stateValue()) }
        }

        if let electricity = entry(snapshot.extras[MerossNamespace.electricity]?["electricity"]) {
            if let power = electricity["power"]?.doubleValue { attributes["watt"] = .init(value: .decimal(power / 1000), unit: .watt) }
            if let voltage = electricity["voltage"]?.doubleValue { attributes["volt"] = .init(value: .decimal(voltage / 10), unit: .volt) }
            if let current = electricity["current"]?.doubleValue { attributes["ampere"] = .init(value: .decimal(current / 1000), unit: .ampere) }
        }
        if let today = snapshot.extras[MerossNamespace.consumptionX]?["consumptionx"]?.arrayValue?.last?["value"]?.doubleValue {
            attributes["energyToday"] = .init(value: .decimal(today / 1000), unit: .kilowattHour)
        }

        return DeviceState(deviceID: deviceID, availability: availability, primaryValue: primary, primaryUnit: unit,
                           attributes: attributes, observedAt: now, receivedAt: now, origin: .local,
                           revision: .init(localSequence: sequence))
    }
}
#endif
