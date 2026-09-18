import Foundation
import Darwin
import CryptoKit

public struct ScheduleOwner: Codable, Hashable, Sendable {
    public let appID: String
    public let installationID: UUID
    public init(appID: String, installationID: UUID) { self.appID = appID; self.installationID = installationID }
}

public enum ScheduleVerification: String, Codable, Sendable { case pending, verified, uncertain, removing }

/// Journal entry persisted before a remote write. An unresolved creation is never automatically replayed.
public struct ScheduleReceipt: Codable, Sendable {
    public let owner: ScheduleOwner
    public let providerID: ProviderID
    public let schedule: DeviceSchedule
    public let previousSchedule: DeviceSchedule?
    public let remoteID: String?
    public let verification: ScheduleVerification
    public let verifiedAt: Date?
    public init(owner: ScheduleOwner, providerID: ProviderID, schedule: DeviceSchedule,
                previousSchedule: DeviceSchedule? = nil, remoteID: String? = nil,
                verification: ScheduleVerification, verifiedAt: Date? = nil) {
        self.owner = owner; self.providerID = providerID; self.schedule = schedule
        self.previousSchedule = previousSchedule; self.remoteID = remoteID
        self.verification = verification; self.verifiedAt = verifiedAt
    }
    public func hasSameIdentity(as other: ScheduleReceipt) -> Bool {
        owner == other.owner && providerID == other.providerID && schedule.deviceID == other.schedule.deviceID && schedule.id == other.schedule.id
    }
}

public protocol ScheduleStore: Actor {
    func receipts(owner: ScheduleOwner, providerID: ProviderID, deviceID: DeviceID) async throws -> [ScheduleReceipt]
    func save(_ receipt: ScheduleReceipt) async throws
    func remove(_ receipt: ScheduleReceipt) async throws
    /// Holds a per-owner/device lease across remote I/O as well as journal reads/writes.
    func withExclusiveOperation<T: Sendable>(owner: ScheduleOwner, providerID: ProviderID, deviceID: DeviceID,
                                           operation: @Sendable () async throws -> T) async throws -> T
}

public extension ScheduleStore {
    /// Custom stores must implement a shared operation lease before they can mutate schedules.
    func withExclusiveOperation<T: Sendable>(owner: ScheduleOwner, providerID: ProviderID, deviceID: DeviceID,
                                           operation: @Sendable () async throws -> T) async throws -> T {
        throw IoTError.notSupported("The schedule store does not provide exclusive operations")
    }
}

/// Local journal without credentials. Supply an app-owned, protected Application Support URL.
/// Records of other apps/instances/devices are retained. Corrupt data is surfaced, never reset.
public actor FileScheduleStore: ScheduleStore {
    private struct Document: Codable { var version = 1; var receipts: [ScheduleReceipt] = [] }
    private struct Identity: Hashable {
        let owner: ScheduleOwner
        let provider: ProviderID
        let device: DeviceID
        let schedule: ScheduleID
        init(_ receipt: ScheduleReceipt) {
            owner = receipt.owner; provider = receipt.providerID
            device = receipt.schedule.deviceID; schedule = receipt.schedule.id
        }
    }
    private let url: URL
    private let maxBytes = 1_048_576
    public init(url: URL) { self.url = url }

    public func withExclusiveOperation<T: Sendable>(owner: ScheduleOwner, providerID: ProviderID, deviceID: DeviceID,
                                                  operation: @Sendable () async throws -> T) async throws -> T {
        guard url.isFileURL else { throw IoTError.notConfigured }
        guard [owner.appID, providerID.rawValue, deviceID.rawValue].allSatisfy({
            !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0")
        }) else { throw IoTError.notConfigured }
        let identity = try JSONEncoder().encode([owner.appID, owner.installationID.uuidString,
                                                providerID.rawValue, deviceID.rawValue])
        // Fixed 256 shards bound the number of lock files even with changing device identities.
        // A hash collision only serializes unrelated operations; it never changes ownership.
        let suffix = SHA256.hash(data: identity).prefix(1).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Separate from the short JSON-file lock: the operation can re-enter this store to save
        // its pending receipt while this descriptor still excludes another app/extension instance.
        let descriptor = Darwin.open(url.appendingPathExtension("operation-" + suffix + ".lock").path,
                                     O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw IoTError.transport("Unable to open schedule operation lock") }
        defer { Darwin.close(descriptor) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let lockFile: (Int32, Int32) -> Int32 = flock
        while lockFile(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw IoTError.transport("Unable to lock schedule operation") }
            guard ContinuousClock.now < deadline else { throw IoTError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
        defer { _ = lockFile(descriptor, LOCK_UN) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func read() throws -> Document {
        guard url.isFileURL else { throw IoTError.notConfigured }
        guard FileManager.default.fileExists(atPath: url.path) else { return Document() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw IoTError.invalidResponse }
        let document = try JSONDecoder().decode(Document.self, from: data)
        try validate(document)
        return document
    }

    private func validate(_ document: Document) throws {
        guard document.version == 1, document.receipts.count <= 1024,
              Set(document.receipts.map(Identity.init)).count == document.receipts.count,
              document.receipts.allSatisfy({ receipt in
                  let ids = [receipt.owner.appID, receipt.providerID.rawValue, receipt.schedule.deviceID.rawValue, receipt.schedule.id.rawValue]
                  return ids.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }
                    && receipt.schedule.start.timeIntervalSince1970.isFinite
                    && (receipt.schedule.timeZoneIdentifier.map { TimeZone(identifier: $0) != nil } ?? true)
              }) else { throw IoTError.invalidResponse }
        for receipt in document.receipts {
            if let previous = receipt.previousSchedule {
                guard previous.id == receipt.schedule.id, previous.deviceID == receipt.schedule.deviceID else { throw IoTError.invalidResponse }
            }
        }
    }

    /// A separate lock inode survives atomic replacement of the JSON file. flock coordinates
    /// independent actors and app/extension processes; nonblocking acquisition keeps waits cancellable.
    private func withFileLock<T: Sendable>(_ operation: () throws -> T) async throws -> T {
        guard url.isFileURL else { throw IoTError.notConfigured }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw IoTError.transport("Unable to open schedule journal lock") }
        defer { Darwin.close(descriptor) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let lockFile: (Int32, Int32) -> Int32 = flock
        while lockFile(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw IoTError.transport("Unable to lock schedule journal") }
            guard ContinuousClock.now < deadline else { throw IoTError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
        defer { _ = lockFile(descriptor, LOCK_UN) }
        try Task.checkCancellation()
        return try operation()
    }

    private func write(_ document: Document) throws {
        try validate(document)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= maxBytes else { throw IoTError.invalidResponse }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }

    public func receipts(owner: ScheduleOwner, providerID: ProviderID, deviceID: DeviceID) async throws -> [ScheduleReceipt] {
        try await withFileLock {
            try read().receipts.filter { $0.owner == owner && $0.providerID == providerID && $0.schedule.deviceID == deviceID }
        }
    }
    public func save(_ receipt: ScheduleReceipt) async throws {
        try await withFileLock {
            var document = try read()
            document.receipts.removeAll { $0.hasSameIdentity(as: receipt) }
            document.receipts.append(receipt)
            try write(document)
        }
    }
    public func remove(_ receipt: ScheduleReceipt) async throws {
        try await withFileLock {
            var document = try read()
            document.receipts.removeAll { $0.hasSameIdentity(as: receipt) }
            try write(document)
        }
    }
}

/// Fixture/preview store. Production scheduling must use a durable store.
public actor MemoryScheduleStore: ScheduleStore {
    private var records: [ScheduleReceipt] = []
    private struct OperationIdentity: Hashable {
        let owner: ScheduleOwner
        let provider: ProviderID
        let device: DeviceID
    }
    private var operations: Set<OperationIdentity> = []
    public init() {}
    public func withExclusiveOperation<T: Sendable>(owner: ScheduleOwner, providerID: ProviderID, deviceID: DeviceID,
                                                  operation: @Sendable () async throws -> T) async throws -> T {
        let identity = OperationIdentity(owner: owner, provider: providerID, device: deviceID)
        guard operations.insert(identity).inserted else { throw IoTError.unconfirmed }
        defer { operations.remove(identity) }
        try Task.checkCancellation()
        return try await operation()
    }
    public func receipts(owner: ScheduleOwner, providerID: ProviderID, deviceID: DeviceID) -> [ScheduleReceipt] {
        records.filter { $0.owner == owner && $0.providerID == providerID && $0.schedule.deviceID == deviceID }
    }
    public func save(_ receipt: ScheduleReceipt) {
        records.removeAll { $0.hasSameIdentity(as: receipt) }; records.append(receipt)
    }
    public func remove(_ receipt: ScheduleReceipt) { records.removeAll { $0.hasSameIdentity(as: receipt) } }
}
