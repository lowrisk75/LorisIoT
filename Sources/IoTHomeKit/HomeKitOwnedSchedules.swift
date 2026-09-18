import Foundation
import IoTCore

/// A timer is persisted disabled, linked to its action, then enabled only when requested.
protocol HomeKitTimerTransport: Sendable {
    func createTimer(_ schedule: DeviceSchedule, name: String) async throws
    func timerMatches(_ schedule: DeviceSchedule, name: String) async throws -> Bool
    func removeTimer(_ schedule: DeviceSchedule, name: String) async throws
}

enum HomeKitScheduleValidation {
    static func validate(_ schedule: DeviceSchedule, deviceID: DeviceID, now: Date) throws {
        guard schedule.deviceID == deviceID, !schedule.id.rawValue.isEmpty,
              schedule.start.timeIntervalSince1970.isFinite else { throw IoTError.notConfigured }
        guard case .setPower = schedule.command else { throw IoTError.notSupported("HomeKit power schedules only") }
        // A transition is performed by the device's own ramp. HomeKit exposes no transition time,
        // so carrying one must fail here rather than arm an instant change with the ramp dropped.
        guard schedule.transition == nil else {
            throw IoTError.notSupported("HomeKit exposes no transition time; this target cannot ramp")
        }
        // HMTimerTrigger's modern API has no timezone-relative recurrence contract.
        // Do not turn a daily or weekly wall-clock request into an elapsed-time timer.
        guard schedule.recurrence == .once else {
            throw IoTError.notSupported("Calendar recurrence requires a qualified HomeKit calendar trigger")
        }
        guard schedule.start.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0 else {
            throw IoTError.notSupported("HomeKit timers require an exact whole minute; seconds are never rounded")
        }
        guard schedule.start.timeIntervalSince(now) >= 60 else {
            throw IoTError.notSupported("HomeKit timers must be at least one minute ahead")
        }
        if let name = schedule.timeZoneIdentifier, TimeZone(identifier: name) == nil { throw IoTError.notConfigured }
    }
}

/// Durable ownership of a one-shot HomeKit timer. A nonce in the journal identifies the remote
/// objects; names chosen by users or another app are never used to infer ownership.
actor HomeKitOwnedSchedules: ScheduleCapability {
    nonisolated let descriptor = CapabilityDescriptor(id: .schedule, operations: [.schedule])
    private let transport: any HomeKitTimerTransport
    private let deviceID: DeviceID
    private let owner: ScheduleOwner
    private let store: any ScheduleStore
    private let providerID: ProviderID
    private let now: @Sendable () -> Date
    private var mutating = false
    init(transport: any HomeKitTimerTransport, deviceID: DeviceID, owner: ScheduleOwner,
         store: any ScheduleStore, providerID: ProviderID = "homekit", now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport; self.deviceID = deviceID; self.owner = owner
        self.store = store; self.now = now
        self.providerID = providerID
    }
    func schedules() async throws -> [DeviceSchedule] {
        let records = try await store.receipts(owner: owner, providerID: providerID, deviceID: deviceID)
        for record in records {
            guard record.verification != .removing, let name = record.remoteID,
                  try await transport.timerMatches(record.schedule, name: name) else { throw IoTError.unconfirmed }
        }
        return records.map(\.schedule)
    }
    func upsert(_ schedule: DeviceSchedule) async throws -> DeviceSchedule {
        try await store.withExclusiveOperation(owner: owner, providerID: providerID, deviceID: deviceID) {
            try await self.upsertExclusively(schedule)
        }
    }
    private func upsertExclusively(_ schedule: DeviceSchedule) async throws -> DeviceSchedule {
        guard !mutating, !owner.appID.isEmpty else { throw IoTError.notConfigured }
        mutating = true; defer { mutating = false }
        try HomeKitScheduleValidation.validate(schedule, deviceID: deviceID, now: now())
        if let old = try await store.receipts(owner: owner, providerID: providerID, deviceID: deviceID)
            .first(where: { $0.schedule.id == schedule.id }) {
            guard old.verification != .removing, let name = old.remoteID,
                  try await transport.timerMatches(old.schedule, name: name) else { throw IoTError.unconfirmed }
            guard old.schedule == schedule else {
                throw IoTError.notSupported("Remove the verified existing HomeKit timer before changing it")
            }
            try await store.save(ScheduleReceipt(owner: owner, providerID: providerID, schedule: schedule,
                remoteID: name, verification: .verified, verifiedAt: now()))
            return schedule
        }
        let name = "LorisIoT." + UUID().uuidString
        try await store.save(ScheduleReceipt(owner: owner, providerID: providerID, schedule: schedule,
            remoteID: name, verification: .pending))
        do {
            try await transport.createTimer(schedule, name: name)
            guard try await transport.timerMatches(schedule, name: name) else { throw IoTError.unconfirmed }
            try await store.save(ScheduleReceipt(owner: owner, providerID: providerID, schedule: schedule,
                remoteID: name, verification: .verified, verifiedAt: now()))
            return schedule
        } catch {
            try? await store.save(ScheduleReceipt(owner: owner, providerID: providerID, schedule: schedule,
                remoteID: name, verification: .uncertain))
            throw error
        }
    }
    func removeSchedule(id: ScheduleID) async throws {
        try await store.withExclusiveOperation(owner: owner, providerID: providerID, deviceID: deviceID) {
            try await self.removeExclusively(id: id)
        }
    }
    private func removeExclusively(id: ScheduleID) async throws {
        guard !mutating else { throw IoTError.unconfirmed }
        mutating = true; defer { mutating = false }
        guard let record = try await store.receipts(owner: owner, providerID: providerID, deviceID: deviceID)
            .first(where: { $0.schedule.id == id }) else { return }
        guard let name = record.remoteID else { throw IoTError.unconfirmed }
        // The bridge also verifies identity/content immediately before the first remote mutation.
        try await store.save(ScheduleReceipt(owner: owner, providerID: providerID, schedule: record.schedule,
            remoteID: name, verification: .removing))
        try await transport.removeTimer(record.schedule, name: name)
        try await store.remove(record)
    }
}
