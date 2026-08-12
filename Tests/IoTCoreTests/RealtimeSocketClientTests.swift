import Testing
import Foundation
@testable import IoTCore

/// A mock transport: yields `frames` in order, then either throws `endError` (clean session end) or —
/// when `hangWhenEmpty` — suspends forever (simulating a silently-dead socket) until `close()`.
actor MockTransport: RealtimeTransport {
    private var frames: [Data]
    private let endError: (any Error)?
    private let hangWhenEmpty: Bool
    private var closed = false

    init(frames: [Data], endError: (any Error)? = nil, hangWhenEmpty: Bool = false) {
        self.frames = frames
        self.endError = endError
        self.hangWhenEmpty = hangWhenEmpty
    }

    func open() async throws {}
    func send(_ data: Data) async throws {}
    func close() async { closed = true }

    func receive() async throws -> Data {
        if closed { throw IoTError.cancelled }
        if !frames.isEmpty { return frames.removeFirst() }
        if let endError { throw endError }
        if hangWhenEmpty {
            while !closed { try await Task.sleep(for: .milliseconds(20)) }  // suspend → freed on close
            throw IoTError.cancelled
        }
        throw IoTError.cancelled
    }
}

/// Sendable counter for how many transports the client created (= connection attempts).
actor Counter { private(set) var value = 0; func bump() { value += 1 } }

@Suite struct RealtimeSocketClientTests {

    @Test func deliversDecodedFramesFromASession() async throws {
        let payloads = ["a", "b", "c"].map { Data($0.utf8) }
        let client = RealtimeSocketClient<String>(
            makeTransport: { MockTransport(frames: payloads, endError: IoTError.cancelled) },
            decode: { String(data: $0, encoding: .utf8) }
        )
        var received: [String] = []
        for await msg in await client.messages() {
            received.append(msg)
            if received.count == 3 { await client.stop() }
        }
        #expect(received == ["a", "b", "c"])
    }

    @Test func watchdogReconnectsOnSilentDeath() async throws {
        // A transport that connects then hangs forever with no frames = silent death.
        let counter = Counter()
        let config = RealtimeSocketClient<String>.Config(
            retry: RetryPolicy(backoff: [0.05], stableSessionSeconds: 0, steadyStateSeconds: 0.05),
            staleAfter: 0.15, pingEvery: 0.05)
        let client = RealtimeSocketClient<String>(
            config: config,
            makeTransport: { await counter.bump(); return MockTransport(frames: [], hangWhenEmpty: true) },
            decode: { String(data: $0, encoding: .utf8) }
        )
        let stream = await client.messages()
        // Let the watchdog fire and reconnect a few times, then stop.
        try await Task.sleep(for: .milliseconds(800))
        await client.stop()
        // Drain (stream finishes after stop()).
        for await _ in stream {}
        let attempts = await counter.value
        #expect(attempts >= 2)   // proved the silent socket was killed and reconnected
    }
}
