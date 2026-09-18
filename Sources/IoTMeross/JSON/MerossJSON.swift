import Foundation
import IoTCore

#if canImport(Darwin)
/// Plain JSON value. Meross payloads are free-form and vary by firmware; decode loosely, map strictly later.
indirect enum MerossJSON: Codable, Hashable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([MerossJSON]), object([String: MerossJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([MerossJSON].self) { self = .array(value) }
        else if let value = try? container.decode([String: MerossJSON].self) { self = .object(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON") }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value == value.rounded(), abs(value) < 9_007_199_254_740_992 { try container.encode(Int64(value)) }
            else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> MerossJSON? { if case .object(let o) = self { return o[key] }; return nil }
    subscript(index: Int) -> MerossJSON? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }; return nil
    }
    var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    var doubleValue: Double? { if case .number(let v) = self { return v }; return nil }
    var intValue: Int? {
        guard case .number(let v) = self, v == v.rounded(), abs(v) < Double(Int.max) else { return nil }
        return Int(v)
    }
    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    var arrayValue: [MerossJSON]? { if case .array(let v) = self { return v }; return nil }
    var objectValue: [String: MerossJSON]? { if case .object(let v) = self { return v }; return nil }

    func stateValue() -> StateValue {
        switch self {
        case .null: .null
        case .bool(let v): .bool(v)
        case .number(let v):
            if let i = intValue { .integer(Int64(i)) } else { .decimal(v) }
        case .string(let v): .string(v)
        case .array(let v): .array(v.map { $0.stateValue() })
        case .object(let v): .object(v.mapValues { $0.stateValue() })
        }
    }
}
#endif
