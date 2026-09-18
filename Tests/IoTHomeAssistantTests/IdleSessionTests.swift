import Foundation
import Testing
import IoTCore
@testable import IoTHomeAssistant

/// Closing the last view, or disconnecting on purpose, is not an interruption: a healthy connection
/// must never be reported degraded on the way.
@Suite struct HAIdleSessionTests {
    @Test func lastSubscriberLeavingDoesNotDegradeAHealthyConnection() async throws {
        let transport = HAIdleTransport()
        let provider = Self.provider(transport)
        let recorder = StateRecorder(await provider.connectionEvents())
        try await provider.connect()
        let subscribe = try #require(try await provider.capabilities(for: "switch.first").subscribe)
        let task = Task { for try await change in await subscribe.stateChanges() { if case .snapshot = change { return } } }
        try await task.value
        #expect(await recorder.waitFor(.connected, after: 1))
        #expect(await transport.waitUntilClosed())
        try await Task.sleep(for: .milliseconds(200))
        let states = await recorder.states
        #expect(!states.contains(.degraded), "states: \(states)")
        #expect(states.last == .connected, "states: \(states)")
    }

    @Test func disconnectingReportsDisconnectedWithoutAnInterruptionFirst() async throws {
        let transport = HAIdleTransport()
        let provider = Self.provider(transport)
        let recorder = StateRecorder(await provider.connectionEvents())
        try await provider.connect()
        let subscribe = try #require(try await provider.capabilities(for: "switch.first").subscribe)
        let stream = await subscribe.stateChanges()
        let task = Task { for try await change in stream { if case .snapshot = change { return } } }
        try await task.value
        #expect(await recorder.waitFor(.connected, after: 1))
        await provider.disconnect()
        #expect(await recorder.waitFor(.disconnected, after: 1))
        try await Task.sleep(for: .milliseconds(200))
        let states = await recorder.states
        #expect(!states.contains(.degraded), "states: \(states)")
        #expect(states.last == .disconnected, "states: \(states)")
    }

    /// REST answering does not bring back live updates: during a stream outage `connect()` must not claim them.
    @Test func connectDuringALiveStreamOutageDoesNotReportConnected() async throws {
        let first = HAIdleTransport()
        let attempts = AttemptCounter()
        let provider = HomeAssistantProvider(config: HAConfig(baseURL: URL(string: "https://ha.invalid")!), token: "fixture-token",
            http: MockHTTP { _, _, _ in (Data(#"{"message":"API running."}"#.utf8), 200) },
            makeTransport: { await attempts.next() == 1 ? first as any RealtimeTransport : UnreachableTransport() })
        let recorder = StateRecorder(await provider.connectionEvents())
        try await provider.connect()
        let subscribe = try #require(try await provider.capabilities(for: "switch.first").subscribe)
        let stream = await subscribe.stateChanges()
        let task = Task { for try await change in stream { if case .snapshot = change { return } } }
        try await task.value
        #expect(await recorder.waitFor(.connected, after: 1))
        await first.drop()
        let dropIndex = await recorder.states.count
        #expect(await recorder.waitFor(.degraded, after: dropIndex))
        let before = await recorder.states.count
        try await provider.connect()
        try await Task.sleep(for: .milliseconds(100))
        let after = await recorder.states.dropFirst(before)
        #expect(!after.contains(.connected), "states after connect: \(Array(after))")
        _ = stream
    }

    /// Closing the last view during an outage must not turn the interruption into "connected".
    @Test func lastSubscriberLeavingDuringAnOutageDoesNotReportConnected() async throws {
        let first = HAIdleTransport()
        let attempts = AttemptCounter()
        let provider = HomeAssistantProvider(config: HAConfig(baseURL: URL(string: "https://ha.invalid")!), token: "fixture-token",
            http: MockHTTP { _, _, _ in (Data(#"{"message":"API running."}"#.utf8), 200) },
            makeTransport: { await attempts.next() == 1 ? first as any RealtimeTransport : UnreachableTransport() })
        let recorder = StateRecorder(await provider.connectionEvents())
        try await provider.connect()
        let subscribe = try #require(try await provider.capabilities(for: "switch.first").subscribe)
        let stream = await subscribe.stateChanges()
        let snapshots = AttemptCounter()
        let listener = Task { for try await change in stream { if case .snapshot = change { _ = await snapshots.next() } } }
        #expect(await recorder.waitFor(.connected, after: 1))
        await first.drop()
        let dropIndex = await recorder.states.count
        #expect(await recorder.waitFor(.degraded, after: dropIndex))
        let before = await recorder.states.count
        listener.cancel()   // the last view closes during the outage
        await Self.expectNoConnected(recorder, after: before)
    }

    private static func expectNoConnected(_ recorder: StateRecorder, after index: Int) async {
        try? await Task.sleep(for: .milliseconds(300))
        let after = await recorder.states.dropFirst(index)
        #expect(!after.contains(.connected), "states after the last subscriber left: \(Array(after))")
    }

    /// While the live stream is still synchronising for the first time, REST alone must not report connected.
    @Test func connectDuringTheFirstHandshakeDoesNotReportConnected() async throws {
        let transport = HeldHandshakeTransport()
        let provider = HomeAssistantProvider(config: HAConfig(baseURL: URL(string: "https://ha.invalid")!), token: "fixture-token",
            http: MockHTTP { _, _, _ in (Data(#"{"message":"API running."}"#.utf8), 200) }, makeTransport: { transport })
        let recorder = StateRecorder(await provider.connectionEvents())
        let subscribe = try #require(try await provider.capabilities(for: "switch.first").subscribe)
        let stream = await subscribe.stateChanges()
        #expect(await recorder.waitFor(.connecting, after: 0))
        try await provider.connect()
        try await Task.sleep(for: .milliseconds(100))
        let states = await recorder.states
        #expect(!states.contains(.connected), "states: \(states)")
        _ = stream
    }

    /// A configuration that cannot produce a live-updates URL must refuse the listener, not leave it silent.
    @Test func aListenerWithoutAUsableStreamAddressIsRefused() async throws {
        let provider = HomeAssistantProvider(config: HAConfig(baseURL: URL(string: "http://203.0.113.5:8123")!), token: "fixture")
        let subscribe = try #require(try await provider.capabilities(for: "switch.first").subscribe)
        let stream = await subscribe.stateChanges()
        let outcome = Task { () -> Bool in
            do { for try await _ in stream {}; return false } catch { return true }
        }
        let timeout = Task { try await Task.sleep(for: .seconds(2)); outcome.cancel() }
        #expect(await outcome.value, "the listener was left open without a stream")
        timeout.cancel()
    }

    /// A disconnect requested while connect() is verifying must win.
    @Test func disconnectDuringConnectIsNotOverriddenByALateConnected() async throws {
        let http = GatedVerifyHTTP()
        let provider = HomeAssistantProvider(config: HAConfig(baseURL: URL(string: "https://ha.invalid")!), token: "fixture", http: http)
        let recorder = StateRecorder(await provider.connectionEvents())
        let connecting = Task { try await provider.connect() }
        await http.waitUntilVerifyEntered()
        await provider.disconnect()
        await http.releaseVerify()
        _ = try? await connecting.value
        try await Task.sleep(for: .milliseconds(100))
        let states = await recorder.states
        #expect(states.last == .disconnected, "states: \(states)")
    }

    /// A disconnect landing after verification, while connect() publishes and resumes, must still win.
    @Test func disconnectAfterVerificationIsNotOverriddenByConnect() async throws {
        let transport = HAIdleTransport()
        let opens = AttemptCounter()
        let provider = HomeAssistantProvider(config: HAConfig(baseURL: URL(string: "https://ha.invalid")!), token: "fixture",
            http: MockHTTP { _, _, _ in (Data(#"{"message":"API running."}"#.utf8), 200) },
            makeTransport: { _ = await opens.next(); return transport })
        let subscribe = try #require(try await provider.capabilities(for: "switch.first").subscribe)
        let stream = await subscribe.stateChanges()
        let snapshots = AttemptCounter()
        let listener = Task { for try await change in stream { if case .snapshot = change { _ = await snapshots.next() } } }
        while await snapshots.current() == 0 { try await Task.sleep(for: .milliseconds(5)) }  // socket open, listener kept
        let recorder = StateRecorder(await provider.connectionEvents())
        let latch = DisconnectLatch()
        await provider.stateSession.setBeforeRestConnected { [provider] in
            await provider.disconnect(); await latch.record(await opens.current())
        }
        try? await provider.connect()
        await provider.stateSession.setBeforeRestConnected(nil)
        let opensAtDisconnect = await latch.opens
        try await Task.sleep(for: .milliseconds(200))
        let states = await recorder.states
        #expect(states.last == .disconnected, "states: \(states)")
        #expect(await opens.current() == opensAtDisconnect, "a socket was opened after the explicit disconnect")
        listener.cancel()
    }

    /// Only an explicit disconnect may cancel connect(): a view closing meanwhile must not erase its result.
    @Test func aListenerLeavingDuringConnectDoesNotEraseTheConnection() async throws {
        let http = GatedVerifyHTTP()
        let transport = HAIdleTransport()
        let provider = HomeAssistantProvider(config: HAConfig(baseURL: URL(string: "https://ha.invalid")!), token: "fixture",
                                             http: http, makeTransport: { transport })
        let subscribe = try #require(try await provider.capabilities(for: "switch.first").subscribe)
        let stream = await subscribe.stateChanges()
        let snapshots = AttemptCounter()
        let listener = Task { for try await change in stream { if case .snapshot = change { _ = await snapshots.next() } } }
        while await snapshots.current() == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let recorder = StateRecorder(await provider.connectionEvents())
        let connecting = Task { try await provider.connect() }
        await http.waitUntilVerifyEntered()
        listener.cancel()                                   // the last view closes during verify
        #expect(await transport.waitUntilClosed())
        await http.releaseVerify()
        let outcome: Bool = (try? await connecting.value) != nil
        try await Task.sleep(for: .milliseconds(100))
        let states = await recorder.states
        #expect(outcome, "connect() failed although nothing disconnected")
        #expect(states.last == .connected, "states: \(states)")
    }

    /// After an explicit disconnect, a new subscription must not silently re-authenticate a socket.
    @Test func subscribingAfterAnExplicitDisconnectDoesNotReopenAnAuthenticatedSocket() async throws {
        let transport = HAIdleTransport()
        let opens = AttemptCounter()
        let provider = HomeAssistantProvider(config: HAConfig(baseURL: URL(string: "https://ha.invalid")!), token: "fixture",
            http: MockHTTP { _, _, _ in (Data(#"{"message":"API running."}"#.utf8), 200) },
            makeTransport: { _ = await opens.next(); return transport })
        try await provider.connect()
        let subscribe = try #require(try await provider.capabilities(for: "switch.first").subscribe)
        let first = await subscribe.stateChanges()
        let snapshots = AttemptCounter()
        let listener = Task { for try await change in first { if case .snapshot = change { _ = await snapshots.next() } } }
        while await snapshots.current() == 0 { try await Task.sleep(for: .milliseconds(5)) }
        await provider.disconnect()
        listener.cancel()
        let opensAtDisconnect = await opens.current()
        let second = await subscribe.stateChanges()
        var refused: (any Error)?
        do { for try await _ in second { break } } catch { refused = error }
        try await Task.sleep(for: .milliseconds(150))
        #expect(refused as? IoTError == .notConnected, "refused for the wrong reason: \(String(describing: refused))")
        #expect(await opens.current() == opensAtDisconnect, "a socket was opened after the explicit disconnect")
    }

    /// The refusal must be lifted by a reconnect, or the app would never get live updates back.
    @Test func connectingAgainAfterADisconnectRestoresSubscriptions() async throws {
        let transport = HAIdleTransport()
        let opens = AttemptCounter()
        let provider = HomeAssistantProvider(config: HAConfig(baseURL: URL(string: "https://ha.invalid")!), token: "fixture",
            http: MockHTTP { _, _, _ in (Data(#"{"message":"API running."}"#.utf8), 200) },
            makeTransport: { _ = await opens.next(); return transport })
        try await provider.connect()
        let subscribe = try #require(try await provider.capabilities(for: "switch.first").subscribe)
        try await Self.firstSnapshot(await subscribe.stateChanges())
        await provider.disconnect()
        let opensAtDisconnect = await opens.current()
        try await provider.connect()
        try await Self.firstSnapshot(await subscribe.stateChanges())
        #expect(await opens.current() == opensAtDisconnect + 1, "the reconnect did not open exactly one socket")
    }

    /// Closing the last view is not a disconnect: a later subscription must still work without connect().
    @Test func closingTheLastViewDoesNotBlockLaterSubscriptions() async throws {
        let transport = HAIdleTransport()
        let provider = HomeAssistantProvider(config: HAConfig(baseURL: URL(string: "https://ha.invalid")!), token: "fixture",
            http: MockHTTP { _, _, _ in (Data(#"{"message":"API running."}"#.utf8), 200) },
            makeTransport: { transport })
        let subscribe = try #require(try await provider.capabilities(for: "switch.first").subscribe)
        try await Self.firstSnapshot(await subscribe.stateChanges())   // the stream ends here, last view closed
        #expect(await transport.waitUntilClosed())
        try await Self.firstSnapshot(await subscribe.stateChanges())   // never connected explicitly
    }

    /// Consumes a stream until its first snapshot, then lets it end.
    private static func firstSnapshot(_ stream: AsyncThrowingStream<DeviceStateChange, any Error>) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { for try await change in stream { if case .snapshot = change { return } } }
            group.addTask { try await Task.sleep(for: .seconds(3)); throw IoTError.timeout }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private static func provider(_ transport: HAIdleTransport) -> HomeAssistantProvider {
        HomeAssistantProvider(config: HAConfig(baseURL: URL(string: "https://ha.invalid")!), token: "fixture-token",
            http: MockHTTP { _, _, _ in (Data(#"{"message":"API running."}"#.utf8), 200) }, makeTransport: { transport })
    }
}

private actor StateRecorder {
    private(set) var states: [ProviderConnectionState] = []
    private var task: Task<Void, Never>?
    init(_ stream: AsyncStream<ProviderConnectionEvent>) {
        task = nil
        Task { await self.start(stream) }
    }
    private func start(_ stream: AsyncStream<ProviderConnectionEvent>) {
        task = Task { for await event in stream { self.append(event.state) } }
    }
    private func append(_ state: ProviderConnectionState) { states.append(state) }
    /// Whether `state` was recorded at an index of at least `after` within two seconds.
    func waitFor(_ state: ProviderConnectionState, after index: Int) async -> Bool {
        for _ in 0..<40 {
            if states.dropFirst(index).contains(state) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}

private actor HAIdleTransport: RealtimeTransport {
    private(set) var closed = false
    private var queue: [Data] = []
    private var waiting: CheckedContinuation<Data, any Error>?
    func open() async throws { closed = false; deliver(#"{"type":"auth_required"}"#) }
    func send(_ data: Data) async throws {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        switch object?["type"] as? String {
        case "auth": deliver(#"{"type":"auth_ok"}"#)
        case "subscribe_events": deliver(#"{"type":"result","id":1,"success":true,"result":null}"#)
        case "get_states": deliver(#"{"type":"result","id":2,"success":true,"result":[{"entity_id":"switch.first","state":"on","attributes":{}}]}"#)
        case "ping": deliver(#"{"type":"pong","id":999}"#)
        default: throw IoTError.invalidResponse
        }
    }
    func receive() async throws -> Data {
        if closed { throw IoTError.cancelled }
        if !queue.isEmpty { return queue.removeFirst() }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func close() async {
        closed = true
        let pending = waiting; waiting = nil
        pending?.resume(throwing: IoTError.cancelled)
    }
    /// Server-side loss: the pending receive fails and later receives fail too.
    func drop() {
        closed = true
        let pending = waiting; waiting = nil
        pending?.resume(throwing: IoTError.transport("fixture drop"))
    }
    func waitUntilClosed() async -> Bool {
        for _ in 0..<40 { if closed { return true }; try? await Task.sleep(for: .milliseconds(50)) }
        return false
    }
    private func deliver(_ json: String) {
        let data = Data(json.utf8)
        if let pending = waiting { waiting = nil; pending.resume(returning: data) } else { queue.append(data) }
    }
}

private actor AttemptCounter {
    private var count = 0
    func next() -> Int { count += 1; return count }
    func current() -> Int { count }
}

private struct UnreachableTransport: RealtimeTransport {
    func open() async throws { throw IoTError.timeout }
    func send(_ data: Data) async throws { throw IoTError.notConnected }
    func receive() async throws -> Data { throw IoTError.notConnected }
    func close() async {}
}

/// Opens, but never sends `auth_required`: the stream stays in its first handshake.
private actor HeldHandshakeTransport: RealtimeTransport {
    private var waiting: CheckedContinuation<Data, any Error>?
    func open() async throws {}
    func send(_ data: Data) async throws {}
    func receive() async throws -> Data { try await withCheckedThrowingContinuation { waiting = $0 } }
    func close() async {
        let pending = waiting; waiting = nil
        pending?.resume(throwing: IoTError.cancelled)
    }
}

private actor GatedVerifyHTTP: HAHTTP {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func send(method: String, path: String, body: Data?) async throws -> (Data, Int) {
        entered = true; waiter?.resume(); waiter = nil
        await withCheckedContinuation { release = $0 }
        return (Data(#"{"message":"API running."}"#.utf8), 200)
    }
    func waitUntilVerifyEntered() async { if entered { return }; await withCheckedContinuation { waiter = $0 } }
    func releaseVerify() { release?.resume(); release = nil }
}

private actor DisconnectLatch {
    private(set) var opens: Int?
    func record(_ count: Int) { opens = count }
}
