import Foundation
import Testing
import IoTCore

/// Compiled integration example. This adapter has no transport, credentials or physical target.
private actor SyntheticWakeAdapter: WakeSchedulingAdapter {
    nonisolated let serializationKey = UUID()
    let snapshot: WakeCapabilitySnapshot
    let now: Date
    init(snapshot: WakeCapabilitySnapshot, now: Date) { self.snapshot = snapshot; self.now = now }
    func capabilities(for target: WakeTargetReference) throws -> WakeCapabilitySnapshot {
        guard target == snapshot.target else { throw WakeContractError.invalidIdentity }
        return snapshot
    }
    func prepare(_ intent: WakeTargetIntent, in plan: WakeOccurrencePlan) throws -> WakeTargetResult {
        let check = WakePlanPreflight.evaluate(plan, snapshots: [snapshot], now: now)
        if let issue = check.first(where: { $0.actionID == intent.actionID })?.issue {
            return try .init(for: intent, in: plan, phase: .unsupported, issue: issue, checkedAt: now)
        }
        // Synthetic readback only. A production adapter must journal and reread its real backend.
        _ = try WakePlanPreflight.deviceSchedule(for: intent, in: plan)
        return try .init(for: intent, in: plan, phase: .scheduled, proof: .scheduleReadback, checkedAt: now)
    }
    func inspect(_ intent: WakeTargetIntent, in plan: WakeOccurrencePlan) throws -> WakeTargetResult {
        try .init(for: intent, in: plan, phase: .uncertain, issue: .adapterRequired, checkedAt: now)
    }
    func cancel(_ intent: WakeTargetIntent, in plan: WakeOccurrencePlan) throws -> WakeTargetResult {
        // Never claim cancellation without a real implementation and cancellation readback.
        try .init(for: intent, in: plan, phase: .uncertain, issue: .cancellationPending, checkedAt: now)
    }
}

struct WakeIntegrationExampleTests {
    @Test func compileAndPrepareTwoSyntheticTargetsWithoutHomeAssistant() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let owner = ScheduleOwner(appID: "com.example.fixture", installationID: UUID())
        let a = try WakeTargetReference(providerID: "fixture", connectionID: UUID(), bindingID: UUID(), deviceID: "same")
        let b = try WakeTargetReference(providerID: "fixture", connectionID: UUID(), bindingID: UUID(), deviceID: "same")
        let intents = try [a,b].map { try WakeTargetIntent(actionID: UUID(), nonce: UUID(), target: $0, start: now.addingTimeInterval(120), action: .power(true)) }
        let plan = try WakeOccurrencePlan(owner: owner, occurrenceID: UUID(), generation: UUID(), wakeAt: now.addingTimeInterval(120), targets: intents)
        let encoded = try JSONEncoder().encode(plan) // Host persists this before any production preparation.
        let restored = try JSONDecoder().decode(WakeOccurrencePlan.self, from: encoded)
        var results: [WakeTargetResult] = []
        for intent in restored.targets {
            let capabilities = try WakeCapabilitySnapshot(target:intent.target,kind:.light,availability:.online,
                manual:[.power],autonomous:[.power],execution:.device,verifiedCancellation:true,
                checkedAt:now,validUntil:now.addingTimeInterval(30))
            let adapter = SyntheticWakeAdapter(snapshot: capabilities, now: now)
            results.append(try await adapter.prepare(intent, in: restored))
        }
        let report = try WakePreparationReport(plan: restored, results: results)
        #expect(report.counts[.scheduled] == 2)
        #expect(report.freshScheduledCount(at: now) == 2)
        #expect(restored.targets[0].target != restored.targets[1].target)
    }
}
