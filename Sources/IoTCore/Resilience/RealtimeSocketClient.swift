import Foundation

/// A bidirectional realtime frame transport (WebSocket, MQTT, SSE…). Injectable so the resilient
/// client can be unit-tested with a mock. `receive()` suspends until a frame and throws on close/error
/// — including when `close()` is called from the watchdog to unstick a silently-dead socket.
public protocol RealtimeTransport: Sendable {
    func open() async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
    /// Protocol-level keep-alive (WebSocket ping frame, MQTT PINGREQ…). Default: no-op.
    /// Best-effort — a dead socket is detected by the watchdog's staleness check, not here.
    func ping() async
}

public extension RealtimeTransport {
    func ping() async {}
}

/// Generic resilient realtime client — the hardening layer every subscribe-capable provider reuses
/// (HA WebSocket, MQTT). Generalized from Lumen `FrigateMQTTClient`. Provides:
///  1. an application-level **watchdog** that kills a silently-dead socket (no frame in `staleAfter`),
///  2. backoff with **reconnect-storm suppression** (`RetryPolicy`),
///  3. a **circuit breaker** so a down server isn't hammered,
///  4. a resubscribe/backfill **hook** on each (re)connect.
/// Emits decoded messages via an `AsyncStream`. `Message` must be `Sendable`.
public actor RealtimeSocketClient<Message: Sendable> {

    public struct Config: Sendable {
        public var retry: RetryPolicy
        public var staleAfter: Double        // seconds without any frame → assume silent death
        public var pingEvery: Double         // watchdog tick + keep-alive cadence
        public var handshakeTimeout: Double = 20
        public var maxBufferedMessages: Int = 1024
        public var maxMessageBytes: Int = 4 * 1024 * 1024
        public init(retry: RetryPolicy = .init(), staleAfter: Double = 35, pingEvery: Double = 15) {
            self.retry = retry; self.staleAfter = staleAfter; self.pingEvery = pingEvery
        }
    }

    private let makeTransport: @Sendable () async -> RealtimeTransport
    private let decode: @Sendable (Data) -> Message?
    private let onConnected: @Sendable (RealtimeTransport) async throws -> Void   // handshake/auth + resubscribe + backfill
    private let onDisconnected: @Sendable () async -> Void   // session ended / connect failed → entering backoff
    /// Keep-alive per watchdog tick. Return true when the ping round-trip itself proved liveness
    /// (e.g. URLSession pong callback) — that bumps the activity clock so a quiet-but-healthy
    /// socket isn't killed at `staleAfter`. Transports whose pong arrives as an inbound frame
    /// (raw TCP) return false; the frame bumps activity via `receive()`.
    private let ping: @Sendable (RealtimeTransport) async -> Bool
    private let config: Config
    private let breaker: CircuitBreaker
    private let now: @Sendable () -> Date

    private var runTask: Task<Void, Never>?
    private var lastActivity = ContinuousClock.now
    private var continuations: [UUID: AsyncStream<Message>.Continuation] = [:]
    private var activeTransport: (any RealtimeTransport)?
    private var generation: UInt64 = 0

    /// - Parameters:
    ///   - onDisconnected: fires whenever an established session ends OR a connect attempt fails —
    ///     i.e. each time the client enters backoff. Without it a consumer's "live" UI state
    ///     latches true through an outage (Lumen LR-M04). `onConnected` re-fires on reconnect.
    ///   - ping: keep-alive per tick; defaults to the transport's own `ping()`.
    public init(config: Config = .init(),
                breaker: CircuitBreaker? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                makeTransport: @escaping @Sendable () async -> RealtimeTransport,
                decode: @escaping @Sendable (Data) -> Message?,
                onConnected: @escaping @Sendable (RealtimeTransport) async throws -> Void = { _ in },
                onDisconnected: @escaping @Sendable () async -> Void = {},
                ping: @escaping @Sendable (RealtimeTransport) async -> Bool = { await $0.ping(); return false }) {
        self.config = config
        self.breaker = breaker ?? CircuitBreaker(now: now)
        self.now = now
        self.makeTransport = makeTransport
        self.decode = decode
        self.onConnected = onConnected
        self.onDisconnected = onDisconnected
        self.ping = ping
    }

    /// Start (idempotently) and return the stream of decoded messages. Call `stop()` to end.
    public func messages() -> AsyncStream<Message> {
        guard config.staleAfter.isFinite, config.staleAfter > 0, config.staleAfter <= 86400,
              config.pingEvery.isFinite, config.pingEvery > 0, config.pingEvery <= 3600,
              config.handshakeTimeout.isFinite, config.handshakeTimeout > 0, config.handshakeTimeout <= 300,
              (1...4096).contains(config.maxBufferedMessages),
              (1...16_777_216).contains(config.maxMessageBytes) else {
            return AsyncStream { $0.finish() }
        }
        let key = UUID()
        return AsyncStream(bufferingPolicy: .bufferingOldest(max(1, config.maxBufferedMessages))) { continuation in
            continuations[key] = continuation
            if runTask == nil {
                generation &+= 1
                let token = generation
                runTask = Task { await self.runLoop(generation: token) }
            }
            continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(key) } }
        }
    }

    private func removeListener(_ key: UUID) async {
        continuations[key] = nil
        if continuations.isEmpty { await stop() }
    }

    public func stop() async {
        generation &+= 1
        runTask?.cancel()
        runTask = nil
        let pending = continuations.values
        continuations = [:]
        for continuation in pending { continuation.finish() }
        let transport = activeTransport
        activeTransport = nil
        await transport?.close()
    }

    // MARK: - Run loop

    private func runLoop(generation token: UInt64) async {
        var attempt = 1
        while !Task.isCancelled && token == generation {
            if await !breaker.allow() {
                try? await Task.sleep(for: .seconds(config.pingEvery))
                continue
            }
            let sessionStart = ContinuousClock.now
            let transport = await makeTransport()
            guard token == generation, !Task.isCancelled else { await transport.close(); break }
            activeTransport = transport
            do {
                try await handshake(transport)
                try Task.checkCancellation()
                guard token == generation else { throw CancellationError() }
                await breaker.recordSuccess()
                lastActivity = .now
                try await pump(transport, generation: token)
            } catch {
                await breaker.recordFailure()
            }
            await transport.close()
            if Task.isCancelled || token != generation { break }
            activeTransport = nil
            await onDisconnected()   // entering backoff — let the consumer flip "live" off (LR-M04)
            let lasted = Self.seconds(sessionStart.duration(to: .now))
            attempt = config.retry.nextAttempt(afterSessionLasting: lasted, previousAttempt: attempt)
            guard config.retry.shouldRetry(attempt: attempt) else { break }
            try? await Task.sleep(for: .seconds(config.retry.delay(forAttempt: attempt)))
        }
        if token == generation {
            runTask = nil
            activeTransport = nil
            let pending = continuations.values
            continuations = [:]
            for continuation in pending { continuation.finish() }
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func handshake(_ transport: any RealtimeTransport) async throws {
        let timeout = config.handshakeTimeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await transport.open(); try await self.onConnected(transport) }
            group.addTask {
                try await Task.sleep(for: .seconds(max(0.01, timeout)))
                await transport.close()
                throw IoTError.timeout
            }
            do { try await group.next() }
            catch { group.cancelAll(); await transport.close(); throw error }
            group.cancelAll()
        }
    }

    /// Run the receive loop + watchdog concurrently until one ends (frames stop or the socket dies).
    private func pump(_ transport: RealtimeTransport, generation: UInt64) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.receiveLoop(transport, generation: generation) }
            group.addTask { try await self.watchdog(transport) }
            group.addTask { try await self.pingLoop(transport, generation: generation) }
            do { try await group.next() }
            catch { group.cancelAll(); await transport.close(); throw error }
            group.cancelAll()
            await transport.close()
        }
    }

    private func receiveLoop(_ transport: RealtimeTransport, generation token: UInt64) async throws {
        while !Task.isCancelled {
            let data = try await transport.receive()   // throws when the watchdog closes the socket
            guard token == generation else { throw CancellationError() }
            guard data.count <= config.maxMessageBytes else { throw IoTError.transport("Oversized realtime message") }
            lastActivity = .now
            if let message = decode(data) {
                for continuation in continuations.values {
                    if case .dropped = continuation.yield(message) {
                        throw IoTError.transport("Realtime consumer overflow; resynchronisation required")
                    }
                }
            }
        }
    }

    /// Every `pingEvery`, keep-alive and check for silent death: if no frame arrived within
    /// `staleAfter`, close the transport so `receive()` throws → the run loop reconnects.
    private func watchdog(_ transport: RealtimeTransport) async throws {
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(max(0.01, min(1, config.pingEvery))))
            if Self.seconds(lastActivity.duration(to: .now)) >= config.staleAfter {
                await transport.close()
                throw IoTError.timeout    // silent death → force reconnect
            }
        }
    }

    private func pingLoop(_ transport: RealtimeTransport, generation token: UInt64) async throws {
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(max(0.01, config.pingEvery)))
            if await ping(transport), token == generation { lastActivity = .now }
        }
    }

    /// Send a frame on the current session (best-effort; throws if no live transport). Exposed for
    /// providers that publish/command over the same socket.
    public func send(_ data: Data, via transport: RealtimeTransport) async throws {
        try await transport.send(data)
    }
}
