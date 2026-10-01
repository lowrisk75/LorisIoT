import Foundation
import Testing
import IoTCore
@testable import IoTHomeAssistant

private let wakeNow = Date(timeIntervalSince1970: 2_000_000_000)
private actor WakeHTTP: HAHTTP {
    var records: [String: [String: Any]] = [:]
    var posts = 0; var deletes = 0; var loseReply = false
    var brightness = true
    func dropReply() { loseReply = true }
    func removeBrightness() { brightness = false }
    func send(method: String, path: String, body: Data?) throws -> (Data, Int) {
        func data(_ object: [String: Any]) throws -> (Data, Int) { (try JSONSerialization.data(withJSONObject: object), 200) }
        if path.hasSuffix("health") {
            return try data(["protocolVersion": 1, "ready": true, "durable": true, "executionPolicy": "at_most_once",
                "serverTime": wakeNow.timeIntervalSince1970, "allowedTargets": ["light.fixture"],
                "minLeadSeconds": 15, "maxLateSeconds": 5, "sunriseAutoOffVersion": 1])
        }
        if path.hasPrefix("api/states/") {
            return try data(["entity_id": "light.fixture", "state": "off", "attributes": [
                "supported_color_modes": brightness ? ["brightness"] : ["onoff"], "supported_features": 32]])
        }
        if method == "POST" {
            posts += 1
            let payload = try #require(JSONSerialization.jsonObject(with: body!) as? [String: Any])
            var record = try #require(payload["record"] as? [String: Any])
            let id = try #require(record["remoteID"] as? String)
            record["state"] = "armed"; record["revision"] = 1; record["updatedAt"] = wakeNow.timeIntervalSince1970
            records[id.lowercased()] = record
            if loseReply { loseReply = false; throw IoTError.timeout }
            return try data(record)
        }
        let id = String(path.split(separator: "/").last!)
        guard var record = records[id] else { return (Data(), 404) }
        if method == "DELETE" {
            deletes += 1; record["state"] = "removed"; record["revision"] = 2; records[id] = record
        }
        return try data(record)
    }
}
struct HAWakeAdapterTests {
    private func plan(off: Int? = nil, level: Double = 0.4) throws -> WakeOccurrencePlan {
        let target = try WakeTargetReference(providerID: "home-assistant", connectionID: UUID(), bindingID: UUID(), deviceID: "light.fixture")
        let intent = try WakeTargetIntent(actionID: UUID(), nonce: UUID(), target: target, start: wakeNow.addingTimeInterval(60),
            action: .light(.init(level: .init(level), transition: 600)), conditionalOffMinutes: off)
        return try .init(owner: .init(appID: "test", installationID: UUID()), occurrenceID: UUID(), generation: UUID(),
            wakeAt: wakeNow.addingTimeInterval(660), targets: [intent])
    }
    @Test func genericAndConditionalReadBackExactOwnedSchedules() async throws {
        for off in [nil, 15] as [Int?] {
            let plan = try plan(off: off); let http = WakeHTTP()
            let adapter = HAWakeSchedulingAdapter(target: plan.targets[0].target, owner: plan.owner, http: http,
                scheduleStore: MemoryScheduleStore(), validateBinding: { true }, now: { wakeNow })
            let c = WakeCoordinator(store: MemoryWakePlanStore(), adapters: [plan.targets[0].target: adapter], now: { wakeNow })
            #expect(try await c.prepare(plan).results[0].phase == .scheduled)
            #expect(try await c.prepare(plan).results[0].phase == .scheduled)
            #expect(await http.posts == 1)
            #expect(try await c.cancel(plan).results[0].phase == .cancelledConfirmed)
            #expect(await http.deletes == 1)
        }
    }
    @Test func lostReplyIsInspectedWithoutSecondPost() async throws {
        let plan = try plan(off: 15); let http = WakeHTTP(); await http.dropReply()
        let adapter = HAWakeSchedulingAdapter(target: plan.targets[0].target, owner: plan.owner, http: http,
            scheduleStore: MemoryScheduleStore(), validateBinding: { true }, now: { wakeNow })
        let c = WakeCoordinator(store: MemoryWakePlanStore(), adapters: [plan.targets[0].target: adapter], now: { wakeNow })
        #expect(try await c.prepare(plan).results[0].phase == .uncertain)
        #expect(try await c.prepare(plan).results[0].phase == .scheduled)
        #expect(await http.posts == 1)
    }
    @Test func rejectsStaleBindingAndUnsupportedBrightnessBeforeWrite() async throws {
        let plan = try plan(); let http = WakeHTTP()
        let stale = HAWakeSchedulingAdapter(target: plan.targets[0].target, owner: plan.owner, http: http,
            scheduleStore: MemoryScheduleStore(), validateBinding: { false }, now: { wakeNow })
        await #expect(throws: (any Error).self) { try await stale.prepare(plan.targets[0], in: plan) }
        await http.removeBrightness()
        let adapter = HAWakeSchedulingAdapter(target: plan.targets[0].target, owner: plan.owner, http: http,
            scheduleStore: MemoryScheduleStore(), validateBinding: { true }, now: { wakeNow })
        #expect(try await adapter.prepare(plan.targets[0], in: plan).phase == .unsupported)
        #expect(await http.posts == 0)
    }
    @Test func conditionalBrightnessNeverSilentlyRounds() async throws {
        let plan = try plan(off: 15, level: 0.405); let http = WakeHTTP()
        let adapter = HAWakeSchedulingAdapter(target: plan.targets[0].target, owner: plan.owner, http: http,
            scheduleStore: MemoryScheduleStore(), validateBinding: { true }, now: { wakeNow })
        await #expect(throws: (any Error).self) { try await adapter.prepare(plan.targets[0], in: plan) }
        #expect(await http.posts == 0)
    }
}
