import Testing
import Foundation
@testable import IoTMQTT
import IoTCore

/// In-memory MQTT transport: records publishes, lets a test inject inbound frames.
actor MockMQTT: MQTTTransport {
    private(set) var published: [(topic: String, payload: Data)] = []
    private var cont: AsyncStream<(topic: String, payload: Data)>.Continuation?

    func connect() async throws {}
    func disconnect() async {}
    func subscribe(topic: String) async throws {}
    func publish(topic: String, payload: Data, qos: MQTTQoS, retain: Bool) async throws {
        published.append((topic, payload))
    }
    func messages() async -> AsyncStream<(topic: String, payload: Data)> {
        AsyncStream { self.cont = $0 }
    }
    func inject(topic: String, payload: Data) { cont?.yield((topic, payload)) }
    func lastPublished() -> (topic: String, payload: Data)? { published.last }
}

private let map = MQTTDeviceMap(id: "lamp", name: "Lamp",
                                stateTopic: "home/lamp/state", commandTopic: "home/lamp/set")

@Suite struct MQTTMappingTests {
    @Test func parseAndRender() {
        #expect(map.parse(Data("ON".utf8)) == true)
        #expect(map.parse(Data("OFF".utf8)) == false)
        #expect(map.parse(Data("garbage".utf8)) == nil)
        #expect(String(data: map.render(true), encoding: .utf8) == "ON")
    }
}

@Suite struct MQTTProviderTests {
    @Test func controlPublishesAndReturnsAccepted() async throws {
        let mock = MockMQTT()
        let p = MQTTProvider(devices: [map], transport: mock)
        try await p.connect()
        let control = try #require(try await p.capabilities(for: "lamp").control)
        let receipt = try await control.execute(SetPowerCommand(deviceID: "lamp", isOn: true))
        #expect(receipt.outcome == .accepted)                 // MQTT can't confirm synchronously
        let sent = await mock.lastPublished()
        #expect(sent?.topic == "home/lamp/set")
        #expect(String(data: sent?.payload ?? Data(), encoding: .utf8) == "ON")
    }

    @Test func inboundStateUpdatesCacheAndSubscribers() async throws {
        let mock = MockMQTT()
        let p = MQTTProvider(devices: [map], transport: mock)
        try await p.connect()
        let sub = try #require(try await p.capabilities(for: "lamp").subscribe)
        let stream = await sub.stateChanges()
        await mock.inject(topic: "home/lamp/state", payload: Data("ON".utf8))

        var got: DeviceState?
        for try await change in stream {
            if case .snapshot(let s) = change { got = s; break }
        }
        #expect(got?.primaryValue == .bool(true))

        let reader = try #require(try await p.capabilities(for: "lamp").readState)
        #expect(try await reader.state().primaryValue == .bool(true))   // cache updated from retained/observed
    }
}
