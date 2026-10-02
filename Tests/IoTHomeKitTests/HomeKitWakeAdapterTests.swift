import Foundation
import Testing
import IoTCore
@testable import IoTHomeKit

private actor WakeHome: HomeKitDeviceTransport {
    let device = DeviceID(rawValue: UUID().uuidString)
    var timers: [String: DeviceSchedule] = [:]
    var creates = 0; var removes = 0; var allowed = true
    func revoke() { allowed = false }
    func devices() -> [HomeKitDeviceDescription] {
        [.init(id: device, name: "Fixture", kind: .light, readable: true, writable: allowed, supportsTimers: allowed)]
    }
    func readPower(_ deviceID: DeviceID) -> Bool { false }
    func setPower(_ deviceID: DeviceID, on: Bool) throws { throw IoTError.notSupported("No physical control") }
    func disconnect() {}
    func createTimer(_ schedule: DeviceSchedule, name: String) { creates += 1; timers[name] = schedule }
    func timerMatches(_ schedule: DeviceSchedule, name: String) -> Bool { timers[name] == schedule }
    func removeTimer(_ schedule: DeviceSchedule, name: String) throws {
        guard timers[name] == schedule else { throw IoTError.unconfirmed }
        removes += 1; timers[name] = nil
    }
}
struct HomeKitWakeAdapterTests {
    @Test func exactMinuteAndRevocationAreCheckedOnEveryOperation() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_040)
        let home = WakeHome(); let owner = ScheduleOwner(appID: "test", installationID: UUID())
        let target = try WakeTargetReference(providerID: "homekit", connectionID: UUID(), bindingID: UUID(), deviceID: home.device)
        let provider = HomeKitProvider(transport: home, owner: owner, store: MemoryScheduleStore())
        let adapter = try await provider.wakeAdapter(for: target, validateBinding: { true }, now: { now })
        func plan(offset: Double) throws -> WakeOccurrencePlan {
            let date = now.addingTimeInterval(offset)
            return try .init(owner: owner, occurrenceID: UUID(), generation: UUID(), wakeAt: date,
                targets: [.init(actionID: UUID(), nonce: UUID(), target: target, start: date, action: .power(true))])
        }
        let rounded = try plan(offset: 601)
        #expect(try await adapter.prepare(rounded.targets[0], in: rounded).issue == .invalidDeadline)
        #expect(await home.creates == 0)
        let exact = try plan(offset: 600)
        #expect(try await adapter.prepare(exact.targets[0], in: exact).phase == .scheduled)
        await home.revoke()
        await #expect(throws: (any Error).self) { try await adapter.prepare(exact.targets[0], in: exact) }
        #expect(await home.creates == 1)
    }
}
