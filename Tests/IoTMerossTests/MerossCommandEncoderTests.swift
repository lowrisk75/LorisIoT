import Foundation
import Testing
import IoTCore
@testable import IoTMeross

#if canImport(Darwin)
struct MerossCommandEncoderTests {
    private func profile(_ abilities: Set<String>) -> MerossProfile { MerossAbilityMap.profile(abilities: abilities) }

    @Test func togglePower() throws {
        let command = try MerossCommandEncoder.encode(.setPower(true), channel: 2, profile: profile([MerossNamespace.toggleX]), current: nil)
        #expect(command.namespace == MerossNamespace.toggleX)
        #expect(command.payload == .object(["togglex": .object(["channel": .number(2), "onoff": .number(1)])]))
        #expect(command.readBack == ["power": .bool(true)])
        let legacy = try MerossCommandEncoder.encode(.setPower(false), channel: 0, profile: profile([MerossNamespace.toggle]), current: nil)
        #expect(legacy.namespace == MerossNamespace.toggle)
        #expect(legacy.payload == .object(["toggle": .object(["channel": .number(0), "onoff": .number(0)])]))
    }
    @Test func thermostatSetpointRoundsToHalfDegreeInTenths() throws {
        let setpoint = try MerossCommandEncoder.encode(.setAttribute(name: "targetTemperature", value: .decimal(21.3)), channel: 0,
                                                       profile: profile([MerossNamespace.thermostatMode]), current: nil)
        #expect(setpoint.namespace == MerossNamespace.thermostatMode)
        #expect(setpoint.payload == .object(["mode": .array([.object(["channel": .number(0), "manualTemp": .number(215), "mode": .number(4)])])]))
        #expect(setpoint.readBack == ["targetTemperature": .decimal(21.5), "mode": .string("manual")])
        let mode = try MerossCommandEncoder.encode(.setAttribute(name: "mode", value: .string("eco")), channel: 0, profile: profile([MerossNamespace.thermostatMode]), current: nil)
        #expect(mode.payload == .object(["mode": .array([.object(["channel": .number(0), "mode": .number(2)])])]))
        #expect(mode.readBack == ["mode": .string("eco")])
        let power = try MerossCommandEncoder.encode(.setPower(false), channel: 0, profile: profile([MerossNamespace.thermostatMode]), current: nil)
        #expect(power.payload == .object(["mode": .array([.object(["channel": .number(0), "onoff": .number(0)])])]))
        #expect(power.readBack == ["power": .bool(false)])
        #expect(throws: IoTError.self) { try MerossCommandEncoder.encode(.setAttribute(name: "mode", value: .string("party")), channel: 0, profile: profile([MerossNamespace.thermostatMode]), current: nil) }
        #expect(throws: IoTError.self) { try MerossCommandEncoder.encode(.setAttribute(name: "targetTemperature", value: .decimal(80)), channel: 0, profile: profile([MerossNamespace.thermostatMode]), current: nil) }
    }
    @Test func diffuserPowerMapsToSprayMode() throws {
        let on = try MerossCommandEncoder.encode(.setPower(true), channel: 0, profile: profile([MerossNamespace.diffuserSpray]), current: nil)
        #expect(on.payload == .object(["spray": .array([.object(["channel": .number(0), "mode": .number(1)])])]))
        #expect(on.readBack == ["power": .bool(true)])
        let intermittent = try MerossCommandEncoder.encode(.setAttribute(name: "sprayMode", value: .string("intermittent")), channel: 0, profile: profile([MerossNamespace.diffuserSpray]), current: nil)
        #expect(intermittent.payload == .object(["spray": .array([.object(["channel": .number(0), "mode": .number(2)])])]))
        #expect(intermittent.readBack == ["sprayMode": .string("intermittent")])
        let light = try MerossCommandEncoder.encode(.setAttribute(name: "light", value: .bool(false)), channel: 0, profile: profile([MerossNamespace.diffuserSpray, MerossNamespace.diffuserLight]), current: nil)
        #expect(light.namespace == MerossNamespace.diffuserLight)
        #expect(light.payload == .object(["light": .array([.object(["channel": .number(0), "onoff": .number(0)])])]))
    }
    @Test func lightLevelColorAndTemperature() throws {
        let level = try MerossCommandEncoder.encode(.setLevel(try UnitInterval(0.5)), channel: 0, profile: profile([MerossNamespace.light]), current: nil)
        #expect(level.payload == .object(["light": .object(["channel": .number(0), "luminance": .number(50), "capacity": .number(4)])]))
        #expect(level.readBack == ["brightness": .integer(50)])
        let color = try MerossCommandEncoder.encode(.setAttribute(name: "color", value: .object(["r": .integer(255), "g": .integer(0), "b": .integer(16)])), channel: 0, profile: profile([MerossNamespace.light]), current: nil)
        #expect(color.payload == .object(["light": .object(["channel": .number(0), "rgb": .number(16711696), "capacity": .number(1)])]))
        let temperature = try MerossCommandEncoder.encode(.setAttribute(name: "colorTemperature", value: .integer(70)), channel: 0, profile: profile([MerossNamespace.light]), current: nil)
        #expect(temperature.payload == .object(["light": .object(["channel": .number(0), "temperature": .number(70), "capacity": .number(2)])]))
    }
    @Test func coversAndUnsupported() throws {
        let open = try MerossCommandEncoder.encode(.invokeAction(name: "open", arguments: [:]), channel: 0, profile: profile([MerossNamespace.garageState]), current: nil)
        #expect(open.payload == .object(["state": .object(["channel": .number(0), "open": .number(1), "uuid": .string("")])]))
        #expect(open.readBack == ["open": .bool(true)])
        let position = try MerossCommandEncoder.encode(.setLevel(try UnitInterval(0.25)), channel: 0, profile: profile([MerossNamespace.shutterState, MerossNamespace.shutterPosition]), current: nil)
        #expect(position.namespace == MerossNamespace.shutterPosition)
        #expect(position.payload == .object(["position": .object(["channel": .number(0), "position": .number(25)])]))
        let stop = try MerossCommandEncoder.encode(.invokeAction(name: "stop", arguments: [:]), channel: 0, profile: profile([MerossNamespace.shutterState]), current: nil)
        #expect(stop.payload == .object(["position": .object(["channel": .number(0), "position": .number(-1)])]))
        #expect(throws: IoTError.notSupported("Meross setLevel")) { try MerossCommandEncoder.encode(.setLevel(try UnitInterval(0.5)), channel: 0, profile: profile([MerossNamespace.toggleX]), current: nil) }
        #expect(throws: IoTError.notSupported("Meross control")) { try MerossCommandEncoder.encode(.setPower(true), channel: 0, profile: profile(["Appliance.Weird"]), current: nil) }
    }
}
#endif
