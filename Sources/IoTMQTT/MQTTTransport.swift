import Foundation
import IoTCore

public enum MQTTQoS: Int, Sendable, Codable, Hashable { case atMostOnce = 0, atLeastOnce = 1, exactlyOnce = 2 }

/// Injectable MQTT transport so the mapping/provider is unit-testable with a mock. The production
/// impl (MQTTNIO, isolated dependency per the spec) is added behind this protocol — the mapping,
/// provider and capability logic never touch MQTTNIO types, so the lib is swappable.
public protocol MQTTTransport: Sendable {
    func connect() async throws
    func disconnect() async
    func subscribe(topic: String) async throws
    func publish(topic: String, payload: Data, qos: MQTTQoS, retain: Bool) async throws
    /// All inbound (topic, payload) frames after subscription. Retained messages give last-known state.
    func messages() async -> AsyncStream<(topic: String, payload: Data)>
}

/// Maps one MQTT device to its topics + on/off token, decoupling the broker's topic tree from the
/// Core domain (the Core never sees topics/QoS/retained). Payload is a simple string token by
/// default; richer JSON mapping can be added without changing the provider.
public struct MQTTDeviceMap: Sendable, Hashable, Identifiable {
    public let id: DeviceID
    public let name: String
    public let stateTopic: String
    public let commandTopic: String
    public let onToken: String
    public let offToken: String
    public init(id: DeviceID, name: String, stateTopic: String, commandTopic: String,
                onToken: String = "ON", offToken: String = "OFF") {
        self.id = id; self.name = name; self.stateTopic = stateTopic; self.commandTopic = commandTopic
        self.onToken = onToken; self.offToken = offToken
    }

    /// Decode a state payload → on/off, or nil if it matches neither token.
    public func parse(_ payload: Data) -> Bool? {
        let s = String(data: payload, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if s == onToken { return true }
        if s == offToken { return false }
        return nil
    }
    /// Encode an on/off command → payload.
    public func render(_ on: Bool) -> Data { Data((on ? onToken : offToken).utf8) }
}
