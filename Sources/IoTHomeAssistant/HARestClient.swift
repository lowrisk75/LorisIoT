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
        let (data, status) = try await http.send(method: "GET", path: "api/states/\(entityID)", body: nil)
        try Self.check(status)
        do { return try JSONDecoder().decode(HAEntityState.self, from: data) }
        catch { throw ProviderError.invalidResponse }
    }

    /// All entity states (initial snapshot; then keep live via the WebSocket).
    public func states() async throws -> [HAEntityState] {
        let (data, status) = try await http.send(method: "GET", path: "api/states", body: nil)
        try Self.check(status)
        do { return try JSONDecoder().decode([HAEntityState].self, from: data) }
        catch { throw ProviderError.invalidResponse }
    }

    /// Call a service, e.g. `light.turn_on` on `light.kitchen` with `{brightness_pct: 60}`.
    public func callService(domain: String, service: String, entityID: String,
                            data: [String: Int] = [:]) async throws {
        var body: [String: Any] = ["entity_id": entityID]
        for (k, v) in data { body[k] = v }
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (_, status) = try await http.send(method: "POST",
                                              path: "api/services/\(domain)/\(service)", body: payload)
        try Self.check(status)
    }

    /// Set an `input_datetime` helper — the server-side pre-provisioning primitive for scheduled wakes.
    public func setInputDatetime(entityID: String, isoDate: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["entity_id": entityID, "datetime": isoDate])
        let (_, status) = try await http.send(method: "POST",
                                              path: "api/services/input_datetime/set_datetime", body: body)
        try Self.check(status)
    }

    private static func check(_ status: Int) throws {
        switch status {
        case 200...299: return
        case 401, 403: throw ProviderError.authenticationFailed(reason: "HTTP \(status)")
        case 404: throw ProviderError.invalidResponse
        default: throw ProviderError.transport("HTTP \(status)")
        }
    }
}
