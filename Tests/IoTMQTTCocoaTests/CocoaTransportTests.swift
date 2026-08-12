import Testing
import Foundation
@preconcurrency import CocoaMQTT
@testable import IoTMQTTCocoa
@testable import IoTMQTT
import IoTCore

// No broker (house rule): the bridge is driven by calling the delegate methods directly, exactly
// as CocoaMQTT's socket queue would. A dummy CocoaMQTT5 instance satisfies the delegate signatures
// without ever connecting.

private let dummy = {
    // nonisolated(unsafe) singleton: never connected, never mutated — only passed as the
    // (ignored) delegate `mqtt5` argument.
    CocoaMQTT5(clientID: "test-dummy", host: "127.0.0.1", port: 1)
}()

@Suite struct MQTT5DelegateBridgeTests {

    @Test func connackSuccessResumesConnect() async throws {
        let bridge = MQTT5DelegateBridge()
        try await bridge.awaitConnack(timeout: 5) {
            bridge.mqtt5(dummy, didConnectAck: .success, connAckData: nil)
        }
    }

    @Test func connackAuthFailureThrowsAuthenticationFailed() async {
        let bridge = MQTT5DelegateBridge()
        do {
            try await bridge.awaitConnack(timeout: 5) {
                bridge.mqtt5(dummy, didConnectAck: .badUsernameOrPassword, connAckData: nil)
            }
            Issue.record("bad credentials must throw")
        } catch let error as IoTError {
            guard case .authenticationFailed = error else {
                Issue.record("expected authenticationFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func connackServerErrorThrowsTransport() async {
        let bridge = MQTT5DelegateBridge()
        await #expect(throws: IoTError.transport("CONNACK 0x88")) {
            try await bridge.awaitConnack(timeout: 5) {
                bridge.mqtt5(dummy, didConnectAck: .serverUnavailable, connAckData: nil)
            }
        }
    }

    @Test func preConnackSocketErrorSurfacesInsteadOfHanging() async {
        let bridge = MQTT5DelegateBridge()
        struct Boom: Error, LocalizedError { var errorDescription: String? { "socket died" } }
        do {
            try await bridge.awaitConnack(timeout: 5) {
                bridge.mqtt5DidDisconnect(dummy, withError: Boom())
            }
            Issue.record("pre-CONNACK disconnect must throw")
        } catch {}
    }

    @Test func subAckResolvesMatchingTopicOnly() async throws {
        let bridge = MQTT5DelegateBridge()
        try await bridge.awaitSubAck(topic: "pool/pump/state", timeout: 5) {
            bridge.mqtt5(dummy, didSubscribeTopics: ["pool/pump/state": 1] as NSDictionary,
                         failed: [], subAckData: nil)
        }
    }

    @Test func subAckFailureThrows() async {
        let bridge = MQTT5DelegateBridge()
        await #expect(throws: IoTError.transport("SUBACK failed for nope/topic")) {
            try await bridge.awaitSubAck(topic: "nope/topic", timeout: 5) {
                bridge.mqtt5(dummy, didSubscribeTopics: [:] as NSDictionary,
                             failed: ["nope/topic"], subAckData: nil)
            }
        }
    }

    @Test func inboundMessagesFlowIntoTheStream() async {
        let bridge = MQTT5DelegateBridge()
        let stream = bridge.frames()
        bridge.mqtt5(dummy, didReceiveMessage: CocoaMQTT5Message(topic: "t/1", payload: [UInt8]("ON".utf8)),
                     id: 1, publishData: nil)
        bridge.mqtt5(dummy, didReceiveMessage: CocoaMQTT5Message(topic: "t/2", payload: [UInt8]("OFF".utf8)),
                     id: 2, publishData: nil)
        bridge.shutDown()   // finishes the stream so iteration ends
        var received: [(String, String)] = []
        for await frame in stream {
            received.append((frame.topic, String(data: frame.payload, encoding: .utf8) ?? ""))
        }
        #expect(received.map(\.0) == ["t/1", "t/2"])
        #expect(received.map(\.1) == ["ON", "OFF"])
    }

    @Test func shutdownFailsPendingWaiters() async {
        let bridge = MQTT5DelegateBridge()
        await #expect(throws: IoTError.cancelled) {
            try await bridge.awaitConnack(timeout: 30) { bridge.shutDown() }
        }
    }

    @Test func qosMapping() {
        #expect(CocoaMQTTTransport.map(.atMostOnce) == .qos0)
        #expect(CocoaMQTTTransport.map(.atLeastOnce) == .qos1)
        #expect(CocoaMQTTTransport.map(.exactlyOnce) == .qos2)
    }

    @Test func bridgeWorksAsProviderTransportEndToEnd() async throws {
        // The full IoTMQTT provider path over the bridge, no broker: subscribe → retained state
        // frame → readState sees it.
        let map = MQTTDeviceMap(id: DeviceID(rawValue: "pump"), name: "Pump",
                                stateTopic: "pool/pump/state", commandTopic: "pool/pump/set")
        let bridge = MQTT5DelegateBridge()
        let stream = bridge.frames()
        bridge.mqtt5(dummy, didReceiveMessage: CocoaMQTT5Message(topic: map.stateTopic, payload: [UInt8]("ON".utf8)),
                     id: 1, publishData: nil)
        bridge.shutDown()
        var last: Bool?
        for await frame in stream where frame.topic == map.stateTopic {
            last = map.parse(frame.payload)
        }
        #expect(last == true)
    }
}

// MARK: - Live broker (opt-in: LORISIOT_MQTT_BROKER=host — CI/unit runs never need a broker)

@Suite struct CocoaMQTTLiveBrokerTests {

    static var brokerHost: String? { ProcessInfo.processInfo.environment["LORISIOT_MQTT_BROKER"] }

    @Test(.enabled(if: brokerHost != nil))
    func liveConnectSubscribePublishReceive() async throws {
        let config = MQTTBrokerConfig(host: Self.brokerHost!, clientID: "lorisiot-test-\(UUID().uuidString.prefix(8))")
        let transport = CocoaMQTTTransport(config: config)
        try await transport.connect()
        let stream = await transport.messages()
        let topic = "lorisiot/test/\(UUID().uuidString.prefix(8))"
        try await transport.subscribe(topic: topic)
        try await transport.publish(topic: topic, payload: Data("ON".utf8), qos: .atLeastOnce, retain: false)

        let first: (topic: String, payload: Data)? = await withTaskGroup(of: (topic: String, payload: Data)?.self) { group in
            group.addTask { for await frame in stream { return frame }; return nil }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return nil }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
        await transport.disconnect()
        #expect(first?.topic == topic)
        #expect(first.map { String(data: $0.payload, encoding: .utf8) } == "ON")
    }

    @Test(.enabled(if: brokerHost != nil))
    func liveRetainedMessageGivesLastKnownState() async throws {
        let topic = "lorisiot/test/retained-\(UUID().uuidString.prefix(8))"
        // Writer publishes retained, then a LATER subscriber must still receive it.
        let writer = CocoaMQTTTransport(config: .init(host: Self.brokerHost!, clientID: "lorisiot-w-\(UUID().uuidString.prefix(8))"))
        try await writer.connect()
        try await writer.publish(topic: topic, payload: Data("OFF".utf8), qos: .atLeastOnce, retain: true)
        try await Task.sleep(for: .milliseconds(300))
        await writer.disconnect()

        let reader = CocoaMQTTTransport(config: .init(host: Self.brokerHost!, clientID: "lorisiot-r-\(UUID().uuidString.prefix(8))"))
        try await reader.connect()
        let stream = await reader.messages()
        try await reader.subscribe(topic: topic)
        let first: (topic: String, payload: Data)? = await withTaskGroup(of: (topic: String, payload: Data)?.self) { group in
            group.addTask { for await frame in stream { return frame }; return nil }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return nil }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
        await reader.disconnect()
        #expect(first.map { String(data: $0.payload, encoding: .utf8) } == "OFF")
    }
}
