import Foundation

/// One app-owned instance per actuator. Save the start before sending ON; clear only after confirmed OFF.
public protocol ActuatorRuntimeStore: Actor {
    func startedAt() async throws -> Date?
    func setStartedAt(_ date: Date?) async throws
}

/// Durable checkpoint for one configured actuator. Use a different app-owned URL for every connection/device.
public actor FileActuatorRuntimeStore: ActuatorRuntimeStore {
    private struct Checkpoint: Codable { let version: Int; let startedAt: Date? }
    private let url: URL
    public init(url: URL) { self.url = url }
    public func startedAt() throws -> Date? {
        guard url.isFileURL else { throw IoTError.notConfigured }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: 4097) ?? Data()
        guard data.count <= 4096 else { throw IoTError.invalidResponse }
        let value = try JSONDecoder().decode(Checkpoint.self, from: data)
        guard value.version == 1, value.startedAt?.timeIntervalSince1970.isFinite ?? true else { throw IoTError.invalidResponse }
        return value.startedAt
    }
    public func setStartedAt(_ date: Date?) throws {
        guard url.isFileURL, date?.timeIntervalSince1970.isFinite ?? true else { throw IoTError.notConfigured }
        // A new start cannot overwrite a damaged checkpoint. A caller-confirmed stop may repair it.
        if date != nil { _ = try startedAt() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Checkpoint(version: 1, startedAt: date))
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}
