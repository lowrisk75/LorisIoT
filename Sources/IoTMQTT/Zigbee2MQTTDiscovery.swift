import Foundation
import IoTCore

/// Parses the retained bridge/devices inventory. No commands or pairing requests are published.
public enum Zigbee2MQTTDiscovery {
    public static func devices(from data: Data, baseTopic: String = "zigbee2mqtt") throws -> [MQTTDeviceMap] {
        guard data.count <= 1_048_576, validTopic(baseTopic),
              let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              rows.count <= 1000 else { throw IoTError.invalidResponse }
        var result: [MQTTDeviceMap] = []
        var identities = Set<String>()
        var names = Set<String>()
        for row in rows {
            guard row["disabled"] as? Bool != true, row["supported"] as? Bool == true,
                  let id = row["ieee_address"] as? String, !id.isEmpty,
                  let name = row["friendly_name"] as? String, validTopic(name), validFriendlyName(name),
                  let definition = row["definition"] as? [String: Any],
                  let exposed = definition["exposes"] as? [[String: Any]] else { continue }
            guard identities.insert(id).inserted, names.insert(name).inserted else { throw IoTError.invalidResponse }
            let properties = try flatten(exposed, depth: 0)
            let numeric = properties.compactMap { p -> MQTTNumericProperty? in
                guard p["type"] as? String == "numeric", let key = p["property"] as? String,
                      let access = p["access"] as? Int, access & 1 != 0 else { return nil }
                return MQTTNumericProperty(key, unit: unit(p["unit"] as? String))
            }
            let power = properties.first { p in
                p["type"] as? String == "binary" && p["property"] as? String == "state"
                    && (p["access"] as? Int ?? 0) & 1 != 0
                    && p["value_on"] as? String == "ON" && p["value_off"] as? String == "OFF"
            }
            let control = (power?["access"] as? Int ?? 0) & 2 != 0
            let primary = power != nil ? "state" : numeric.first { $0.key == "temperature" }?.key ?? numeric.first?.key
            guard let primary else { continue }
            let topic = "\(baseTopic)/\(name)"
            result.append(MQTTDeviceMap(id: DeviceID(rawValue: id), name: name, stateTopic: topic,
                commandTopic: control ? "\(topic)/set" : "", kind: power == nil ? .sensor : .switchDevice,
                jsonMapping: MQTTJSONStateMapping(primary: primary, numericProperties: numeric,
                                                  powerProperty: power == nil ? nil : "state"),
                availabilityTopic: "\(topic)/availability"))
        }
        return result.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private static func flatten(_ entries: [[String: Any]], depth: Int) throws -> [[String: Any]] {
        guard depth <= 8, entries.count <= 256 else { throw IoTError.invalidResponse }
        var result: [[String: Any]] = []
        for entry in entries {
            result.append(entry)
            if let children = entry["features"] as? [[String: Any]] {
                result += try flatten(children, depth: depth + 1)
            }
            guard result.count <= 256 else { throw IoTError.invalidResponse }
        }
        return result
    }

    /// Rejects names that would alias the bridge's own topics or another device's command/get/availability topics.
    static func validFriendlyName(_ name: String) -> Bool {
        let segments = name.split(separator: "/", omittingEmptySubsequences: false)
        return segments.first != "bridge" && !segments.contains { $0.isEmpty || ["set", "get", "availability"].contains($0) }
    }

    static func validTopic(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 65535 && !value.contains("#")
            && !value.contains("+") && !value.contains("\0")
    }

    private static func unit(_ symbol: String?) -> UnitSymbol? {
        switch symbol {
        case "°C": .celsius
        case "°F": .fahrenheit
        case "%": .percent
        case "W": .watt
        case "kWh": .kilowattHour
        case "V": .volt
        case "A": .ampere
        case "lx": .lux
        case "ppm": .ppm
        default: nil
        }
    }
}
