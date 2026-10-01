import Foundation
import Testing
@testable import IoTMatter

struct MatterFabricTests {
    @Test func cancellationAndExpiredDeadlinesPreventAdvancingCommissioning() {
        let active = MatterCommissioningLifetime()
        #expect(active.isActive)
        active.cancel(); #expect(!active.isActive)
        #expect(!MatterCommissioningLifetime(timeout: .zero).isActive)
    }
    private func record() -> MatterFabricRecord {
        MatterFabricRecord(identity: UUID(), fabricID: 123, vendorID: 0x1234,
            ipk: Data(repeating: 7, count: 16), rootPrivateKey: Data(repeating: 8, count: 97))
    }
    @Test func identitySurvivesReopenAndNodeReservationsNeverReuseAnUncertainAttempt() throws {
        let storage = MatterMemoryStorage(); let repository = MatterFabricRepository(storage: storage)
        let initial = record(); try repository.create(initial)
        #expect(try repository.load().identity == initial.identity)
        #expect(try repository.reserveNode() == 2)
        let reopened = MatterFabricRepository(storage: storage)
        #expect(try reopened.reserveNode() == 3)
        #expect(try reopened.load().attempts[2] == .pending)
        try reopened.finishNode(2, outcome: .uncertain)
        #expect(try repository.load().attempts[2] == .uncertain)
        #expect(throws: MatterFabricError.alreadyExists) { try repository.create(record()) }
    }
    @Test func storageFailureAndCorruptionNeverGenerateAReplacementFabric() throws {
        let storage = MatterMemoryStorage(); let repository = MatterFabricRepository(storage: storage)
        try repository.create(record()); let original = try storage.read("identity.v1")
        storage.failWrites = true
        #expect(throws: MatterFabricError.storageUnavailable) { try repository.reserveNode() }
        #expect(try storage.read("identity.v1") == original)
        storage.failReads = true
        #expect(throws: MatterFabricError.storageUnavailable) { try repository.load() }
        storage.failReads = false; storage.failWrites = false
        try storage.write(Data("corrupt".utf8), key: "identity.v1", insertOnly: false)
        #expect(throws: MatterFabricError.corruptStorage) { try repository.load() }
    }
    @Test func reservationIsPersistedBeforeItCanBeUsedAndTerminalNodesCannotBeRewritten() throws {
        let storage = MatterMemoryStorage(); let repository = MatterFabricRepository(storage: storage)
        try repository.create(record())
        let node = try repository.reserveNode()
        try repository.finishNode(node, outcome: .commissioned)
        #expect(throws: MatterFabricError.invalidState) { try repository.finishNode(node, outcome: .uncertain) }
        #expect(throws: MatterFabricError.invalidState) { try repository.finishNode(99, outcome: .commissioned) }
    }
    @Test func commissioningRefusesWrongNodesAndPrematureCompletion() {
        var flow = MatterCommissioningFlow(nodeID: 2)
        #expect(flow.complete(nodeID: 2, failed: false) == .failed)
        #expect(flow.established(failed: false) == .ignore)
        flow = MatterCommissioningFlow(nodeID: 2)
        #expect(flow.established(failed: false) == .commission)
        #expect(flow.established(failed: false) == .ignore)
        #expect(flow.complete(nodeID: 3, failed: false) == .failed)
        #expect(flow.complete(nodeID: 2, failed: false) == .ignore)
    }
    @Test func onlyMatchingSuccessfulCommissioningCompletesTheFlow() {
        var flow = MatterCommissioningFlow(nodeID: 2)
        #expect(flow.established(failed: false) == .commission)
        #expect(flow.complete(nodeID: 2, failed: false) == .succeeded)
        #expect(flow.complete(nodeID: 2, failed: false) == .ignore)
        var failed = MatterCommissioningFlow(nodeID: 4)
        #expect(failed.established(failed: true) == .failed)
        #expect(failed.complete(nodeID: 4, failed: false) == .ignore)
    }
}

final class MatterMemoryStorage: MatterSecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    var failWrites = false
    var failReads = false
    func read(_ key: String) throws -> Data? {
        try lock.withLock {
            if failReads { throw MatterFabricError.storageUnavailable }
            return items[key]
        }
    }
    func write(_ data: Data, key: String, insertOnly: Bool) throws {
        try lock.withLock {
            if failWrites { throw MatterFabricError.storageUnavailable }
            if insertOnly && items[key] != nil { throw MatterFabricError.alreadyExists }
            items[key] = data
        }
    }
    func remove(_ key: String) throws -> Bool { lock.withLock { items.removeValue(forKey: key) != nil } }
}
