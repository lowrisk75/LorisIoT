import Foundation
import Testing
import IoTCore
@testable import IoTDreo

@Suite struct DreoProviderTests {
    @Test func inventoryUsesNativeSerialAndDiscoveredFanRanges() async throws {
        let p = provider(Fixture()); try await p.connect()
        let devices = try await p.devices()
        #expect(devices.count == 2)
        #expect(devices.allSatisfy { $0.providerID == "dreo" && $0.kind == .fan })
        let caps = try await p.capabilities(for: "fan-1")
        #expect(caps.control != nil && caps.schedule == nil && caps.subscribe == nil)
        #expect(caps.descriptors.last?.metadata["maximumSpeed"] == .integer(8))
    }
    @Test func readOnlyByDefaultAndUnknownModelsHaveNoControl() async throws {
        let p = provider(Fixture(), control: false); try await p.connect()
        #expect(try await p.capabilities(for: "fan-1").control == nil)
        let other = provider(Fixture(model: "DR-UNKNOWN")); try await other.connect()
        #expect(try await other.capabilities(for: "fan-1").control == nil)
    }
    @Test func regionAndAccountStayBoundAcrossTokenRefresh() async throws {
        let http = Fixture(); let credentials = Credentials()
        let p = DreoProvider(token: { try await credentials.token() }, allowsControl: true, http: http)
        try await p.connect()
        await credentials.changeAccount()
        let reader = try #require(try await p.capabilities(for: "fan-1").readState)
        await #expect(throws: (any Error).self) { try await reader.state() }
        #expect(await http.requests.count == 1)
    }
    @Test func expiredOrMalformedTokenNeverReachesHTTP() async throws {
        #expect(throws: (any Error).self) { try DreoAccessToken(value: "fixture:EU", accountID: "a", region: .northAmerica, expiresAt: .distantFuture) }
        #expect(throws: (any Error).self) { try DreoAccessToken(value: "fixture\r\ninjected", accountID: "a", region: .europe, expiresAt: .distantFuture) }
        let http = Fixture()
        let p = DreoProvider(token: { try DreoAccessToken(value: "fixture", accountID: "a", region: .europe, expiresAt: .distantPast) }, http: http)
        await #expect(throws: (any Error).self) { try await p.connect() }
        #expect(await http.requests.isEmpty)
    }
    @Test func tokenSuffixIsNotTransmittedAndRequestsStayInEurope() async throws {
        let http = Fixture(); let p = provider(http); try await p.connect()
        let reader = try #require(try await p.capabilities(for: "fan-1").readState); _ = try await reader.state()
        #expect(await http.requests.allSatisfy { $0.url?.host == "open-api-eu.dreo-tech.com" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" })
        #expect(await http.requests.allSatisfy { !($0.url!.absoluteString.contains("fixture-token")) })
    }
    @Test func missingObservationTimeIsNotFreshPhysicalEvidence() async throws {
        let p = provider(Fixture()); try await p.connect()
        let reader = try #require(try await p.capabilities(for: "fan-1").readState)
        let state = try await reader.state()
        #expect(state.primaryValue == .bool(true)); #expect(state.origin == .cloud)
        #expect(state.observedAt == .distantPast && state.availability == .degraded)
        #expect(state.freshness() != .current)
    }
    @Test func offlineOrWrongIdentityRefusesCommands() async throws {
        for http in [Fixture(connected: false), Fixture(stateSerial: "different")] {
            let p = provider(http); try await p.connect()
            let control = try #require(try await p.capabilities(for: "fan-1").control)
            await #expect(throws: (any Error).self) { try await control.execute(SetPowerCommand(deviceID: "fan-1", isOn: false)) }
            #expect(await http.posts == 0)
        }
    }
    @Test func commandsValidateExactTargetAndAdvertisedRange() async throws {
        let http = Fixture(); let p = provider(http); try await p.connect()
        let control = try #require(try await p.capabilities(for: "fan-1").control)
        for command in [DreoFanCommand(deviceID: "wrong", speed: 3), DreoFanCommand(deviceID: "fan-1", speed: 9), DreoFanCommand(deviceID: "fan-1", mode: "invented")] {
            await #expect(throws: (any Error).self) { try await control.execute(command) }
        }
        #expect(await http.posts == 0)
    }
    @Test func speedDoesNotImplicitlyTurnOnFanAndCloudAckIsOnlyAccepted() async throws {
        let http = Fixture(); let p = provider(http); try await p.connect()
        let control = try #require(try await p.capabilities(for: "fan-1").control)
        let receipt = try await control.execute(DreoFanCommand(deviceID: "fan-1", speed: 4))
        #expect(receipt.outcome == .accepted && receipt.state?.origin == .cloud)
        let request = try #require(await http.requests.first { $0.httpMethod == "POST" })
        let bytes = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(body["devicesn"] as? String == "fan-1")
        #expect((body["desired"] as? [String: Int]) == ["speed": 4])
        #expect(await http.posts == 1)
    }
    @Test func lostCommandIsNeverReplayed() async throws {
        let http = Fixture(failPost: true); let p = provider(http); try await p.connect()
        let control = try #require(try await p.capabilities(for: "fan-1").control)
        let result = try await control.execute(SetPowerCommand(deviceID: "fan-1", isOn: false))
        #expect(result.outcome == .uncertain)
        #expect(await http.posts == 1)
    }
    @Test func disconnectInvalidatesOldHandlesEvenAfterReconnect() async throws {
        let http = Fixture(); let p = provider(http); try await p.connect()
        let old = try #require(try await p.capabilities(for: "fan-1").control)
        await p.disconnect(); try await p.connect()
        await #expect(throws: (any Error).self) { try await old.execute(SetPowerCommand(deviceID: "fan-1", isOn: true)) }
        #expect(await http.posts == 0)
    }
    @Test func disconnectDuringTokenLookupCannotSend() async throws {
        let http = Fixture(); let gate = TokenGate()
        let p = DreoProvider(token: { await gate.wait(); return try DreoAccessToken(value: "fixture", accountID: "a", region: .europe, expiresAt: .distantFuture) }, http: http)
        let task = Task { try await p.connect() }
        while !(await gate.entered) { await Task.yield() }
        await p.disconnect(); await gate.release()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(await http.requests.isEmpty)
    }
    @Test func revokedProfilePreventsRetainedCapabilityFromSending() async throws {
        let http = Fixture(); let p = provider(http); try await p.connect()
        let control = try #require(try await p.capabilities(for: "fan-1").control)
        await http.revokeProfile()
        await #expect(throws: (any Error).self) { try await control.execute(SetPowerCommand(deviceID: "fan-1", isOn: true)) }
        #expect(await http.posts == 0)
    }
    @Test func productionBoundaryRejectsForeignOriginsAndUnapprovedRoutes() {
        for address in ["http://open-api-eu.dreo-tech.com/api/v2/device/list", "https://open-api-eu.dreo-tech.com.evil.test/api/v2/device/list", "https://user@open-api-eu.dreo-tech.com/api/v2/device/list", "https://open-api-eu.dreo-tech.com/api/oauth/login", "https://open-api-eu.dreo-tech.com/api/v2/device/list?token=bad"] {
            #expect(!DreoURLSessionHTTP.allowed(URLRequest(url: URL(string: address)!)))
        }
    }
}
private func provider(_ http: Fixture, control: Bool = true) -> DreoProvider {
    DreoProvider(token: { try DreoAccessToken(value: "fixture-token:EU", accountID: "fixture-account", region: .europe, expiresAt: Date().addingTimeInterval(3600)) }, allowsControl: control, http: http)
}
private actor Credentials {
    var account = "a"
    func changeAccount() { account = "b" }
    func token() throws -> DreoAccessToken { try .init(value: "fixture", accountID: account, region: .europe, expiresAt: .distantFuture) }
}
private actor Fixture: DreoHTTP {
    var requests: [URLRequest] = []
    var posts: Int { requests.filter { $0.httpMethod == "POST" }.count }
    var model: String; let connected: Bool; let stateSerial: String; let failPost: Bool
    init(model: String = "DR-HAF003S", connected: Bool = true, stateSerial: String = "fan-1", failPost: Bool = false) {
        self.model = model; self.connected = connected; self.stateSerial = stateSerial; self.failPost = failPost
    }
    func revokeProfile() { model = "DR-UNKNOWN" }
    func send(_ request: URLRequest) async throws -> DreoHTTPResponse {
        requests.append(request)
        let data: Any
        if request.httpMethod == "POST" {
            if failPost { throw URLError(.timedOut) }
            data = ["accepted": true]
        } else if request.url!.path.hasSuffix("/state") {
            data = ["deviceSn": stateSerial, "connected": connected, "power_switch": true, "speed": 4, "mode": "Normal"] as [String: Any]
        } else {
            data = [["deviceSn": "fan-1", "deviceName": "PolyFan", "model": model, "deviceType": "circulation_fan", "config": ["fan_entity_config": ["speed_range": [1,8], "preset_modes": ["Normal", "Sleep"]]]],
                    ["deviceSn": "fan-2", "deviceName": "Lynx", "model": "DR-HAF001S", "deviceType": "circulation_fan", "config": ["fan_entity_config": ["speed_range": [1,4]]]]] as [[String: Any]]
        }
        return .init(data: try JSONSerialization.data(withJSONObject: ["code": 0, "data": data]), status: 200)
    }
}

private actor TokenGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
