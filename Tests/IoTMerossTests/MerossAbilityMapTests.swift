import Foundation
import Testing
import IoTCore
@testable import IoTMeross

#if canImport(Darwin)
struct MerossAbilityMapTests {
    @Test func plugWithMeteringIsControllableOutlet() {
        let profile = MerossAbilityMap.profile(abilities: [MerossNamespace.systemAll, MerossNamespace.toggleX, MerossNamespace.electricity, MerossNamespace.consumptionX])
        #expect(profile.family == .toggleX && profile.kind == .outlet && profile.canControl)
        #expect(profile.readNamespaces == [MerossNamespace.electricity])
        #expect(profile.commands == ["setPower"])
        #expect(profile.descriptors().map(\.id) == [.readState, .subscribe, .control])
    }
    @Test func thermostatDiffuserGarageShutter() {
        let thermostat = MerossAbilityMap.profile(abilities: [MerossNamespace.thermostatMode, MerossNamespace.thermostatWindow, MerossNamespace.toggleX])
        #expect(thermostat.family == .thermostat && thermostat.kind == .thermostat)
        #expect(thermostat.commands == ["setPower", "setAttribute:targetTemperature", "setAttribute:mode"])
        #expect(thermostat.readNamespaces == [MerossNamespace.thermostatMode, MerossNamespace.thermostatWindow])
        let diffuser = MerossAbilityMap.profile(abilities: [MerossNamespace.diffuserSpray, MerossNamespace.diffuserLight])
        #expect(diffuser.family == .diffuser && diffuser.kind == .appliance)
        #expect(diffuser.commands == ["setPower", "setAttribute:sprayMode", "setAttribute:light"])
        let garage = MerossAbilityMap.profile(abilities: [MerossNamespace.garageState, MerossNamespace.toggleX])
        #expect(garage.family == .garage && garage.kind == .cover && garage.commands == ["invokeAction:open", "invokeAction:close"])
        let shutter = MerossAbilityMap.profile(abilities: [MerossNamespace.shutterState, MerossNamespace.shutterPosition])
        #expect(shutter.family == .shutter && shutter.kind == .cover && shutter.commands == ["setLevel", "invokeAction:open", "invokeAction:close", "invokeAction:stop"])
    }
    @Test func lightAndLegacyToggle() {
        let bulb = MerossAbilityMap.profile(abilities: [MerossNamespace.light, MerossNamespace.toggleX])
        #expect(bulb.family == .light && bulb.kind == .light && bulb.commands == ["setPower", "setLevel", "setAttribute:colorTemperature", "setAttribute:color"])
        let legacy = MerossAbilityMap.profile(abilities: [MerossNamespace.toggle])
        #expect(legacy.family == .toggle && legacy.kind == .switchDevice && legacy.canControl)
    }
    @Test func hubAndUnknownStayHonest() {
        let hub = MerossAbilityMap.profile(abilities: [MerossNamespace.hubMts100All, MerossNamespace.hubSensorAll])
        #expect(hub.family == .hub && hub.isHub && hub.kind == .bridge && !hub.canControl)
        let unknown = MerossAbilityMap.profile(abilities: ["Appliance.Control.Something.New"])
        #expect(unknown.family == .unknown && unknown.kind == .unknown && !unknown.canControl)
        #expect(unknown.descriptors().map(\.id) == [.readState, .subscribe])
    }
}
#endif
