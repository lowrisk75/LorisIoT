import Foundation
import IoTCore

/// Observations from a transport that can reconnect independently of the provider.
public protocol MQTTConnectionMonitoring: Sendable {
    func connectionStates() async -> AsyncStream<ProviderConnectionState>
}

/// One provider owns one broker session and timestamped state cache. All consumers of a device
/// share its subscription. A cached read never changes the observation timestamp or revision.
public actor MQTTProvider: DeviceProvider {
    public nonisolated let id: ProviderID
    public nonisolated let displayName = "MQTT"

    private let maps: [DeviceID: MQTTDeviceMap]
    private let mapsByTopic: [String: [MQTTDeviceMap]]
    private let mapsByAvailability: [String: [MQTTDeviceMap]]
    private let validConfiguration: Bool
    private let transport: MQTTTransport
    private let events: ConnectionEventHub
    private let now: @Sendable () -> Date
    private let maxStateAge: TimeInterval
    private var sequence: UInt64 = 0
    private var cache: [DeviceID: DeviceState] = [:]
    private var subscribers: [DeviceID: [UUID: AsyncThrowingStream<DeviceStateChange, any Error>.Continuation]] = [:]
    private var consumer: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var connecting: Task<Void, any Error>?
    private var generation: UInt64 = 0
    private var connected = false

    public init(devices: [MQTTDeviceMap], transport: MQTTTransport, id: ProviderID = "mqtt",
                maxStateAge: TimeInterval = 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.id = id
        self.maps = devices.reduce(into: [:]) { $0[$1.id] = $1 }
        self.mapsByTopic = Dictionary(grouping: devices, by: \.stateTopic)
        self.mapsByAvailability = Dictionary(grouping: devices.filter { $0.availabilityTopic != nil },
                                             by: { $0.availabilityTopic! })
        self.validConfiguration = Set(devices.map(\.id)).count == devices.count
            && devices.count <= 1000
            && devices.allSatisfy { !$0.id.rawValue.isEmpty && Zigbee2MQTTDiscovery.validTopic($0.stateTopic)
                && ($0.commandTopic.isEmpty || Zigbee2MQTTDiscovery.validTopic($0.commandTopic))
                && ($0.availabilityTopic.map(Zigbee2MQTTDiscovery.validTopic) ?? true) }
            && maxStateAge.isFinite && maxStateAge > 0
        self.transport = transport
        self.events = ConnectionEventHub(providerID: id)
        self.maxStateAge = maxStateAge
        self.now = now
    }

    public func connect() async throws {
        guard validConfiguration else { throw IoTError.notConfigured }
        if let connecting { return try await connecting.value }
        if connected { return }
        consumer?.cancel(); consumer = nil
        monitor?.cancel(); monitor = nil
        generation &+= 1
        let token = generation
        let task = Task { try await self.start(generation: token) }
        connecting = task
        do {
            try await task.value
            if generation == token { connecting = nil }
        } catch {
            if generation == token {
                connecting = nil
                connected = false
                consumer?.cancel()
                monitor?.cancel()
                await transport.disconnect()
                await events.publish(.degraded, reason: "Connection failed")
            }
            throw error
        }
    }

    private func start(generation token: UInt64) async throws {
        await events.publish(.connecting)
        // Register the stream before connect/SUBSCRIBE: retained frames can precede SUBACK.
        let frames = await transport.observations()
        consumer = Task { [weak self] in
            for await frame in frames {
                guard !Task.isCancelled else { break }
                await self?.ingest(topic: frame.topic, payload: frame.payload, retained: frame.retained, generation: token)
            }
            await self?.streamEnded(generation: token)
        }
        try await transport.connect()
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        for topic in Set(mapsByTopic.keys).union(mapsByAvailability.keys).sorted() {
            try await transport.subscribe(topic: topic)
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
        }
        connected = true
        await events.publish(.connected)
        if let observable = transport as? any MQTTConnectionMonitoring {
            let states = await observable.connectionStates()
            monitor = Task { [weak self] in
                for await state in states {
                    guard !Task.isCancelled else { break }
                    await self?.transportChanged(state, generation: token)
                }
            }
        }
    }

    public func disconnect() async {
        generation &+= 1
        connected = false
        connecting?.cancel(); connecting = nil
        consumer?.cancel(); consumer = nil
        monitor?.cancel(); monitor = nil
        markUnavailable()
        await transport.disconnect()
        await events.publish(.disconnected)
    }

    private func streamEnded(generation token: UInt64) async {
        guard token == generation else { return }
        connected = false
        markUnavailable()
        await events.publish(.degraded, reason: "State stream ended")
    }

    private func transportChanged(_ state: ProviderConnectionState, generation token: UInt64) async {
        guard token == generation else { return }
        connected = state == .connected
        if !connected { markUnavailable() }
        await events.publish(state)
    }

    private func markUnavailable() {
        for (id, listeners) in subscribers {
            listeners.values.forEach { $0.yield(.unavailable(deviceID: id, at: now())) }
        }
        for (id, state) in cache { cache[id] = state.withAvailability(.offline, origin: .cache) }
    }

    private func ingest(topic: String, payload: Data, retained: Bool?, generation token: UInt64) {
        guard token == generation, payload.count <= 65_536 else { return }
        if let maps = mapsByAvailability[topic] {
            let raw = (try? JSONSerialization.jsonObject(with: payload) as? [String: String])?["state"]
                ?? String(data: payload, encoding: .utf8)
            if raw == "offline" {
                for map in maps {
                    if let state = cache[map.id] { cache[map.id] = state.withAvailability(.offline, origin: .bridge) }
                    subscribers[map.id]?.values.forEach { $0.yield(.unavailable(deviceID: map.id, at: now())) }
                }
            }
            // Online is not a new measurement. Wait for a fresh state report to restore it.
        }
        guard let matching = mapsByTopic[topic] else { return }
        let received = now()
        for map in matching {
            guard let decoded = map.decodeState(payload) else { continue }
            sequence &+= 1
            let observed = decoded.observedAt
                ?? (map.jsonMapping?.observedAtProperty != nil || retained != false ? .distantPast : received)
            let age = received.timeIntervalSince(observed)
            let availability: DeviceAvailability = age >= 0 && age <= maxStateAge ? .online : .degraded
            let state = DeviceState(deviceID: map.id, availability: availability, primaryValue: decoded.value,
                                    primaryUnit: map.jsonMapping.flatMap { decoded.attributes[$0.primary]?.unit },
                                    attributes: decoded.attributes, observedAt: observed, receivedAt: received, origin: .bridge,
                                    revision: StateRevision(localSequence: sequence))
            cache[map.id] = state
            subscribers[map.id]?.values.forEach { $0.yield(.snapshot(state)) }
        }
    }

    public func devices() async throws -> [Device] {
        maps.values.sorted { $0.id.rawValue < $1.id.rawValue }.map {
            Device(id: $0.id, providerID: id, nativeID: $0.stateTopic, name: $0.name, kind: $0.kind,
                   capabilities: Self.descriptors(control: $0.supportsControl))
        }
    }

    private static func descriptors(control: Bool) -> [CapabilityDescriptor] {
        (control ? [.init(id: .control, operations: [.control])] : []) + [.init(id: .readState, operations: [.readState]),
         .init(id: .subscribe, operations: [.subscribe])]
    }

    public func capabilities(for deviceID: DeviceID) async throws -> DeviceCapabilitySet {
        guard let map = maps[deviceID] else { throw IoTError.notConfigured }
        return DeviceCapabilitySet(descriptors: Self.descriptors(control: map.supportsControl),
            control: map.supportsControl ? MQTTControlCapability(provider: self, map: map) : nil,
            readState: MQTTReadStateCapability(provider: self, deviceID: map.id),
            subscribe: MQTTSubscribeCapability(provider: self, deviceID: map.id))
    }

    public func connectionEvents() async -> AsyncStream<ProviderConnectionEvent> { await events.events() }

    func cachedState(_ id: DeviceID) -> DeviceState {
        guard let state = cache[id] else {
            return DeviceState(deviceID: id, availability: .unknown, observedAt: .distantPast,
                               receivedAt: .distantPast, origin: .cache, revision: .init(localSequence: 0))
        }
        guard connected else { return state.withAvailability(.offline, origin: .cache) }
        return state.freshness(at: now(), maxAge: maxStateAge) == .current
            ? state : state.withAvailability(.degraded, origin: .cache)
    }

    func publish(_ map: MQTTDeviceMap, on: Bool, replay: CommandReplayPolicy) async throws {
        guard connected else { throw IoTError.notConnected }
        try Task.checkCancellation()
        try await transport.publish(topic: map.commandTopic, payload: map.render(on),
                                    qos: replay == .replaySafe ? .atLeastOnce : .atMostOnce, retain: false)
    }

    func stateStream(_ id: DeviceID) -> AsyncThrowingStream<DeviceStateChange, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let key = UUID()
            subscribers[id, default: [:]][key] = continuation
            if cache[id] != nil { continuation.yield(.snapshot(cachedState(id))) }
            continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id, key) } }
        }
    }

    private func removeSubscriber(_ id: DeviceID, _ key: UUID) {
        subscribers[id]?[key] = nil
        if subscribers[id]?.isEmpty == true { subscribers[id] = nil }
    }

    deinit {
        consumer?.cancel()
        monitor?.cancel()
        connecting?.cancel()
        for listeners in subscribers.values { for c in listeners.values { c.finish() } }
        let events = events
        Task { await events.finish() }
    }
}

actor MQTTControlCapability: ControlCapability {
    public nonisolated let descriptor = CapabilityDescriptor(id: .control, operations: [.control])
    private let provider: MQTTProvider
    private let map: MQTTDeviceMap
    init(provider: MQTTProvider, map: MQTTDeviceMap) { self.provider = provider; self.map = map }

    func execute<C: DeviceCommand>(_ command: C) async throws -> CommandReceipt {
        guard command.deviceID == map.id else { throw IoTError.notConfigured }
        guard case .setPower(let on) = command.payload else { throw IoTError.notSupported("MQTT control supports power") }
        // Cancelled before dispatch: nothing was sent. Afterwards, even a cancellation cannot prove non-delivery.
        try Task.checkCancellation()
        do { try await provider.publish(map, on: on, replay: command.replayPolicy) }
        catch {
            return CommandReceipt(commandID: command.id, deviceID: map.id, outcome: .uncertain)
        }
        return CommandReceipt(commandID: command.id, deviceID: map.id, outcome: .accepted)
    }
}

actor MQTTReadStateCapability: ReadStateCapability {
    public nonisolated let descriptor = CapabilityDescriptor(id: .readState, operations: [.readState])
    private let provider: MQTTProvider
    private let deviceID: DeviceID
    init(provider: MQTTProvider, deviceID: DeviceID) { self.provider = provider; self.deviceID = deviceID }
    func state() async throws -> DeviceState { await provider.cachedState(deviceID) }
}

actor MQTTSubscribeCapability: SubscribeCapability {
    public nonisolated let descriptor = CapabilityDescriptor(id: .subscribe, operations: [.subscribe])
    private let provider: MQTTProvider
    private let deviceID: DeviceID
    init(provider: MQTTProvider, deviceID: DeviceID) { self.provider = provider; self.deviceID = deviceID }
    func stateChanges() async -> AsyncThrowingStream<DeviceStateChange, any Error> { await provider.stateStream(deviceID) }
}
