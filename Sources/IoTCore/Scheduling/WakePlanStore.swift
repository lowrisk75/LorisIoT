import Foundation
import Darwin

public enum WakeDispatchState: String, Codable, Sendable {
    case pending, dispatched, cancelling, cancelled, cancelledWithoutDispatch
}

/// Local authority only. Do not sync or restore this journal onto another installation.
public struct WakeJournalEntry: Codable, Equatable, Sendable {
    public let plan: WakeOccurrencePlan
    public fileprivate(set) var states: [UUID: WakeDispatchState]
    private enum CodingKeys: String, CodingKey { case plan, states }
    fileprivate init(plan: WakeOccurrencePlan) {
        self.plan = plan
        states = Dictionary(uniqueKeysWithValues: plan.targets.map { ($0.nonce, .pending) })
    }
    public init(from decoder: any Decoder) throws {
        try wakeKeys(decoder, allowed: ["plan", "states"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try c.decode(WakeOccurrencePlan.self, forKey: .plan)
        states = try c.decode([UUID: WakeDispatchState].self, forKey: .states)
        guard Set(states.keys) == Set(plan.targets.map(\.nonce)) else { throw WakeContractError.invalidPlan }
    }
}

public protocol WakePlanStore: Actor {
    func entries(owner: ScheduleOwner?) async throws -> [WakeJournalEntry]
    /// Identical inserts are idempotent; a generation and every nonce are immutable.
    func insert(_ plan: WakeOccurrencePlan) async throws
    func mark(_ plan: WakeOccurrencePlan, nonce: UUID, state: WakeDispatchState) async throws
    /// Shared by independent actors/processes using the same journal and transport identity.
    func withTransportLease<T: Sendable>(_ key: UUID, operation: @Sendable () async throws -> T) async throws -> T
}

private struct WakeJournal: Codable {
    var version = 1
    var entries: [WakeJournalEntry] = []
    var retiredGenerations = Set<UUID>()
    var retiredNonces = Set<UUID>()
    private enum CodingKeys: String, CodingKey { case version, entries, retiredGenerations, retiredNonces }
    init() {}
    init(from decoder: any Decoder) throws {
        try wakeKeys(decoder, allowed: ["version", "entries", "retiredGenerations", "retiredNonces"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version == 1 else { throw WakeContractError.unsupportedVersion }
        entries = try c.decode([WakeJournalEntry].self, forKey: .entries)
        retiredGenerations = try c.decodeIfPresent(Set<UUID>.self, forKey: .retiredGenerations) ?? []
        retiredNonces = try c.decodeIfPresent(Set<UUID>.self, forKey: .retiredNonces) ?? []
        try validate()
    }
    func validate() throws {
        guard version == 1, entries.count <= 128, retiredGenerations.count <= 4096, retiredNonces.count <= 32768,
              retiredGenerations.isDisjoint(with: entries.map { $0.plan.generation }),
              retiredNonces.isDisjoint(with: entries.flatMap { $0.plan.targets.map(\.nonce) }),
              Set(entries.map { $0.plan.generation }).count == entries.count else { throw WakeContractError.invalidPlan }
        var seen: [UUID: (WakeOccurrencePlan, WakeTargetIntent, WakeDispatchState)] = [:]
        for entry in entries {
            for intent in entry.plan.targets {
                guard let state = entry.states[intent.nonce] else { throw WakeContractError.invalidPlan }
                if let (plan, previous, previousState) = seen[intent.nonce] {
                    guard plan.owner == entry.plan.owner, plan.occurrenceID == entry.plan.occurrenceID,
                          plan.wakeAt == entry.plan.wakeAt, previous == intent, previousState == state else {
                        throw WakeContractError.invalidPlan
                    }
                } else { seen[intent.nonce] = (entry.plan, intent, state) }
            }
        }
    }
    mutating func insert(_ plan: WakeOccurrencePlan) throws {
        guard !retiredGenerations.contains(plan.generation), retiredNonces.isDisjoint(with: plan.targets.map(\.nonce)) else {
            throw WakeContractError.invalidPlan
        }
        if let entry = entries.first(where: { $0.plan.generation == plan.generation }) {
            guard entry.plan == plan else { throw WakeContractError.invalidPlan }
            return
        }
        if entries.count >= 128 {
            let retired = entries.filter { $0.states.values.allSatisfy { $0 == .cancelled || $0 == .cancelledWithoutDispatch } }
            retiredGenerations.formUnion(retired.map { $0.plan.generation })
            entries.removeAll { retiredGenerations.contains($0.plan.generation) }
            let retained = Set(entries.flatMap { $0.plan.targets.map(\.nonce) })
            retiredNonces.formUnion(Set(retired.flatMap { $0.plan.targets.map(\.nonce) }).subtracting(retained))
            guard !retiredGenerations.contains(plan.generation), retiredNonces.isDisjoint(with: plan.targets.map(\.nonce)) else {
                throw WakeContractError.invalidPlan
            }
        }
        var next = WakeJournalEntry(plan: plan)
        for intent in plan.targets {
            if let old = entries.first(where: { $0.states[intent.nonce] != nil }) {
                next.states[intent.nonce] = old.states[intent.nonce]
            }
        }
        entries.append(next); try validate()
    }
    mutating func mark(_ plan: WakeOccurrencePlan, nonce: UUID, state: WakeDispatchState) throws {
        guard let index = entries.firstIndex(where: { $0.plan == plan }), let old = entries[index].states[nonce] else {
            throw WakeContractError.invalidPlan
        }
        let permitted: Bool
        switch (old, state) {
        case let (a, b) where a == b: permitted = true
        case (.pending, .cancelledWithoutDispatch), (.pending, .dispatched), (.pending, .cancelling), (.dispatched, .cancelling), (.cancelling, .cancelled): permitted = true
        default: permitted = false
        }
        guard permitted else { throw WakeContractError.invalidPlan }
        for index in entries.indices where entries[index].states[nonce] != nil {
            entries[index].states[nonce] = state
        }
    }
}

/// Fixture store only; production preparation requires FileWakePlanStore or another durable store.
public actor MemoryWakePlanStore: WakePlanStore {
    private var journal = WakeJournal()
    private var leases = Set<UUID>()
    public init() {}
    public func entries(owner: ScheduleOwner?) -> [WakeJournalEntry] { journal.entries.filter { owner == nil || $0.plan.owner == owner } }
    public func insert(_ plan: WakeOccurrencePlan) throws {
        var next = journal; try next.insert(plan); journal = next
    }
    public func mark(_ plan: WakeOccurrencePlan, nonce: UUID, state: WakeDispatchState) throws { try journal.mark(plan, nonce: nonce, state: state) }
    public func withTransportLease<T: Sendable>(_ key: UUID, operation: @Sendable () async throws -> T) async throws -> T {
        guard leases.insert(key).inserted else { throw IoTError.unconfirmed }
        defer { leases.remove(key) }
        try Task.checkCancellation()
        return try await operation()
    }
}

/// Bounded, atomically replaced journal. Unknown/corrupt bytes are never overwritten.
/// A separate flock inode coordinates writers; transport leases survive caller timeouts.
public actor FileWakePlanStore: WakePlanStore {
    private let url: URL
    private let maximumBytes = 4_194_304
    public init(url: URL) { self.url = url }
    private func lock(_ suffix: String) async throws -> Int32 {
        guard url.isFileURL else { throw IoTError.notConfigured }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(url.appendingPathExtension(suffix).path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw IoTError.unconfirmed }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EAGAIN else { throw IoTError.unconfirmed }
                guard ContinuousClock.now < deadline else { throw IoTError.timeout }
                try await Task.sleep(for: .milliseconds(10))
            }
            try Task.checkCancellation()
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    private func unlock(_ fd: Int32) { _ = flock(fd, LOCK_UN); Darwin.close(fd) }
    private func read() throws -> WakeJournal {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 {
            guard errno == ENOENT else { throw IoTError.invalidResponse }
            return WakeJournal()
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw IoTError.invalidResponse }
        return try JSONDecoder().decode(WakeJournal.self, from: data)
    }
    private func write(_ journal: WakeJournal) throws {
        try journal.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal)
        guard data.count <= maximumBytes else { throw IoTError.invalidResponse }
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var resource = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try resource.setResourceValues(values)
    }
    public func entries(owner: ScheduleOwner?) async throws -> [WakeJournalEntry] {
        let fd = try await lock("lock"); defer { unlock(fd) }
        return try read().entries.filter { owner == nil || $0.plan.owner == owner }
    }
    public func insert(_ plan: WakeOccurrencePlan) async throws {
        let fd = try await lock("lock"); defer { unlock(fd) }
        var journal = try read(); try journal.insert(plan); try write(journal)
    }
    public func mark(_ plan: WakeOccurrencePlan, nonce: UUID, state: WakeDispatchState) async throws {
        let fd = try await lock("lock"); defer { unlock(fd) }
        var journal = try read(); try journal.mark(plan, nonce: nonce, state: state); try write(journal)
    }
    public func withTransportLease<T: Sendable>(_ key: UUID, operation: @Sendable () async throws -> T) async throws -> T {
        // 256 fixed shards bound lock-file growth. A collision only serializes unrelated transports.
        let suffix = key.uuidString.prefix(2).lowercased()
        let fd = try await lock("transport-\(suffix).lock"); defer { unlock(fd) }
        return try await operation()
    }
}
