import Foundation
import IoTCore

/// A Home Assistant entity state (`GET /api/states/<id>` or a `state_changed` event's `new_state`).
/// Decodes only what we map to `DeviceState`; the full attribute bag is intentionally not modelled.
public struct HAEntityState: Sendable, Equatable, Decodable {
    public let entityID: String
    public let state: String
    public let friendlyName: String?
    public let brightness: Int?     // HA reports 0…255

    enum CodingKeys: String, CodingKey { case entityID = "entity_id", state, attributes }
    enum AttrKeys: String, CodingKey { case friendlyName = "friendly_name", brightness }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entityID = try c.decode(String.self, forKey: .entityID)
        state = try c.decode(String.self, forKey: .state)
        if let a = try? c.nestedContainer(keyedBy: AttrKeys.self, forKey: .attributes) {
            friendlyName = try? a.decodeIfPresent(String.self, forKey: .friendlyName)
            brightness = try? a.decodeIfPresent(Int.self, forKey: .brightness)
        } else {
            friendlyName = nil; brightness = nil
        }
    }

    public init(entityID: String, state: String, friendlyName: String? = nil, brightness: Int? = nil) {
        self.entityID = entityID; self.state = state; self.friendlyName = friendlyName; self.brightness = brightness
    }

    /// Map to the vendor-neutral `DeviceState`. `unavailable`/`unknown` → offline.
    public func deviceState(sequence: UInt64, observedAt: Date = Date()) -> DeviceState {
        let available: DeviceAvailability = (state == "unavailable" || state == "unknown") ? .offline : .online
        let primary: StateValue? = available == .online ? .bool(state == "on") : nil
        var attrs: [String: StateAttribute] = [:]
        if let brightness {
            let pct = Int((Double(brightness) / 255.0 * 100).rounded())
            attrs["level"] = StateAttribute(value: .integer(Int64(pct)), unit: .percent, displayName: "Brightness")
        }
        return DeviceState(deviceID: DeviceID(rawValue: entityID), availability: available,
                           primaryValue: primary, attributes: attrs, observedAt: observedAt,
                           origin: .bridge, revision: StateRevision(localSequence: sequence))
    }

    /// The device's on/off, or nil when offline/unknown.
    public var isOn: Bool? {
        (state == "unavailable" || state == "unknown") ? nil : (state == "on")
    }
}

/// The domain (`light`, `switch`, `fan`…) inferred from an entity id like `light.kitchen`.
public func haDomain(of entityID: String) -> String {
    entityID.split(separator: ".").first.map(String.init) ?? "homeassistant"
}

// MARK: - WebSocket message envelope

/// Inbound WS messages we care about (auth phase + subscribed events + command results).
public enum HAMessage: Sendable {
    case authRequired
    case authOK
    case authInvalid(String)
    case result(id: Int, success: Bool)
    case stateChanged(HAEntityState)
    case pong(id: Int)
    case other(type: String)

    /// Decode from a raw WS text frame.
    public static func decode(_ data: Data) -> HAMessage? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch type {
        case "auth_required": return .authRequired
        case "auth_ok": return .authOK
        case "auth_invalid": return .authInvalid((obj["message"] as? String) ?? "auth invalid")
        case "pong": return .pong(id: (obj["id"] as? Int) ?? 0)
        case "result": return .result(id: (obj["id"] as? Int) ?? 0, success: (obj["success"] as? Bool) ?? false)
        case "event":
            guard let event = obj["event"] as? [String: Any],
                  (event["event_type"] as? String) == "state_changed",
                  let dataDict = event["data"] as? [String: Any],
                  let newState = dataDict["new_state"],
                  let json = try? JSONSerialization.data(withJSONObject: newState),
                  let entity = try? JSONDecoder().decode(HAEntityState.self, from: json) else {
                return .other(type: "event")
            }
            return .stateChanged(entity)
        default: return .other(type: type)
        }
    }
}

/// Build outbound WS frames (auth, subscribe, ping). Monotonic ids are the caller's responsibility.
public enum HAOutbound {
    public static func auth(token: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["type": "auth", "access_token": token])) ?? Data()
    }
    public static func subscribeStateChanged(id: Int) -> Data {
        (try? JSONSerialization.data(withJSONObject: [
            "id": id, "type": "subscribe_events", "event_type": "state_changed"])) ?? Data()
    }
    public static func ping(id: Int) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["id": id, "type": "ping"])) ?? Data()
    }
}
