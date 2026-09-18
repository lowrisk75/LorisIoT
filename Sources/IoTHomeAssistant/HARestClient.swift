import Foundation
import IoTCore

/// Home Assistant REST client — the request/response half (initial state, service calls, provisioning).
/// Live updates come from the WebSocket (see `HomeAssistantProvider`). Status mapping distinguishes
/// auth failures (401/403 → re-auth) from transport/other so recovery is driven correctly.
public actor HARestClient {
    private let http: HAHTTP

    public init(http: HAHTTP) { self.http = http }

    /// Cheap reachability probe — `GET /api/` (a few bytes). Never fetch the full entity list for status.
    public func verify() async throws -> Bool {
        let (_, status) = try await http.send(method: "GET", path: "api/", body: nil)
        try Self.check(status)
        return true
    }

    /// One entity's current state.
    public func state(entityID: String) async throws -> HAEntityState {
        guard Self.isEntityID(entityID) else { throw IoTError.notConfigured }
        let (data, status) = try await http.send(method: "GET", path: "api/states/\(entityID)", body: nil)
        try Self.check(status)
        do {
            let state = try JSONDecoder().decode(HAEntityState.self, from: data)
            guard state.entityID == entityID else { throw IoTError.invalidResponse }
            return state
        }
        catch { throw IoTError.invalidResponse }
    }

    /// All entity states (initial snapshot; then keep live via the WebSocket).
    public func states() async throws -> [HAEntityState] {
        let (data, status) = try await http.send(method: "GET", path: "api/states", body: nil)
        try Self.check(status)
        do { return try JSONDecoder().decode([HAEntityState].self, from: data) }
        catch { throw IoTError.invalidResponse }
    }

    /// Call a service, e.g. `light.turn_on` on `light.kitchen` with `{brightness_pct: 60,
    /// transition: 2.5}` — arbitrary JSON-encodable service data.
    public func callService(domain: String, service: String, entityID: String,
                            data: [String: any Sendable] = [:]) async throws {
        guard Self.isIdentifier(domain), Self.isIdentifier(service), Self.isEntityID(entityID),
              Set(data.keys).isDisjoint(with: ["entity_id", "device_id", "area_id", "floor_id", "label_id", "target"]) else {
            throw IoTError.notConfigured
        }
        var body: [String: Any] = ["entity_id": entityID]
        for (k, v) in data { body[k] = v }
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (_, status) = try await http.send(method: "POST",
                                              path: "api/services/\(domain)/\(service)", body: payload)
        try Self.check(status)
    }

    /// Set an entity's state directly via `POST /api/states/<id>` — creates the entity when absent.
    /// The zero-HA-side-setup provisioning primitive (Velya publishes `sensor.velya_next_wake` this
    /// way and a server automation reacts to it).
    public func setState(entityID: String, state: String,
                         attributes: [String: any Sendable] = [:]) async throws {
        guard Self.isEntityID(entityID) else { throw IoTError.notConfigured }
        let body: [String: Any] = ["state": state, "attributes": attributes]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (_, status) = try await http.send(method: "POST",
                                              path: "api/states/\(entityID)", body: payload)
        try Self.check(status)
    }

    /// Raw body of `GET /api/states/<id>` — for apps whose domain needs more of the attribute bag
    /// than `HAEntityState` models (rule engines…). Auth/status mapping still applies.
    public func stateData(entityID: String) async throws -> Data {
        guard Self.isEntityID(entityID) else { throw IoTError.notConfigured }
        let (data, status) = try await http.send(method: "GET", path: "api/states/\(entityID)", body: nil)
        try Self.check(status)
        return data
    }

    /// Raw body of `GET /api/states` (byte-capped by the transport). See `stateData(entityID:)`.
    public func statesData() async throws -> Data {
        let (data, status) = try await http.send(method: "GET", path: "api/states", body: nil)
        try Self.check(status)
        return data
    }

    /// Set an `input_datetime` helper — the server-side pre-provisioning primitive for scheduled wakes.
    public func setInputDatetime(entityID: String, isoDate: String) async throws {
        guard Self.isEntityID(entityID), entityID.hasPrefix("input_datetime.") else { throw IoTError.notConfigured }
        let body = try JSONSerialization.data(withJSONObject: ["entity_id": entityID, "datetime": isoDate])
        let (_, status) = try await http.send(method: "POST",
                                              path: "api/services/input_datetime/set_datetime", body: body)
        try Self.check(status)
    }

    nonisolated static func isEntityID(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.utf8.count <= 255 && parts.count == 2 && parts.allSatisfy { isIdentifier(String($0)) }
    }

    private nonisolated static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }

    private static func check(_ status: Int) throws {
        switch status {
        case 200...299: return
        case 401, 403: throw IoTError.authenticationFailed(reason: "HTTP \(status)")
        case 404: throw IoTError.invalidResponse
        default: throw IoTError.transport("HTTP \(status)")
        }
    }
}
