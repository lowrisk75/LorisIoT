import Foundation
import IoTCore

public enum MQTTQoS: Int, Sendable, Codable, Hashable { case atMostOnce = 0, atLeastOnce = 1, exactlyOnce = 2 }

public struct MQTTObservation: Sendable {
    public let topic: String
    public let payload: Data
    /// nil means the custom transport does not supply retained metadata.
    public let retained: Bool?
    public init(topic: String, payload: Data, retained: Bool? = nil) {
        self.topic = topic; self.payload = payload; self.retained = retained
    }
}

/// Injectable MQTT transport so the mapping/provider is unit-testable with a mock. The production
/// implementation is isolated in IoTMQTTCocoa; broker-library types stay behind this boundary.
public protocol MQTTTransport: Sendable {
    func connect() async throws
    func disconnect() async
    func subscribe(topic: String) async throws
    /// QoS 0 confirms enqueueing; QoS 1/2 await broker acknowledgement in the production transport.
    /// Broker delivery never substitutes for the device's state confirmation.
    func publish(topic: String, payload: Data, qos: MQTTQoS, retain: Bool) async throws
    /// All inbound (topic, payload) frames after subscription. Retained messages give last-known state.
    func messages() async -> AsyncStream<(topic: String, payload: Data)>
    func observations() async -> AsyncStream<MQTTObservation>
}

public extension MQTTTransport {
    func observations() async -> AsyncStream<MQTTObservation> {
        let frames = await messages()
        return AsyncStream(bufferingPolicy: .bufferingOldest(64)) { c in
            let task = Task {
                for await frame in frames {
                    guard !Task.isCancelled else { break }
                    if case .dropped = c.yield(MQTTObservation(topic: frame.topic, payload: frame.payload)) { break }
                }
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
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
    public let kind: DeviceKind
    public let jsonMapping: MQTTJSONStateMapping?
    public let availabilityTopic: String?
    public init(id: DeviceID, name: String, stateTopic: String, commandTopic: String,
                onToken: String = "ON", offToken: String = "OFF", kind: DeviceKind = .switchDevice,
                jsonMapping: MQTTJSONStateMapping? = nil, availabilityTopic: String? = nil) {
        self.id = id; self.name = name; self.stateTopic = stateTopic; self.commandTopic = commandTopic
        self.onToken = onToken; self.offToken = offToken
        self.kind = kind; self.jsonMapping = jsonMapping
        self.availabilityTopic = availabilityTopic
    }

    /// Decode a state payload → on/off, or nil if it matches neither token.
    public func parse(_ payload: Data) -> Bool? {
        let s = String(data: payload, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if s == onToken { return true }
        if s == offToken { return false }
        return nil
    }
    /// Encode an on/off command → payload.
    public func render(_ on: Bool) -> Data {
        if let property = jsonMapping?.powerProperty {
            return (try? JSONSerialization.data(withJSONObject: [property: on ? onToken : offToken], options: [.sortedKeys])) ?? Data()
        }
        return Data((on ? onToken : offToken).utf8)
    }
}
