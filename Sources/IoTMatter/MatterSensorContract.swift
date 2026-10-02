import Foundation
import IoTCore

/// An endpoint on an already commissioned node. Names are presentation data, never authority.
public struct MatterSensorConfiguration: Hashable, Sendable {
    public let nodeID: UInt64
    public let endpointID: UInt16
    public let name: String
    public init(nodeID: UInt64, endpointID: UInt16, name: String) throws {
        guard nodeID > 0, nodeID != .max, endpointID != .max,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256 else {
            throw IoTError.notConfigured
        }
        self.nodeID = nodeID; self.endpointID = endpointID; self.name = name
    }
    func deviceID(fabric: UUID) -> DeviceID {
        DeviceID(rawValue: "\(fabric.uuidString.lowercased())/\(nodeID)/\(endpointID)")
    }
}

enum MatterMeasurement: UInt32, CaseIterable, Hashable, Sendable {
    case temperature = 0x0402, humidity = 0x0405
    var key: String { self == .temperature ? "temperature" : "humidity" }
    var unit: UnitSymbol { self == .temperature ? .celsius : .percent }
    func decode(_ value: MatterRawValue) throws -> Double? {
        switch value {
        case .null: return nil
        case .invalid: throw IoTError.invalidResponse
        case .integer(let value):
            let range: ClosedRange<Int64> = self == .temperature ? -27315...32767 : 0...10000
            guard range.contains(value) else { throw IoTError.invalidResponse }
            return Double(value) / 100
        }
    }
}
enum MatterRawValue: Sendable, Equatable { case integer(Int64), null, invalid }
struct MatterSensorDescription: Sendable {
    let id: DeviceID
    let name: String
    let measurements: Set<MatterMeasurement>
}
enum MatterReport: Sendable {
    case values(deviceID: DeviceID, values: [MatterMeasurement: MatterRawValue], cached: Bool)
    case unavailable(deviceID: DeviceID)
}
protocol MatterSensorTransport: Sendable {
    func connect() async throws
    func disconnect() async
    func sensors() async throws -> [MatterSensorDescription]
    func read(_ id: DeviceID) async throws -> [MatterMeasurement: MatterRawValue]
    func reports() async -> AsyncStream<MatterReport>
}
