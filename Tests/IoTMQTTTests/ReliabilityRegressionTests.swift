import Foundation
import Testing
@testable import IoTMQTT
import IoTCore

@Suite struct MQTTReliabilityRegressionTests {
    private let mapping = MQTTDeviceMap(id: "lamp", name: "Lamp", stateTopic: "lamp/state", commandTopic: "lamp/set")

    @Test func retainedDuringSubscribeIsNotLostAndCacheReadDoesNotRefreshItsAge() async throws {
        let transport = ImmediateRetainedTransport()
        let provider = MQTTProvider(devices: [mapping], transport: transport)
        try await provider.connect()
        defer { Task { await provider.disconnect() } }
        let reader = try #require(try await provider.capabilities(for: "lamp").readState)
        var first = try await reader.state()
        for _ in 0..<100 where first.primaryValue == nil {
            try await Task.sleep(for: .milliseconds(2))
            first = try await reader.state()
        }
        #expect(first.primaryValue == .bool(true))
        try await Task.sleep(for: .milliseconds(5))
        let second = try await reader.state()
        #expect(second.observedAt == first.observedAt)
        #expect(second.revision == first.revision)
        await provider.disconnect()
        #expect(try await reader.state().availability != .online)
    }

    @Test func aCapabilityCannotControlAnotherDevice() async throws {
        let transport = ImmediateRetainedTransport()
        let provider = MQTTProvider(devices: [mapping], transport: transport)
        try await provider.connect()
        let control = try #require(try await provider.capabilities(for: "lamp").control)
        await #expect(throws: (any Error).self) {
            _ = try await control.execute(SetPowerCommand(deviceID: "different-device", isOn: true))
        }
        #expect(await transport.publishCount == 0)
        await provider.disconnect()
    }

    /// Once the publish has left, a cancellation cannot prove the broker never received it.
    @Test func cancellationAfterDispatchIsUncertainNotUnexecuted() async throws {
        let transport = ImmediateRetainedTransport()
        await transport.cancelAfterPublishing()
        let provider = MQTTProvider(devices: [mapping], transport: transport)
        try await provider.connect()
        let control = try #require(try await provider.capabilities(for: "lamp").control)
        let receipt = try await control.execute(SetPowerCommand(deviceID: "lamp", isOn: true))
        #expect(receipt.outcome == .uncertain)
        #expect(await transport.publishCount == 1)
        await provider.disconnect()
    }
}

private actor ImmediateRetainedTransport: MQTTTransport {
    private var continuation: AsyncStream<(topic: String, payload: Data)>.Continuation?
    private(set) var publishCount = 0
    func connect() async throws {}
    func disconnect() async { continuation?.finish() }
    func messages() async -> AsyncStream<(topic: String, payload: Data)> {
        AsyncStream { continuation = $0 }
    }
    func subscribe(topic: String) async throws { continuation?.yield((topic, Data("ON".utf8))) }
    private var cancelsAfterPublish = false
    func cancelAfterPublishing() { cancelsAfterPublish = true }
    func publish(topic: String, payload: Data, qos: MQTTQoS, retain: Bool) async throws {
        publishCount += 1
        if cancelsAfterPublish { throw CancellationError() }
    }
}
