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

@Suite struct RealtimeSocketClientDisconnectHookTests {

    @Test func stoppingClosesAnUncooperativeReceive() async throws {
        let transport = CloseOnlyTransport()
        let client = RealtimeSocketClient<String>(makeTransport: { transport }, decode: { _ in nil })
        let stream = await client.messages()
        for _ in 0..<100 where !(await transport.waiting) {
            try await Task.sleep(for: .milliseconds(2))
        }
        await client.stop()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await transport.wasClosed)
        await transport.close() // Always release the test transport, including a failing baseline.
        for await _ in stream {}
    }

    @Test(arguments: [Duration.zero, .milliseconds(400)])
    func onDisconnectedFiresOnEachSessionEndBeforeBackoff(startDelay: Duration) async throws {
        // Two short sessions → the hook must fire per session end (LR-M04 disconnect edge).
        let disconnects = Counter()
        let hooks = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(2))
        let config = RealtimeSocketClient<String>.Config(
            retry: RetryPolicy(backoff: [0.02], stableSessionSeconds: 0, steadyStateSeconds: 0.02),
            staleAfter: 5, pingEvery: 5)
        let client = RealtimeSocketClient<String>(
            config: config,
            makeTransport: {
                if startDelay > .zero { try? await Task.sleep(for: startDelay) }
                return MockTransport(frames: [Data("x".utf8)], endError: IoTError.cancelled)
            },
            decode: { String(data: $0, encoding: .utf8) },
            onDisconnected: { await disconnects.bump(); hooks.continuation.yield() }
        )
        let stream = await client.messages()
        // Observe two actual session ends before stopping. A hook caused by stop() must not
        // make this test pass. The deadline bounds a broken implementation, not performance.
        let receivedTwo = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var count = 0
                for await _ in hooks.stream {
                    count += 1
                    if count == 2 { return true }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        #expect(receivedTwo)
        #expect(await disconnects.value >= 2)
        await client.stop()
        hooks.continuation.finish()
        for await _ in stream {}
    }
}

private actor CloseOnlyTransport: RealtimeTransport {
    private var continuation: CheckedContinuation<Data, any Error>?
    private(set) var wasClosed = false
    var waiting: Bool { continuation != nil }
    func open() async throws {}
    func send(_ data: Data) async throws {}
    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func close() async {
        wasClosed = true
        let pending = continuation; continuation = nil
        pending?.resume(throwing: IoTError.cancelled)
    }
}
