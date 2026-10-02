import Foundation
import IoTCore

/// One immutable, owned session. Persist this request BEFORE arm; reuse its nonce after a lost response.
/// OFF is conditional on a confirmed ON and retained HA context, not an independent power schedule.
public struct HASunriseRequest: Codable, Equatable, Sendable {
    public let remoteID: UUID
    public let owner: ScheduleOwner
    public let providerID: String
    public let scheduleID: String
    public let deviceID: String
    public let on: Bool
    public let enabled: Bool
    public let start: Double
    public let level: Double
    public let transition: Double
    public let autoOffAt: Double
    public let sunriseProfile: String?

    public init(remoteID: UUID, owner: ScheduleOwner, deviceID: String, start: Date, wake: Date,
                autoOffMinutes: Int, brightness: Int, sunriseProfile: String? = nil) throws {
        self.sunriseProfile = sunriseProfile
        guard sunriseProfile == nil || sunriseProfile == "gentle-v1" else { throw IoTError.notConfigured }
        self.remoteID = remoteID; self.owner = owner; self.deviceID = deviceID
        providerID = "sunrise-session.v1"; scheduleID = remoteID.uuidString.lowercased()
        on = true; enabled = true; self.start = start.timeIntervalSince1970
        transition = wake.timeIntervalSince(start)
        guard (1...180).contains(autoOffMinutes), (1...100).contains(brightness),
              deviceID.hasPrefix("light."), HARestClient.isEntityID(deviceID),
              owner.appID.range(of: "^[A-Za-z0-9_.:-]{1,256}$", options: .regularExpression) != nil,
              self.start.isFinite, transition.isFinite, (60...1800).contains(transition) else {
            throw IoTError.notConfigured
        }
        level = Double(brightness) / 100
        autoOffAt = wake.addingTimeInterval(Double(autoOffMinutes) * 60).timeIntervalSince1970
    }

    func validate() throws {
        let minutes = (autoOffAt - start - transition) / 60
        guard minutes.isFinite, (1...180).contains(minutes), minutes.rounded() == minutes,
              level.isFinite, (0.01...1).contains(level) else { throw IoTError.notConfigured }
        let canonical = try Self(remoteID: remoteID, owner: owner, deviceID: deviceID,
            start: Date(timeIntervalSince1970: start), wake: Date(timeIntervalSince1970: start + transition),
            autoOffMinutes: Int(minutes), brightness: Int((level * 100).rounded()), sunriseProfile: sunriseProfile)
        guard self == canonical else { throw IoTError.notConfigured }
    }
}

public struct HASunriseReceipt: Decodable, Sendable {
    public enum State: String, Codable, Sendable {
        case armed, disabled, executing, holding, offExecuting, completed, overridden
        case uncertain, missed, expired, removed
    }
    public let request: HASunriseRequest
    public let revision: Int
    public let state: State
    private enum CodingKeys: String, CodingKey { case revision, state }
    public init(from decoder: any Decoder) throws {
        request = try HASunriseRequest(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(Int.self, forKey: .revision)
        state = try container.decode(State.self, forKey: .state)
        guard revision > 0 else { throw IoTError.invalidResponse }
    }
}

/// No auto-install, retries, timers or global selectors. HAHTTP owns credentials/transport policy.
public actor HASunriseClient {
    private let http: any HAHTTP
    private let prefix = "api/lorisiot_schedule/v1/"
    public init(http: any HAHTTP) { self.http = http }

    public func read(_ request: HASunriseRequest) async throws -> HASunriseReceipt? {
        try request.validate()
        let (data, status) = try await http.send(method: "GET", path: path(request), body: nil)
        if status == 404 { return nil }
        try check(status)
        return try receipt(data, matching: request)
    }

    public func arm(_ request: HASunriseRequest, now: Date = Date()) async throws -> HASunriseReceipt {
        try request.validate()
        let health = try await HAScheduleAPI(http: http).health()
        guard health.sunriseAutoOffVersion == 1, health.allowedTargets.contains(request.deviceID),
              abs(health.serverTime - now.timeIntervalSince1970) <= 5 else {
            throw IoTError.notSupported("A compatible sunrise server and target are required")
        }
        guard request.sunriseProfile == nil || health.gentleSunriseVersion == 1 else {
            throw IoTError.notSupported("The gentle wake profile requires an updated sunrise component")
        }
        // Reconcile even after the deadline: never recreate a consumed/cancelled session.
        if let existing = try await read(request) { return existing }
        guard (20...366 * 86400).contains(request.start - now.timeIntervalSince1970) else {
            throw IoTError.notSupported("Sunrise requires at least 20 seconds of preparation")
        }
        struct Body: Encodable { let record: HASunriseRequest }
        let (data, status) = try await http.send(method: "POST", path: prefix + "records",
            body: JSONEncoder().encode(Body(record: request)))
        try check(status)
        _ = try receipt(data, matching: request)
        guard let verified = try await read(request) else { throw IoTError.unconfirmed }
        return verified
    }

    public func cancel(_ request: HASunriseRequest) async throws {
        // A bare 404 is not cancellation. For a fully elapsed absent session, require the
        // server to persist an exact tombstone that also prevents a delayed replay.
        guard let current = try await read(request) else {
            struct Retirement: Encodable { let record: HASunriseRequest }
            let (data, status) = try await http.send(method: "POST", path: prefix + "retire",
                body: JSONEncoder().encode(Retirement(record: request)))
            try check(status)
            guard try receipt(data, matching: request).state == .removed,
                  try await read(request)?.state == .removed else { throw IoTError.unconfirmed }
            return
        }
        if current.state == .removed { return }
        guard current.state != .executing, current.state != .offExecuting, current.state != .uncertain else {
            throw IoTError.unconfirmed
        }
        struct Body: Encodable { let owner: ScheduleOwner; let expectedRevision: Int }
        let (data, status) = try await http.send(method: "DELETE", path: path(request),
            body: JSONEncoder().encode(Body(owner: request.owner, expectedRevision: current.revision)))
        try check(status)
        guard try receipt(data, matching: request).state == .removed,
              try await read(request)?.state == .removed else { throw IoTError.unconfirmed }
    }

    private func path(_ request: HASunriseRequest) -> String {
        prefix + "records/" + request.remoteID.uuidString.lowercased()
    }
    private func receipt(_ data: Data, matching request: HASunriseRequest) throws -> HASunriseReceipt {
        guard data.count <= 65_536 else { throw IoTError.invalidResponse }
        let value = try JSONDecoder().decode(HASunriseReceipt.self, from: data)
        guard value.request == request else { throw IoTError.unconfirmed }
        return value
    }
    private func check(_ status: Int) throws {
        switch status {
        case 200...299: return
        case 401, 403: throw IoTError.authenticationFailed(reason: "Sunrise scheduling requires authorization")
        case 404: throw IoTError.notSupported("Sunrise scheduling is not installed")
        case 409: throw IoTError.unconfirmed
        default: throw IoTError.invalidResponse
        }
    }
}
