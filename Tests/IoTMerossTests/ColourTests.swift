import Testing
import IoTCore
@testable import IoTMeross

#if canImport(Darwin)
struct MerossColourTests {
    @Test func typedColourIsExplicitlyUnsupported() throws {
        let profile = MerossAbilityMap.profile(abilities: [MerossNamespace.light])
        #expect(throws: IoTError.notSupported("Meross colour is not encoded in this version")) {
            try MerossCommandEncoder.encode(.setColor(.init(red: 255, green: 0, blue: 16), level: nil), channel: 0, profile: profile, current: nil)
        }
    }
}
#endif
