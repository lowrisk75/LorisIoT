import Foundation
import Testing
import IoTCore
@testable import IoTHomeAssistant

@Suite struct HASharedSessionTests {
    @Test func twoDevicesShareOneAuthenticatedSocketAndGetInitialSnapshots() async throws {
        let transport = HASequenceTransport()
        let provider = HomeAssistantProvider(config: HAConfig(baseURL: URL(string: "https://ha.invalid")!),
            token: "fixture-token", http: MockHTTP { _, _, _ in (Data(), 200) }, makeTransport: { transport })
        let first = try #require(try await provider.capabilities(for: "switch.first").subscribe)
        let second = try #require(try await provider.capabilities(for: "sensor.temperature").subscribe)
        let stream1 = await first.stateChanges()
        let stream2 = await second.stateChanges()
        let snapshot1 = try await firstSnapshot(stream1)
        let snapshot2 = try await firstSnapshot(stream2)
        #expect(snapshot1.primaryValue == .bool(true))
        #expect(snapshot2.primaryValue == .decimal(21.5))
        #expect(await transport.opens == 1)
        #expect(await transport.subscriptions == 1)
        await provider.disconnect()
        #expect(await transport.closed)
    }

    @Test func eventsStartDisconnectedInsteadOfInventingAConnection() async throws {
        let provider = HomeAssistantProvider(config: HAConfig(baseURL: URL(string: "https://ha.invalid")!),
            token: "fixture-token", http: MockHTTP { _, _, _ in (Data(), 200) })
        var iterator = await provider.connectionEvents().makeAsyncIterator()
        #expect(await iterator.next()?.state == .disconnected)
        try await provider.connect()
        #expect(await iterator.next()?.state == .connected)
        await provider.disconnect()
        #expect(await iterator.next()?.state == .disconnected)
    }

    @Test func entityRemovalIsNotSilentlyDropped() {
        let frame = Data(#"{"type":"event","event":{"event_type":"state_changed","data":{"entity_id":"sensor.gone","new_state":null}}}"#.utf8)
        guard case .entityRemoved("sensor.gone")? = HAMessage.decode(frame) else { Issue.record("missing removal"); return }
    }

    private func firstSnapshot(_ stream: AsyncThrowingStream<DeviceStateChange, any Error>) async throws -> DeviceState {
        try await withThrowingTaskGroup(of: DeviceState.self) { group in
            group.addTask {
                for try await change in stream {
                    if case .snapshot(let state) = change { return state }
                }
                throw IoTError.notConnected
            }
            group.addTask { try await Task.sleep(for: .seconds(5)); throw IoTError.timeout }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

private actor HASequenceTransport: RealtimeTransport {
    private(set) var opens = 0
    private(set) var subscriptions = 0
    private(set) var closed = false
    private var queue: [Data] = []
    private var waiting: CheckedContinuation<Data, any Error>?
    func open() async throws {
        opens += 1; closed = false
        deliver(#"{"type":"auth_required"}"#)
    }
    func send(_ data: Data) async throws {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        switch object?["type"] as? String {
        case "auth": deliver(#"{"type":"auth_ok"}"#)
        case "subscribe_events": subscriptions += 1; deliver(#"{"type":"result","id":1,"success":true,"result":null}"#)
        case "get_states": deliver(#"{"type":"result","id":2,"success":true,"result":[{"entity_id":"switch.first","state":"on","attributes":{}},{"entity_id":"sensor.temperature","state":"21.5","attributes":{}}]}"#)
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
    private func deliver(_ json: String) {
        let data = Data(json.utf8)
        if let pending = waiting { waiting = nil; pending.resume(returning: data) }
        else { queue.append(data) }
    }
}
