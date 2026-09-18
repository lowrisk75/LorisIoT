import Foundation
import Testing
import Darwin
@testable import IoTCore

@Suite struct ScheduleStoreConcurrencyTests {
    let owner = ScheduleOwner(appID: "fixture.app", installationID: UUID())
    func receipt(_ number: Int) -> ScheduleReceipt {
        ScheduleReceipt(owner: owner, providerID: "fixture", schedule: DeviceSchedule(
            id: ScheduleID(rawValue: "job-\(number)"), deviceID: "plug", command: .setPower(true),
            start: Date(timeIntervalSince1970: 1_900_000_000), recurrence: .once, isEnabled: true), verification: .pending)
    }
    @Test func independentInstancesCannotLoseEachOthersWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iot-journal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("schedules.json")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask { try await FileScheduleStore(url: url).save(receipt(index)) }
            }
            try await group.waitForAll()
        }
        let records = try await FileScheduleStore(url: url).receipts(owner: owner, providerID: "fixture", deviceID: "plug")
        #expect(records.count == 40)
    }

    @Test(arguments: [false, true])
    func interruptedLockWaitPreservesJournalAndCanRecover(cancel: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iot-blocked-journal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("schedules.json")
        let store = FileScheduleStore(url: url)
        try await store.save(receipt(0))
        let before = try Data(contentsOf: url)
        let descriptor = Darwin.open(url.appendingPathExtension("lock").path, O_RDWR | O_CLOEXEC)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        let lockFile: (Int32, Int32) -> Int32 = flock
        let locked = lockFile(descriptor, LOCK_EX | LOCK_NB)
        #expect(locked == 0)
        guard locked == 0 else { return }
        defer { _ = lockFile(descriptor, LOCK_UN) }

        let writing = Task { try await store.save(receipt(1)) }
        if cancel {
            try await Task.sleep(for: .milliseconds(50))
            writing.cancel()
        }
        let result = await writing.result
        switch result {
        case .success: Issue.record("A blocked writer must not bypass the lock")
        case .failure(let error):
            if cancel { #expect(error is CancellationError) }
            else { #expect(error as? IoTError == .timeout) }
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(lockFile(descriptor, LOCK_UN) == 0)
        try await store.save(receipt(2))
        let records = try await store.receipts(owner: owner, providerID: "fixture", deviceID: "plug")
        #expect(Set(records.map { $0.schedule.id.rawValue }) == ["job-0", "job-2"])
    }
    @Test func duplicateOwnedIdentitiesAreCorruption() async throws {
        struct Document: Encodable { let version = 1; let receipts: [ScheduleReceipt] }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iot-journal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("schedules.json")
        try JSONEncoder().encode(Document(receipts: [receipt(1), receipt(1)])).write(to: url)
        await #expect(throws: (any Error).self) {
            try await FileScheduleStore(url: url).receipts(owner: owner, providerID: "fixture", deviceID: "plug")
        }
    }

    @Test func fileOperationLeaseSurvivesActorReentrancyAndAllowsJournalWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iot-operation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("schedules.json")
        let probe = ScheduleOperationProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for number in 0..<12 {
                group.addTask {
                    let store = FileScheduleStore(url: url)
                    try await store.withExclusiveOperation(owner: owner, providerID: "fixture", deviceID: "plug") {
                        await probe.enter()
                        try await store.save(receipt(number))
                        try await Task.sleep(for: .milliseconds(10))
                        await probe.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await probe.maximum == 1)
        #expect(try await FileScheduleStore(url: url).receipts(owner: owner, providerID: "fixture", deviceID: "plug").count == 12)
    }

    @Test func cancellingAnOperationReleasesItsFileLease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iot-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("schedules.json")
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            defer { entered.continuation.finish() }
            try await FileScheduleStore(url: url).withExclusiveOperation(owner: owner, providerID: "fixture", deviceID: "plug") {
                entered.continuation.yield(())
                entered.continuation.finish()
                try await Task.sleep(for: .seconds(2))
            }
        }
        for await _ in entered.stream { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let value = try await FileScheduleStore(url: url).withExclusiveOperation(owner: owner, providerID: "fixture", deviceID: "plug") { 42 }
        #expect(value == 42)
    }

    @Test func changingDeviceIDsCannotCreateUnboundedLockFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iot-shards-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileScheduleStore(url: directory.appendingPathComponent("schedules.json"))
        for number in 0..<300 {
            try await store.withExclusiveOperation(owner: owner, providerID: "fixture", deviceID: .init(rawValue: "device-\(number)")) { }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count <= 256)
    }
}

private actor ScheduleOperationProbe {
    private var active = 0
    private(set) var maximum = 0
    func enter() { active += 1; maximum = max(maximum, active) }
    func leave() { active -= 1 }
}
