import Foundation

/// Process-wide leases also cover separate coordinator instances. A timed-out worker retains
/// its slot until the underlying operation actually terminates (including noncooperative I/O).
actor WakeTransportLeases {
    static let shared = WakeTransportLeases()
    private var keys = Set<UUID>()
    var isIdle: Bool { keys.isEmpty }
    func acquire(_ key: UUID, until deadline: ContinuousClock.Instant) async throws {
        while keys.count >= 4 || keys.contains(key) {
            guard ContinuousClock.now < deadline else { throw IoTError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw IoTError.timeout }
        keys.insert(key)
    }
    func release(_ key: UUID) { keys.remove(key) }
}

/// Unlike a throwing task-group race, this continuation does not wait for an uncooperative loser.
private actor WakeCompletion {
    private var result: Result<WakeTargetResult, any Error>?
    private var continuation: CheckedContinuation<WakeTargetResult, any Error>?
    func finish(_ result: Result<WakeTargetResult, any Error>) {
        guard self.result == nil else { return }
        self.result = result; continuation?.resume(with: result); continuation = nil
    }
    func value() async throws -> WakeTargetResult {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

/// Own one instance per app execution authority; the app supplies verified bindings/adapters.
/// This coordinator never arms an audible alarm, invents a route, or retries a dispatched intent.
public actor WakeCoordinator {
    public struct Configuration: Sendable {
        public let targetTimeout: Duration
        public let groupTimeout: Duration
        public init(targetTimeout: Duration = .seconds(20), groupTimeout: Duration = .seconds(160)) throws {
            guard targetTimeout > .zero, targetTimeout <= .seconds(20), groupTimeout >= targetTimeout,
                  groupTimeout <= .seconds(160) else { throw WakeContractError.invalidParameters }
            self.targetTimeout = targetTimeout; self.groupTimeout = groupTimeout
        }
    }
    private enum Operation: Sendable { case prepare, inspect, cancel }
    private let store: any WakePlanStore
    private let adapters: [WakeTargetReference: any WakeSchedulingAdapter]
    private let configuration: Configuration
    private let now: @Sendable () -> Date
    private var running = false
    public init(store: any WakePlanStore, adapters: [WakeTargetReference: any WakeSchedulingAdapter],
                configuration: Configuration? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.adapters = adapters
        self.configuration = configuration ?? (try! Configuration()); self.now = now
    }
    public func prepare(_ plan: WakeOccurrencePlan) async throws -> WakePreparationReport {
        try await run(plan, operation: .prepare)
    }
    public func inspect(_ plan: WakeOccurrencePlan) async throws -> WakePreparationReport {
        try await run(plan, operation: .inspect)
    }
    public func cancel(_ plan: WakeOccurrencePlan, actionIDs: Set<UUID>? = nil) async throws -> WakePreparationReport {
        if let actionIDs, !actionIDs.isSubset(of: Set(plan.targets.map(\.actionID))) { throw WakeContractError.invalidPlan }
        return try await run(plan, operation: .cancel, actionIDs: actionIDs)
    }
    /// Reconciles known intentions only. Pending cancellations are completed before anything else.
    public func reconcile(owner: ScheduleOwner) async throws -> [WakePreparationReport] {
        let entries = try await store.entries(owner: owner)
        var reports: [WakePreparationReport] = []
        for entry in entries { reports.append(try await inspect(entry.plan)) }
        return reports
    }
    private func run(_ plan: WakeOccurrencePlan, operation: Operation, actionIDs: Set<UUID>? = nil) async throws -> WakePreparationReport {
        guard !running else { throw IoTError.unconfirmed }
        running = true; defer { running = false }
        try Task.checkCancellation()
        let deadline = ContinuousClock.now.advanced(by: configuration.groupTimeout)
        // Failure to persist is a group error BEFORE any adapter can mutate the remote system.
        if operation == .prepare { try await store.insert(plan) }
        let entries = try await store.entries(owner: plan.owner)
        guard let current = entries.first(where: { $0.plan == plan }) else { throw WakeContractError.invalidPlan }
        if current.states.values.allSatisfy({ $0 == .cancelled || $0 == .cancelledWithoutDispatch }) {
            return try await batch(plan, operation: .inspect, deadline: deadline)
        }
        if operation == .prepare {
            guard entries.last(where: { $0.plan.occurrenceID == plan.occurrenceID })?.plan.generation == plan.generation else {
                return try failure(plan, issue: .ownershipConflict)
            }
            for old in entries where old.plan.occurrenceID == plan.occurrenceID && old.plan.generation != plan.generation {
                if old.states.values.allSatisfy({ $0 == .cancelled || $0 == .cancelledWithoutDispatch }) { continue }
                let obsolete = Set(old.plan.targets.filter { !plan.targets.contains($0) }.map(\.actionID))
                if obsolete.isEmpty { continue }
                let report = try await batch(old.plan, operation: .cancel, deadline: deadline, actionIDs: obsolete)
                guard report.results.filter({ obsolete.contains($0.actionID) }).allSatisfy({ $0.phase == .cancelledConfirmed }) else {
                    return try failure(plan, issue: .cancellationPending)
                }
            }
            // Distinct occurrences on the same target must not overlap a still-owned session.
            for old in entries where old.plan.occurrenceID != plan.occurrenceID {
                for previous in old.plan.targets where old.states[previous.nonce] != .cancelled && old.states[previous.nonce] != .cancelledWithoutDispatch {
                    let end = old.plan.wakeAt.addingTimeInterval(Double(previous.conditionalOffMinutes ?? 0) * 60)
                    if plan.targets.contains(where: { next in
                        next.target == previous.target && next.start <= end && previous.start <= plan.wakeAt.addingTimeInterval(Double(next.conditionalOffMinutes ?? 0) * 60)
                    }) { return try failure(plan, issue: .ownershipConflict) }
                }
            }
        }
        return try await batch(plan, operation: operation, deadline: deadline, actionIDs: actionIDs)
    }
    private func failure(_ plan: WakeOccurrencePlan, issue: WakeIssue) throws -> WakePreparationReport {
        try .init(plan: plan, results: plan.targets.map { try .init(for: $0, in: plan, phase: .uncertain, issue: issue, checkedAt: now()) })
    }
    private func batch(_ plan: WakeOccurrencePlan, operation: Operation, deadline: ContinuousClock.Instant, actionIDs: Set<UUID>? = nil) async throws -> WakePreparationReport {
        let store = store; let now = now; let timeout = configuration.targetTimeout
        return try await withThrowingTaskGroup(of: WakeTargetResult.self) { group in
            for intent in plan.targets {
                let adapter = adapters[intent.target]
                group.addTask {
                    if operation == .cancel, let actionIDs, !actionIDs.contains(intent.actionID) {
                        return try .init(for: intent, in: plan, phase: .preparing, checkedAt: now())
                    }
                    let entry = try await store.entries(owner: plan.owner).first { $0.plan == plan }
                    if let state = entry?.states[intent.nonce], state == .cancelled || state == .cancelledWithoutDispatch {
                        return try .init(for: intent, in: plan, phase: .cancelledConfirmed,
                            proof: state == .cancelledWithoutDispatch ? .noDispatch : .cancellationReadback, checkedAt: now())
                    }
                    if operation == .cancel, entry?.states[intent.nonce] == .pending {
                        try await store.mark(plan, nonce: intent.nonce, state: .cancelledWithoutDispatch)
                        return try .init(for: intent, in: plan, phase: .cancelledConfirmed, proof: .noDispatch, checkedAt: now())
                    }
                    // Persist cancellation before resolving the transport: a missing connection
                    // must not turn a requested cancellation into a later inspection/preparation.
                    if operation == .cancel, entry?.states[intent.nonce] == .dispatched {
                        try await store.mark(plan, nonce: intent.nonce, state: .cancelling)
                    }
                    guard let adapter else {
                        return try .init(for: intent, in: plan, phase: .unsupported, issue: .adapterRequired, checkedAt: now())
                    }
                    do {
                        try await WakeTransportLeases.shared.acquire(adapter.serializationKey, until: deadline)
                        let limit = min(deadline, ContinuousClock.now.advanced(by: timeout))
                        let completion = WakeCompletion()
                        let worker = Task {
                            let result: Result<WakeTargetResult, any Error>
                            do {
                                let value = try await store.withTransportLease(adapter.serializationKey) {
                                    try Task.checkCancellation()
                                    guard ContinuousClock.now < limit else { throw IoTError.timeout }
                                    return try await Self.perform(intent, plan: plan, operation: operation, adapter: adapter, store: store, now: now)
                                }
                                result = .success(value)
                            } catch { result = .failure(error) }
                            await WakeTransportLeases.shared.release(adapter.serializationKey)
                            await completion.finish(result)
                        }
                        let timer = Task {
                            do { try await ContinuousClock().sleep(until: limit) }
                            catch { return }
                            worker.cancel()
                            await completion.finish(.failure(IoTError.timeout))
                        }
                        defer { timer.cancel() }
                        return try await withTaskCancellationHandler {
                            try await completion.value()
                        } onCancel: {
                            worker.cancel()
                            Task { await completion.finish(.failure(CancellationError())) }
                        }
                    } catch {
                        let issue: WakeIssue
                        if case IoTError.timeout = error { issue = .timeout }
                        else if error is CancellationError { issue = .cancellationPending }
                        else { issue = .transportFailure }
                        return try .init(for: intent, in: plan, phase: .uncertain, issue: issue, checkedAt: now())
                    }
                }
            }
            var results: [WakeTargetResult] = []
            for try await result in group { results.append(result) }
            return try .init(plan: plan, results: results)
        }
    }
    private nonisolated static func perform(_ intent: WakeTargetIntent, plan: WakeOccurrencePlan, operation: Operation,
        adapter: any WakeSchedulingAdapter, store: any WakePlanStore, now: @Sendable () -> Date) async throws -> WakeTargetResult {
        let entries = try await store.entries(owner: plan.owner)
        guard let entry = entries.first(where: { $0.plan == plan }), let state = entry.states[intent.nonce] else {
            throw WakeContractError.invalidPlan
        }
        if state == .cancelled || state == .cancelledWithoutDispatch {
            return try .init(for: intent, in: plan, phase: .cancelledConfirmed, proof: state == .cancelledWithoutDispatch ? .noDispatch : .cancellationReadback, checkedAt: now())
        }
        let result: WakeTargetResult
        if operation == .cancel || state == .cancelling {
            if state == .pending {
                try await store.mark(plan, nonce: intent.nonce, state: .cancelledWithoutDispatch)
                return try .init(for: intent, in: plan, phase: .cancelledConfirmed, proof: .noDispatch, checkedAt: now())
            }
            try await store.mark(plan, nonce: intent.nonce, state: .cancelling)
            result = try await adapter.cancel(intent, in: plan)
        } else if operation == .inspect || state == .dispatched {
            result = try await adapter.inspect(intent, in: plan)
        } else {
            let snapshot = try await adapter.capabilities(for: intent.target)
            if let issue = WakePlanPreflight.evaluate(plan, snapshots: [snapshot], now: now()).first(where: { $0.actionID == intent.actionID })?.issue {
                return try .init(for: intent, in: plan, phase: .unsupported, issue: issue, checkedAt: now())
            }
            try Task.checkCancellation()
            try await store.mark(plan, nonce: intent.nonce, state: .dispatched)
            try Task.checkCancellation()
            result = try await adapter.prepare(intent, in: plan)
        }
        // Reject a buggy adapter's receipt before changing the durable journal.
        guard result.owner == plan.owner, result.occurrenceID == plan.occurrenceID,
              result.generation == plan.generation, result.actionID == intent.actionID,
              result.nonce == intent.nonce, result.target == intent.target, result.start == intent.start,
              result.proof != .noDispatch, result.checkedAt <= now() else {
            throw WakeContractError.invalidEvidence
        }
        if result.phase == .cancelledConfirmed {
            if state != .cancelling { try await store.mark(plan, nonce: intent.nonce, state: .cancelling) }
            try await store.mark(plan, nonce: intent.nonce, state: .cancelled)
        }
        return result
    }
}
