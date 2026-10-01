import Foundation
import Testing
import IoTCore
@testable import IoTSmartThings

private let uuid = "11111111-1111-4111-8111-111111111111"
private let target = DeviceID(rawValue: "11111111-1111-4111-8111-111111111111/main")
private func provider(_ http: Fixture, control: Bool = true) -> SmartThingsProvider {
    SmartThingsProvider(token: { try SmartThingsAccessToken(value: "fixture-token", expiresAt: Date().addingTimeInterval(3600)) }, allowsControl: control, http: http)
}
@Suite struct SmartThingsProviderTests {
    @Test func nativeInventoryAndComponentsAreNotHomeAssistantEntities() async throws {
        let http = Fixture(); let p = provider(http)
        try await p.connect()
        let devices = try await p.devices()
        #expect(devices.count == 2)
        #expect(Set(devices.map(\.id)).count == 2)
        #expect(devices.allSatisfy { $0.providerID == "smartthings" })
        #expect(try await p.capabilities(for: target).schedule == nil)
        #expect(await http.requests.allSatisfy { $0.url?.host == "api.smartthings.com" })
    }
    @Test func crossOriginPaginationCannotReceiveTheToken() async throws {
        let http = Fixture(next: "https://evil.example/v1/devices?page=1")
        await #expect(throws: (any Error).self) { try await provider(http).connect() }
        #expect(await http.requests.count == 1)
    }
    @Test func duplicatePagesAndEncodedPathCannotWidenTheTarget() async throws {
        for next in ["https://api.smartthings.com/v1/devices", "https://api.smartthings.com/v1/%64evices?page=1", "https://api.smartthings.com/v1/devices?access_token=bad"] {
            let http = Fixture(next: next)
            await #expect(throws: (any Error).self) { try await provider(http).connect() }
            #expect(await http.requests.count <= 2)
        }
    }
    @Test func expiredTokenDoesNotReachHTTP() async throws {
        let http = Fixture()
        let p = SmartThingsProvider(token: { try SmartThingsAccessToken(value: "expired", expiresAt: .distantPast) }, http: http)
        await #expect(throws: (any Error).self) { try await p.connect() }
        #expect(await http.requests.isEmpty)
    }
    @Test func defaultConnectionIsReadOnly() async throws {
        let p = provider(Fixture(), control: false); try await p.connect()
        #expect(try await p.capabilities(for: target).control == nil)
    }
    @Test func unadvertisedCommandNeverDispatches() async throws {
        let http = Fixture(); let p = provider(http); try await p.connect()
        let secondary = DeviceID(rawValue: uuid + "/secondary")
        let control = try #require(try await p.capabilities(for: secondary).control)
        await #expect(throws: (any Error).self) {
            try await control.execute(SetLevelCommand(deviceID: secondary, level: UnitInterval(0.5)))
        }
        #expect(await http.posts == 0)
    }
    @Test func wrongTargetAndOfflineDeviceNeverDispatch() async throws {
        let http = Fixture(health: "OFFLINE"); let p = provider(http); try await p.connect()
        let control = try #require(try await p.capabilities(for: target).control)
        await #expect(throws: (any Error).self) { try await control.execute(SetPowerCommand(deviceID: "foreign", isOn: true)) }
        await #expect(throws: (any Error).self) { try await control.execute(SetPowerCommand(deviceID: target, isOn: true)) }
        #expect(await http.posts == 0)
    }
    @Test func acceptedCloudCommandIsNotClaimedAppliedEvenWithMatchingReadback() async throws {
        let http = Fixture(); let p = provider(http); try await p.connect()
        let control = try #require(try await p.capabilities(for: target).control)
        let receipt = try await control.execute(SetPowerCommand(deviceID: target, isOn: true))
        #expect(receipt.outcome == .accepted)
        #expect(receipt.state?.origin == .cloud)
        #expect(await http.posts == 1)
        let post = try #require(await http.requests.first { $0.httpMethod == "POST" })
        let body = try JSONSerialization.jsonObject(with: #require(post.httpBody)) as? [String: [[String: Any]]]
        #expect(body?["commands"]?.first?["component"] as? String == "main")
        #expect(body?["commands"]?.first?["command"] as? String == "on")
    }
    @Test func lostPostResponseIsUncertainAndNeverRetried() async throws {
        let http = Fixture(failPost: true); let p = provider(http); try await p.connect()
        let control = try #require(try await p.capabilities(for: target).control)
        let receipt = try await control.execute(SetPowerCommand(deviceID: target, isOn: true))
        #expect(receipt.outcome == .uncertain)
        #expect(await http.posts == 1)
    }
    @Test func cloudSnapshotDoesNotRefreshTheObservationTimestamp() async throws {
        let http = Fixture(timestamp: "2000-01-01T00:00:00Z"); let p = provider(http); try await p.connect()
        let reader = try #require(try await p.capabilities(for: target).readState)
        let state = try await reader.state()
        #expect(state.observedAt < Date(timeIntervalSince1970: 1_000_000_000))
        #expect(state.availability == .degraded)
        #expect(state.freshness() != .current)
    }
    @Test func retainedHandlesStayInvalidAfterDisconnectAndReconnect() async throws {
        let http = Fixture(); let p = provider(http); try await p.connect()
        let control = try #require(try await p.capabilities(for: target).control)
        await p.disconnect(); try await p.connect()
        await #expect(throws: (any Error).self) { try await control.execute(SetPowerCommand(deviceID: target, isOn: true)) }
        #expect(await http.posts == 0)
    }
    @Test func nullOrStructuredPrimaryValueCannotClaimOnline() async throws {
        let http = Fixture(invalidPrimary: true); let p = provider(http); try await p.connect()
        let reader = try #require(try await p.capabilities(for: target).readState)
        #expect(try await reader.state().availability == .unknown)
    }
    @Test func paginationParametersAreBoundedASCIIIntegers() {
        for query in ["page=", "page=１２", "page=1&page=2", "max=999999999999999999999", "page=-1"] {
            #expect(!SmartThingsProvider.allowedURL(URL(string: "https://api.smartthings.com/v1/devices?" + query)!))
        }
        #expect(SmartThingsProvider.allowedURL(URL(string: "https://api.smartthings.com/v1/devices?page=1&max=100")!))
    }
    @Test func productionHTTPRejectsUnrelatedRoutesAndCredentialsInURLs() {
        for path in ["https://api.smartthings.com/v1/devices/../oauth", "https://api.smartthings.com/v1/devices/foreign/status", "https://api.smartthings.com:444/v1/devices", "https://api.smartthings.com.evil.example/v1/devices", "https://user@api.smartthings.com/v1/devices", "http://api.smartthings.com/v1/devices"] {
            #expect(!SmartThingsProvider.allowedURL(URL(string: path)!))
        }
    }
    @Test func disconnectWhileAuthorizationIsPendingCannotOpenANewConnection() async throws {
        let http = Fixture(); let gate = TokenGate()
        let p = SmartThingsProvider(token: { await gate.wait(); return try SmartThingsAccessToken(value: "fixture", expiresAt: Date().addingTimeInterval(3600)) }, http: http)
        let task = Task { try await p.connect() }
        while !(await gate.entered) { await Task.yield() }
        await p.disconnect(); await gate.release()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(await http.requests.isEmpty)
        await #expect(throws: (any Error).self) { try await p.devices() }
    }

}
private actor Fixture: SmartThingsHTTP {
    var requests: [URLRequest] = []
    var posts: Int { requests.filter { $0.httpMethod == "POST" }.count }
    let next: String?; let health: String; let failPost: Bool; let timestamp: String; let invalidPrimary: Bool
    init(next: String? = nil, health: String = "ONLINE", failPost: Bool = false, timestamp: String? = nil, invalidPrimary: Bool = false) {
        self.next = next; self.health = health; self.failPost = failPost; self.invalidPrimary = invalidPrimary
        self.timestamp = timestamp ?? ISO8601DateFormatter().string(from: Date())
    }
    func send(_ request: URLRequest) async throws -> SmartThingsHTTPResponse {
        requests.append(request)
        let data: Data
        if request.httpMethod == "POST" {
            if failPost { throw URLError(.timedOut) }
            data = Data(#"{"results":[{"id":"transaction","status":"ACCEPTED"}]}"#.utf8)
        } else if request.url!.path.hasSuffix("/health") {
            data = try JSONSerialization.data(withJSONObject: ["deviceId": uuid, "state": health])
        } else if request.url!.path.hasSuffix("/status") {
            let primary: Any = invalidPrimary ? ["unexpected": "object"] : "on"
            data = try JSONSerialization.data(withJSONObject: ["components": ["main": ["switch": ["switch": ["value": primary, "timestamp": timestamp]]], "secondary": ["switch": ["switch": ["value": "off", "timestamp": timestamp]]]]])
        } else {
            var object: [String: Any] = ["items": [["deviceId": uuid, "label": "Samsung lamp", "components": [["id": "main", "capabilities": [["id": "switch"], ["id": "switchLevel"]]], ["id": "secondary", "capabilities": [["id": "switch"]]]]]]]
            if let next { object["_links"] = ["next": ["href": next]] }
            data = try JSONSerialization.data(withJSONObject: object)
        }
        return SmartThingsHTTPResponse(data: data, status: 200)
    }
}

private actor TokenGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
