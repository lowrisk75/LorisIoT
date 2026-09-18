import Foundation
import IoTCore

/// Opt-in to the separately installed LorisIoT server component. A helper name is insufficient.
public struct HASchedulingConfiguration: Sendable {
    public let owner: ScheduleOwner
    public let store: any ScheduleStore
    /// Seconds an armed intent stays valid without a renewal. It bounds a zombie intent, so an
    /// owner that stops pushing stops arming the home; it does not bound a cancellation, whose
    /// owner is alive and whose lease is still fresh. Nil keeps an intent valid until it fires.
    public let lease: TimeInterval?
    public init(owner: ScheduleOwner, store: any ScheduleStore, lease: TimeInterval? = nil) {
        self.owner = owner; self.store = store; self.lease = lease
    }
}

struct HAScheduleHealth: Decodable, Sendable {
    let protocolVersion: Int
    let ready: Bool
    let serverTime: Double
    let allowedTargets: [String]
    let minLeadSeconds: Double
    let maxLateSeconds: Double
    let durable: Bool
    let executionPolicy: String
}

struct HAScheduleRequest: Codable, Equatable, Sendable {
    let remoteID: String
    let owner: ScheduleOwner
    let providerID: String
    let scheduleID: String
    let deviceID: String
    let on: Bool
    let start: Double
    let enabled: Bool
    let level: Double?
    let transition: Double?
    let expiresAt: Double?

    // The lease is renewed on every push, so it does not take part in exact equality. It is checked
    // separately: a server that shortens it can only prevent a firing, but one that drops or extends it
    // removes the bound on an intent nobody renews, so that readback is not verified.
    func honoursLease(of desired: HAScheduleRequest) -> Bool {
        guard let bound = desired.expiresAt else { return true }
        guard let expiresAt else { return false }
        return expiresAt <= bound
    }

    static func == (l: HAScheduleRequest, r: HAScheduleRequest) -> Bool {
        l.remoteID == r.remoteID && l.owner == r.owner && l.providerID == r.providerID
            && l.scheduleID == r.scheduleID && l.deviceID == r.deviceID && l.on == r.on
            && l.start == r.start && l.enabled == r.enabled && l.level == r.level
            && l.transition == r.transition
    }

    init(schedule: DeviceSchedule, remoteID: UUID, owner: ScheduleOwner, providerID: ProviderID,
         expiresAt: Double? = nil) throws {
        let on: Bool, level: Double?
        switch schedule.command {
        case .setPower(let value): on = value; level = nil
        case .setLevel(let value): on = true; level = value.value
        default: throw IoTError.notSupported("The HA server supports one-shot power and level schedules")
        }
        guard schedule.recurrence == .once else {
            throw IoTError.notSupported("The HA server supports one-shot power and level schedules")
        }
        // Only a luminaire carries a level or a transition; a switch, fan or helper has neither.
        if level != nil || schedule.transition != nil {
            guard schedule.deviceID.rawValue.hasPrefix("light.") else {
                throw IoTError.notSupported("The target accepts neither a level nor a transition")
            }
        }
        if let transition = schedule.transition {
            guard transition.isFinite, (0...3600).contains(transition) else { throw IoTError.notConfigured }
        }
        if let expiresAt { guard expiresAt.isFinite else { throw IoTError.notConfigured } }
        guard HARestClient.isEntityID(schedule.deviceID.rawValue), schedule.start.timeIntervalSince1970.isFinite,
              [owner.appID, providerID.rawValue, schedule.id.rawValue].allSatisfy({
                  $0.range(of: "^[A-Za-z0-9_.:-]{1,256}$", options: .regularExpression) != nil
              }), schedule.timeZoneIdentifier.map({ TimeZone(identifier: $0) != nil }) ?? true else {
            throw IoTError.notConfigured
        }
        self.remoteID = remoteID.uuidString.lowercased(); self.owner = owner
        self.providerID = providerID.rawValue; scheduleID = schedule.id.rawValue
        deviceID = schedule.deviceID.rawValue; self.on = on
        start = schedule.start.timeIntervalSince1970; enabled = schedule.isEnabled
        self.level = level; transition = schedule.transition; self.expiresAt = expiresAt
    }
}

struct HAScheduleRecord: Decodable, Sendable {
    enum State: String, Decodable { case armed, disabled, executing, applied, uncertain, missed, expired, removed }
    let request: HAScheduleRequest
    let revision: Int
    let state: State
    let updatedAt: Double
    enum CodingKeys: String, CodingKey { case revision, state, updatedAt }
    init(from decoder: any Decoder) throws {
        request = try HAScheduleRequest(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(Int.self, forKey: .revision)
        state = try container.decode(State.self, forKey: .state)
        updatedAt = try container.decode(Double.self, forKey: .updatedAt)
        guard revision > 0, updatedAt.isFinite else { throw IoTError.invalidResponse }
    }
}

struct HAScheduleAPI: Sendable {
    let http: any HAHTTP
    private let prefix = "api/lorisiot_schedule/v1/"
    func health() async throws -> HAScheduleHealth {
        let (data, status) = try await http.send(method: "GET", path: prefix + "health", body: nil)
        try check(status)
        let value = try decode(HAScheduleHealth.self, data)
        guard value.protocolVersion == 1, value.ready, value.durable, value.executionPolicy == "at_most_once",
              value.serverTime.isFinite, value.minLeadSeconds == 15, value.maxLateSeconds == 5,
              value.allowedTargets.count <= 256, Set(value.allowedTargets).count == value.allowedTargets.count,
              value.allowedTargets.allSatisfy(HARestClient.isEntityID) else {
            throw IoTError.notSupported("The server scheduling contract is not qualified")
        }
        return value
    }
    func record(_ id: UUID) async throws -> HAScheduleRecord? {
        let (data, status) = try await http.send(method: "GET", path: prefix + "records/" + id.uuidString.lowercased(), body: nil)
        if status == 404 { return nil }
        try check(status)
        let value = try decode(HAScheduleRecord.self, data)
        guard UUID(uuidString: value.request.remoteID) == id else { throw IoTError.invalidResponse }
        return value
    }
    func put(_ request: HAScheduleRequest, expectedRevision: Int?) async throws {
        struct Body: Encodable { let record: HAScheduleRequest; let expectedRevision: Int? }
        let body = try JSONEncoder().encode(Body(record: request, expectedRevision: expectedRevision))
        let (data, status) = try await http.send(method: "POST", path: prefix + "records", body: body)
        try check(status)
        let stored = try decode(HAScheduleRecord.self, data).request
        guard stored == request, stored.honoursLease(of: request) else { throw IoTError.invalidResponse }
    }
    func remove(_ id: UUID, owner: ScheduleOwner, revision: Int) async throws {
        struct Body: Encodable { let owner: ScheduleOwner; let expectedRevision: Int }
        let body = try JSONEncoder().encode(Body(owner: owner, expectedRevision: revision))
        let (_, status) = try await http.send(method: "DELETE", path: prefix + "records/" + id.uuidString.lowercased(), body: body)
        try check(status)
    }
    private func check(_ status: Int) throws {
        switch status {
        case 200...299: return
        case 401, 403: throw IoTError.authenticationFailed(reason: "Server scheduling authorization required")
        case 404: throw IoTError.notSupported("LorisIoT scheduling is not installed on this server")
        case 400: throw IoTError.notConfigured
        case 409: throw IoTError.unconfirmed
        default: throw IoTError.transport("Server scheduling unavailable")
        }
    }
    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try Task.checkCancellation()
        guard data.count <= 65_536 else { throw IoTError.invalidResponse }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw IoTError.invalidResponse }
    }
}

actor HAOwnedSchedules: ScheduleCapability {
    nonisolated let descriptor = CapabilityDescriptor(id: .schedule, operations: [.schedule])
    private let api: HAScheduleAPI
    private let deviceID: DeviceID
    private let providerID: ProviderID
    private let owner: ScheduleOwner
    private let store: any ScheduleStore
    private let lease: TimeInterval?
    private let now: @Sendable () -> Date
    init(http: any HAHTTP, deviceID: DeviceID, providerID: ProviderID, configuration: HASchedulingConfiguration,
         now: @escaping @Sendable () -> Date = { Date() }) {
        api = HAScheduleAPI(http: http); self.deviceID = deviceID; self.providerID = providerID
        owner = configuration.owner; store = configuration.store; lease = configuration.lease; self.now = now
    }
    private func request(_ schedule: DeviceSchedule, id: UUID) throws -> HAScheduleRequest {
        guard schedule.deviceID == deviceID else { throw IoTError.notConfigured }
        var expiresAt: Double?
        if let lease {
            guard lease.isFinite, lease > 0, lease <= 366 * 86400 else { throw IoTError.notConfigured }
            expiresAt = now().addingTimeInterval(lease).timeIntervalSince1970
        }
        return try HAScheduleRequest(schedule: schedule, remoteID: id, owner: owner,
                                     providerID: providerID, expiresAt: expiresAt)
    }
    func schedules() async throws -> [DeviceSchedule] {
        var active: [DeviceSchedule] = []
        for receipt in try await store.receipts(owner: owner, providerID: providerID, deviceID: deviceID) {
            guard let id = receipt.remoteID.flatMap(UUID.init(uuidString:)), let remote = try await api.record(id) else {
                throw IoTError.unconfirmed
            }
            let expected = try request(receipt.schedule, id: id)
            // A dropped or extended lease leaves an intent nobody bounds: not an active schedule.
            guard remote.request == expected, remote.request.honoursLease(of: expected) else { throw IoTError.unconfirmed }
            switch remote.state {
            case .armed where receipt.schedule.isEnabled, .disabled where !receipt.schedule.isEnabled:
                active.append(receipt.schedule)
            case .applied, .removed, .expired: break  // Known terminal outcomes, not uncertainty.
            default: throw IoTError.unconfirmed
            }
        }
        return active
    }
    func upsert(_ schedule: DeviceSchedule) async throws -> DeviceSchedule {
        try await store.withExclusiveOperation(owner: owner, providerID: providerID, deviceID: deviceID) {
            try await self.upsertExclusively(schedule)
        }
    }
    private func upsertExclusively(_ schedule: DeviceSchedule) async throws -> DeviceSchedule {
        let health = try await api.health()
        guard health.allowedTargets.contains(deviceID.rawValue), abs(health.serverTime - now().timeIntervalSince1970) <= 5 else {
            throw IoTError.notSupported("The target or server clock is not qualified")
        }
        guard schedule.start.timeIntervalSince(now()) >= 20, schedule.start.timeIntervalSince(now()) <= 366 * 86400 else {
            throw IoTError.notSupported("A server schedule must be 20 seconds to 366 days ahead")
        }
        let old = try await store.receipts(owner: owner, providerID: providerID, deviceID: deviceID).first { $0.schedule.id == schedule.id }
        let remoteID: UUID
        if let old {
            guard let id = old.remoteID.flatMap(UUID.init(uuidString:)) else { throw IoTError.unconfirmed }
            remoteID = id
        } else { remoteID = UUID() }
        let desired = try request(schedule, id: remoteID)
        var revision: Int?
        var previous = old?.schedule
        if let old {
            guard old.verification != .removing else { throw IoTError.unconfirmed }
            if let remote = try await api.record(remoteID) {
                let matchesDesired = remote.request == (try request(old.schedule, id: remoteID))
                let matchesPrevious = try old.previousSchedule.map { remote.request == (try request($0, id: remoteID)) } ?? false
                guard matchesDesired || matchesPrevious,
                      remote.state != .executing, remote.state != .uncertain else { throw IoTError.unconfirmed }
                revision = remote.revision
                previous = matchesDesired ? old.schedule : old.previousSchedule
                // With a lease, pushing again is the renewal, so an identical intent is still written.
                if remote.request == desired, desired.expiresAt == nil,
                   remote.state == (schedule.isEnabled ? .armed : .disabled) {
                    try await store.save(ScheduleReceipt(owner: owner, providerID: providerID, schedule: schedule,
                        remoteID: remoteID.uuidString, verification: .verified, verifiedAt: now()))
                    return schedule
                }
            } else {
                // Only an unresolved creation may replay the SAME nonce and exact original intent.
                guard old.verification != .verified, old.previousSchedule == nil, old.schedule == schedule else {
                    throw IoTError.unconfirmed
                }
                previous = nil
            }
        }
        try await store.save(ScheduleReceipt(owner: owner, providerID: providerID, schedule: schedule,
            previousSchedule: previous, remoteID: remoteID.uuidString, verification: .pending))
        do {
            try await api.put(desired, expectedRevision: revision)
            guard let remote = try await api.record(remoteID), remote.request == desired,
                  remote.request.honoursLease(of: desired),
                  remote.state == (schedule.isEnabled ? .armed : .disabled) else { throw IoTError.unconfirmed }
            try await store.save(ScheduleReceipt(owner: owner, providerID: providerID, schedule: schedule,
                remoteID: remoteID.uuidString, verification: .verified, verifiedAt: now()))
            return schedule
        } catch {
            try? await store.save(ScheduleReceipt(owner: owner, providerID: providerID, schedule: schedule,
                previousSchedule: previous, remoteID: remoteID.uuidString, verification: .uncertain))
            throw error
        }
    }
    func removeSchedule(id: ScheduleID) async throws {
        try await store.withExclusiveOperation(owner: owner, providerID: providerID, deviceID: deviceID) {
            try await self.removeExclusively(id: id)
        }
    }
    private func removeExclusively(id: ScheduleID) async throws {
        guard let receipt = try await store.receipts(owner: owner, providerID: providerID, deviceID: deviceID)
            .first(where: { $0.schedule.id == id }) else { return }
        guard let remoteID = receipt.remoteID.flatMap(UUID.init(uuidString:)), let remote = try await api.record(remoteID) else {
            throw IoTError.unconfirmed
        }
        let matchesDesired = remote.request == (try request(receipt.schedule, id: remoteID))
        let matchesPrevious = try receipt.previousSchedule.map { remote.request == (try request($0, id: remoteID)) } ?? false
        guard matchesDesired || matchesPrevious else { throw IoTError.unconfirmed }
        if remote.state != .removed {
            try await store.save(ScheduleReceipt(owner: owner, providerID: providerID, schedule: receipt.schedule,
                previousSchedule: receipt.previousSchedule, remoteID: receipt.remoteID, verification: .removing))
            try await api.remove(remoteID, owner: owner, revision: remote.revision)
            guard let cleared = try await api.record(remoteID), cleared.state == .removed,
                  cleared.request == remote.request else { throw IoTError.unconfirmed }
        }
        try await store.remove(receipt)
    }
}
