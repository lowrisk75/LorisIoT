import Testing
import Foundation
@testable import IoTHomeKit
import IoTCore

// HomeKit itself is device-gated (no Simulator, needs a home hub + entitlement), so these cover the
// provider's structure/mapping without touching HMHomeManager.
@Suite struct HomeKitStructureTests {
    @Test func providerIdentity() {
        let p = HomeKitProvider()
        #expect(p.id == "homekit")
        #expect(p.displayName == "HomeKit")
    }

    @Test func invalidDeviceCannotAdvertiseCapabilitiesWithoutTouchingHomeKit() async throws {
        await #expect(throws: IoTError.notConfigured) {
            try await HomeKitProvider().capabilities(for: "acc-uuid")
        }
    }

    @Test func stateMapping() {
        #expect(homeKitState(true, id: "x", seq: 1).primaryValue == .bool(true))
        #expect(homeKitState(nil, id: "x", seq: 1).availability == .offline)
    }
}
