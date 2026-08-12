import Testing
import Foundation
@testable import IoTHomeAssistant
import IoTCore

struct MockHTTP: HAHTTP {
    let handler: @Sendable (_ method: String, _ path: String, _ body: Data?) -> (Data, Int)
    func send(method: String, path: String, body: Data?) async throws -> (Data, Int) { handler(method, path, body) }
}
private func json(_ s: String) -> Data { Data(s.utf8) }

@Suite struct HAModelTests {
    @Test func decodesEntityAndMapsToDeviceState() throws {
        let e = try JSONDecoder().decode(HAEntityState.self, from: json(#"""
        {"entity_id":"light.kitchen","state":"on","attributes":{"friendly_name":"Kitchen","brightness":128}}
        """#))
        #expect(e.entityID == "light.kitchen")
        #expect(e.isOn == true)
        let ds = e.deviceState(sequence: 1)
        #expect(ds.availability == .online)
        #expect(ds.primaryValue == .bool(true))
        #expect(ds.attributes["level"]?.value == .integer(50))   // 128/255 ≈ 50%
        #expect(ds.revision.localSequence == 1)
    }

    @Test func unavailableMapsToOffline() throws {
        let e = try JSONDecoder().decode(HAEntityState.self,
                    from: json(#"{"entity_id":"switch.pump","state":"unavailable","attributes":{}}"#))
        #expect(e.deviceState(sequence: 1).availability == .offline)
        #expect(e.isOn == nil)
    }

    @Test func domainInference() {
        #expect(haDomain(of: "light.kitchen") == "light")
        #expect(HomeAssistantProvider.kind(for: "switch.pump") == .switchDevice)
    }

    @Test func websocketMessageDecoding() {
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
        #expect(c.websocketURL?.absoluteString == "wss://homeassistant.local:8123/api/websocket")
        let http = HAConfig(baseURL: HAConfig.normalize("http://192.168.1.2:8123")!)
        #expect(http.websocketURL?.absoluteString == "ws://192.168.1.2:8123/api/websocket")
    }
}

@Suite struct HAProviderTests {
    private func provider(_ handler: @escaping @Sendable (String, String, Data?) -> (Data, Int)) -> HomeAssistantProvider {
        HomeAssistantProvider(config: HAConfig(baseURL: URL(string: "http://ha.local:8123")!),
                              token: "TESTTOKEN", http: MockHTTP(handler: handler))
    }

    @Test func controlAppliedWhenConfirmed() async throws {
        let p = provider { method, _, _ in
            method == "POST" ? (Data("[]".utf8), 200)
                             : (json(#"{"entity_id":"switch.pump","state":"on","attributes":{}}"#), 200)
        }
        let caps = try await p.capabilities(for: "switch.pump")
        let control = try #require(caps.control)
        let receipt = try await control.execute(SetPowerCommand(deviceID: "switch.pump", isOn: true))
        #expect(receipt.outcome == .applied)
    }

    @Test func controlRejectedWhenStateDoesNotChange() async throws {
        let p = provider { method, _, _ in
            method == "POST" ? (Data("[]".utf8), 200)
                             : (json(#"{"entity_id":"switch.pump","state":"off","attributes":{}}"#), 200)
        }
        let control = try #require(try await p.capabilities(for: "switch.pump").control)
        let receipt = try await control.execute(SetPowerCommand(deviceID: "switch.pump", isOn: true))
        #expect(receipt.outcome == .rejected)   // confirm-by-reread: no silent success
    }

    @Test func authFailureIsDistinguished() async throws {
        let p = provider { _, _, _ in (Data(), 401) }
        let reader = try #require(try await p.capabilities(for: "light.x").readState)
        await #expect(throws: IoTError.authenticationFailed(reason: "HTTP 401")) {
            try await reader.state()
        }
    }
}

// MARK: - HARestClient additions (setState / rich callService / raw passthroughs)

@Suite struct HARestClientAdditionsTests {

    @Test func setStatePostsStateAndAttributes() async throws {
        let captured = CapturedRequest()
        let client = HARestClient(http: MockHTTP { method, path, body in
            Task { await captured.set(method: method, path: path, body: body) }
            return (Data("{}".utf8), 200)
        })
        try await client.setState(entityID: "sensor.velya_next_wake", state: "2026-08-12T07:00:00Z",
                                  attributes: ["device_class": "timestamp", "velya_actions": "[]"])
        try await Task.sleep(for: .milliseconds(50))
        #expect(await captured.method == "POST")
        #expect(await captured.path == "api/states/sensor.velya_next_wake")
        let json = try JSONSerialization.jsonObject(with: await captured.body ?? Data()) as? [String: Any]
        #expect(json?["state"] as? String == "2026-08-12T07:00:00Z")
        #expect((json?["attributes"] as? [String: Any])?["device_class"] as? String == "timestamp")
    }

    @Test func setStateAuthErrorIsTyped() async {
        let client = HARestClient(http: MockHTTP { _, _, _ in (Data(), 401) })
        await #expect(throws: IoTError.authenticationFailed(reason: "HTTP 401")) {
            try await client.setState(entityID: "sensor.x", state: "unavailable")
        }
    }

    @Test func callServiceCarriesHeterogeneousData() async throws {
        let captured = CapturedRequest()
        let client = HARestClient(http: MockHTTP { method, path, body in
            Task { await captured.set(method: method, path: path, body: body) }
            return (Data("[]".utf8), 200)
        })
        try await client.callService(domain: "light", service: "turn_on", entityID: "light.bed",
                                     data: ["brightness_pct": 60, "transition": 2.5, "effect": "sunrise"])
        try await Task.sleep(for: .milliseconds(50))
        #expect(await captured.path == "api/services/light/turn_on")
        let json = try JSONSerialization.jsonObject(with: await captured.body ?? Data()) as? [String: Any]
        #expect(json?["entity_id"] as? String == "light.bed")
        #expect(json?["transition"] as? Double == 2.5)
        #expect(json?["effect"] as? String == "sunrise")
    }

    @Test func rawPassthroughsReturnBodyAfterStatusCheck() async throws {
        let payload = #"[{"entity_id":"sensor.t","state":"21.5","attributes":{"unit":"°C"}}]"#
        let client = HARestClient(http: MockHTTP { _, path, _ in
            (Data(payload.utf8), path == "api/states" ? 200 : 404)
        })
        #expect(try await client.statesData() == Data(payload.utf8))
        await #expect(throws: IoTError.invalidResponse) { _ = try await client.stateData(entityID: "sensor.gone") }
    }
}

private actor CapturedRequest {
    private(set) var method: String?
    private(set) var path: String?
    private(set) var body: Data?
    func set(method: String, path: String, body: Data?) {
        self.method = method; self.path = path; self.body = body
    }
}
