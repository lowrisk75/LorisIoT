import Foundation

/// Errors intentionally omit onboarding payloads, network credentials and native error details.
public enum MatterFabricError: Error, Sendable, Equatable {
    case invalidConfiguration, alreadyExists, notFound, corruptStorage, storageUnavailable
    case invalidState, factoryInUse, controllerUnavailable, commissioningFailed
}

protocol MatterSecretStorage: Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data, key: String, insertOnly: Bool) throws
    func remove(_ key: String) throws -> Bool
}
public enum MatterCommissioningDisposition: String, Codable, Sendable { case pending, commissioned, uncertain }
public struct MatterCommissioningRecord: Sendable, Equatable {
    public let nodeID: UInt64
    public let disposition: MatterCommissioningDisposition
}
typealias MatterNodeOutcome = MatterCommissioningDisposition
struct MatterFabricRecord: Codable, Sendable {
    var version = 1
    let identity: UUID
    let fabricID: UInt64
    let vendorID: UInt16
    let ipk: Data
    let rootPrivateKey: Data
    var nextNodeID: UInt64 = 2
    var attempts: [UInt64: MatterNodeOutcome] = [:]
    var initialized = false
    static let maximumNodeID: UInt64 = 0xFFFF_FFEF_FFFF_FFFF
    func validate() throws {
        guard version == 1, fabricID != 0, vendorID != 0, vendorID != .max,
              ipk.count == 16, rootPrivateKey.count == 97,
              nextNodeID >= 2, nextNodeID <= Self.maximumNodeID, attempts.count <= 1024,
              attempts.keys.allSatisfy({ $0 >= 2 && $0 < nextNodeID }) else { throw MatterFabricError.corruptStorage }
    }
}

/// Serializes in-process read/modify/write. A service belongs to one app process; extensions
/// must not open the same fabric concurrently. Failed writes never delete the previous record.
final class MatterFabricRepository: @unchecked Sendable {
    private let storage: any MatterSecretStorage
    private let lock = NSLock()
    private let key = "identity.v1"
    init(storage: any MatterSecretStorage) { self.storage = storage }
    func create(_ record: MatterFabricRecord) throws {
        try lock.withLock {
            try record.validate()
            guard try storage.read(key) == nil else { throw MatterFabricError.alreadyExists }
            try storage.write(JSONEncoder().encode(record), key: key, insertOnly: true)
        }
    }
    func load() throws -> MatterFabricRecord { try lock.withLock { try loadUnlocked() } }
    private func loadUnlocked() throws -> MatterFabricRecord {
        guard let data = try storage.read(key) else { throw MatterFabricError.notFound }
        guard data.count <= 262_144, let record = try? JSONDecoder().decode(MatterFabricRecord.self, from: data) else {
            throw MatterFabricError.corruptStorage
        }
        try record.validate(); return record
    }
    private func update(_ body: (inout MatterFabricRecord) throws -> Void) throws {
        try lock.withLock {
            var record = try loadUnlocked(); try body(&record); try record.validate()
            try storage.write(JSONEncoder().encode(record), key: key, insertOnly: false)
        }
    }
    func markInitialized() throws { try update { $0.initialized = true } }
    func reserveNode() throws -> UInt64 {
        var result: UInt64 = 0
        try update {
            guard $0.attempts.count < 1024, $0.nextNodeID < MatterFabricRecord.maximumNodeID else {
                throw MatterFabricError.invalidState
            }
            result = $0.nextNodeID; $0.nextNodeID += 1; $0.attempts[result] = .pending
        }
        return result
    }
    func finishNode(_ node: UInt64, outcome: MatterNodeOutcome) throws {
        try update {
            guard outcome != .pending, $0.attempts[node] == .pending else { throw MatterFabricError.invalidState }
            $0.attempts[node] = outcome
        }
    }
}

struct MatterCommissioningFlow {
    enum Action: Equatable { case ignore, commission, succeeded, failed }
    private enum Phase { case establishing, commissioning, finished }
    let nodeID: UInt64
    private var phase = Phase.establishing
    init(nodeID: UInt64) { self.nodeID = nodeID }
    mutating func established(failed: Bool) -> Action {
        guard phase == .establishing else { return .ignore }
        if failed { phase = .finished; return .failed }
        phase = .commissioning; return .commission
    }
    mutating func complete(nodeID: UInt64?, failed: Bool) -> Action {
        guard phase != .finished else { return .ignore }
        let valid = phase == .commissioning && !failed && nodeID == self.nodeID
        phase = .finished; return valid ? .succeeded : .failed
    }
}

/// Cancellation can arrive off the delegate queue. Check a monotonic deadline before
/// starting the second (device-mutating) commissioning phase from a queued callback.
final class MatterCommissioningLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private let clock = ContinuousClock()
    private let deadline: ContinuousClock.Instant
    private var cancelled = false
    init(timeout: Duration = .seconds(180)) { deadline = ContinuousClock().now.advanced(by: timeout) }
    var isActive: Bool { lock.withLock { !cancelled && clock.now < deadline } }
    func cancel() { lock.withLock { cancelled = true } }
}
