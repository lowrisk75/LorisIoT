import Foundation
import CoreFoundation
import IoTCore

/// Explicit property mapping; unrecognized JSON never becomes a fabricated switch state.
public struct MQTTNumericProperty: Sendable, Hashable {
    public let key: String
    public let unit: UnitSymbol?
    public init(_ key: String, unit: UnitSymbol? = nil) { self.key = key; self.unit = unit }
}

public struct MQTTJSONStateMapping: Sendable, Hashable {
    public let primary: String
    public let numericProperties: [MQTTNumericProperty]
    public let powerProperty: String?
    public let observedAtProperty: String?
    public init(primary: String, numericProperties: [MQTTNumericProperty] = [],
                powerProperty: String? = nil, observedAtProperty: String? = "last_seen") {
        self.primary = primary; self.numericProperties = numericProperties
        self.powerProperty = powerProperty; self.observedAtProperty = observedAtProperty
    }
}

extension MQTTDeviceMap {
    public var supportsControl: Bool { !commandTopic.isEmpty && (jsonMapping == nil || jsonMapping?.powerProperty != nil) }

    func decodeState(_ data: Data) -> (value: StateValue, attributes: [String: StateAttribute], observedAt: Date?)? {
        guard let mapping = jsonMapping else {
            return parse(data).map { (.bool($0), [:], nil) }
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var attributes: [String: StateAttribute] = [:]
        for property in mapping.numericProperties {
            guard let number = root[property.key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { continue }
            attributes[property.key] = StateAttribute(value: .decimal(number.doubleValue), unit: property.unit)
        }
        if let property = mapping.powerProperty, let token = root[property] as? String,
           token == onToken || token == offToken {
            attributes[property] = StateAttribute(value: .bool(token == onToken))
        }
        guard let value = attributes[mapping.primary]?.value else { return nil }
        let date: Date?
        if let key = mapping.observedAtProperty, let raw = root[key] as? String {
            let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = format.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        } else if let key = mapping.observedAtProperty, let raw = root[key] as? NSNumber,
                  CFGetTypeID(raw) != CFBooleanGetTypeID(), raw.doubleValue.isFinite {
            // Zigbee2MQTT epoch mode is milliseconds.
            date = Date(timeIntervalSince1970: raw.doubleValue / 1000)
        } else { date = nil }
        return (value, attributes, date)
    }
}
