import Foundation
import Testing
import IoTCore
@preconcurrency import CocoaMQTT
@testable import IoTMQTTCocoa

@Suite struct MQTTAcknowledgementTests {
    @Test func publicationRequiresTheMatchingBrokerAcknowledgement() async throws {
        let bridge = MQTT5DelegateBridge()
        let client = CocoaMQTT5(clientID: "fixture", host: "localhost")
        bridge.activate(client)
        try await bridge.awaitPublishAck(qos: .atLeastOnce, timeout: 1) {
            Task {
                bridge.mqtt5(client, didPublishAck: 99, pubAckData: nil)
                try? await Task.sleep(for: .milliseconds(20))
                bridge.mqtt5(client, didPublishAck: 7, pubAckData: nil)
            }
            return 7
        }
        await #expect(throws: IoTError.timeout) {
            try await bridge.awaitPublishAck(qos: .atLeastOnce, timeout: 0.02) { 8 }
        }
    }
    @Test func qosTwoWaitsForPubCompAndBrokerRejectionThrows() async throws {
        let bridge = MQTT5DelegateBridge()
        let client = CocoaMQTT5(clientID: "fixture", host: "localhost")
        bridge.activate(client)
        await #expect(throws: IoTError.timeout) {
            try await bridge.awaitPublishAck(qos: .exactlyOnce, timeout: 0.03) {
                Task { bridge.mqtt5(client, didPublishRec: 4, pubRecData: nil) }
                return 4
            }
        }
        try await bridge.awaitPublishAck(qos: .exactlyOnce, timeout: 1) {
            Task { bridge.mqtt5(client, didPublishComplete: 5, pubCompData: nil) }
            return 5
        }
        await #expect(throws: IoTError.self) {
            try await bridge.awaitPublishAck(qos: .atLeastOnce, timeout: 1) {
                Task {
                    let data = MqttDecodePubAck(); data.reasonCode = .notAuthorized
                    bridge.mqtt5(client, didPublishAck: 6, pubAckData: data)
                }
                return 6
            }
        }
    }
    @Test func cancelledWaiterCompletesWithoutWaitingForTimeout() async throws {
        let ack = MQTTAcknowledgement()
        let ready = AsyncStream<Void>.makeStream()
        let task = Task { try await ack.wait(timeout: 30) { ready.continuation.yield(()) } }
        for await _ in ready.stream { break }
        task.cancel()
        do { try await task.value; Issue.record("Cancellation was lost") }
        catch is CancellationError {}
        catch { Issue.record("Unexpected error: \(error)") }
        ack.finish(.success(())) // a late callback must not double-resume
    }

    @Test func anOldTimeoutCannotFinishTheNextConnect() async throws {
        let bridge = MQTT5DelegateBridge()
        try await bridge.awaitConnack(timeout: 0.02) { bridge.failConnectForTestSuccess() }
        try await bridge.awaitConnack(timeout: 0.3) {
            Task {
                try? await Task.sleep(for: .milliseconds(60))
                bridge.failConnectForTestSuccess()
            }
        }
    }

    @Test func oldClientCallbacksCannotReviveDisconnectedBridge() {
        let bridge = MQTT5DelegateBridge()
        let old = CocoaMQTT5(clientID: "old", host: "localhost")
        let current = CocoaMQTT5(clientID: "current", host: "localhost")
        bridge.activate(old); bridge.shutDown(); bridge.activate(current)
        bridge.mqtt5(old, didConnectAck: .success, connAckData: nil)
        #expect(!bridge.isReady)
        bridge.mqtt5(current, didConnectAck: .success, connAckData: nil)
        #expect(bridge.isReady)
        bridge.shutDown()
        bridge.mqtt5(current, didConnectAck: .success, connAckData: nil)
        #expect(!bridge.isReady)
    }
}

private extension MQTT5DelegateBridge {
    func failConnectForTestSuccess() {
        mqtt5(CocoaMQTT5(clientID: "fixture", host: "localhost"), didConnectAck: .success, connAckData: nil)
    }
}
