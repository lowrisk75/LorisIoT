import Foundation
import IoTCore

private func mqttState(_ on: Bool?, id: DeviceID, seq: UInt64) -> DeviceState {
    DeviceState(deviceID: id, availability: on == nil ? .unknown : .online,
                primaryValue: on.map { .bool($0) }, observedAt: Date(), origin: .bridge,
                revision: StateRevision(localSequence: seq))
}

/// MQTT provider. MQTT is pub/sub with no request/response, so: control **publishes** a command
/// (outcome `.accepted` — the physical result arrives asynchronously on the state topic, observed via
/// Subscribe, never a fake `.applied`); readState returns the last **retained/observed** value;
/// subscribe streams live state changes. The broker's topics/QoS/retained never reach the Core.
public actor MQTTProvider: DeviceProvider {
    public nonisolated let id: ProviderID = "mqtt"
    public nonisolated let displayName = "MQTT"

    private let maps: [DeviceID: MQTTDeviceMap]
    private let transport: MQTTTransport
    private let seq = SequenceGen()
    private var cache: [DeviceID: Bool] = [:]
    private var subscribers: [DeviceID: [UUID: AsyncThrowingStream<DeviceStateChange, any Error>.Continuation]] = [:]
    private var consumer: Task<Void, Never>?

    public init(devices: [MQTTDeviceMap], transport: MQTTTransport) {
        self.maps = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        self.transport = transport
    }

    public func connect() async throws {
        try await transport.connect()
        for m in maps.values { try await transport.subscribe(topic: m.stateTopic) }
        let stream = await transport.messages()
        consumer = Task { [weak self] in
            for await frame in stream { await self?.ingest(topic: frame.topic, payload: frame.payload) }
        }
    }

    public func disconnect() async {
        consumer?.cancel(); consumer = nil
        await transport.disconnect()
    }

    private func ingest(topic: String, payload: Data) async {
        guard let m = maps.values.first(where: { $0.stateTopic == topic }), let on = m.parse(payload) else { return }
        cache[m.id] = on
        let change = DeviceStateChange.snapshot(mqttState(on, id: m.id, seq: await seq.next()))
        subscribers[m.id]?.values.forEach { $0.yield(change) }
    }

    public func devices() async throws -> [Device] {
        maps.values.map { m in
            Device(id: m.id, providerID: id, nativeID: m.stateTopic, name: m.name, kind: .unknown,
                   capabilities: [.control, .readState, .subscribe].map { CapabilityDescriptor(id: $0, operations: []) })
        }
    }

    public func capabilities(for deviceID: DeviceID) async throws -> DeviceCapabilitySet {
        guard let m = maps[deviceID] else { throw IoTError.notConfigured }
        return DeviceCapabilitySet(
            descriptors: [.readState, .control, .subscribe].map { CapabilityDescriptor(id: $0, operations: []) },
            control: MQTTControlCapability(provider: self, map: m),
            readState: MQTTReadStateCapability(provider: self, deviceID: m.id, seq: seq),
            subscribe: MQTTSubscribeCapability(provider: self, deviceID: m.id))
    }

    public func connectionEvents() async -> AsyncStream<ProviderConnectionEvent> {
        let id = self.id
        return AsyncStream { c in c.yield(ProviderConnectionEvent(providerID: id, state: .connected)); c.finish() }
    }

    // MARK: - Internal (used by capabilities)

    func cachedState(_ id: DeviceID) -> Bool? { cache[id] }

    func publish(_ map: MQTTDeviceMap, on: Bool) async throws {
        try await transport.publish(topic: map.commandTopic, payload: map.render(on), qos: .atLeastOnce, retain: false)
    }

    func stateStream(_ id: DeviceID) -> AsyncThrowingStream<DeviceStateChange, any Error> {
        AsyncThrowingStream { continuation in
            let key = UUID()
            subscribers[id, default: [:]][key] = continuation
            continuation.onTermination = { _ in Task { await self.removeSubscriber(id, key) } }
        }
    }
    private func removeSubscriber(_ id: DeviceID, _ key: UUID) { subscribers[id]?[key] = nil }
    func nextSeq() async -> UInt64 { await seq.next() }
}

// MARK: - Capabilities

actor MQTTControlCapability: ControlCapability {
    public nonisolated let descriptor = CapabilityDescriptor(id: .control, operations: [.control])
    private let provider: MQTTProvider; private let map: MQTTDeviceMap
    init(provider: MQTTProvider, map: MQTTDeviceMap) { self.provider = provider; self.map = map }
    func execute<C: DeviceCommand>(_ command: C) async throws -> CommandReceipt {
        guard case .setPower(let on) = command.payload else { throw IoTError.notSupported("MQTT control supports power") }
        do { try await provider.publish(map, on: on) }
        catch { return CommandReceipt(commandID: command.id, deviceID: map.id, outcome: .uncertain) }
        // .accepted, not .applied: MQTT can't confirm the physical result synchronously — it arrives
        // on the state topic (observe via Subscribe).
        return CommandReceipt(commandID: command.id, deviceID: map.id, outcome: .accepted)
    }
}

actor MQTTReadStateCapability: ReadStateCapability {
    public nonisolated let descriptor = CapabilityDescriptor(id: .readState, operations: [.readState])
    private let provider: MQTTProvider; private let deviceID: DeviceID; private let seq: SequenceGen
    init(provider: MQTTProvider, deviceID: DeviceID, seq: SequenceGen) { self.provider = provider; self.deviceID = deviceID; self.seq = seq }
    func state() async throws -> DeviceState {
        mqttState(await provider.cachedState(deviceID), id: deviceID, seq: await seq.next())
    }
}

actor MQTTSubscribeCapability: SubscribeCapability {
    public nonisolated let descriptor = CapabilityDescriptor(id: .subscribe, operations: [.subscribe])
    private let provider: MQTTProvider; private let deviceID: DeviceID
    init(provider: MQTTProvider, deviceID: DeviceID) { self.provider = provider; self.deviceID = deviceID }
    func stateChanges() async -> AsyncThrowingStream<DeviceStateChange, any Error> {
        await provider.stateStream(deviceID)
    }
}
