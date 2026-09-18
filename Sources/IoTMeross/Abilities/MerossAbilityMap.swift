import Foundation
import IoTCore

#if canImport(Darwin)
enum MerossNamespace {
    static let systemAll = "Appliance.System.All"
    static let systemAbility = "Appliance.System.Ability"
    static let systemOnline = "Appliance.System.Online"
    static let toggle = "Appliance.Control.Toggle"
    static let toggleX = "Appliance.Control.ToggleX"
    static let light = "Appliance.Control.Light"
    static let electricity = "Appliance.Control.Electricity"
    static let consumptionX = "Appliance.Control.ConsumptionX"
    static let thermostatMode = "Appliance.Control.Thermostat.Mode"
    static let thermostatWindow = "Appliance.Control.Thermostat.WindowOpened"
    static let diffuserSpray = "Appliance.Control.Diffuser.Spray"
    static let diffuserLight = "Appliance.Control.Diffuser.Light"
    static let garageState = "Appliance.GarageDoor.State"
    static let shutterState = "Appliance.RollerShutter.State"
    static let shutterPosition = "Appliance.RollerShutter.Position"
    static let hubToggleX = "Appliance.Hub.ToggleX"
    static let hubMts100All = "Appliance.Hub.Mts100.All"
    static let hubMts100Mode = "Appliance.Hub.Mts100.Mode"
    static let hubSensorAll = "Appliance.Hub.Sensor.All"
    static let hubSensorTempHum = "Appliance.Hub.Sensor.TempHum"
}

enum MerossFamily: Hashable, Sendable { case toggle, toggleX, light, thermostat, diffuser, garage, shutter, hub, unknown }

/// What one device can do, derived only from what it declares. Order of precedence matters:
/// a thermostat also declares ToggleX, a bulb too; the richer family wins.
struct MerossProfile: Hashable, Sendable {
    let family: MerossFamily
    let kind: DeviceKind
    let abilities: Set<String>
    let readNamespaces: [String]
    let canControl: Bool
    let commands: [String]
    var isHub: Bool { family == .hub }

    func descriptors() -> [CapabilityDescriptor] {
        var result: [CapabilityDescriptor] = [
            CapabilityDescriptor(id: .readState, operations: [.readState],
                metadata: ["transport": .string("lan-http"), "authenticated": .bool(true), "requestCorrelation": .bool(true)]),
            CapabilityDescriptor(id: .subscribe, operations: [.subscribe],
                metadata: ["delivery": .string("shared-polling"), "buffer": .integer(1)]),
        ]
        if canControl {
            result.append(CapabilityDescriptor(id: .control, operations: [.control],
                metadata: ["commands": .array(commands.map { .string($0) }), "confirmation": .string("re-read")]))
        }
        return result
    }
}

enum MerossAbilityMap {
    static func profile(abilities: Set<String>) -> MerossProfile {
        let has = { (namespace: String) in abilities.contains(namespace) }
        let metering = [MerossNamespace.electricity, MerossNamespace.consumptionX].filter(has)
        if has(MerossNamespace.hubMts100All) || has(MerossNamespace.hubSensorAll) || has(MerossNamespace.hubToggleX) {
            return MerossProfile(family: .hub, kind: .bridge, abilities: abilities, readNamespaces: [], canControl: false, commands: [])
        }
        if has(MerossNamespace.thermostatMode) {
            return MerossProfile(family: .thermostat, kind: .thermostat, abilities: abilities,
                readNamespaces: [MerossNamespace.thermostatMode] + (has(MerossNamespace.thermostatWindow) ? [MerossNamespace.thermostatWindow] : []),
                canControl: true, commands: ["setPower", "setAttribute:targetTemperature", "setAttribute:mode"])
        }
        if has(MerossNamespace.diffuserSpray) {
            return MerossProfile(family: .diffuser, kind: .appliance, abilities: abilities,
                readNamespaces: [MerossNamespace.diffuserSpray] + (has(MerossNamespace.diffuserLight) ? [MerossNamespace.diffuserLight] : []),
                canControl: true, commands: ["setPower", "setAttribute:sprayMode"] + (has(MerossNamespace.diffuserLight) ? ["setAttribute:light"] : []))
        }
        if has(MerossNamespace.garageState) {
            return MerossProfile(family: .garage, kind: .cover, abilities: abilities, readNamespaces: [MerossNamespace.garageState],
                canControl: true, commands: ["invokeAction:open", "invokeAction:close"])
        }
        if has(MerossNamespace.shutterState) {
            return MerossProfile(family: .shutter, kind: .cover, abilities: abilities,
                readNamespaces: [MerossNamespace.shutterState] + (has(MerossNamespace.shutterPosition) ? [MerossNamespace.shutterPosition] : []),
                canControl: true, commands: (has(MerossNamespace.shutterPosition) ? ["setLevel"] : []) + ["invokeAction:open", "invokeAction:close", "invokeAction:stop"])
        }
        if has(MerossNamespace.light) {
            return MerossProfile(family: .light, kind: .light, abilities: abilities, readNamespaces: [MerossNamespace.light],
                canControl: true, commands: ["setPower", "setLevel", "setAttribute:colorTemperature", "setAttribute:color"])
        }
        if has(MerossNamespace.toggleX) {
            let electricityOnly = has(MerossNamespace.electricity) ? [MerossNamespace.electricity] : []
            return MerossProfile(family: .toggleX, kind: metering.isEmpty ? .switchDevice : .outlet, abilities: abilities,
                readNamespaces: electricityOnly, canControl: true, commands: ["setPower"])
        }
        if has(MerossNamespace.toggle) {
            let electricityOnly = has(MerossNamespace.electricity) ? [MerossNamespace.electricity] : []
            return MerossProfile(family: .toggle, kind: .switchDevice, abilities: abilities, readNamespaces: electricityOnly,
                canControl: true, commands: ["setPower"])
        }
        return MerossProfile(family: .unknown, kind: .unknown, abilities: abilities, readNamespaces: [], canControl: false, commands: [])
    }
}
#endif
