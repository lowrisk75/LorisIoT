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
