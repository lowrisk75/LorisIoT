import Foundation
import Testing
import IoTCore
@testable import IoTHomeKit

@Suite struct HomeKitOwnedTimerTests {
    let owner = ScheduleOwner(appID: "fixture.app", installationID: UUID())
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    func schedule(recurrence: ScheduleRecurrence = .once, offset: Double = 0, enabled: Bool = true) -> DeviceSchedule {
        .init(id: .init(rawValue: "wake"), deviceID: "fixture-device", command: .setPower(true),
              start: date.addingTimeInterval(offset), recurrence: recurrence, isEnabled: enabled)
    }
    // A transition is performed by the device's own ramp. HomeKit exposes no transition time, so a
    // schedule carrying one must be refused, never armed with the ramp silently dropped.
    @Test func rejectsATransitionItCannotPerformBeforeAnyMutation() async throws {
        let transport = TimerFixture()
        let cap = HomeKitOwnedSchedules(transport: transport, deviceID: "fixture-device", owner: owner,
            store: MemoryScheduleStore(), now: { .distantPast })
        let ramp = DeviceSchedule(id: .init(rawValue: "wake"), deviceID: "fixture-device",
                                  command: .setPower(true), start: date, recurrence: .once,
                                  isEnabled: true, transition: 1200)
        await #expect(throws: (any Error).self) { try await cap.upsert(ramp) }
        #expect(await transport.creates == 0)
    }
    @Test func rejectsRoundingAndRecurrenceBeforeAnyMutation() async throws {
        let transport = TimerFixture()
        let cap = HomeKitOwnedSchedules(transport: transport, deviceID: "fixture-device", owner: owner,
            store: MemoryScheduleStore(), now: { .distantPast })
        for invalid in [schedule(offset: 1), schedule(recurrence: .daily), schedule(recurrence: .weekly([.monday]))] {
            await #expect(throws: (any Error).self) { try await cap.upsert(invalid) }
        }
        #expect(await transport.creates == 0)
    }
    @Test func disabledTimerIsOwnedAcrossRecreationAndOtherAppsCannotDeleteIt() async throws {
        let transport = TimerFixture(); let store = MemoryScheduleStore()
        func cap(_ owner: ScheduleOwner) -> HomeKitOwnedSchedules {
            HomeKitOwnedSchedules(transport: transport, deviceID: "fixture-device", owner: owner,
                                  store: store, now: { .distantPast })
        }
        let desired = schedule(enabled: false)
        _ = try await cap(owner).upsert(desired)
        #expect(try await cap(owner).schedules() == [desired])
        try await cap(.init(appID: "another.app", installationID: UUID())).removeSchedule(id: desired.id)
        #expect(await transport.deletes == 0)
        try await cap(owner).removeSchedule(id: desired.id)
        #expect(await transport.deletes == 1)
    }
    @Test func lostCreationResponseReconcilesWithoutDuplicate() async throws {
        let transport = TimerFixture(); let store = MemoryScheduleStore()
        let cap = HomeKitOwnedSchedules(transport: transport, deviceID: "fixture-device", owner: owner,
                                       store: store, now: { .distantPast })
        await transport.loseNextResponse()
        await #expect(throws: IoTError.timeout) { try await cap.upsert(schedule()) }
        _ = try await cap.upsert(schedule())
        #expect(await transport.creates == 1)
    }

    @Test func twoCapabilityInstancesCannotCreateTheSameOwnedTimerTwice() async throws {
        let transport = TimerFixture(), store = DelayedScheduleFixture()
        let desired = schedule()
        let first = HomeKitOwnedSchedules(transport: transport, deviceID: desired.deviceID,
            owner: owner, store: store, now: { .distantPast })
        let second = HomeKitOwnedSchedules(transport: transport, deviceID: desired.deviceID,
            owner: owner, store: store, now: { .distantPast })
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await first.upsert(desired) }
            group.addTask { _ = try? await second.upsert(desired) }
        }
        #expect(await transport.creates == 1)
    }
}

private actor DelayedScheduleFixture: ScheduleStore {
    private let memory = MemoryScheduleStore()
    private var leased = false
    func receipts(owner: ScheduleOwner, providerID: ProviderID, deviceID: DeviceID) async throws -> [ScheduleReceipt] {
        let snapshot = await memory.receipts(owner: owner, providerID: providerID, deviceID: deviceID)
        try await Task.sleep(for: .milliseconds(40))
        return snapshot
    }
    func save(_ receipt: ScheduleReceipt) async { await memory.save(receipt) }
    func remove(_ receipt: ScheduleReceipt) async { await memory.remove(receipt) }
    func withExclusiveOperation<T: Sendable>(owner: ScheduleOwner, providerID: ProviderID, deviceID: DeviceID,
                                           operation: @Sendable () async throws -> T) async throws -> T {
        guard !leased else { throw IoTError.unconfirmed }
        leased = true; defer { leased = false }
        return try await operation()
    }
}

private actor TimerFixture: HomeKitTimerTransport {
    private var timers: [String: DeviceSchedule] = [:]
    private var loseResponse = false
    private(set) var creates = 0
    private(set) var deletes = 0
    func loseNextResponse() { loseResponse = true }
    func createTimer(_ schedule: DeviceSchedule, name: String) throws {
        creates += 1; timers[name] = schedule
        if loseResponse { loseResponse = false; throw IoTError.timeout }
    }
    func timerMatches(_ schedule: DeviceSchedule, name: String) -> Bool { timers[name] == schedule }
    func removeTimer(_ schedule: DeviceSchedule, name: String) throws {
        guard timers[name] == schedule else { throw IoTError.unconfirmed }
        deletes += 1; timers[name] = nil
    }
}
