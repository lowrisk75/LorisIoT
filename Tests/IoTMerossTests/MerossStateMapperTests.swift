import Foundation
import Testing
import IoTCore
@testable import IoTMeross

#if canImport(Darwin)
struct MerossStateMapperTests {
    private func json(_ text: String) throws -> MerossJSON { try JSONDecoder().decode(MerossJSON.self, from: Data(text.utf8)) }
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func identityFromSystemAll() throws {
        let all = try json(#"{"all":{"system":{"hardware":{"uuid":"ABC","macAddress":"34:29:8f:00:00:01"},"firmware":{"version":"6.1.8","innerIp":"192.168.1.20"},"online":{"status":1}}}}"#)
        let identity = try #require(MerossStateMapper.identity(all: all))
        #expect(identity.uuid == "ABC" && identity.firmware == "6.1.8" && identity.innerIp == "192.168.1.20" && identity.online == true)
        #expect(MerossStateMapper.identity(all: try json(#"{"all":{}}"#)) == nil)
    }
    @Test func plugWithElectricity() throws {
        let all = try json(#"{"all":{"system":{"hardware":{"uuid":"ABC"},"online":{"status":1}},"digest":{"togglex":[{"channel":0,"onoff":1,"lmTime":1}]}}}"#)
        let electricity = try json(#"{"electricity":{"channel":0,"current":512,"voltage":2301,"power":123456}}"#)
        let profile = MerossAbilityMap.profile(abilities: [MerossNamespace.toggleX, MerossNamespace.electricity])
        let state = MerossStateMapper.state(deviceID: "meross:ABC", channel: 0, profile: profile,
                                            snapshot: .init(all: all, extras: [MerossNamespace.electricity: electricity]), sequence: 7, now: now)
        #expect(state.primaryValue == .bool(true))
        #expect(state.availability == .online && state.origin == .local && state.revision.localSequence == 7)
        #expect(state.attributes["watt"] == .init(value: .decimal(123.456), unit: .watt))
        #expect(state.attributes["volt"] == .init(value: .decimal(230.1), unit: .volt))
        #expect(state.attributes["ampere"] == .init(value: .decimal(0.512), unit: .ampere))
        #expect(state.observedAt == now)
    }
    @Test func multiChannelPicksItsChannelAndOfflineStatus() throws {
        let all = try json(#"{"all":{"system":{"hardware":{"uuid":"ABC"},"online":{"status":2}},"digest":{"togglex":[{"channel":0,"onoff":1},{"channel":1,"onoff":0},{"channel":2,"onoff":1}]}}}"#)
        let profile = MerossAbilityMap.profile(abilities: [MerossNamespace.toggleX])
        let two = MerossStateMapper.state(deviceID: "meross:ABC#2", channel: 2, profile: profile, snapshot: .init(all: all, extras: [:]), sequence: 1, now: now)
        #expect(two.primaryValue == .bool(true) && two.availability == .offline)
        let one = MerossStateMapper.state(deviceID: "meross:ABC#1", channel: 1, profile: profile, snapshot: .init(all: all, extras: [:]), sequence: 2, now: now)
        #expect(one.primaryValue == .bool(false))
    }
    @Test func thermostatTenthsAndModes() throws {
        let all = try json(#"{"all":{"system":{"hardware":{"uuid":"T"},"online":{"status":1}},"digest":{"thermostat":{"mode":[{"channel":0,"onoff":1,"mode":4,"state":1,"currentTemp":215,"targetTemp":220,"heatTemp":240,"coolTemp":180,"ecoTemp":170,"manualTemp":220,"min":50,"max":350,"warning":0}]}}}}"#)
        let profile = MerossAbilityMap.profile(abilities: [MerossNamespace.thermostatMode])
        let state = MerossStateMapper.state(deviceID: "meross:T", channel: 0, profile: profile, snapshot: .init(all: all, extras: [:]), sequence: 1, now: now)
        #expect(state.primaryValue == .decimal(22.0) && state.primaryUnit == .celsius)
        #expect(state.attributes["temperature"] == .init(value: .decimal(21.5), unit: .celsius))
        #expect(state.attributes["targetTemperature"] == .init(value: .decimal(22.0), unit: .celsius))
        #expect(state.attributes["mode"]?.value == .string("manual"))
        #expect(state.attributes["power"]?.value == .bool(true))
        #expect(state.attributes["heating"]?.value == .bool(true))
        #expect(state.attributes["minTemperature"] == .init(value: .decimal(5.0), unit: .celsius))
    }
    @Test func diffuserSprayAndLight() throws {
        let all = try json(#"{"all":{"system":{"hardware":{"uuid":"D"},"online":{"status":1}},"digest":{"diffuser":{"type":"mod100","spray":[{"channel":0,"mode":2,"lmTime":1}],"light":[{"channel":0,"onoff":1,"mode":1,"luminance":60,"rgb":16711680}]}}}}"#)
        let profile = MerossAbilityMap.profile(abilities: [MerossNamespace.diffuserSpray, MerossNamespace.diffuserLight])
        let state = MerossStateMapper.state(deviceID: "meross:D", channel: 0, profile: profile, snapshot: .init(all: all, extras: [:]), sequence: 1, now: now)
        #expect(state.primaryValue == .bool(true))
        #expect(state.attributes["sprayMode"]?.value == .string("intermittent"))
        #expect(state.attributes["light"]?.value == .bool(true))
        #expect(state.attributes["brightness"] == .init(value: .integer(60), unit: .percent))
        #expect(state.attributes["color"]?.value == .object(["r": .integer(255), "g": .integer(0), "b": .integer(0)]))
        let off = try json(#"{"all":{"system":{"hardware":{"uuid":"D"},"online":{"status":1}},"digest":{"diffuser":{"spray":[{"channel":0,"mode":0}]}}}}"#)
        let offState = MerossStateMapper.state(deviceID: "meross:D", channel: 0, profile: profile, snapshot: .init(all: off, extras: [:]), sequence: 2, now: now)
        #expect(offState.primaryValue == .bool(false) && offState.attributes["sprayMode"]?.value == .string("off"))
    }
    @Test func bulbGarageShutter() throws {
        let bulb = try json(#"{"all":{"system":{"hardware":{"uuid":"B"},"online":{"status":1}},"digest":{"togglex":[{"channel":0,"onoff":1}],"light":{"channel":0,"onoff":1,"luminance":80,"temperature":40,"rgb":65280,"capacity":6}}}}"#)
        let bulbState = MerossStateMapper.state(deviceID: "meross:B", channel: 0, profile: MerossAbilityMap.profile(abilities: [MerossNamespace.light, MerossNamespace.toggleX]),
                                                snapshot: .init(all: bulb, extras: [:]), sequence: 1, now: now)
        #expect(bulbState.primaryValue == .bool(true))
        #expect(bulbState.attributes["brightness"] == .init(value: .integer(80), unit: .percent))
        #expect(bulbState.attributes["colorTemperature"] == .init(value: .integer(40), unit: .percent))
        let garage = try json(#"{"all":{"system":{"hardware":{"uuid":"G"},"online":{"status":1}},"digest":{"garageDoor":[{"channel":0,"open":1,"lmTime":1}]}}}"#)
        let garageState = MerossStateMapper.state(deviceID: "meross:G", channel: 0, profile: MerossAbilityMap.profile(abilities: [MerossNamespace.garageState]),
                                                  snapshot: .init(all: garage, extras: [:]), sequence: 1, now: now)
        #expect(garageState.primaryValue == .bool(true) && garageState.attributes["open"]?.value == .bool(true))
        let shutter = try json(#"{"all":{"system":{"hardware":{"uuid":"S"},"online":{"status":1}}}}"#)
        let position = try json(#"{"position":[{"channel":0,"position":35}]}"#)
        let shutterState = MerossStateMapper.state(deviceID: "meross:S", channel: 0, profile: MerossAbilityMap.profile(abilities: [MerossNamespace.shutterState, MerossNamespace.shutterPosition]),
                                                   snapshot: .init(all: shutter, extras: [MerossNamespace.shutterPosition: position]), sequence: 1, now: now)
        #expect(shutterState.primaryValue == .integer(35) && shutterState.primaryUnit == .percent)
    }
    @Test func unknownFamilyKeepsRawDigest() throws {
        let all = try json(#"{"all":{"system":{"hardware":{"uuid":"U"},"online":{"status":1}},"digest":{"weird":{"x":1}}}}"#)
        let state = MerossStateMapper.state(deviceID: "meross:U", channel: 0, profile: MerossAbilityMap.profile(abilities: ["Appliance.Weird"]),
                                            snapshot: .init(all: all, extras: [:]), sequence: 1, now: now)
        #expect(state.primaryValue == nil)
        #expect(state.attributes["digest"]?.value == .object(["weird": .object(["x": .integer(1)])]))
    }
}
#endif
