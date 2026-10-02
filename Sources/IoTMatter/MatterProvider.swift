import Foundation
import IoTCore

/// Read-only Matter temperature/humidity. Fabric commissioning and controller ownership belong
/// to the host. A received report is not proof of any scheduled action or physical actuation.
public actor MatterProvider: DeviceProvider {
    public nonisolated let id: ProviderID
    public nonisolated let displayName = "Matter"
    private let transport: any MatterSensorTransport
    private let events: ConnectionEventHub
    private let now: @Sendable () -> Date
    private let maxStateAge: TimeInterval
    private var catalog: [DeviceID: MatterSensorDescription] = [:]
    private struct Observation { let value: Double?; let at: Date; let sequence: UInt64 }
    private var observations: [DeviceID: [MatterMeasurement: Observation]] = [:]
    private var cache: [DeviceID: DeviceState] = [:]
    private var listeners: [DeviceID: [UUID: AsyncThrowingStream<DeviceStateChange, any Error>.Continuation]] = [:]
    private var consumer: Task<Void, Never>?
    private var connecting: Task<Void, any Error>?
    private var pendingReads: [DeviceID: Task<DeviceState, any Error>] = [:]
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var connected = false
    private var unavailableSensors = Set<DeviceID>()

    init(transport: any MatterSensorTransport, id: ProviderID = "matter", maxStateAge: TimeInterval = 60,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport; self.id = id; self.events = ConnectionEventHub(providerID: id)
        self.maxStateAge = maxStateAge; self.now = now
    }
    public func connect() async throws {
        guard maxStateAge.isFinite, maxStateAge > 0, !id.rawValue.isEmpty else { throw IoTError.notConfigured }
        if let connecting { return try await connecting.value }
        if connected { return }
        generation &+= 1; let token = generation
        let task = Task { try await self.start(token) }; connecting = task
        do {
            try await task.value
            guard token == generation else { throw CancellationError() }
            connecting = nil
        } catch {
            if token == generation {
                await disconnect()
                await events.publish(.degraded, reason: "Matter sensor connection failed")
            }
            throw error
        }
    }
    private func start(_ token: UInt64) async throws {
        await events.publish(.connecting)
        try await transport.connect()
        try check(token)
        let sensors = try await transport.sensors()
        try check(token)
        guard !sensors.isEmpty, sensors.count <= 32, Set(sensors.map(\.id)).count == sensors.count,
              sensors.allSatisfy({ !$0.id.rawValue.isEmpty && !$0.measurements.isEmpty }) else { throw IoTError.invalidResponse }
        catalog = Dictionary(uniqueKeysWithValues: sensors.map { ($0.id, $0) })
        let reports = await transport.reports()
        try check(token)
        consumer = Task { [weak self] in
            for await report in reports {
                guard !Task.isCancelled else { break }
                await self?.ingest(report, token: token)
            }
            await self?.reportStreamEnded(token)
        }
        for sensor in sensors {
            let issuedSequence = sequence
            let values = try await transport.read(sensor.id)
            try check(token)
            try applyRead(values, to: sensor.id, issuedSequence: issuedSequence)
        }
        try check(token)
        connected = true
        await publishHealth()
    }
    private func check(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }
    public func disconnect() async {
        generation &+= 1; connected = false
        unavailableSensors = []
        connecting?.cancel(); connecting = nil
        consumer?.cancel(); consumer = nil
        for task in pendingReads.values { task.cancel() }; pendingReads = [:]
        for key in cache.keys { cache[key] = cache[key]?.withAvailability(.offline) }
        let streams = listeners; listeners = [:]
        for (key, items) in streams {
            for item in items.values { item.yield(.unavailable(deviceID: key, at: now())); item.finish() }
        }
        await transport.disconnect()
        await events.publish(.disconnected)
    }
    public func devices() throws -> [Device] {
        guard connected else { throw IoTError.notConnected }
        return catalog.values.sorted { $0.id.rawValue < $1.id.rawValue }.map { sensor in
            Device(id: sensor.id, providerID: id, nativeID: sensor.id.rawValue, name: sensor.name, kind: .sensor,
                   capabilities: descriptors)
        }
    }
    private var descriptors: [CapabilityDescriptor] {
        [.init(id: .readState, operations: [.readState]), .init(id: .subscribe, operations: [.subscribe])]
    }
    public func capabilities(for deviceID: DeviceID) throws -> DeviceCapabilitySet {
        guard connected else { throw IoTError.notConnected }
        guard catalog[deviceID] != nil else { throw IoTError.notConfigured }
        return DeviceCapabilitySet(descriptors: descriptors,
            readState: MatterReadState(provider: self, deviceID: deviceID),
            subscribe: MatterSubscription(provider: self, deviceID: deviceID))
    }
    public func connectionEvents() async -> AsyncStream<ProviderConnectionEvent> { await events.events() }

    /// Returns retained evidence without renewing its timestamp. A network read uses refresh(_:).
    public func cachedState(for deviceID: DeviceID) throws -> DeviceState {
        guard let state = cache[deviceID] else { throw IoTError.notConfigured }
        if state.freshness(at: now(), maxAge: maxStateAge) == .stale { return state.withAvailability(.degraded, origin: .cache) }
        return state
    }
    public func refresh(_ deviceID: DeviceID) async throws -> DeviceState {
        guard connected else { throw IoTError.notConnected }
        guard catalog[deviceID] != nil else { throw IoTError.notConfigured }
        if let pending = pendingReads[deviceID] { return try await pending.value }
        let token = generation
        let issuedSequence = sequence
        let task = Task { () throws -> DeviceState in
            let values = try await self.transport.read(deviceID)
            try self.check(token)
            try self.applyRead(values, to: deviceID, issuedSequence: issuedSequence)
            self.unavailableSensors.remove(deviceID)
            await self.publishHealth()
            return try self.cachedState(for: deviceID)
        }
        pendingReads[deviceID] = task
        do {
            let value = try await task.value
            if token == generation { pendingReads[deviceID] = nil }
            return value
        } catch {
            if token == generation {
                pendingReads[deviceID] = nil
                await unavailable(deviceID)
            }
            throw error
        }
    }
    private func applyRead(_ values: [MatterMeasurement: MatterRawValue], to deviceID: DeviceID,
                           issuedSequence: UInt64) throws {
        guard let sensor = catalog[deviceID], Set(values.keys) == sensor.measurements else { throw IoTError.invalidResponse }
        for (kind, value) in values { _ = try kind.decode(value) }
        // A report delivered while a read was in flight is newer evidence. Preserve it per
        // measurement, while still filling fields that did not receive a newer report.
        let unchanged = values.filter { (observations[deviceID]?[$0.key]?.sequence ?? 0) <= issuedSequence }
        if !unchanged.isEmpty { try apply(unchanged, to: deviceID) }
    }
    private func ingest(_ report: MatterReport, token: UInt64) async {
        guard token == generation else { return }
        switch report {
        case .values(let deviceID, let values, let cached):
            // Native priming can contain Apple's cache with no trustworthy observation date.
            guard !cached else { return }
            do {
                try apply(values, to: deviceID)
                unavailableSensors.remove(deviceID)
                await publishHealth()
            }
            catch { await unavailable(deviceID) }
        case .unavailable(let deviceID): await unavailable(deviceID)
        }
    }
    private func apply(_ values: [MatterMeasurement: MatterRawValue], to deviceID: DeviceID) throws {
        guard let sensor = catalog[deviceID], !values.isEmpty, Set(values.keys).isSubset(of: sensor.measurements) else {
            throw IoTError.invalidResponse
        }
        let at = now(); var current = observations[deviceID] ?? [:]
        // Decode the complete batch before publishing; a malformed attribute must not partly refresh a state.
        for (kind, value) in values { current[kind] = Observation(value: try kind.decode(value), at: at, sequence: sequence &+ 1) }
        observations[deviceID] = current
        let primary: MatterMeasurement = sensor.measurements.contains(.temperature) ? .temperature : .humidity
        let observation = current[primary]
        var attributes: [String: StateAttribute] = [:]
        for (kind, entry) in current {
            attributes[kind.key] = StateAttribute(value: entry.value.map(StateValue.decimal) ?? .null, unit: kind.unit)
            attributes[kind.key + "ObservedAt"] = StateAttribute(value: .date(entry.at))
        }
        sequence &+= 1
        let previous = cache[deviceID]
        let state = DeviceState(deviceID: deviceID, availability: observation?.value == nil ? .unknown : .online,
            primaryValue: observation?.value.map(StateValue.decimal), primaryUnit: primary.unit, attributes: attributes,
            observedAt: observation?.at ?? at, receivedAt: observation?.at ?? at, origin: .local,
            revision: StateRevision(localSequence: sequence))
        cache[deviceID] = state
        for listener in listeners[deviceID]?.values ?? [:].values {
            listener.yield(.updated(previous: previous, current: state))
        }
    }
    private func unavailable(_ deviceID: DeviceID) async {
        guard catalog[deviceID] != nil else { return }
        unavailableSensors.insert(deviceID)
        cache[deviceID] = cache[deviceID]?.withAvailability(.degraded)
        for listener in listeners[deviceID]?.values ?? [:].values { listener.yield(.unavailable(deviceID: deviceID, at: now())) }
        await events.publish(.degraded, reason: "A Matter sensor is unavailable")
    }
    private func publishHealth() async {
        guard connected else { return }
        if unavailableSensors.isEmpty { await events.publish(.connected) }
        else { await events.publish(.degraded, reason: "A Matter sensor is unavailable") }
    }
    private func reportStreamEnded(_ token: UInt64) async {
        guard token == generation else { return }
        await disconnect()
        await events.publish(.degraded, reason: "Matter reports ended")
    }
    func updates(_ deviceID: DeviceID) -> AsyncThrowingStream<DeviceStateChange, any Error> {
        let key = UUID()
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            guard connected, catalog[deviceID] != nil else { continuation.finish(throwing: IoTError.notConnected); return }
            guard (listeners[deviceID]?.count ?? 0) < 16 else { continuation.finish(throwing: IoTError.notSupported("Too many sensor listeners")); return }
            listeners[deviceID, default: [:]][key] = continuation
            if let state = try? cachedState(for: deviceID) { continuation.yield(.snapshot(state)) }
            continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(key, deviceID: deviceID) } }
        }
    }
    private func removeListener(_ key: UUID, deviceID: DeviceID) { listeners[deviceID]?[key] = nil }
}

private actor MatterReadState: ReadStateCapability {
    nonisolated let descriptor = CapabilityDescriptor(id: .readState, operations: [.readState])
    let provider: MatterProvider; let deviceID: DeviceID
    init(provider: MatterProvider, deviceID: DeviceID) { self.provider = provider; self.deviceID = deviceID }
    func state() async throws -> DeviceState { try await provider.refresh(deviceID) }
}
private actor MatterSubscription: SubscribeCapability {
    nonisolated let descriptor = CapabilityDescriptor(id: .subscribe, operations: [.subscribe])
    let provider: MatterProvider; let deviceID: DeviceID
    init(provider: MatterProvider, deviceID: DeviceID) { self.provider = provider; self.deviceID = deviceID }
    func stateChanges() async -> AsyncThrowingStream<DeviceStateChange, any Error> { await provider.updates(deviceID) }
}
