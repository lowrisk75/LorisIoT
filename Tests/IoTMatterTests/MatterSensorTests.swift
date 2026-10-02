import Foundation
import Testing
import IoTCore
@testable import IoTMatter

struct MatterSensorTests {
    @Test func nullIsUnknownAndIntegerUnitsAreConvertedExactly() throws {
        #expect(try MatterMeasurement.temperature.decode(.integer(-1234)) == -12.34)
        #expect(try MatterMeasurement.humidity.decode(.integer(4567)) == 45.67)
        #expect(try MatterMeasurement.temperature.decode(.null) == nil)
        #expect(try MatterMeasurement.humidity.decode(.null) == nil)
        #expect(throws: IoTError.invalidResponse) { try MatterMeasurement.humidity.decode(.integer(10001)) }
        #expect(throws: IoTError.invalidResponse) { try MatterMeasurement.temperature.decode(.integer(-32768)) }
    }
    @Test func identitiesIncludeFabricNodeAndEndpointAndRefuseReservedEndpoints() throws {
        let a = try MatterSensorConfiguration(nodeID: 1, endpointID: 1, name: "Room")
        let b = try MatterSensorConfiguration(nodeID: 1, endpointID: 2, name: "Room")
        #expect(a.deviceID(fabric: UUID()) != a.deviceID(fabric: UUID()))
        let fabric = UUID(); #expect(a.deviceID(fabric: fabric) != b.deviceID(fabric: fabric))
        #expect(throws: IoTError.notConfigured) { try MatterSensorConfiguration(nodeID: 0, endpointID: 1, name: "Room") }
        #expect(throws: IoTError.notConfigured) { try MatterSensorConfiguration(nodeID: 1, endpointID: .max, name: "Room") }
    }
    @Test func sensorHasNoControlOrAutonomousScheduleAndDisconnectDoesNotRefreshCache() async throws {
        let clock = MatterTestClock()
        let transport = MatterFixture()
        let provider = MatterProvider(transport: transport, maxStateAge: 60, now: { clock.value })
        try await provider.connect()
        let devices = try await provider.devices()
        #expect(devices.count == 1)
        let caps = try await provider.capabilities(for: "sensor")
        #expect(caps.control == nil && caps.schedule == nil)
        #expect(caps.readState != nil && caps.subscribe != nil)
        let state = try await provider.cachedState(for: "sensor")
        #expect(state.primaryValue == .decimal(21.34))
        #expect(state.primaryUnit == .celsius)
        #expect(state.attributes["humidity"]?.value == .decimal(50))
        clock.advance(61)
        #expect(try await provider.cachedState(for: "sensor").freshness(at: clock.value) == .stale)
        await provider.disconnect()
        let offline = try await provider.cachedState(for: "sensor")
        #expect(offline.availability == .offline)
        #expect(offline.receivedAt == state.receivedAt)
        await #expect(throws: IoTError.notConnected) { try await provider.refresh("sensor") }
    }
    @Test func malformedAndIncompleteFreshReadsFailInsteadOfInventingValues() async throws {
        for values: [MatterMeasurement: MatterRawValue] in [[:], [.temperature: .integer(2100)], [.temperature: .integer(2100), .humidity: .integer(11000)]] {
            let fixture = MatterFixture(values: values)
            let provider = MatterProvider(transport: fixture)
            await #expect(throws: IoTError.invalidResponse) { try await provider.connect() }
            #expect(await fixture.disconnections == 1)
        }
    }
    @Test func lateRepliesCannotReconnectAnOldGeneration() async throws {
        let fixture = MatterFixture()
        let provider = MatterProvider(transport: fixture)
        try await provider.connect()
        await fixture.pause()
        let first = Task { try await provider.refresh("sensor") }
        while await fixture.reads < 2 { await Task.yield() }
        await provider.disconnect()
        await fixture.resume()
        do { _ = try await first.value; Issue.record("A late read must not reconnect") } catch {}
        #expect(try await provider.cachedState(for: "sensor").availability == .offline)
    }
    @Test func olderReadCannotOverwriteAReportReceivedWhileItWasInFlight() async throws {
        let fixture = MatterFixture(); let provider = MatterProvider(transport: fixture)
        try await provider.connect()
        let capability = try #require(try await provider.capabilities(for: "sensor").subscribe)
        var iterator = await capability.stateChanges().makeAsyncIterator()
        _ = try await iterator.next()
        await fixture.pause()
        let read = Task { try await provider.refresh("sensor") }
        while await fixture.reads < 2 { await Task.yield() }
        await fixture.send(.values(deviceID: "sensor", values: [.temperature: .integer(3000)], cached: false))
        _ = try await iterator.next()
        await fixture.resume()
        #expect(try await read.value.primaryValue == .decimal(30))
        await provider.disconnect()
    }
    @Test func freshReadsRestoreConnectionHealthAfterAReportedFailure() async throws {
        let fixture = MatterFixture(); let provider = MatterProvider(transport: fixture)
        try await provider.connect()
        var events = await provider.connectionEvents().makeAsyncIterator()
        #expect(await events.next()?.state == .connected)
        await fixture.send(.unavailable(deviceID: "sensor"))
        #expect(await events.next()?.state == .degraded)
        _ = try await provider.refresh("sensor")
        #expect(await events.next()?.state == .connected)
        await provider.disconnect()
    }
    @Test func subscriptionSharesTransportAndCachedPrimingDoesNotRenewFreshness() async throws {
        let clock = MatterTestClock(); let fixture = MatterFixture()
        let provider = MatterProvider(transport: fixture, now: { clock.value })
        try await provider.connect()
        let capability = try #require(try await provider.capabilities(for: "sensor").subscribe)
        let stream = await capability.stateChanges(); var iterator = stream.makeAsyncIterator()
        guard case .snapshot(let first) = try await iterator.next() else { Issue.record("Missing snapshot"); return }
        clock.advance(20)
        await fixture.send(.values(deviceID: "sensor", values: [.temperature: .integer(3000)], cached: true))
        await fixture.send(.values(deviceID: "sensor", values: [.humidity: .integer(6000)], cached: false))
        guard case .updated(_, let update) = try await iterator.next() else { Issue.record("Missing update"); return }
        #expect(update.primaryValue == first.primaryValue)
        #expect(update.receivedAt == first.receivedAt)
        #expect(update.attributes["humidity"]?.value == .decimal(60))
        #expect(await fixture.connections == 1)
        await provider.disconnect()
    }
}

private final class MatterTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 2_000_000_000)
    var value: Date { lock.withLock { date } }
    func advance(_ seconds: Double) { lock.withLock { date.addTimeInterval(seconds) } }
}
actor MatterFixture: MatterSensorTransport {
    var connections = 0; var disconnections = 0; var reads = 0
    let values: [MatterMeasurement: MatterRawValue]
    var waiter: CheckedContinuation<Void, Never>?
    var paused = false
    let channel = AsyncStream<MatterReport>.makeStream(bufferingPolicy: .bufferingNewest(32))
    init(values: [MatterMeasurement: MatterRawValue] = [.temperature: .integer(2134), .humidity: .integer(5000)]) { self.values = values }
    func connect() { connections += 1 }
    func disconnect() { disconnections += 1 }
    func sensors() -> [MatterSensorDescription] { [.init(id: "sensor", name: "Room", measurements: [.temperature, .humidity])] }
    func read(_ id: DeviceID) async -> [MatterMeasurement: MatterRawValue] {
        reads += 1
        if paused { await withCheckedContinuation { waiter = $0 } }
        return values
    }
    func reports() -> AsyncStream<MatterReport> { channel.stream }
    func pause() { paused = true }
    func resume() { paused = false; waiter?.resume(); waiter = nil }
    func send(_ report: MatterReport) { channel.continuation.yield(report) }
}
