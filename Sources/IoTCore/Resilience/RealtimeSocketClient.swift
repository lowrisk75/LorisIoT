import Foundation

/// A bidirectional realtime frame transport (WebSocket, MQTT, SSE…). Injectable so the resilient
/// client can be unit-tested with a mock. `receive()` suspends until a frame and throws on close/error
/// — including when `close()` is called from the watchdog to unstick a silently-dead socket.
public protocol RealtimeTransport: Sendable {
    func open() async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
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
        public init(retry: RetryPolicy = .init(), staleAfter: Double = 35, pingEvery: Double = 15) {
            self.retry = retry; self.staleAfter = staleAfter; self.pingEvery = pingEvery
        }
    }

    private let makeTransport: @Sendable () async -> RealtimeTransport
    private let decode: @Sendable (Data) -> Message?
    private let onConnected: @Sendable (RealtimeTransport) async throws -> Void   // handshake/auth + resubscribe + backfill
    private let ping: @Sendable (RealtimeTransport) async -> Void          // protocol keep-alive
    private let config: Config
    private let breaker: CircuitBreaker
    private let now: @Sendable () -> Date

    private var runTask: Task<Void, Never>?
    private var lastActivity: Date = .distantPast
    private var continuation: AsyncStream<Message>.Continuation?

    public init(config: Config = .init(),
                breaker: CircuitBreaker? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                makeTransport: @escaping @Sendable () async -> RealtimeTransport,
                decode: @escaping @Sendable (Data) -> Message?,
                onConnected: @escaping @Sendable (RealtimeTransport) async throws -> Void = { _ in },
                ping: @escaping @Sendable (RealtimeTransport) async -> Void = { _ in }) {
        self.config = config
        self.breaker = breaker ?? CircuitBreaker(now: now)
        self.now = now
        self.makeTransport = makeTransport
        self.decode = decode
        self.onConnected = onConnected
        self.ping = ping
    }

    /// Start (idempotently) and return the stream of decoded messages. Call `stop()` to end.
    public func messages() -> AsyncStream<Message> {
        AsyncStream { continuation in
            self.continuation = continuation
            if runTask == nil { runTask = Task { await self.runLoop() } }
            continuation.onTermination = { _ in Task { await self.stop() } }
        }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Run loop

    private func runLoop() async {
        var attempt = 1
        while !Task.isCancelled {
            if await !breaker.allow() {
                try? await Task.sleep(for: .seconds(config.pingEvery))
                continue
            }
            let sessionStart = now()
            let transport = await makeTransport()
            do {
                try await transport.open()
                await breaker.recordSuccess()
                lastActivity = now()
                try await onConnected(transport)  // handshake/auth + resubscribe + backfill; throws → reconnect
                lastActivity = now()              // handshake counts as activity
                try await pump(transport)         // returns/throws when the session dies
            } catch {
                await breaker.recordFailure()
            }
            await transport.close()
            if Task.isCancelled { break }
            let lasted = now().timeIntervalSince(sessionStart)
            attempt = config.retry.nextAttempt(afterSessionLasting: lasted, previousAttempt: attempt)
            guard config.retry.shouldRetry(attempt: attempt) else { break }
            try? await Task.sleep(for: .seconds(config.retry.delay(forAttempt: attempt)))
        }
        continuation?.finish()
    }

    /// Run the receive loop + watchdog concurrently until one ends (frames stop or the socket dies).
    private func pump(_ transport: RealtimeTransport) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.receiveLoop(transport) }
            group.addTask { try await self.watchdog(transport) }
            try await group.next()      // first to finish/throw ends the session
            group.cancelAll()
        }
    }

    private func receiveLoop(_ transport: RealtimeTransport) async throws {
        while !Task.isCancelled {
            let data = try await transport.receive()   // throws when the watchdog closes the socket
            lastActivity = now()
            if let message = decode(data) { continuation?.yield(message) }
        }
    }

    /// Every `pingEvery`, keep-alive and check for silent death: if no frame arrived within
    /// `staleAfter`, close the transport so `receive()` throws → the run loop reconnects.
    private func watchdog(_ transport: RealtimeTransport) async throws {
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(config.pingEvery))
            await ping(transport)
            if now().timeIntervalSince(lastActivity) > config.staleAfter {
                await transport.close()
                throw ProviderError.timeout    // silent death → force reconnect
            }
        }
    }

    /// Send a frame on the current session (best-effort; throws if no live transport). Exposed for
    /// providers that publish/command over the same socket.
    public func send(_ data: Data, via transport: RealtimeTransport) async throws {
        try await transport.send(data)
    }
}
