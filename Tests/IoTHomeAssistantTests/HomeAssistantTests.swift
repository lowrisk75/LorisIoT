import Testing
import Foundation
@testable import IoTHomeAssistant
import IoTCore

/// Scripted HTTP mock: answers from a Sendable closure, no network.
struct MockHTTP: HAHTTP {
    let handler: @Sendable (_ method: String, _ path: String, _ body: Data?) -> (Data, Int)
    func send(method: String, path: String, body: Data?) async throws -> (Data, Int) {
        handler(method, path, body)
    }
}

private func json(_ s: String) -> Data { Data(s.utf8) }

@Suite struct HAModelTests {
    @Test func decodesEntityAndMapsToDeviceState() throws {
        let data = json(#"""
        {"entity_id":"light.kitchen","state":"on",
         "attributes":{"friendly_name":"Kitchen","brightness":128}}
        """#)
        let e = try JSONDecoder().decode(HAEntityState.self, from: data)
        #expect(e.entityID == "light.kitchen")
        let ds = e.deviceState
        #expect(ds.power == true)
        #expect(ds.name == "Kitchen")
        #expect(ds.level == 50)          // 128/255 ≈ 50%
        #expect(ds.reachable)
    }

    @Test func unavailableMapsToUnreachable() throws {
        let e = try JSONDecoder().decode(HAEntityState.self,
                    from: json(#"{"entity_id":"switch.pump","state":"unavailable","attributes":{}}"#))
        #expect(e.deviceState.reachable == false)
        #expect(e.deviceState.power == nil)
    }

    @Test func domainInference() {
        #expect(haDomain(of: "light.kitchen") == "light")
        #expect(haDomain(of: "switch.pump") == "switch")
    }

    @Test func websocketMessageDecoding() {
        #expect({ if case .authRequired = HAMessage.decode(json(#"{"type":"auth_required"}"#))! { return true }; return false }())
        #expect({ if case .authOK = HAMessage.decode(json(#"{"type":"auth_ok"}"#))! { return true }; return false }())
        let event = json(#"""
        {"type":"event","event":{"event_type":"state_changed","data":{"new_state":
          {"entity_id":"light.kitchen","state":"off","attributes":{}}}}}
        """#)
        guard case .stateChanged(let e)? = HAMessage.decode(event) else { Issue.record("expected stateChanged"); return }
        #expect(e.entityID == "light.kitchen" && e.state == "off")
    }

    @Test func configNormalizeAndWebsocketURL() {
        let c = HAConfig(baseURL: HAConfig.normalize("homeassistant.local:8123")!)
        #expect(c.baseURL.absoluteString == "https://homeassistant.local:8123")
        #expect(c.websocketURL?.absoluteString == "wss://homeassistant.local:8123/api/websocket")
        let http = HAConfig(baseURL: HAConfig.normalize("http://192.168.1.2:8123")!)
        #expect(http.websocketURL?.absoluteString == "ws://192.168.1.2:8123/api/websocket")
    }

    @Test func nextISOIsFutureOnTheMinute() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 8, minute: 0))!
        let s = HomeAssistantProvider.nextISO(hour: 6, minute: 40, now: now, calendar: cal)
        #expect(s == "2026-01-02 06:40:00")   // 06:40 already passed today → tomorrow
    }
}

@Suite struct HAProviderTests {
    private func provider(_ handler: @escaping @Sendable (String, String, Data?) -> (Data, Int)) -> HomeAssistantProvider {
        HomeAssistantProvider(config: HAConfig(baseURL: URL(string: "http://ha.local:8123")!),
                              token: "TESTTOKEN", http: MockHTTP(handler: handler))
    }

    @Test func setPowerConfirmsByReread() async throws {
        // turn_on succeeds, then the re-read reports "on" → confirmed.
        let p = provider { method, path, _ in
            if method == "POST" { return (Data("[]".utf8), 200) }
            return (json(#"{"entity_id":"switch.pump","state":"on","attributes":{}}"#), 200)
        }
        let ds = try await p.setState(DeviceTarget(id: "switch.pump"), .setPower(true))
        #expect(ds.power == true)
    }

    @Test func setPowerThrowsWhenNotConfirmed() async throws {
        // turn_on "succeeds" but the device still reads "off" → confirm-by-reread must throw.
        let p = provider { method, _, _ in
            if method == "POST" { return (Data("[]".utf8), 200) }
            return (json(#"{"entity_id":"switch.pump","state":"off","attributes":{}}"#), 200)
        }
        await #expect(throws: ProviderError.unconfirmed) {
            try await p.setState(DeviceTarget(id: "switch.pump"), .setPower(true))
        }
    }

    @Test func authFailureIsDistinguished() async throws {
        let p = provider { _, _, _ in (Data(), 401) }
        await #expect(throws: ProviderError.authenticationFailed(reason: "HTTP 401")) {
            try await p.readState(DeviceTarget(id: "light.x"))
        }
    }
}
