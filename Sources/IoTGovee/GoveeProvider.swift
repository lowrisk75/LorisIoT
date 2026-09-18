import Foundation
import IoTCore

#if canImport(Darwin)
public struct GoveeDeviceConfig: Sendable {
    public let device: String
    public let model: String
    public let host: String
    public let name: String
    public var id: DeviceID { .init(rawValue: "govee:" + device.uppercased()) }
    public init(device: String, model: String, host: String, name: String) {
        self.device = device.uppercased(); self.model = model
        self.host = host; self.name = name
    }

    /// Targeted discovery only: no setting, control or multicast scan is performed.
    public static func discover(host: String, name: String = "",
                                client: any GoveeLANClient = GoveeLANTransport()) async throws -> Self {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.utf8.count <= 15, name.utf8.count <= 256 else { throw IoTError.notConfigured }
        let reply: GoveeLANMessage
        do { reply = try await client.query(.discovery, host: host, timeout: 2) }
        catch GoveeLANTransport.Failure.timeout { throw IoTError.timeout }
        catch GoveeLANTransport.Failure.invalidEndpoint { throw IoTError.notConfigured }
        catch is CancellationError { throw IoTError.cancelled }
        catch { throw IoTError.transport("Govee discovery failed") }
        try Task.checkCancellation()
        guard case .discovery(let found) = reply, found.ip == host else { throw IoTError.invalidResponse }
        return Self(device: found.device, model: found.sku, host: host,
                    name: name.isEmpty ? "Govee " + found.sku : name)
    }
}

/// Native LAN provider. Read support is available before control qualification; unsupported
/// capabilities are absent. No durable device schedule is implied by LAN reachability.
public actor GoveeProvider: DeviceProvider {
    public nonisolated let id: ProviderID
    public nonisolated let displayName = "Govee"
    private let configs: [GoveeDeviceConfig]
    private let client: any GoveeLANClient
    private let controlClient: (any GoveeLANControlClient)?
    private let events: ConnectionEventHub
    private var connected = false
    private var busy = false
    private var foregroundQueue: [UUID] = []
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var pending: Task<GoveeLANMessage, any Error>?
    private var pendingControl: Task<Void, any Error>?
    private var cancelDiscovery: (@Sendable () -> Void)?
    private let observationInterval: Duration
    private var observers: [UUID: (DeviceID, AsyncThrowingStream<DeviceStateChange, any Error>.Continuation)] = [:]
    private var observedStates: [DeviceID: DeviceState] = [:]
    private var monitor: Task<Void, Never>?
    private var monitorID: UUID?
    private static let subscribeDescriptor = CapabilityDescriptor(id: .subscribe, operations: [.subscribe],
        metadata: ["delivery": .string("shared-polling"), "buffer": .integer(1)])
    private static let controlModels: Set<String> = ["H6022", "H61E6"]
    private static let controlDescriptor = CapabilityDescriptor(id: .control, operations: [.control],
        metadata: ["commands": .array([.string("setPower"), .string("setLevel"),
            .string("color"), .string("colorTemperature")]), "requestCorrelation": .bool(false)])
    private static let readDescriptor = CapabilityDescriptor(id: .readState, operations: [.readState],
        metadata: ["transport": .string("lan-udp"), "authenticated": .bool(false),
                   "observationTime": .string("receipt-time"), "requestCorrelation": .bool(false)])

    public init(devices: [GoveeDeviceConfig], client: any GoveeLANClient = GoveeLANTransport(),
                id: ProviderID = "govee", observationInterval: Duration = .seconds(2)) {
        configs = devices; self.client = client; self.id = id
        self.observationInterval = observationInterval
        controlClient = client as? any GoveeLANControlClient
        events = ConnectionEventHub(providerID: id)
    }

    public func connect() async throws {
        if connected { return }
        guard !configs.isEmpty, configs.count <= 64,
              observationInterval >= .milliseconds(50), observationInterval <= .seconds(60),
              Set(configs.map(\.id)).count == configs.count,
              Set(configs.map(\.host)).count == configs.count,
              configs.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 256 }) else {
            throw IoTError.notConfigured
        }
        guard !busy else { throw IoTError.transport("Govee exchange already in progress") }
        busy = true
        defer { busy = false }
        connected = false
        generation &+= 1
        let epoch = generation
        await events.publish(.connecting)
        do {
            for config in configs { try await verify(config, epoch: epoch) }
            try requireCurrent(epoch)
            connected = true
            await events.publish(.connected)
        } catch {
            if generation == epoch { await events.publish(.degraded, reason: "Govee identity or connection check failed") }
            throw error
        }
    }

    public func disconnect() async {
        generation &+= 1
        connected = false
        pending?.cancel()
        pendingControl?.cancel()
        cancelDiscovery?()
        monitor?.cancel(); monitor = nil; monitorID = nil
        let active = observers.values
        observers = [:]; observedStates = [:]
        for (_, continuation) in active { continuation.finish() }
        await events.publish(.disconnected)
    }

    public func devices() async throws -> [Device] {
        guard connected else { throw IoTError.notConnected }
        return configs.map {
            Device(id: $0.id, providerID: id, nativeID: $0.device, name: $0.name, kind: .light,
                   manufacturer: "Govee", model: $0.model, capabilities: descriptors($0))
        }
    }

    public func capabilities(for deviceID: DeviceID) async throws -> DeviceCapabilitySet {
        guard connected else { throw IoTError.notConnected }
        guard let config = configs.first(where: { $0.id == deviceID }) else { throw IoTError.notConfigured }
        return DeviceCapabilitySet(descriptors: descriptors(config),
            control: canControl(config) ? GoveeController(provider: self, deviceID: deviceID) : nil,
            readState: GoveeReader(provider: self, deviceID: deviceID),
            subscribe: GoveeSubscriber(provider: self, deviceID: deviceID))
    }

    private func canControl(_ config: GoveeDeviceConfig) -> Bool {
        controlClient != nil && Self.controlModels.contains(config.model)
    }

    private func descriptors(_ config: GoveeDeviceConfig) -> [CapabilityDescriptor] {
        [Self.readDescriptor, Self.subscribeDescriptor] + (canControl(config) ? [Self.controlDescriptor] : [])
    }

    fileprivate func observe(_ deviceID: DeviceID) -> AsyncThrowingStream<DeviceStateChange, any Error> {
        let pair = AsyncThrowingStream<DeviceStateChange, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard connected else { pair.continuation.finish(throwing: IoTError.notConnected); return pair.stream }
        guard observers.count < 64, configs.contains(where: { $0.id == deviceID }) else {
            pair.continuation.finish(throwing: IoTError.notConfigured); return pair.stream
        }
        let key = UUID()
        observers[key] = (deviceID, pair.continuation)
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(key) } }
        if monitor == nil {
            let identity = UUID()
            monitorID = identity
            let interval = observationInterval
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    guard let shouldContinue = await self?.poll(identity), shouldContinue else { return }
                    do { try await Task.sleep(for: interval) } catch { return }
                }
            }
        }
        return pair.stream
    }

    private func removeObserver(_ key: UUID) {
        observers[key] = nil
        let retained = Set(observers.values.map { $0.0 })
        observedStates = observedStates.filter { retained.contains($0.key) }
        if observers.isEmpty {
            monitor?.cancel(); monitor = nil; monitorID = nil
        }
    }

    private func poll(_ identity: UUID) async -> Bool {
        guard monitorID == identity, connected, !observers.isEmpty else { return false }
        // Never let background polling compete with an in-flight manual command.
        guard !busy, foregroundQueue.isEmpty else { return true }
        let ids = Set(observers.values.map { $0.0 }).sorted { $0.rawValue < $1.rawValue }
        for deviceID in ids {
            guard !Task.isCancelled, monitorID == identity, connected else { return false }
            guard !busy, foregroundQueue.isEmpty else { break }
            do {
                let state = try await read(deviceID)
                guard !Task.isCancelled, monitorID == identity, connected else { return false }
                let previous = observedStates[deviceID]
                observedStates[deviceID] = state
                let change: DeviceStateChange = previous.map { .updated(previous: $0, current: state) } ?? .snapshot(state)
                for (id, continuation) in observers.values where id == deviceID { continuation.yield(change) }
            } catch {
                guard !Task.isCancelled, monitorID == identity, connected else { return false }
                observedStates[deviceID] = nil
                for (id, continuation) in observers.values where id == deviceID {
                    continuation.yield(.unavailable(deviceID: deviceID, at: Date()))
                }
            }
        }
        return true
    }

    deinit {
        monitor?.cancel()
        pending?.cancel()
        pendingControl?.cancel()
        cancelDiscovery?()
        for (_, continuation) in observers.values { continuation.finish() }
    }

    fileprivate func execute<C: DeviceCommand>(_ command: C, expectedID: DeviceID) async throws -> CommandReceipt {
        guard connected else { throw IoTError.notConnected }
        guard command.deviceID == expectedID,
              let config = configs.first(where: { $0.id == expectedID }) else { throw IoTError.notConfigured }
        guard canControl(config), let controlClient else { throw IoTError.notSupported("Govee model control") }
        let encoded = try GoveeLANCommand(payload: command.payload)
        let epoch = generation
        try await acquireForeground(epoch: epoch)
        defer { busy = false; pendingControl = nil }
        try await verify(config, epoch: epoch)
        try requireCurrent(epoch)
        let send = Task { try await controlClient.send(encoded, host: config.host) }
        pendingControl = send
        do {
            try await withTaskCancellationHandler { try await send.value } onCancel: { send.cancel() }
            try requireCurrent(epoch)
            guard case .status(let status) = try await exchange(.status, host: config.host, epoch: epoch) else {
                throw IoTError.invalidResponse
            }
            // Matching content is useful, but without a transaction ID even this read can
            // be a delayed UDP packet. Do not label it applied or automatically replay it.
            return CommandReceipt(commandID: command.id, deviceID: expectedID,
                outcome: encoded.matches(status) ? .accepted : .uncertain,
                state: makeState(status, id: expectedID))
        } catch {
            // Once dispatch starts, cancellation/timeout/disconnect cannot prove non-delivery.
            return CommandReceipt(commandID: command.id, deviceID: expectedID, outcome: .uncertain)
        }
    }

    public func connectionEvents() async -> AsyncStream<ProviderConnectionEvent> { await events.events() }

    public func withDiscoveryPaused<T: Sendable>(
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard connected else { throw IoTError.notConnected }
        let epoch = generation
        try await acquireForeground(epoch: epoch)
        defer { busy = false; cancelDiscovery = nil }
        let task = Task { try Task.checkCancellation(); return try await operation() }
        cancelDiscovery = { task.cancel() }
        let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try requireCurrent(epoch)
        return value
    }

    public static func withDiscoveryPaused<T: Sendable>(
        providers: [GoveeProvider], operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard providers.count <= 64, Set(providers.map(ObjectIdentifier.init)).count == providers.count else {
            throw IoTError.notConfigured
        }
        // Stable actor order prevents competing callers acquiring the same set in reverse.
        let sorted = providers.sorted { String(describing: ObjectIdentifier($0)) < String(describing: ObjectIdentifier($1)) }
        return try await pause(sorted, at: 0, operation: operation)
    }

    private static func pause<T: Sendable>(_ providers: [GoveeProvider], at index: Int,
                                          operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard index < providers.count else { return try await operation() }
        return try await providers[index].withDiscoveryPaused {
            try await pause(providers, at: index + 1, operation: operation)
        }
    }

    private func acquireForeground(epoch: UInt64) async throws {
        guard foregroundQueue.count < 16 else { throw IoTError.transport("Govee command queue is full") }
        let ticket = UUID()
        foregroundQueue.append(ticket)
        defer { foregroundQueue.removeAll { $0 == ticket } }
        let deadline = ContinuousClock.now + .seconds(5)
        while busy || foregroundQueue.first != ticket {
            try requireCurrent(epoch)
            guard ContinuousClock.now < deadline else { throw IoTError.timeout }
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { throw IoTError.cancelled }
        }
        try requireCurrent(epoch)
        busy = true
    }

    fileprivate func read(_ id: DeviceID) async throws -> DeviceState {
        guard connected else { throw IoTError.notConnected }
        guard let config = configs.first(where: { $0.id == id }) else { throw IoTError.notConfigured }
        guard !busy, foregroundQueue.isEmpty else { throw IoTError.transport("Govee exchange already in progress") }
        busy = true
        defer { busy = false }
        let epoch = generation
        // Recheck identity because a DHCP address may have been reassigned after connect.
        try await verify(config, epoch: epoch)
        guard case .status(let status) = try await exchange(.status, host: config.host, epoch: epoch) else {
            throw IoTError.invalidResponse
        }
        return makeState(status, id: id)
    }

    private func makeState(_ status: GoveeLANMessage.Status, id: DeviceID) -> DeviceState {
        sequence &+= 1
        var attributes: [String: StateAttribute] = [:]
        if let value = status.brightness { attributes["brightness"] = .init(value: .integer(Int64(value)), unit: .percent) }
        if let value = status.colorTemInKelvin, value != 0 {
            attributes["colorTemperature"] = .init(value: .integer(Int64(value)), unit: .kelvin)
        }
        if let rgb = status.color {
            attributes["color"] = .init(value: .object(["r": .integer(Int64(rgb.r)),
                "g": .integer(Int64(rgb.g)), "b": .integer(Int64(rgb.b))]))
        }
        let received = Date()
        return DeviceState(deviceID: id, availability: .online,
            primaryValue: status.onOff.map { .bool($0 == 1) }, attributes: attributes,
            observedAt: received, receivedAt: received, origin: .local,
            revision: .init(localSequence: sequence))
    }

    private func verify(_ config: GoveeDeviceConfig, epoch: UInt64) async throws {
        guard case .discovery(let found) = try await exchange(.discovery, host: config.host, epoch: epoch),
              found.device.uppercased() == config.device, found.sku == config.model,
              found.ip == config.host else { throw IoTError.invalidResponse }
    }

    private func requireCurrent(_ epoch: UInt64) throws {
        try Task.checkCancellation()
        guard generation == epoch else { throw IoTError.notConnected }
    }

    private func exchange(_ query: GoveeLANTransport.Query, host: String, epoch: UInt64) async throws -> GoveeLANMessage {
        try requireCurrent(epoch)
        let task = Task { try await client.query(query, host: host, timeout: 2) }
        pending = task
        defer { pending = nil }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try requireCurrent(epoch)
            return result
        } catch let error as IoTError { throw error }
        catch is CancellationError { throw IoTError.cancelled }
        catch let error as GoveeLANTransport.Failure {
            switch error {
            case .timeout: throw IoTError.timeout
            case .cancelled: throw IoTError.cancelled
            case .invalidEndpoint: throw IoTError.notConfigured
            case .busyOrUnavailable: throw IoTError.transport("Govee reply port unavailable")
            case .socket: throw IoTError.transport("Govee LAN exchange failed")
            }
        } catch { throw IoTError.invalidResponse }
    }
}

private actor GoveeController: ControlCapability {
    nonisolated let descriptor = CapabilityDescriptor(id: .control, operations: [.control])
    let provider: GoveeProvider
    let deviceID: DeviceID
    init(provider: GoveeProvider, deviceID: DeviceID) { self.provider = provider; self.deviceID = deviceID }
    func execute<C: DeviceCommand>(_ command: C) async throws -> CommandReceipt {
        try await provider.execute(command, expectedID: deviceID)
    }
}

private actor GoveeReader: ReadStateCapability {
    nonisolated let descriptor = CapabilityDescriptor(id: .readState, operations: [.readState])
    let provider: GoveeProvider
    let deviceID: DeviceID
    init(provider: GoveeProvider, deviceID: DeviceID) { self.provider = provider; self.deviceID = deviceID }
    func state() async throws -> DeviceState { try await provider.read(deviceID) }
}

private actor GoveeSubscriber: SubscribeCapability {
    nonisolated let descriptor = CapabilityDescriptor(id: .subscribe, operations: [.subscribe])
    let provider: GoveeProvider
    let deviceID: DeviceID
    init(provider: GoveeProvider, deviceID: DeviceID) { self.provider = provider; self.deviceID = deviceID }
    func stateChanges() async -> AsyncThrowingStream<DeviceStateChange, any Error> {
        await provider.observe(deviceID)
    }
}
#endif
