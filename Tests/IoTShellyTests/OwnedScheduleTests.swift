import Foundation
import Testing
import IoTCore
@testable import IoTShelly

@Suite struct ShellyOwnedScheduleTests {
    private let owner = ScheduleOwner(appID: "fixture.app", installationID: UUID())
    private func schedule(_ recurrence: ScheduleRecurrence = .daily, hour: Int = 6) -> DeviceSchedule {
        let date = ISO8601DateFormatter().date(from: "2026-10-20T04:42:09Z")!.addingTimeInterval(Double(hour - 6) * 3600)
        return DeviceSchedule(id: .init(rawValue: "wake"), deviceID: "plug", command: .setPower(true),
                              start: date, recurrence: recurrence, isEnabled: true, timeZoneIdentifier: "Europe/Paris")
    }
    @Test func compilerPreservesWeekdaysSecondsAndRejectsUnqualifiedOnce() throws {
        let zone = TimeZone(identifier: "Europe/Paris")!
        #expect(try ShellyScheduleCompiler.timespec(for: schedule(.weekly([.monday, .sunday])), deviceTimeZone: zone)
                == "9 42 6 * * MON,SUN")
        #expect(throws: (any Error).self) {
            try ShellyScheduleCompiler.timespec(for: schedule(.once), deviceTimeZone: zone)
        }
        #expect(throws: (any Error).self) {
            try ShellyScheduleCompiler.timespec(for: schedule(.weekly([])), deviceTimeZone: zone)
        }
    }
    @Test func ownsOnlyItsJournalAndSurvivesRecreation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lorisiot-store-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let rpc = ScheduleFixture()
        func capability(_ store: any ScheduleStore, owner: ScheduleOwner) -> ShellyOwnedSchedules {
            ShellyOwnedSchedules(client: ShellyClient(host: "fixture", rpc: rpc), deviceID: "plug",
                                 switchID: 0, owner: owner, store: store)
        }
        let first = capability(FileScheduleStore(url: url), owner: owner)
        _ = try await first.upsert(schedule())
        let recreated = capability(FileScheduleStore(url: url), owner: owner)
        #expect(try await recreated.schedules() == [schedule()])
        _ = try await recreated.upsert(schedule())
        #expect(await rpc.creates == 1)
        let stranger = capability(FileScheduleStore(url: url), owner: ScheduleOwner(appID: "other.app", installationID: UUID()))
        try await stranger.removeSchedule(id: schedule().id)
        #expect(await rpc.deletes == 0)
        try await recreated.removeSchedule(id: schedule().id)
        #expect(await rpc.deletes == 1)
        #expect(try await recreated.schedules().isEmpty)
    }
    // A Shelly relay has no ramp. A transition must be refused before any device mutation.
    @Test func rejectsATransitionItCannotPerformBeforeAnyMutation() async throws {
        let rpc = ScheduleFixture()
        let cap = ShellyOwnedSchedules(client: ShellyClient(host: "fixture", rpc: rpc), deviceID: "plug",
                                      switchID: 0, owner: owner, store: MemoryScheduleStore())
        let base = schedule()
        let ramp = DeviceSchedule(id: base.id, deviceID: base.deviceID, command: base.command,
                                  start: base.start, recurrence: base.recurrence, isEnabled: base.isEnabled,
                                  timeZoneIdentifier: base.timeZoneIdentifier, transition: 1200)
        await #expect(throws: (any Error).self) { try await cap.upsert(ramp) }
        #expect(await rpc.creates == 0)
    }
    @Test func lostUpdateResponseReconcilesWithoutDuplicateCreation() async throws {
        let rpc = ScheduleFixture()
        let cap = ShellyOwnedSchedules(client: ShellyClient(host: "fixture", rpc: rpc), deviceID: "plug",
                                      switchID: 0, owner: owner, store: MemoryScheduleStore())
        _ = try await cap.upsert(schedule())
        await rpc.loseNextUpdate()
        await #expect(throws: IoTError.timeout) { try await cap.upsert(schedule(hour: 7)) }
        _ = try await cap.upsert(schedule(hour: 7))
        #expect(await rpc.creates == 1)
        #expect(await rpc.updates == 1)
    }
    @Test func corruptJournalIsNotSilentlyReinitialized() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lorisiot-corrupt-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("corrupt".utf8).write(to: url)
        let store = FileScheduleStore(url: url)
        await #expect(throws: (any Error).self) {
            try await store.save(ScheduleReceipt(owner: owner, providerID: "shelly", schedule: schedule(), verification: .pending))
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "corrupt")
    }

    @Test func retryPreservesTheActualRemoteBaselineAfterRepeatedFailedUpdates() async throws {
        let rpc = ScheduleFixture()
        let cap = ShellyOwnedSchedules(client: ShellyClient(host: "fixture", rpc: rpc), deviceID: "plug",
            switchID: 0, owner: owner, store: MemoryScheduleStore())
        _ = try await cap.upsert(schedule())
        await rpc.failBeforeNextUpdate()
        await #expect(throws: IoTError.timeout) { try await cap.upsert(schedule(hour: 7)) }
        await rpc.failBeforeNextUpdate()
        await #expect(throws: IoTError.timeout) { try await cap.upsert(schedule(hour: 8)) }
        _ = try await cap.upsert(schedule(hour: 8))
        #expect(try await cap.schedules() == [schedule(hour: 8)])
        #expect(await rpc.creates == 1)
    }

    @Test func retryingFailedCancellationPreservesThePreviousRemoteSchedule() async throws {
        let rpc = ScheduleFixture(), store = MemoryScheduleStore()
        func capability() -> ShellyOwnedSchedules {
            ShellyOwnedSchedules(client: ShellyClient(host: "fixture", rpc: rpc), deviceID: "plug",
                switchID: 0, owner: owner, store: store)
        }
        _ = try await capability().upsert(schedule())
        await rpc.failBeforeNextUpdate()
        await #expect(throws: IoTError.timeout) { try await capability().upsert(schedule(hour: 7)) }
        await rpc.failBeforeNextDelete()
        await #expect(throws: IoTError.timeout) { try await capability().removeSchedule(id: schedule().id) }
        try await capability().removeSchedule(id: schedule().id)
        #expect(await rpc.deletes == 1)
        #expect(await store.receipts(owner: owner, providerID: "shelly", deviceID: "plug").isEmpty)
    }

    // A relay has no brightness. Refusing it must cost the household device nothing: no clock
    // probe, no timezone read, no round trip of any kind before the refusal.
    @Test func rejectsALevelItCannotPerformBeforeAnyRoundTrip() async throws {
        let rpc = ScheduleFixture()
        let cap = ShellyOwnedSchedules(client: ShellyClient(host: "fixture", rpc: rpc), deviceID: "plug",
                                      switchID: 0, owner: owner, store: MemoryScheduleStore())
        let base = schedule()
        let level = DeviceSchedule(id: base.id, deviceID: base.deviceID,
                                   command: .setLevel(try UnitInterval(0.5)), start: base.start,
                                   recurrence: base.recurrence, isEnabled: base.isEnabled,
                                   timeZoneIdentifier: base.timeZoneIdentifier)
        await #expect(throws: (any Error).self) { try await cap.upsert(level) }
        #expect(await rpc.calls == 0)
    }

    @Test func fractionalSecondsAreNeverRoundedSilently() throws {
        let precise = DeviceSchedule(id: .init(rawValue: "precise"), deviceID: "plug", command: .setPower(true),
            start: schedule().start.addingTimeInterval(0.5), recurrence: .daily, isEnabled: true)
        #expect(throws: (any Error).self) {
            try ShellyScheduleCompiler.timespec(for: precise, deviceTimeZone: .gmt)
        }
    }
}

private actor ScheduleFixture: ShellyRPC {
    private var job: [String: any Sendable]?
    private var failUpdate = false
    private var failBeforeUpdate = false
    private var failBeforeDelete = false
    private(set) var calls = 0
    private(set) var creates = 0
    private(set) var updates = 0
    private(set) var deletes = 0
    func loseNextUpdate() { failUpdate = true }
    func failBeforeNextUpdate() { failBeforeUpdate = true }
    func failBeforeNextDelete() { failBeforeDelete = true }
    func call(host: String, password: String?, method: String, params: [String: any Sendable]) async throws -> [String: any Sendable] {
        calls += 1
        switch method {
        case "Sys.GetStatus": return ["unixtime": Date().timeIntervalSince1970]
        case "Sys.GetConfig": return ["location": ["tz": "Europe/Paris"] as [String: any Sendable]]
        case "Schedule.List":
            let jobs: [[String: any Sendable]] = job.map { [$0] } ?? []
            return ["jobs": jobs]
        case "Schedule.Create":
            creates += 1; job = params; job?["id"] = 2; return ["id": 2]
        case "Schedule.Update":
            if failBeforeUpdate { failBeforeUpdate = false; throw IoTError.timeout }
            updates += 1; job = params
            if failUpdate { failUpdate = false; throw IoTError.timeout }
            return [:]
        case "Schedule.Delete":
            if failBeforeDelete { failBeforeDelete = false; throw IoTError.timeout }
            deletes += 1; job = nil; return [:]
        default: throw IoTError.notSupported(method)
        }
    }
}
