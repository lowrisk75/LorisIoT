import Foundation
import Testing
import IoTCore
@testable import IoTHomeAssistant

@Suite struct SunriseSessionTests {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    func request() throws -> HASunriseRequest {
        try .init(remoteID: UUID(), owner: .init(appID: "fixture.app", installationID: UUID()),
                  deviceID: "light.fixture", start: now.addingTimeInterval(120),
                  wake: now.addingTimeInterval(720), autoOffMinutes: 15, brightness: 80)
    }
    @Test func gentleProfileRequiresExplicitServerSupportBeforeAnyWrite() async throws {
        let fixture = SunriseHTTPFixture(now: now)
        let desired = try HASunriseRequest(remoteID: UUID(), owner: .init(appID: "fixture.app", installationID: UUID()),
            deviceID: "light.fixture", start: now.addingTimeInterval(120),
            wake: now.addingTimeInterval(720), autoOffMinutes: 15, brightness: 40,
            sunriseProfile: "gentle-v1")
        #expect(try JSONDecoder().decode(HASunriseRequest.self, from: JSONEncoder().encode(desired)) == desired)
        await #expect(throws: (any Error).self) { try await HASunriseClient(http: fixture).arm(desired, now: now) }
        #expect(await fixture.posts == 0)
    }
    @Test func legacyServerCannotSilentlyDropAutoOff() async throws {
        let fixture = SunriseHTTPFixture(now: now, version: nil)
        let client = HASunriseClient(http: fixture)
        await #expect(throws: (any Error).self) { try await client.arm(request(), now: now) }
        #expect(await fixture.posts == 0)
    }
    @Test func exactReadbackAndReplayReuseOneNonce() async throws {
        let fixture = SunriseHTTPFixture(now: now)
        let client = HASunriseClient(http: fixture)
        let desired = try request()
        #expect(try await client.arm(desired, now: now).state == .armed)
        #expect(try await client.arm(desired, now: now).request == desired)
        #expect(await fixture.posts == 1)
        #expect(desired.autoOffAt == now.timeIntervalSince1970 + 720 + 900)
        try await client.cancel(desired)
        #expect(try await client.read(desired)?.state == .removed)
    }
    @Test func tamperedReceiptNeverConfirmsNorDeletes() async throws {
        let fixture = SunriseHTTPFixture(now: now)
        let client = HASunriseClient(http: fixture)
        let desired = try request()
        _ = try await client.arm(desired, now: now)
        await fixture.tamper()
        await #expect(throws: (any Error).self) { try await client.cancel(desired) }
        #expect(await fixture.deletes == 0)
    }
    @Test func absentExpiredSessionNeedsDurableServerCancellation() async throws {
        let fixture = SunriseHTTPFixture(now: now.addingTimeInterval(86400))
        let client = HASunriseClient(http: fixture)
        let desired = try request()
        try await client.cancel(desired)
        #expect(try await client.read(desired)?.state == .removed)
        #expect(await fixture.retirements == 1)
        #expect(await fixture.posts == 0)
    }
    @Test func absentFutureSessionIsNotGuessedCancelled() async throws {
        let fixture = SunriseHTTPFixture(now: now)
        let client = HASunriseClient(http: fixture)
        await #expect(throws: (any Error).self) { try await client.cancel(request()) }
        #expect(try await client.read(request()) == nil)
    }
    @Test func missingRetirementReadbackCannotConfirmCancellation() async throws {
        let fixture = SunriseHTTPFixture(now: now.addingTimeInterval(86400), dropRetiredReadback: true)
        let client = HASunriseClient(http: fixture)
        await #expect(throws: (any Error).self) { try await client.cancel(request()) }
        #expect(await fixture.retirements == 1)
    }
    @Test func invalidDurationTargetAndWindowAreRejected() throws {
        for minutes in [0, -1, 181] {
            #expect(throws: (any Error).self) {
                try HASunriseRequest(remoteID: UUID(), owner: .init(appID: "fixture", installationID: UUID()),
                    deviceID: "light.fixture", start: now, wake: now.addingTimeInterval(600),
                    autoOffMinutes: minutes, brightness: 100)
            }
        }
    }
}

private actor SunriseHTTPFixture: HAHTTP {
    let now: Date
    let version: Int?
    var record: [String: Any]?
    var posts = 0
    var deletes = 0
    var retirements = 0
    let dropRetiredReadback: Bool
    init(now: Date, version: Int? = 1, dropRetiredReadback: Bool = false) {
        self.now = now; self.version = version; self.dropRetiredReadback = dropRetiredReadback
    }
    func tamper() { record?["autoOffAt"] = 0 }
    func send(method: String, path: String, body: Data?) async throws -> (Data, Int) {
        if path.hasSuffix("health") {
            var health: [String: Any] = ["protocolVersion": 1, "ready": true,
                "serverTime": now.timeIntervalSince1970, "allowedTargets": ["light.fixture"],
                "minLeadSeconds": 15, "maxLateSeconds": 5, "durable": true, "executionPolicy": "at_most_once"]
            health["sunriseAutoOffVersion"] = version
            return (try JSONSerialization.data(withJSONObject: health), 200)
        }
        if method == "GET", record?["state"] as? String == "removed", dropRetiredReadback {
            return (Data(), 404)
        }
        if method == "POST", path.hasSuffix("/retire") {
            let payload = try #require(JSONSerialization.jsonObject(with: body!) as? [String: Any])
            let request = try #require(payload["record"] as? [String: Any])
            let off = try #require(request["autoOffAt"] as? Double)
            guard off + 5 < now.timeIntervalSince1970 else { return (Data(), 409) }
            retirements += 1
            record = request; record?["state"] = "removed"; record?["revision"] = 1
            return (try JSONSerialization.data(withJSONObject: record!), 200)
        }
        if method == "POST" {
            posts += 1
            let payload = try #require(JSONSerialization.jsonObject(with: body!) as? [String: Any])
            record = payload["record"] as? [String: Any]
            record?["state"] = "armed"; record?["revision"] = 1
        }
        if method == "DELETE" { deletes += 1; record?["state"] = "removed"; record?["revision"] = 2 }
        guard let record else { return (Data(), 404) }
        return (try JSONSerialization.data(withJSONObject: record), 200)
    }
}
