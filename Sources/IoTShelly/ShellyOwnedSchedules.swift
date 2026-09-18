import Foundation
import IoTCore

/// Owns only jobs present in its durable journal, and checks the remote contents before changing them.
/// An interrupted creation without an acknowledged ID needs reconciliation; it is never recreated blindly.
public actor ShellyOwnedSchedules: ScheduleCapability {
    public nonisolated let descriptor = CapabilityDescriptor(id: .schedule, operations: [.schedule])
    private let client: ShellyClient
    private let deviceID: DeviceID
    private let switchID: Int
    private let owner: ScheduleOwner
    private let store: any ScheduleStore
    private let providerID: ProviderID
    private let supportsYear: Bool
    private let now: @Sendable () -> Date
    private var mutating = false

    public init(client: ShellyClient, deviceID: DeviceID, switchID: Int, owner: ScheduleOwner,
                store: any ScheduleStore, providerID: ProviderID = "shelly", supportsYear: Bool = false,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client; self.deviceID = deviceID; self.switchID = switchID
        self.owner = owner; self.store = store; self.providerID = providerID
        self.supportsYear = supportsYear; self.now = now
    }

    private func timezone() async throws -> TimeZone {
        let config = try await client.call(method: "Sys.GetConfig")
        guard let location = config["location"] as? [String: any Sendable],
              let name = location["tz"] as? String, let zone = TimeZone(identifier: name) else {
            throw IoTError.notSupported("The device timezone is not available")
        }
        return zone
    }

    private func jobs() async throws -> [[String: any Sendable]] {
        let result = try await client.call(method: "Schedule.List")
        guard let jobs = result["jobs"] as? [[String: any Sendable]], jobs.count <= 256 else { throw IoTError.invalidResponse }
        return jobs
    }

    private func matches(_ job: [String: any Sendable], schedule: DeviceSchedule, zone: TimeZone) throws -> Bool {
        let expected = try ShellyScheduleCompiler.timespec(for: schedule, deviceTimeZone: zone,
                                                          supportsYear: supportsYear || schedule.recurrence == .once, now: .distantPast)
        guard job["timespec"] as? String == expected, job["enable"] as? Bool == schedule.isEnabled,
              let calls = job["calls"] as? [[String: any Sendable]], calls.count == 1,
              (calls[0]["method"] as? String)?.lowercased() == "switch.set", let params = calls[0]["params"] as? [String: any Sendable],
              Set(params.keys) == Set(["id", "on"]),
              params["id"] as? Int == switchID, case .setPower(let on) = schedule.command else { return false }
        return params["on"] as? Bool == on
    }

    public func schedules() async throws -> [DeviceSchedule] {
        let records = try await store.receipts(owner: owner, providerID: providerID, deviceID: deviceID)
        guard !records.isEmpty else { return [] }
        let zone = try await timezone()
        let current = try await jobs()
        var schedules: [DeviceSchedule] = []
        for record in records {
            guard let id = record.remoteID.flatMap(Int.init), let job = current.first(where: { $0["id"] as? Int == id }),
                  try matches(job, schedule: record.schedule, zone: zone) else { throw IoTError.unconfirmed }
            schedules.append(record.schedule)
        }
        return schedules
    }

    public func upsert(_ schedule: DeviceSchedule) async throws -> DeviceSchedule {
        try await store.withExclusiveOperation(owner: owner, providerID: providerID, deviceID: deviceID) {
            try await self.upsertExclusively(schedule)
        }
    }
    private func upsertExclusively(_ schedule: DeviceSchedule) async throws -> DeviceSchedule {
        guard !mutating else { throw IoTError.transport("A schedule operation is already in progress") }
        guard schedule.deviceID == deviceID, !owner.appID.isEmpty, !schedule.id.rawValue.isEmpty else { throw IoTError.notConfigured }
        // A relay has neither a ramp nor a brightness. Both refusals are owed before any round
        // trip: contacting the household device for a request that was always going to fail is a
        // cost with no possible benefit.
        guard case .setPower(let on) = schedule.command else { throw IoTError.notSupported("Power schedules only") }
        guard schedule.transition == nil else {
            throw IoTError.notSupported("A Shelly relay cannot ramp; a transition is not supported")
        }
        mutating = true; defer { mutating = false }
        let zone = try await timezone()
        try await ShellyScheduleQualification.verifyClock(client: client, now: now)
        let timespec: String
        if schedule.recurrence == .once, !supportsYear {
            timespec = try await ShellyScheduleQualification.oneShotTimespec(schedule, client: client,
                deviceTimeZone: zone, now: now())
        } else {
            timespec = try ShellyScheduleCompiler.timespec(for: schedule, deviceTimeZone: zone,
                supportsYear: supportsYear, now: now())
        }
        let old = try await store.receipts(owner: owner, providerID: providerID, deviceID: deviceID).first { $0.schedule.id == schedule.id }
        var remoteID = old?.remoteID.flatMap(Int.init)
        var previousSchedule = old?.schedule
        if let old {
            guard let id = remoteID else { throw IoTError.unconfirmed }
            let current = try await jobs()
            guard let job = current.first(where: { $0["id"] as? Int == id }) else { throw IoTError.unconfirmed }
            let matchesDesired = try matches(job, schedule: old.schedule, zone: zone)
            let matchesPrevious = try old.previousSchedule.map { try matches(job, schedule: $0, zone: zone) } ?? false
            guard matchesDesired || matchesPrevious else { throw IoTError.unconfirmed }
            previousSchedule = matchesDesired ? old.schedule : old.previousSchedule
            if old.schedule == schedule, matchesDesired {
                try await store.save(ScheduleReceipt(owner: owner, providerID: providerID, schedule: schedule,
                    remoteID: String(id), verification: .verified, verifiedAt: now()))
                return schedule
            }
        }
        let pending = ScheduleReceipt(owner: owner, providerID: providerID, schedule: schedule,
            previousSchedule: previousSchedule, remoteID: remoteID.map(String.init), verification: .pending)
        try await store.save(pending)
        do {
            let call: [String: any Sendable] = ["method": "Switch.Set", "params": ["id": switchID, "on": on] as [String: any Sendable]]
            var params: [String: any Sendable] = ["enable": schedule.isEnabled, "timespec": timespec, "calls": [call]]
            // Update the owned job in place; never delete the working job before its replacement exists.
            if let id = remoteID {
                params["id"] = id
                _ = try await client.call(method: "Schedule.Update", params: params)
            } else {
                let result = try await client.call(method: "Schedule.Create", params: params)
                guard let id = result["id"] as? Int, id >= 0 else { throw IoTError.invalidResponse }
                remoteID = id
            }
            try await store.save(ScheduleReceipt(owner: owner, providerID: providerID, schedule: schedule,
                previousSchedule: previousSchedule, remoteID: remoteID.map(String.init), verification: .pending))
            let current = try await jobs()
            guard let job = current.first(where: { $0["id"] as? Int == remoteID }),
                  try matches(job, schedule: schedule, zone: zone) else { throw IoTError.unconfirmed }
            try await store.save(ScheduleReceipt(owner: owner, providerID: providerID, schedule: schedule,
                remoteID: remoteID.map(String.init), verification: .verified, verifiedAt: now()))
            return schedule
        } catch {
            // Keep the pending journal even if updating its status fails. Never swallow the remote uncertainty.
            try? await store.save(ScheduleReceipt(owner: owner, providerID: providerID, schedule: schedule,
                previousSchedule: previousSchedule, remoteID: remoteID.map(String.init), verification: .uncertain))
            throw error
        }
    }

    public func removeSchedule(id: ScheduleID) async throws {
        try await store.withExclusiveOperation(owner: owner, providerID: providerID, deviceID: deviceID) {
            try await self.removeExclusively(id: id)
        }
    }
    private func removeExclusively(id: ScheduleID) async throws {
        guard !mutating else { throw IoTError.transport("A schedule operation is already in progress") }
        mutating = true; defer { mutating = false }
        guard let record = try await store.receipts(owner: owner, providerID: providerID, deviceID: deviceID).first(where: { $0.schedule.id == id }) else {
            return // No local ownership: do not touch any device job.
        }
        guard let remoteID = record.remoteID.flatMap(Int.init) else { throw IoTError.unconfirmed }
        let zone = try await timezone()
        let current = try await jobs()
        if let job = current.first(where: { $0["id"] as? Int == remoteID }) {
            let desiredMatches = try matches(job, schedule: record.schedule, zone: zone)
            let previousMatches = try record.previousSchedule.map { try matches(job, schedule: $0, zone: zone) } ?? false
            guard desiredMatches || previousMatches else { throw IoTError.unconfirmed }
            try await store.save(ScheduleReceipt(owner: owner, providerID: providerID, schedule: record.schedule,
                previousSchedule: record.previousSchedule, remoteID: record.remoteID, verification: .removing))
            _ = try await client.call(method: "Schedule.Delete", params: ["id": remoteID])
            guard try await jobs().allSatisfy({ $0["id"] as? Int != remoteID }) else { throw IoTError.unconfirmed }
        }
        try await store.remove(record)
    }
}
