import Foundation
import Testing
import IoTCore
import IoTMQTT
@testable import IoTMQTTCocoa

/// Opt-in socket tests against our loopback fixture, never against household devices.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LORISIOT_MQTT_LOOPBACK"] == "1"))
struct LoopbackWireTests {
    private func transport() throws -> CocoaMQTTTransport {
        let env = ProcessInfo.processInfo.environment
        guard env["LORISIOT_MQTT_BROKER"] == "127.0.0.1",
              let port = UInt16(env["LORISIOT_MQTT_PORT"] ?? ""), port > 0 else {
            throw IoTError.notConfigured
        }
        return CocoaMQTTTransport(config: .init(host: "127.0.0.1", port: port,
                                                clientID: "loopback-\(UUID())", keepAlive: 5))
    }

    private func first(_ stream: AsyncStream<(topic: String, payload: Data)>) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                for await frame in stream { return String(data: frame.payload, encoding: .utf8) }
                return nil
            }
            group.addTask { try? await Task.sleep(for: .seconds(15)); return nil }
            let value = await group.next() ?? nil
            group.cancelAll()
            return value
        }
    }

    @Test func qosTwoCompletesTheWireHandshake() async throws {
        let client = try transport()
        try await client.connect()
        let stream = await client.messages()
        let topic = "lorisiot/test/qos2/\(UUID())"
        do {
            try await client.subscribe(topic: topic)
            try await client.publish(topic: topic, payload: Data("23.45".utf8), qos: .exactlyOnce, retain: false)
            #expect(await first(stream) == "23.45")
            await client.disconnect()
        } catch { await client.disconnect(); throw error }
    }

    @Test func deniedSubscriptionRetiresTheConnection() async throws {
        let client = try transport()
        try await client.connect()
        do {
            try await client.subscribe(topic: "lorisiot/test/denied/\(UUID())")
            Issue.record("SUBACK denial must throw")
        } catch let error as IoTError {
            guard case .transport = error else { Issue.record("Expected SUBACK transport failure"); return }
        }
        await #expect(throws: IoTError.notConnected) {
            try await client.publish(topic: "lorisiot/test/unused", payload: Data(), qos: .atMostOnce, retain: false)
        }
        await client.disconnect()
    }

    @Test func retainedFlagSurvivesTheWire() async throws {
        let writer = try transport()
        let reader = try transport()
        let topic = "lorisiot/test/metadata/\(UUID())"
        do {
            try await writer.connect()
            try await writer.publish(topic: topic, payload: Data("{\"temperature\":23.45}".utf8),
                                     qos: .atLeastOnce, retain: true)
            await writer.disconnect()
            try await reader.connect()
            let observations = await reader.observations()
            try await reader.subscribe(topic: topic)
            let report = await withTaskGroup(of: MQTTObservation?.self) { group in
                group.addTask {
                    for await report in observations { return report }
                    return nil
                }
                group.addTask { try? await Task.sleep(for: .seconds(15)); return nil }
                let value = await group.next() ?? nil
                group.cancelAll()
                return value
            }
            #expect(report?.topic == topic)
            #expect(report?.retained == true)
            #expect(report?.payload == Data("{\"temperature\":23.45}".utf8))
            await reader.disconnect()
        } catch { await writer.disconnect(); await reader.disconnect(); throw error }
    }

    @Test func reconnectReplaysSubscriptionsBeforeReportingReady() async throws {
        let client = try transport()
        try await client.connect()
        let states = await client.connectionStates()
        let frames = await client.messages()
        let topic = "lorisiot/test/replay/\(UUID())"
        try await client.subscribe(topic: topic)
        let reconnected = Task {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    var sawDisconnect = false
                    for await state in states {
                        if state == .degraded { sawDisconnect = true }
                        if sawDisconnect && state == .connected { return true }
                    }
                    return false
                }
                group.addTask { try? await Task.sleep(for: .seconds(20)); return false }
                let value = await group.next() ?? false
                group.cancelAll()
                return value
            }
        }
        do {
            try await client.publish(topic: "lorisiot/test/drop/\(UUID())", payload: Data(), qos: .atLeastOnce, retain: false)
            let ready = await reconnected.value
            #expect(ready)
            if ready {
                try await client.publish(topic: topic, payload: Data("after-reconnect".utf8), qos: .atLeastOnce, retain: false)
                #expect(await first(frames) == "after-reconnect")
            }
            await client.disconnect()
        } catch { reconnected.cancel(); await client.disconnect(); throw error }
    }
}
