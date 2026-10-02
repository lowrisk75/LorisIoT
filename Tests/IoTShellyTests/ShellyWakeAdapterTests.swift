import Foundation
import Testing
import IoTCore
@testable import IoTShelly

private actor WakeRelay: ShellyRPC {
    let now: Date
    var mac = "aabbccddeeff"
    var job: [String: any Sendable]?
    var creates = 0
    init(now: Date) { self.now = now }
    func changeIdentity() { mac = "001122334455" }
    func call(host: String, password: String?, method: String, params: [String: any Sendable]) throws -> [String: any Sendable] {
        switch method {
        case "Shelly.GetDeviceInfo": return ["id": "fixture", "model": "Plus", "gen": 2, "mac": mac]
        case "Shelly.GetStatus": return ["switch:0": ["output": false] as [String: any Sendable]]
        case "Shelly.ListMethods": return ["methods": ["Schedule.Create", "Schedule.Update", "Schedule.List", "Schedule.Delete", "Sys.GetConfig"]]
        case "Sys.GetStatus": return ["unixtime": now.timeIntervalSince1970]
        case "Sys.GetConfig": return ["location": ["tz": "UTC"] as [String: any Sendable]]
        case "Schedule.List":
            let jobs: [[String: any Sendable]] = job.map { [$0] } ?? []
            return ["jobs": jobs]
        case "Schedule.Create": creates += 1; job = params; job?["id"] = 1; return ["id": 1]
        case "Schedule.Delete": job = nil; return [:]
        default: throw IoTError.notSupported(method)
        }
    }
}
struct ShellyWakeAdapterTests {
    @Test func nativeIdentityAndOwnedReadbackAreRequired() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000); let rpc = WakeRelay(now: now)
        let owner = ScheduleOwner(appID: "test", installationID: UUID())
        let target = try WakeTargetReference(providerID: "shelly", connectionID: UUID(), bindingID: UUID(), deviceID: "relay")
        let provider = ShellyProvider(devices: [.init(id: "relay", name: "Fixture", host: "fixture", mac: "aabbccddeeff")],
            rpc: rpc, scheduleOwner: owner, scheduleStore: MemoryScheduleStore(), qualifiedYearSupport: ["relay"])
        let adapter = try await provider.wakeAdapter(for: target, validateBinding: { true }, now: { now })
        let date = now.addingTimeInterval(600)
        let plan = try WakeOccurrencePlan(owner: owner, occurrenceID: UUID(), generation: UUID(), wakeAt: date,
            targets: [.init(actionID: UUID(), nonce: UUID(), target: target, start: date, action: .power(true))])
        #expect(try await adapter.prepare(plan.targets[0], in: plan).phase == .scheduled)
        #expect(try await adapter.cancel(plan.targets[0], in: plan).phase == .cancelledConfirmed)
        await rpc.changeIdentity()
        await #expect(throws: (any Error).self) { try await adapter.prepare(plan.targets[0], in: plan) }
        #expect(await rpc.creates == 1)
    }
}
