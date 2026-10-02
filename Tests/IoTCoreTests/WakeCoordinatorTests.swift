import Foundation
import Testing
@testable import IoTCore

private let instant = Date(timeIntervalSince1970: 2_000_000_000)
private func makePlan(targets: Int = 1, owner: ScheduleOwner = .init(appID: "test", installationID: UUID())) throws -> WakeOccurrencePlan {
    try .init(owner: owner, occurrenceID: UUID(), generation: UUID(), wakeAt: instant.addingTimeInterval(600),
        targets: (0..<targets).map { index in
            try .init(actionID: UUID(), nonce: UUID(), target: .init(providerID: "fake", connectionID: UUID(),
                bindingID: UUID(), deviceID: .init(rawValue: "light.\(index)")), start: instant.addingTimeInterval(600), action: .power(true))
        })
}
private actor ActiveCounter {
    var active = 0; var peak = 0
    func enter() { active += 1; peak = max(peak, active) }
    func leave() { active -= 1 }
}
private actor ProbeAdapter: WakeSchedulingAdapter {
    nonisolated let serializationKey: UUID
    var prepares = 0; var inspections = 0; var cancels = 0
    let counter: ActiveCounter?
    var loseReply = false
    var suspended: CheckedContinuation<Void, Never>?
    var hang = false
    init(key: UUID = UUID(), loseReply: Bool = false, hang: Bool = false, counter: ActiveCounter? = nil) {
        self.counter = counter
        serializationKey = key; self.loseReply = loseReply; self.hang = hang
    }
    func capabilities(for target: WakeTargetReference) throws -> WakeCapabilitySnapshot {
        try .init(target: target, kind: .light, availability: .online, manual: [.power], autonomous: [.power],
            execution: .userServer, verifiedCancellation: true, checkedAt: instant, validUntil: instant.addingTimeInterval(60))
    }
    func prepare(_ intent: WakeTargetIntent, in plan: WakeOccurrencePlan) async throws -> WakeTargetResult {
        prepares += 1
        if let counter {
            await counter.enter()
            try await Task.sleep(for: .milliseconds(15))
            await counter.leave()
        }
        if hang { await withCheckedContinuation { suspended = $0 } }
        if loseReply { throw IoTError.timeout }
        return try result(intent, plan)
    }
    func inspect(_ intent: WakeTargetIntent, in plan: WakeOccurrencePlan) throws -> WakeTargetResult {
        inspections += 1; return try result(intent, plan)
    }
    func cancel(_ intent: WakeTargetIntent, in plan: WakeOccurrencePlan) throws -> WakeTargetResult {
        cancels += 1
        return try .init(for: intent, in: plan, phase: .cancelledConfirmed, proof: .cancellationReadback, checkedAt: instant)
    }
    func release() { suspended?.resume(); suspended = nil; hang = false }
    private func result(_ intent: WakeTargetIntent, _ plan: WakeOccurrencePlan) throws -> WakeTargetResult {
        try .init(for: intent, in: plan, phase: .scheduled, proof: .scheduleReadback, checkedAt: instant)
    }
}

@Suite(.serialized) struct WakeCoordinatorTests {
    @Test func cancellationSurvivesATemporarilyMissingAdapter() async throws {
        let plan = try makePlan(); let store = MemoryWakePlanStore(); let adapter = ProbeAdapter()
        let c = WakeCoordinator(store: store, adapters: [plan.targets[0].target: adapter], now: { instant })
        _ = try await c.prepare(plan)
        let offline = WakeCoordinator(store: store, adapters: [:], now: { instant })
        _ = try await offline.cancel(plan)
        #expect(try await store.entries(owner: plan.owner).first?.states[plan.targets[0].nonce] == .cancelling)
        #expect(try await c.reconcile(owner: plan.owner).first?.results.first?.phase == .cancelledConfirmed)
        #expect(await adapter.cancels == 1)
        #expect(await adapter.prepares == 1)
    }

    @Test func terminalHistoryCompactsWithoutAllowingReplay() async throws {
        let store = MemoryWakePlanStore(); let first = try makePlan()
        for plan in [first] + (try (0..<127).map { _ in try makePlan(owner: first.owner) }) {
            try await store.insert(plan)
            try await store.mark(plan, nonce: plan.targets[0].nonce, state: .cancelledWithoutDispatch)
        }
        try await store.insert(makePlan(owner: first.owner))
        #expect(try await store.entries(owner: first.owner).count == 1)
        await #expect(throws: (any Error).self) { try await store.insert(first) }
        let replay = try WakeOccurrencePlan(owner: first.owner, occurrenceID: first.occurrenceID, generation: UUID(),
            wakeAt: first.wakeAt, targets: first.targets)
        await #expect(throws: (any Error).self) { try await store.insert(replay) }
    }
    @Test func removingOneTargetRetainsTheOtherIntent() async throws {
        let old = try makePlan(targets: 2); let store = MemoryWakePlanStore()
        let first = ProbeAdapter(); let second = ProbeAdapter()
        let c = WakeCoordinator(store: store, adapters: [old.targets[0].target: first, old.targets[1].target: second], now: { instant })
        _ = try await c.prepare(old)
        let next = try WakeOccurrencePlan(owner: old.owner, occurrenceID: old.occurrenceID, generation: UUID(),
            wakeAt: old.wakeAt, targets: [old.targets[0]])
        #expect(try await c.prepare(next).results[0].phase == .scheduled)
        #expect(await first.cancels == 0)
        #expect(await first.prepares == 1)
        #expect(await second.cancels == 1)
    }
    @Test func thirtyTwoTargetsRespectGlobalConcurrencyAndSharedTransport() async throws {
        for shared in [false, true] {
            let plan = try makePlan(targets: 32); let counter = ActiveCounter(); let key = UUID()
            var adapters: [WakeTargetReference: any WakeSchedulingAdapter] = [:]
            for intent in plan.targets { adapters[intent.target] = ProbeAdapter(key: shared ? key : UUID(), counter: counter) }
            let c = WakeCoordinator(store: MemoryWakePlanStore(), adapters: adapters, now: { instant })
            #expect(try await c.prepare(plan).counts[.scheduled] == 32)
            #expect(await counter.peak <= (shared ? 1 : 4))
        }
    }

    @Test func pendingCancellationHasDurableNoDispatchProof() async throws {
        let plan = try makePlan(); let store = MemoryWakePlanStore(); let adapter = ProbeAdapter()
        try await store.insert(plan)
        let c = WakeCoordinator(store: store, adapters: [plan.targets[0].target: adapter], now: { instant })
        #expect(try await c.cancel(plan).results[0].proof == .noDispatch)
        #expect(try await c.prepare(plan).results[0].proof == .noDispatch)
        #expect(await adapter.prepares == 0)
        #expect(await adapter.cancels == 0)
    }
    @Test func replacementCancelsOldGenerationBeforeSendingNewOne() async throws {
        let old = try makePlan(); let target = old.targets[0].target; let adapter = ProbeAdapter()
        let c = WakeCoordinator(store: MemoryWakePlanStore(), adapters: [target: adapter], now: { instant })
        _ = try await c.prepare(old)
        let next = try WakeOccurrencePlan(owner: old.owner, occurrenceID: old.occurrenceID, generation: UUID(), wakeAt: old.wakeAt,
            targets: [.init(actionID: UUID(), nonce: UUID(), target: target, start: old.wakeAt, action: .power(false))])
        #expect(try await c.prepare(next).results[0].phase == .scheduled)
        #expect(await adapter.cancels == 1)
        #expect(await adapter.prepares == 2)
        #expect(try await c.prepare(old).results[0].phase == .cancelledConfirmed)
        #expect(await adapter.prepares == 2)
        #expect(await adapter.cancels == 1)
        #expect(try await c.inspect(next).results[0].phase == .scheduled)
    }
    @Test func separateFileActorsDoNotLoseEntries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("wake.json")
        let first = try makePlan(); let second = try makePlan(owner: first.owner)
        async let a: Void = FileWakePlanStore(url: url).insert(first)
        async let b: Void = FileWakePlanStore(url: url).insert(second)
        _ = try await (a, b)
        #expect(try await FileWakePlanStore(url: url).entries(owner: first.owner).count == 2)
    }
    @Test func storageFailurePreventsAnyPreparation() async throws {
        let plan = try makePlan(); let adapter = ProbeAdapter()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("wake.json")
        try Data("broken".utf8).write(to: url)
        let c = WakeCoordinator(store: FileWakePlanStore(url: url), adapters: [plan.targets[0].target: adapter], now: { instant })
        await #expect(throws: (any Error).self) { try await c.prepare(plan) }
        #expect(await adapter.prepares == 0)
    }
    @Test func responseLossInspectsWithoutReplayingAfterRestart() async throws {
        let plan = try makePlan(); let store = MemoryWakePlanStore(); let adapter = ProbeAdapter(loseReply: true)
        let first = WakeCoordinator(store: store, adapters: [plan.targets[0].target: adapter], now: { instant })
        #expect(try await first.prepare(plan).results[0].phase == .uncertain)
        let restarted = WakeCoordinator(store: store, adapters: [plan.targets[0].target: adapter], now: { instant })
        #expect(try await restarted.prepare(plan).results[0].phase == .scheduled)
        #expect(await adapter.prepares == 1)
        #expect(await adapter.inspections == 1)
    }
    @Test func cancelledIntentCannotBePreparedAgain() async throws {
        let plan = try makePlan(); let store = MemoryWakePlanStore(); let adapter = ProbeAdapter()
        let coordinator = WakeCoordinator(store: store, adapters: [plan.targets[0].target: adapter], now: { instant })
        _ = try await coordinator.prepare(plan)
        #expect(try await coordinator.cancel(plan).results[0].phase == .cancelledConfirmed)
        #expect(try await coordinator.prepare(plan).results[0].phase == .cancelledConfirmed)
        #expect(await adapter.prepares == 1)
    }
    @Test func nonCooperativeTimeoutKeepsTransportQuarantinedAcrossCoordinators() async throws {
        let plan = try makePlan(); let adapter = ProbeAdapter(hang: true)
        let settings = try WakeCoordinator.Configuration(targetTimeout: .milliseconds(30), groupTimeout: .milliseconds(100))
        let store = MemoryWakePlanStore()
        let first = WakeCoordinator(store: store, adapters: [plan.targets[0].target: adapter], configuration: settings, now: { instant })
        let began = ContinuousClock.now
        #expect(try await first.prepare(plan).results[0].issue == .timeout)
        #expect(began.duration(to: .now) < .seconds(2))
        let second = WakeCoordinator(store: store, adapters: [plan.targets[0].target: adapter], configuration: settings, now: { instant })
        #expect(try await second.inspect(plan).results[0].issue == .timeout)
        #expect(await adapter.inspections == 0)
        await adapter.release()
        for _ in 0..<100 { if await WakeTransportLeases.shared.isIdle { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(try await second.inspect(plan).results[0].phase == .scheduled)
    }
    @Test func unknownAdapterDoesNotPreventOtherTargets() async throws {
        let plan = try makePlan(targets: 2); let adapter = ProbeAdapter()
        let c = WakeCoordinator(store: MemoryWakePlanStore(), adapters: [plan.targets[0].target: adapter], now: { instant })
        let report = try await c.prepare(plan)
        #expect(report.results.map(\.phase) == [.scheduled, .unsupported])
    }
    @Test func immutableGenerationAndNonceAreEnforced() async throws {
        let plan = try makePlan(); let store = MemoryWakePlanStore()
        try await store.insert(plan)
        let changed = try WakeOccurrencePlan(owner: plan.owner, occurrenceID: plan.occurrenceID, generation: plan.generation,
            wakeAt: plan.wakeAt.addingTimeInterval(1), targets: plan.targets)
        await #expect(throws: (any Error).self) { try await store.insert(changed) }
        let reused = try WakeOccurrencePlan(owner: plan.owner, occurrenceID: UUID(), generation: UUID(), wakeAt: plan.wakeAt, targets: plan.targets)
        await #expect(throws: (any Error).self) { try await store.insert(reused) }
    }
    @Test func corruptAndFutureStoreNeverGetOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("wake.json")
        for bytes in [Data("broken".utf8), Data("{\"version\":99,\"entries\":[]}".utf8), Data("{\"version\":1,\"entries\":[],\"future\":true}".utf8)] {
            try bytes.write(to: url)
            let store = FileWakePlanStore(url: url)
            await #expect(throws: (any Error).self) { try await store.insert(makePlan()) }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }
    @Test func fileStorePersistsDispatchBeforeRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("wake.json"); let plan = try makePlan()
        let store = FileWakePlanStore(url: url)
        try await store.insert(plan)
        try await store.mark(plan, nonce: plan.targets[0].nonce, state: .dispatched)
        let reopened = FileWakePlanStore(url: url)
        #expect(try await reopened.entries(owner: plan.owner)[0].states[plan.targets[0].nonce] == .dispatched)
    }
}
