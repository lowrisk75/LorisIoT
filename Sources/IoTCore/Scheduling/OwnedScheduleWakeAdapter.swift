import Foundation

/// Narrow adapter for providers with an existing durable, owned ScheduleCapability.
/// The resolver must verify the exact connection binding on EVERY call, including cancellation.
/// Use through WakeCoordinator so dispatch/cancellation tombstones outlive this actor.
public actor OwnedScheduleWakeAdapter: WakeSchedulingAdapter {
    public nonisolated let serializationKey: UUID
    public typealias Resolver = @Sendable () async throws -> (WakeCapabilitySnapshot, any ScheduleCapability)
    private let target: WakeTargetReference
    private let owner: ScheduleOwner
    private let store: any ScheduleStore
    private let scheduleProviderID: ProviderID
    private let resolve: Resolver
    private let now: @Sendable () -> Date
    private var busy = false
    public init(target: WakeTargetReference, owner: ScheduleOwner, serializationKey: UUID,
                store: any ScheduleStore, scheduleProviderID: ProviderID, resolve: @escaping Resolver,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.target = target; self.owner = owner; self.serializationKey = serializationKey
        self.store = store; self.scheduleProviderID = scheduleProviderID; self.resolve = resolve; self.now = now
    }
    public func capabilities(for target: WakeTargetReference) async throws -> WakeCapabilitySnapshot {
        guard target == self.target else { throw WakeContractError.invalidIdentity }
        let (snapshot, _) = try await resolve()
        guard snapshot.target == target else { throw WakeContractError.invalidIdentity }
        return snapshot
    }
    private func schedule(_ intent: WakeTargetIntent, _ plan: WakeOccurrencePlan) throws -> DeviceSchedule {
        guard intent.target == target, plan.owner == owner else { throw WakeContractError.invalidIdentity }
        return try WakePlanPreflight.deviceSchedule(for: intent, in: plan)
    }
    private func receipt(_ schedule: DeviceSchedule) async throws -> ScheduleReceipt? {
        let entry = try await store.receipts(owner: owner, providerID: scheduleProviderID, deviceID: target.deviceID)
            .first { $0.schedule.id == schedule.id }
        guard entry == nil || entry?.schedule == schedule else { throw IoTError.unconfirmed }
        return entry
    }
    public func prepare(_ intent: WakeTargetIntent, in plan: WakeOccurrencePlan) async throws -> WakeTargetResult {
        guard !busy else { throw IoTError.unconfirmed }; busy = true; defer { busy = false }
        let schedule = try schedule(intent, plan)
        let (snapshot, handle) = try await resolve()
        guard snapshot.target == target else { throw WakeContractError.invalidIdentity }
        if let issue = WakePlanPreflight.evaluate(plan, snapshots: [snapshot], now: now()).first(where: { $0.actionID == intent.actionID })?.issue {
            return try .init(for: intent, in: plan, phase: .unsupported, issue: issue, checkedAt: now())
        }
        try Task.checkCancellation()
        // Existing ownership is inspected, never upserted again: consumed jobs must not resurrect.
        if try await receipt(schedule) == nil { _ = try await handle.upsert(schedule) }
        return try await readback(intent, plan, schedule, handle)
    }
    public func inspect(_ intent: WakeTargetIntent, in plan: WakeOccurrencePlan) async throws -> WakeTargetResult {
        let desired = try schedule(intent, plan)
        let (snapshot, handle) = try await resolve()
        guard snapshot.target == target else { throw WakeContractError.invalidIdentity }
        return try await readback(intent, plan, desired, handle)
    }
    private func readback(_ intent: WakeTargetIntent, _ plan: WakeOccurrencePlan, _ desired: DeviceSchedule,
                          _ handle: any ScheduleCapability) async throws -> WakeTargetResult {
        guard let record = try await receipt(desired), record.verification != .removing,
              try await handle.schedules().contains(desired), now() < intent.start else {
            return try .init(for: intent, in: plan, phase: .uncertain, issue: .transportFailure, checkedAt: now())
        }
        return try .init(for: intent, in: plan, phase: .scheduled, proof: .scheduleReadback, checkedAt: now())
    }
    public func cancel(_ intent: WakeTargetIntent, in plan: WakeOccurrencePlan) async throws -> WakeTargetResult {
        guard !busy else { throw IoTError.unconfirmed }; busy = true; defer { busy = false }
        let desired = try schedule(intent, plan)
        let (snapshot, handle) = try await resolve()
        guard snapshot.target == target else { throw WakeContractError.invalidIdentity }
        // No local receipt is not remote cancellation evidence, including after a lost response.
        guard try await receipt(desired) != nil else {
            return try .init(for: intent, in: plan, phase: .uncertain, issue: .cancellationPending, checkedAt: now())
        }
        try await handle.removeSchedule(id: desired.id)
        guard try await receipt(desired) == nil, try await handle.schedules().allSatisfy({ $0.id != desired.id }) else {
            throw IoTError.unconfirmed
        }
        return try .init(for: intent, in: plan, phase: .cancelledConfirmed, proof: .cancellationReadback, checkedAt: now())
    }
}
