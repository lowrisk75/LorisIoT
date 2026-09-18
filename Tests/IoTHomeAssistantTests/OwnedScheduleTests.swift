import Foundation
import Testing
import IoTCore
@testable import IoTHomeAssistant

@Suite struct HAOwnedScheduleTests {
    let owner = ScheduleOwner(appID: "fixture.app", installationID: UUID())
    let now = Date()
    func schedule(recurrence: ScheduleRecurrence = .once, device: DeviceID = "switch.fixture") -> DeviceSchedule {
        .init(id: .init(rawValue: "wake"), deviceID: device, command: .setPower(true),
              start: now.addingTimeInterval(120), recurrence: recurrence, isEnabled: true)
    }
    private func capability(_ http: HAScheduleFixture, store: any ScheduleStore, owner: ScheduleOwner? = nil) -> HAOwnedSchedules {
        HAOwnedSchedules(http: http, deviceID: "switch.fixture", providerID: "fixture-ha",
            configuration: .init(owner: owner ?? self.owner, store: store), now: { now })
    }
    @Test func schedulingRequiresAnExplicitQualifiedTargetAndSharesItsProbe() async throws {
        let http = HAScheduleFixture(now: now)
        let provider = HomeAssistantProvider(config: .init(baseURL: URL(string: "https://fixture.invalid")!), token: "fixture",
            http: http, scheduling: .init(owner: owner, store: MemoryScheduleStore()))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    let capabilities = try await provider.capabilities(for: "switch.fixture")
                    #expect(capabilities.schedule != nil)
                }
            }
            try await group.waitForAll()
        }
        #expect(try await provider.capabilities(for: "switch.unapproved").schedule == nil)
        #expect(try await provider.capabilities(for: "sensor.fixture").schedule == nil)
        #expect(await http.healthCalls == 1)
    }
    @Test func ownedScheduleSurvivesRecreationAndAnotherOwnerCannotRemoveIt() async throws {
        let http = HAScheduleFixture(now: now), store = MemoryScheduleStore()
        let desired = schedule()
        #expect(try await capability(http, store: store).upsert(desired) == desired)
        #expect(try await capability(http, store: store).schedules() == [desired])
        try await capability(http, store: store, owner: .init(appID: "another.app", installationID: UUID())).removeSchedule(id: desired.id)
        #expect(await http.deletes == 0)
    }
    @Test func lostCreateResponseUsesTheExistingNonceWithoutAnotherWrite() async throws {
        let http = HAScheduleFixture(now: now), store = MemoryScheduleStore()
        await http.loseCreateResponse()
        await #expect(throws: IoTError.timeout) { try await capability(http, store: store).upsert(schedule()) }
        #expect(try await capability(http, store: store).upsert(schedule()) == schedule())
        #expect(await http.posts == 1)
    }
    @Test func changedRemoteTargetPreventsDeletion() async throws {
        let http = HAScheduleFixture(now: now), store = MemoryScheduleStore()
        let cap = capability(http, store: store)
        _ = try await cap.upsert(schedule())
        try await http.changeRecord(key: "deviceID", value: "switch.another")
        await #expect(throws: IoTError.unconfirmed) { try await cap.removeSchedule(id: schedule().id) }
        #expect(await http.deletes == 0)
    }
    @Test func lostCancellationResponseReconcilesWithoutAnotherDelete() async throws {
        let http = HAScheduleFixture(now: now), store = MemoryScheduleStore()
        let cap = capability(http, store: store)
        _ = try await cap.upsert(schedule())
        await http.loseDeleteResponse()
        await #expect(throws: IoTError.timeout) { try await cap.removeSchedule(id: schedule().id) }
        try await cap.removeSchedule(id: schedule().id)
        #expect(await http.deletes == 1)
        #expect(try await cap.schedules().isEmpty)
    }
    @Test func changedCancellationReceiptCannotEraseTheLocalOwnershipJournal() async throws {
        let http = HAScheduleFixture(now: now), store = MemoryScheduleStore()
        let cap = capability(http, store: store)
        _ = try await cap.upsert(schedule())
        await http.tamperAfterDelete()
        await #expect(throws: IoTError.unconfirmed) { try await cap.removeSchedule(id: schedule().id) }
        #expect(await store.receipts(owner: owner, providerID: "fixture-ha", deviceID: "switch.fixture").count == 1)
    }
    @Test func executionInProgressCannotBeReportedAsCancelled() async throws {
        let http = HAScheduleFixture(now: now), store = MemoryScheduleStore()
        let cap = capability(http, store: store)
        _ = try await cap.upsert(schedule())
        try await http.changeRecord(key: "state", value: "executing")
        await #expect(throws: IoTError.unconfirmed) { try await cap.removeSchedule(id: schedule().id) }
        #expect(await store.receipts(owner: owner, providerID: "fixture-ha", deviceID: "switch.fixture").count == 1)
    }
    @Test func unsupportedRecurrenceAndWrongTargetNeverWrite() async throws {
        let http = HAScheduleFixture(now: now), store = MemoryScheduleStore()
        for invalid in [schedule(recurrence: .daily), schedule(device: "switch.another")] {
            await #expect(throws: (any Error).self) { try await capability(http, store: store).upsert(invalid) }
        }
        #expect(await http.posts == 0)
    }
    @Test func changedEndpointUsesAnotherJournalNamespace() async throws {
        let http = HAScheduleFixture(now: now), store = MemoryScheduleStore()
        for host in ["first.invalid", "second.invalid"] {
            let provider = HomeAssistantProvider(config: .init(baseURL: URL(string: "https://" + host)! ), token: "fixture", http: http,
                scheduling: .init(owner: owner, store: store))
            let cap = try #require(try await provider.capabilities(for: "switch.fixture").schedule)
            _ = try await cap.upsert(schedule())
        }
        #expect(Set(try await http.requests().map(\.providerID)).count == 2)
    }
    @Test func anUnqualifiedClockCannotArmTheServer() async throws {
        let http = HAScheduleFixture(now: now.addingTimeInterval(3600))
        await #expect(throws: (any Error).self) {
            try await capability(http, store: MemoryScheduleStore()).upsert(schedule())
        }
        #expect(await http.posts == 0)
    }
    // A luminaire owns its ramp (Zigbee/Matter Level Control transition time), so a sunrise travels
    // as one intent with a target level and a duration, never as a server-driven step sequence.
    @Test func aSunriseIsOneScheduledIntentCarryingItsOwnTransition() async throws {
        let http = HAScheduleFixture(now: now), store = MemoryScheduleStore()
        let desired = DeviceSchedule(id: .init(rawValue: "wake"), deviceID: "light.fixture",
                                     command: .setLevel(try UnitInterval(0.75)), start: now.addingTimeInterval(120),
                                     recurrence: .once, isEnabled: true, transition: 1200)
        let cap = HAOwnedSchedules(http: http, deviceID: "light.fixture", providerID: "fixture-ha",
                                   configuration: .init(owner: owner, store: store), now: { now })
        #expect(try await cap.upsert(desired) == desired)
        let sent = try #require(try await http.requests().first)
        #expect(sent.on)
        #expect(sent.level == 0.75)
        #expect(sent.transition == 1200)
    }
    @Test func aLevelIsRefusedOnATargetThatCannotRamp() async throws {
        let http = HAScheduleFixture(now: now)
        let desired = DeviceSchedule(id: .init(rawValue: "wake"), deviceID: "switch.fixture",
                                     command: .setLevel(try UnitInterval(0.5)), start: now.addingTimeInterval(120),
                                     recurrence: .once, isEnabled: true)
        await #expect(throws: (any Error).self) {
            try await capability(http, store: MemoryScheduleStore()).upsert(desired)
        }
        #expect(await http.posts == 0)
    }
    // The lease is renewed on every push, so it must not take part in the exact-readback
    // comparison. A server that shortens it can only prevent a firing, never cause one.
    @Test func aRenewedLeaseTravelsWithTheIntentWithoutBreakingReadback() async throws {
        let http = HAScheduleFixture(now: now), store = MemoryScheduleStore()
        let configuration = HASchedulingConfiguration(owner: owner, store: store, lease: 172_800)
        let cap = HAOwnedSchedules(http: http, deviceID: "switch.fixture", providerID: "fixture-ha",
                                   configuration: configuration, now: { now })
        #expect(try await cap.upsert(schedule()) == schedule())
        let sent = try #require(try await http.requests().first)
        #expect(sent.expiresAt == now.addingTimeInterval(172_800).timeIntervalSince1970)
        let later = HAOwnedSchedules(http: http, deviceID: "switch.fixture", providerID: "fixture-ha",
                                     configuration: configuration, now: { now.addingTimeInterval(60) })
        #expect(try await later.schedules() == [schedule()])
    }
    /// Dropping or extending the lease removes the bound on an intent nobody renews: it can cause a firing.
    @Test func aServerThatDropsOrExtendsTheLeaseIsNotVerified() async throws {
        for tamper in [HAScheduleFixture.LeaseTamper.drop, .extend] {
            let http = HAScheduleFixture(now: now), store = MemoryScheduleStore()
            await http.tamperLease(tamper)
            let cap = HAOwnedSchedules(http: http, deviceID: "switch.fixture", providerID: "fixture-ha",
                configuration: HASchedulingConfiguration(owner: owner, store: store, lease: 172_800), now: { now })
            await #expect(throws: (any Error).self, "\(tamper)") { _ = try await cap.upsert(schedule()) }
        }
    }
    /// Pushing the same intent again is how a live owner renews its lease: it must reach the server.
    @Test func reUpsertingTheSameScheduleRenewsTheLease() async throws {
        let http = HAScheduleFixture(now: now), store = MemoryScheduleStore()
        let configuration = HASchedulingConfiguration(owner: owner, store: store, lease: 172_800)
        _ = try await HAOwnedSchedules(http: http, deviceID: "switch.fixture", providerID: "fixture-ha",
                                       configuration: configuration, now: { now }).upsert(schedule())
        let later = now.addingTimeInterval(3)  // within the fixture server clock tolerance
        _ = try await HAOwnedSchedules(http: http, deviceID: "switch.fixture", providerID: "fixture-ha",
                                       configuration: configuration, now: { later }).upsert(schedule())
        #expect(await http.posts == 2)
        #expect(try await http.requests().first?.expiresAt == later.addingTimeInterval(172_800).timeIntervalSince1970)
    }
    /// A lease dropped by the server after verification is an unbounded intent, not an active schedule.
    @Test func aLeaseDroppedAfterVerificationIsNotReportedActive() async throws {
        let http = HAScheduleFixture(now: now), store = MemoryScheduleStore()
        let cap = HAOwnedSchedules(http: http, deviceID: "switch.fixture", providerID: "fixture-ha",
            configuration: HASchedulingConfiguration(owner: owner, store: store, lease: 172_800), now: { now })
        _ = try await cap.upsert(schedule())
        try await http.dropStoredLease()
        await #expect(throws: (any Error).self) { _ = try await cap.schedules() }
    }
    @Test func anIntentWithoutALeaseSendsNoExpiry() async throws {
        let http = HAScheduleFixture(now: now), store = MemoryScheduleStore()
        _ = try await capability(http, store: store).upsert(schedule())
        #expect(try await http.requests().first?.expiresAt == nil)
    }
    @Test func anExpiredLeaseIsATerminalOutcomeNotAnUncertainty() async throws {
        let http = HAScheduleFixture(now: now), store = MemoryScheduleStore()
        let cap = capability(http, store: store)
        _ = try await cap.upsert(schedule())
        try await http.changeRecord(key: "state", value: "expired")
        #expect(try await cap.schedules() == [])
    }
    @Test func anUnboundedTransitionCannotArmTheServer() async throws {
        let http = HAScheduleFixture(now: now), store = MemoryScheduleStore()
        let cap = HAOwnedSchedules(http: http, deviceID: "light.fixture", providerID: "fixture-ha",
                                   configuration: .init(owner: owner, store: store), now: { now })
        for transition in [-1.0, 4000.0, Double.infinity] {
            let desired = DeviceSchedule(id: .init(rawValue: "wake"), deviceID: "light.fixture",
                                         command: .setLevel(try UnitInterval(0.5)), start: now.addingTimeInterval(120),
                                         recurrence: .once, isEnabled: true, transition: transition)
            await #expect(throws: (any Error).self) { try await cap.upsert(desired) }
        }
        #expect(await http.posts == 0)
    }
}

private actor HAScheduleFixture: HAHTTP {
    let now: Date
    private var records: [String: Data] = [:]
    private var loseCreate = false, loseDelete = false
    private var tamperedDelete = false
    private(set) var healthCalls = 0, posts = 0, deletes = 0
    init(now: Date) { self.now = now }
    enum LeaseTamper { case drop, extend }
    private var leaseTamper: LeaseTamper?
    func tamperLease(_ tamper: LeaseTamper) { leaseTamper = tamper }
    func loseCreateResponse() { loseCreate = true }
    func loseDeleteResponse() { loseDelete = true }
    func tamperAfterDelete() { tamperedDelete = true }
    func requests() throws -> [HAScheduleRequest] {
        try records.values.map { try JSONDecoder().decode(HAScheduleRequest.self, from: $0) }
    }
    func dropStoredLease() throws {
        let id = try #require(records.keys.first)
        var record = try #require(JSONSerialization.jsonObject(with: records[id]!) as? [String: Any])
        record["expiresAt"] = nil
        records[id] = try JSONSerialization.data(withJSONObject: record)
    }
    func changeRecord(key: String, value: String) throws {
        let id = try #require(records.keys.first)
        var record = try #require(JSONSerialization.jsonObject(with: records[id]!) as? [String: Any])
        record[key] = value
        records[id] = try JSONSerialization.data(withJSONObject: record)
    }
    func send(method: String, path: String, body: Data?) async throws -> (Data, Int) {
        if path.hasSuffix("/health") {
            healthCalls += 1
            try await Task.sleep(for: .milliseconds(5))
            return (try JSONSerialization.data(withJSONObject: [
                "protocolVersion": 1, "ready": true, "serverTime": now.timeIntervalSince1970,
                "allowedTargets": ["switch.fixture", "light.fixture"], "minLeadSeconds": 15, "maxLateSeconds": 5,
                "durable": true, "executionPolicy": "at_most_once"
            ]), 200)
        }
        if method == "POST" {
            posts += 1
            let payload = try #require(body)
            let object = try JSONSerialization.jsonObject(with: payload)
            let envelope = try #require(object as? [String: Any])
            var record = try #require(envelope["record"] as? [String: Any])
            let id = try #require(record["remoteID"] as? String)
            record["revision"] = 1; record["state"] = (record["enabled"] as? Bool) == true ? "armed" : "disabled"
            record["updatedAt"] = now.timeIntervalSince1970
            switch leaseTamper {
            case .drop: record["expiresAt"] = nil
            case .extend: record["expiresAt"] = ((record["expiresAt"] as? Double) ?? 0) + 86_400
            case nil: break
            }
            let data = try JSONSerialization.data(withJSONObject: record)
            records[id] = data
            if loseCreate { loseCreate = false; throw IoTError.timeout }
            return (data, 200)
        }
        let id = String(path.split(separator: "/").last ?? "")
        guard let data = records[id] else { return (Data(), 404) }
        if method == "DELETE" {
            var record = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            guard record["state"] as? String != "executing" else { return (Data(), 409) }
            deletes += 1; record["state"] = "removed"; record["revision"] = 2
            if tamperedDelete { record["deviceID"] = "switch.another" }
            let removed = try JSONSerialization.data(withJSONObject: record)
            records[id] = removed
            if loseDelete { loseDelete = false; throw IoTError.timeout }
            return (removed, 200)
        }
        return (data, 200)
    }
}
