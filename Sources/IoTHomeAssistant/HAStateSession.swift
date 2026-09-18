import Foundation
import IoTCore

/// A single authenticated stream per configured HA connection, with a snapshot on every session.
/// Subscribe and get_states travel on the same ordered WebSocket. Events preceding the snapshot
/// are superseded by that snapshot; later events update it. Device listeners never open sockets.
actor HAStateSession {
    private let url: URL?
    private let token: @Sendable () async throws -> String
    private let makeTransport: (@Sendable () async -> any RealtimeTransport)?
    private let events: ConnectionEventHub
    private let sequence: SequenceGen
    private var cache: [DeviceID: DeviceState] = [:]
    private var listeners: [DeviceID: [UUID: AsyncThrowingStream<DeviceStateChange, any Error>.Continuation]] = [:]
    private var client: RealtimeSocketClient<HAObservedFrame>?
    private var consumer: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var live = false
    private var sessionEpoch: UInt64 = 0
    private var idleState: ProviderConnectionState = .disconnected
    private var interrupted = false
    /// Set by an explicit disconnect and cleared by a successful connect: no listener may re-authenticate
    /// a socket in between, however the app obtained its capability handle.
    private var disconnected = false
    /// REST connectivity was verified. Decided on this actor, so it cannot interleave with `lost()`
    /// between the check and the publication: an interrupted live stream keeps the provider degraded.
    /// Advanced only by an explicit disconnect: work started before it must not resume or publish after it.
    /// A view closing (listener removal) is not a disconnect and leaves it alone.
    private(set) var pauseEpoch: UInt64 = 0

    /// Called by `connect()` with the epoch it observed before verifying. A pause since then (an explicit
    /// disconnect) wins: nothing is resumed or published.
    /// Returns false when an explicit disconnect happened since `epoch`, so the caller can report it.
    @discardableResult
    func restConnected(epoch: UInt64) async -> Bool {
        await beforeRestConnected?()
        guard epoch == pauseEpoch else { return false }
        disconnected = false
        idleState = .connected
        await resumeIfNeeded()
        guard epoch == pauseEpoch else { return false }
        if client != nil && interrupted {
            await events.publish(.degraded, reason: "Home Assistant live updates are reconnecting")
        } else if client == nil || live {
            await events.publish(.connected)
        }
        // Otherwise the stream is still synchronising: it publishes `.connected` itself once the snapshot lands.
        return true
    }

    /// Test seam: runs where an interleaving with `pause()` matters most.
    private var beforeRestConnected: (@Sendable () async -> Void)?
    func setBeforeRestConnected(_ hook: (@Sendable () async -> Void)?) { beforeRestConnected = hook }

    init(url: URL?, token: @escaping @Sendable () async throws -> String,
         makeTransport: (@Sendable () async -> any RealtimeTransport)? = nil,
         events: ConnectionEventHub, sequence: SequenceGen) {
        self.url = url; self.token = token; self.makeTransport = makeTransport
        self.events = events; self.sequence = sequence
    }

    func stream(for device: DeviceID) async -> AsyncThrowingStream<DeviceStateChange, any Error> {
        // Without a usable live-updates address the listener would wait forever: refuse it instead.
        guard url != nil else {
            return AsyncThrowingStream { $0.finish(throwing: IoTError.notConfigured) }
        }
        // After an explicit disconnect only `connect()` may bring the credentialed stream back.
        guard !disconnected else {
            return AsyncThrowingStream { $0.finish(throwing: IoTError.notConnected) }
        }
        let key = UUID()
        let stream = AsyncThrowingStream<DeviceStateChange, any Error>(bufferingPolicy: .bufferingNewest(1)) { c in
            listeners[device, default: [:]][key] = c
            if let state = cache[device] { c.yield(.snapshot(state)) }
            c.onTermination = { [weak self] _ in Task { await self?.remove(device, key) } }
        }
        await resumeIfNeeded()
        return stream
    }

    func resumeIfNeeded() async {
        guard client == nil, !listeners.isEmpty, let url else { return }
        generation &+= 1
        let generation = generation
        let factory = makeTransport
        let tokenProvider = token
        let epoch = HAFrameEpoch()
        let realtime = RealtimeSocketClient<HAObservedFrame>(
            makeTransport: { if let factory { return await factory() }; return HAWebSocketTransport(url: url) },
            decode: { data in HAMessage.decode(data).map { HAObservedFrame(message: $0, epoch: epoch.current) } },
            onConnected: { [weak self] transport in
                let sessionEpoch = epoch.advance()
                await self?.preparing(generation: generation, epoch: sessionEpoch)
                guard case .authRequired? = HAMessage.decode(try await transport.receive()) else { throw IoTError.invalidResponse }
                try await transport.send(HAOutbound.auth(token: try await tokenProvider()))
                guard case .authOK? = HAMessage.decode(try await transport.receive()) else {
                    throw IoTError.authenticationFailed(reason: "Home Assistant")
                }
                try await transport.send(HAOutbound.subscribeStateChanged(id: 1))
                guard case .result(id: 1, success: true)? = HAMessage.decode(try await transport.receive()) else {
                    throw IoTError.invalidResponse
                }
                try await transport.send(Data(#"{"id":2,"type":"get_states"}"#.utf8))
                // The shared client's handshake deadline bounds this phase, even on a busy server.
                for _ in 0..<1024 {
                    try Task.checkCancellation()
                    guard let message = HAMessage.decode(try await transport.receive()) else { throw IoTError.invalidResponse }
                    if case .states(id: 2, entities: let entities) = message {
                        try await self?.bootstrap(entities, generation: generation)
                        return
                    }
                    if case .result(id: 2, success: false) = message { throw IoTError.invalidResponse }
                }
                throw IoTError.transport("Home Assistant snapshot limit exceeded")
            },
            onDisconnected: { [weak self] in await self?.lost(generation: generation) },
            ping: { transport in try? await transport.send(HAOutbound.ping(id: 999)); return false })
        client = realtime
        let messages = await realtime.messages()
        // A pause during that await already dropped this client; starting it now would orphan a live socket.
        guard client === realtime, generation == self.generation else { await realtime.stop(); return }
        consumer?.cancel()
        consumer = Task { [weak self] in
            for await message in messages {
                guard !Task.isCancelled else { break }
                await self?.ingest(message, generation: generation)
            }
            await self?.lost(generation: generation)
        }
    }

    private func preparing(generation token: UInt64, epoch: UInt64) async {
        guard token == generation else { return }
        sessionEpoch = epoch
        live = false
        await events.publish(.connecting, reason: "Synchronising Home Assistant")
    }

    private func bootstrap(_ entities: [HAEntityState], generation token: UInt64) async throws {
        guard token == generation else { throw CancellationError() }
        guard entities.count <= 10_000, Set(entities.map(\.entityID)).count == entities.count else { throw IoTError.invalidResponse }
        var snapshot: [DeviceID: DeviceState] = [:]
        for entity in entities {
            let seq = await sequence.next()
            snapshot[DeviceID(rawValue: entity.entityID)] = entity.deviceState(sequence: seq)
        }
        guard token == generation else { throw CancellationError() }
        cache = snapshot
        live = true
        interrupted = false
        for (id, subscribers) in listeners {
            for c in subscribers.values {
                if let state = cache[id] { c.yield(.snapshot(state)) }
                else { c.yield(.unavailable(deviceID: id, at: Date())) }
            }
        }
        await events.publish(.connected)
    }

    private func ingest(_ frame: HAObservedFrame, generation token: UInt64) async {
        guard token == generation, frame.epoch == sessionEpoch, live else { return }
        switch frame.message {
        case .stateChanged(let entity):
            let id = DeviceID(rawValue: entity.entityID)
            guard cache[id] != nil || cache.count < 10_000 else { await lost(generation: token); return }
            if let existing = cache[id], let updated = entity.lastUpdated, updated < existing.observedAt { return }
            let seq = await sequence.next()
            guard token == generation, frame.epoch == sessionEpoch, live else { return }
            let state = entity.deviceState(sequence: seq)
            let previous = cache.updateValue(state, forKey: id)
            listeners[id]?.values.forEach { $0.yield(.updated(previous: previous, current: state)) }
        case .entityRemoved(let entity):
            let id = DeviceID(rawValue: entity)
            cache[id] = nil
            listeners[id]?.values.forEach { $0.yield(.unavailable(deviceID: id, at: Date())) }
        default: break
        }
    }

    private func lost(generation token: UInt64) async {
        guard token == generation else { return }
        markOffline()
        interrupted = true
        await events.publish(.degraded, reason: "Home Assistant connection interrupted")
    }

    private func markOffline() {
        live = false
        for (id, state) in cache { cache[id] = state.withAvailability(.offline, origin: .cache) }
        for (id, subscribers) in listeners { subscribers.values.forEach { $0.yield(.unavailable(deviceID: id, at: Date())) } }
    }

    /// What an idle provider reports once no listener needs the stream: the REST connection's state.
    func setIdleState(_ state: ProviderConnectionState) { idleState = state }

    /// Intentional stop, not an interruption. `settle` is the state to publish; nil leaves it to the caller.
    /// An explicit disconnect: invalidates in-flight connects and settles the idle state in the same step.
    func disconnect() async {
        pauseEpoch &+= 1
        disconnected = true
        idleState = .disconnected
        await pause()
    }

    func pause(settle: ProviderConnectionState? = nil) async {
        let hadStream = client != nil
        let wasInterrupted = interrupted
        markOffline()
        interrupted = false
        generation &+= 1
        if hadStream, let settle {
            // An old REST success says nothing about a connection that is down right now.
            if wasInterrupted, settle == .connected {
                await events.publish(.degraded, reason: "Home Assistant connection interrupted")
            } else {
                await events.publish(settle)
            }
        }
        let old = client; client = nil
        consumer?.cancel(); consumer = nil
        await old?.stop()
    }

    private func remove(_ device: DeviceID, _ key: UUID) async {
        listeners[device]?[key] = nil
        if listeners[device]?.isEmpty == true { listeners[device] = nil }
        if listeners.isEmpty { await pause(settle: idleState) }
    }

    deinit {
        consumer?.cancel()
        let old = client
        Task { await old?.stop() }
        for subscribers in listeners.values { subscribers.values.forEach { $0.finish() } }
    }
}

private struct HAObservedFrame: Sendable {
    let message: HAMessage
    let epoch: UInt64
}
private final class HAFrameEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    var current: UInt64 { lock.withLock { value } }
    func advance() -> UInt64 { lock.withLock { value &+= 1; return value } }
}
