import Foundation
import IoTCore

#if canImport(Darwin)
/// Native LAN provider. One exchange at a time; every command is confirmed by re-reading the device.
public actor MerossProvider: DeviceProvider {
    public nonisolated let id: ProviderID
    public nonisolated let displayName = "Meross"
    private let key: String
    private let configs: [MerossDeviceConfig]
    private let client: any MerossLANClient
    private let events: ConnectionEventHub
    private let observationInterval: Duration
    private var connected = false
    private var busy = false
    private var foregroundQueue: [UUID] = []
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var pending: Task<MerossReply, any Error>?
    private var profiles: [String: MerossProfile] = [:]
    private var firmwareByUUID: [String: String] = [:]
    private var observers: [UUID: (DeviceID, AsyncThrowingStream<DeviceStateChange, any Error>.Continuation)] = [:]
    private var observedStates: [DeviceID: DeviceState] = [:]
    private var monitor: Task<Void, Never>?
    private var monitorID: UUID?

    struct Target: Hashable, Sendable { let config: MerossDeviceConfig; let channel: Int; let id: DeviceID }

    public init(account: MerossAccount, devices: [MerossDeviceConfig], id: ProviderID = "meross",
                observationInterval: Duration = .seconds(5)) {
        self.init(account: account, devices: devices, client: MerossLANTransport(), id: id, observationInterval: observationInterval)
    }

    init(account: MerossAccount, devices: [MerossDeviceConfig], client: any MerossLANClient,
         id: ProviderID = "meross", observationInterval: Duration = .seconds(5)) {
        key = account.key; configs = devices; self.client = client; self.id = id
        self.observationInterval = observationInterval
        events = ConnectionEventHub(providerID: id)
    }

    // MARK: DeviceProvider

    public func connect() async throws {
        if connected { return }
        guard !configs.isEmpty, configs.count <= 64, !key.isEmpty,
              observationInterval >= .seconds(1), observationInterval <= .seconds(60),
              Set(configs.map(\.uuid)).count == configs.count, Set(configs.map(\.host)).count == configs.count,
              configs.allSatisfy({ MerossLANTransport.url(host: $0.host) != nil && !$0.name.isEmpty && $0.name.utf8.count <= 256 }) else {
            throw IoTError.notConfigured
        }
        guard !busy else { throw IoTError.transport("Meross exchange already in progress") }
        busy = true
        defer { busy = false }
        connected = false
        generation &+= 1
        let epoch = generation
        await events.publish(.connecting)
        do {
            var drift: [String] = []
            for config in configs {
                let identity = try await verify(config, epoch: epoch)
                if let firmware = identity.firmware { firmwareByUUID[config.uuid] = firmware }
                if let ip = identity.innerIp, ip != config.host { drift.append(config.uuid) }
                guard case .ack(let ability) = try await exchange(.get, MerossNamespace.systemAbility, .object([:]), host: config.host, epoch: epoch) else {
                    throw IoTError.invalidResponse
                }
                profiles[config.uuid] = MerossAbilityMap.profile(abilities: Set((ability["ability"]?.objectValue ?? [:]).keys))
            }
            try requireCurrent(epoch)
            connected = true
            await events.publish(.connected, reason: drift.isEmpty ? nil : "Reported address differs for \(drift.count) device(s)")
        } catch {
            if generation == epoch { await events.publish(.degraded, reason: "Meross identity or ability check failed") }
            throw error
        }
    }

    public func disconnect() async {
        generation &+= 1
        connected = false
        pending?.cancel()
        monitor?.cancel(); monitor = nil; monitorID = nil
        let active = observers.values
        observers = [:]; observedStates = [:]
        for (_, continuation) in active { continuation.finish() }
        await events.publish(.disconnected)
    }

    public func devices() async throws -> [Device] {
        guard connected else { throw IoTError.notConnected }
        return targets().map { target in
            let profile = profiles[target.config.uuid] ?? MerossAbilityMap.profile(abilities: [])
            let name = target.config.channelCount > 1 ? "\(target.config.name) \(target.channel)" : target.config.name
            return Device(id: target.id, providerID: id, nativeID: "\(target.config.uuid)#\(target.channel)", name: name, kind: profile.kind,
                          manufacturer: "Meross", model: target.config.model,
                          firmwareVersion: firmwareByUUID[target.config.uuid] ?? target.config.firmware,
                          capabilities: profile.descriptors())
        }
    }

    public func capabilities(for deviceID: DeviceID) async throws -> DeviceCapabilitySet {
        guard connected else { throw IoTError.notConnected }
        guard let target = targets().first(where: { $0.id == deviceID }) else { throw IoTError.notConfigured }
        let profile = profiles[target.config.uuid] ?? MerossAbilityMap.profile(abilities: [])
        return DeviceCapabilitySet(descriptors: profile.descriptors(),
            control: profile.canControl ? MerossController(provider: self, deviceID: deviceID) : nil,
            readState: MerossReader(provider: self, deviceID: deviceID),
            subscribe: MerossSubscriber(provider: self, deviceID: deviceID))
    }

    public func connectionEvents() async -> AsyncStream<ProviderConnectionEvent> { await events.events() }

    // MARK: Targets

    private func targets() -> [Target] {
        configs.flatMap { config -> [Target] in
            if config.channelCount <= 1 { return [Target(config: config, channel: 0, id: config.id)] }
            return (1..<config.channelCount).map { Target(config: config, channel: $0, id: DeviceID(rawValue: "meross:\(config.uuid)#\($0)")) }
        }
    }

    // MARK: Read

    fileprivate func read(_ deviceID: DeviceID) async throws -> DeviceState {
        guard connected else { throw IoTError.notConnected }
        guard let target = targets().first(where: { $0.id == deviceID }) else { throw IoTError.notConfigured }
        guard !busy, foregroundQueue.isEmpty else { throw IoTError.transport("Meross exchange already in progress") }
        busy = true
        defer { busy = false }
        return try await snapshot(target, epoch: generation)
    }

    private func snapshot(_ target: Target, epoch: UInt64) async throws -> DeviceState {
        let profile = profiles[target.config.uuid] ?? MerossAbilityMap.profile(abilities: [])
        guard case .ack(let all) = try await exchange(.get, MerossNamespace.systemAll, .object([:]), host: target.config.host, epoch: epoch),
              let identity = MerossStateMapper.identity(all: all), identity.uuid == target.config.uuid else { throw IoTError.invalidResponse }
        var extras: [String: MerossJSON] = [:]
        for namespace in profile.readNamespaces {
            let payload = readPayload(for: namespace, channel: target.channel)
            if case .ack(let ack) = try await exchange(.get, namespace, payload, host: target.config.host, epoch: epoch) { extras[namespace] = ack }
        }
        sequence &+= 1
        return MerossStateMapper.state(deviceID: target.id, channel: target.channel, profile: profile,
                                       snapshot: .init(all: all, extras: extras), sequence: sequence, now: Date())
    }

    /// Most GET namespaces are answered device-wide with an empty payload; per-channel metering
    /// (e.g. electricity) must ask for the specific channel or the device answers for its default one.
    private func readPayload(for namespace: String, channel: Int) -> MerossJSON {
        if namespace == MerossNamespace.electricity {
            return .object(["electricity": .object(["channel": .number(Double(channel))])])
        }
        return .object([:])
    }

    // MARK: Execute

    fileprivate func execute<C: DeviceCommand>(_ command: C, expectedID: DeviceID) async throws -> CommandReceipt {
        guard connected else { throw IoTError.notConnected }
        guard command.deviceID == expectedID, let target = targets().first(where: { $0.id == expectedID }) else { throw IoTError.notConfigured }
        let profile = profiles[target.config.uuid] ?? MerossAbilityMap.profile(abilities: [])
        let encoded = try MerossCommandEncoder.encode(command.payload, channel: target.channel, profile: profile, current: observedStates[expectedID])
        let epoch = generation
        try await acquireForeground(epoch: epoch)
        defer { busy = false }
        let reply: MerossReply
        do { reply = try await exchange(.set, encoded.namespace, encoded.payload, host: target.config.host, epoch: epoch) }
        catch { return CommandReceipt(commandID: command.id, deviceID: expectedID, outcome: .uncertain) }
        if case .error(let code, _) = reply {
            return CommandReceipt(commandID: command.id, deviceID: expectedID, outcome: .rejected, providerTransactionID: "meross-error:\(code)")
        }
        do {
            let state = try await snapshot(target, epoch: epoch)
            observedStates[expectedID] = state
            let confirmed = !encoded.readBack.isEmpty && encoded.readBack.allSatisfy { state.attributes[$0.key]?.value == $0.value }
            let outcome: CommandOutcome = encoded.readBack.isEmpty ? .accepted : (confirmed ? .applied : .uncertain)
            return CommandReceipt(commandID: command.id, deviceID: expectedID, outcome: outcome, state: state)
        } catch {
            return CommandReceipt(commandID: command.id, deviceID: expectedID, outcome: .uncertain)
        }
    }

    // MARK: Subscribe (temporary; replaced in Task 11)

    fileprivate func observe(_ deviceID: DeviceID) -> AsyncThrowingStream<DeviceStateChange, any Error> {
        let pair = AsyncThrowingStream<DeviceStateChange, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.finish(throwing: IoTError.notSupported("Meross subscribe pending"))
        return pair.stream
    }

    // MARK: Plumbing

    private func acquireForeground(epoch: UInt64) async throws {
        guard foregroundQueue.count < 16 else { throw IoTError.transport("Meross command queue is full") }
        let ticket = UUID()
        foregroundQueue.append(ticket)
        defer { foregroundQueue.removeAll { $0 == ticket } }
        let deadline = ContinuousClock.now + .seconds(5)
        while busy || foregroundQueue.first != ticket {
            try requireCurrent(epoch)
            guard ContinuousClock.now < deadline else { throw IoTError.timeout }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { throw IoTError.cancelled }
        }
        try requireCurrent(epoch)
        busy = true
    }

    private func verify(_ config: MerossDeviceConfig, epoch: UInt64) async throws -> (uuid: String, firmware: String?, innerIp: String?, mac: String?, online: Bool?) {
        guard case .ack(let all) = try await exchange(.get, MerossNamespace.systemAll, .object([:]), host: config.host, epoch: epoch),
              let identity = MerossStateMapper.identity(all: all), identity.uuid == config.uuid else { throw IoTError.invalidResponse }
        return identity
    }

    private func requireCurrent(_ epoch: UInt64) throws {
        try Task.checkCancellation()
        guard generation == epoch else { throw IoTError.notConnected }
    }

    private func exchange(_ method: MerossMethod, _ namespace: String, _ payload: MerossJSON, host: String, epoch: UInt64) async throws -> MerossReply {
        try requireCurrent(epoch)
        let request = MerossMessage.request(method: method, namespace: namespace, payload: payload, key: key)
        let client = self.client
        let task = Task { try await Self.exchange(request, host: host, client: client) }
        pending = task
        defer { pending = nil }
        let reply = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try requireCurrent(epoch)
        return reply
    }

    /// Shared by discovery and the provider: maps transport/device failures onto IoTError, keeps
    /// device `ERROR`s (other than signature) as `.error` replies for the caller to classify.
    static func exchange(_ request: MerossMessage, host: String, client: any MerossLANClient) async throws -> MerossReply {
        let message: MerossMessage
        do { message = try await client.exchange(request, host: host) }
        catch let error as IoTError { throw error }
        catch is CancellationError { throw IoTError.cancelled }
        catch let failure as MerossLANTransport.Failure {
            switch failure {
            case .invalidHost: throw IoTError.notConfigured
            case .http, .oversize, .malformed: throw IoTError.transport("Meross LAN exchange failed")
            }
        } catch let error as URLError where error.code == .timedOut { throw IoTError.timeout }
        catch { throw IoTError.transport("Meross LAN exchange failed") }
        let reply = try message.reply(to: request)
        if case .error(let code, _) = reply, MerossDeviceError(code: code, detail: "") == .signature {
            throw IoTError.authenticationFailed(reason: "Meross key rejected")
        }
        return reply
    }

    deinit {
        monitor?.cancel()
        pending?.cancel()
        for (_, continuation) in observers.values { continuation.finish() }
    }
}

private actor MerossController: ControlCapability {
    nonisolated let descriptor = CapabilityDescriptor(id: .control, operations: [.control])
    let provider: MerossProvider
    let deviceID: DeviceID
    init(provider: MerossProvider, deviceID: DeviceID) { self.provider = provider; self.deviceID = deviceID }
    func execute<C: DeviceCommand>(_ command: C) async throws -> CommandReceipt { try await provider.execute(command, expectedID: deviceID) }
}

private actor MerossReader: ReadStateCapability {
    nonisolated let descriptor = CapabilityDescriptor(id: .readState, operations: [.readState])
    let provider: MerossProvider
    let deviceID: DeviceID
    init(provider: MerossProvider, deviceID: DeviceID) { self.provider = provider; self.deviceID = deviceID }
    func state() async throws -> DeviceState { try await provider.read(deviceID) }
}

private actor MerossSubscriber: SubscribeCapability {
    nonisolated let descriptor = CapabilityDescriptor(id: .subscribe, operations: [.subscribe])
    let provider: MerossProvider
    let deviceID: DeviceID
    init(provider: MerossProvider, deviceID: DeviceID) { self.provider = provider; self.deviceID = deviceID }
    func stateChanges() async -> AsyncThrowingStream<DeviceStateChange, any Error> { await provider.observe(deviceID) }
}
#endif
