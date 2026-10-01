import Foundation
import IoTCore
#if canImport(Matter)
@preconcurrency import Matter

public extension MatterProvider {
    /// The factory transfers EXCLUSIVE ownership of a running, already commissioned controller.
    /// It must return a new controller on reconnect, backed by the same durable host-owned fabric.
    /// Never pass Apple Home's controller or a controller used by another app subsystem.
    /// Disconnect shuts this controller down; it does not delete its fabric, keys or pairings.
    @MainActor
    static func usingExclusiveController(fabricIdentity: UUID, sensors: [MatterSensorConfiguration],
        id: ProviderID = "matter", maxStateAge: TimeInterval = 60,
        makeController: @escaping @MainActor @Sendable () async throws -> MTRDeviceController) throws -> MatterProvider {
        guard !sensors.isEmpty, sensors.count <= 32,
              Set(sensors.map { $0.deviceID(fabric: fabricIdentity) }).count == sensors.count,
              maxStateAge.isFinite, maxStateAge > 0, !id.rawValue.isEmpty else { throw IoTError.notConfigured }
        return MatterProvider(transport: NativeMatterSensors(fabric: fabricIdentity, sensors: sensors,
            makeController: makeController), id: id, maxStateAge: maxStateAge)
    }
}

/// No generation, distribution or copying of fabric credentials occurs inside this transport.
/// Apple objects are confined to the main actor; callbacks export only closed Sendable values.
@MainActor
final class NativeMatterSensors: MatterSensorTransport {
    private static var controllerLeases = Set<ObjectIdentifier>()
    private let fabric: UUID
    private let configurations: [MatterSensorConfiguration]
    private let makeController: @MainActor @Sendable () async throws -> MTRDeviceController
    private var controller: MTRDeviceController?
    private var catalog: [DeviceID: MatterSensorDescription] = [:]
    private var addresses: [DeviceID: MatterSensorConfiguration] = [:]
    private var devices: [DeviceID: MTRBaseDevice] = [:]
    private var channel = AsyncStream<MatterReport>.makeStream(bufferingPolicy: .bufferingNewest(128))
    private var generation: UInt64 = 0

    init(fabric: UUID, sensors: [MatterSensorConfiguration],
         makeController: @escaping @MainActor @Sendable () async throws -> MTRDeviceController) {
        self.fabric = fabric; self.configurations = sensors; self.makeController = makeController
    }
    func connect() async throws {
        guard controller == nil else { return }
        generation &+= 1; let token = generation
        let candidate = try await makeController()
        let identity = ObjectIdentifier(candidate)
        guard !Self.controllerLeases.contains(identity) else { throw IoTError.notConfigured }
        // A provider cancelled while its factory ran must not adopt a late controller.
        guard token == generation, !Task.isCancelled else { candidate.shutdown(); throw CancellationError() }
        guard candidate.isRunning else { throw IoTError.notConfigured }
        Self.controllerLeases.insert(identity); controller = candidate
        channel = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(128))
        for config in configurations {
            let device = MTRBaseDevice(nodeID: NSNumber(value: config.nodeID), controller: candidate)
            let rows: [MatterNativeAttribute] = try await matterReadWithDeadline { completion in
                device.readAttributes(withEndpointID: NSNumber(value: config.endpointID), clusterID: 0x001D,
                    attributeID: 1, params: nil, queue: .main) { values, error in
                    completion(MatterNativeDecoder.result(values, error: error))
                }
            }
            guard token == generation, !Task.isCancelled else { throw CancellationError() }
            guard rows.count == 1, rows[0].endpoint == config.endpointID, rows[0].cluster == 0x001D,
                  rows[0].attribute == 1, case .clusters(let clusters) = rows[0].value else { throw IoTError.invalidResponse }
            let measurements = Set(MatterMeasurement.allCases.filter { clusters.contains($0.rawValue) })
            guard !measurements.isEmpty else { continue }
            let id = config.deviceID(fabric: fabric)
            catalog[id] = MatterSensorDescription(id: id, name: config.name, measurements: measurements)
            addresses[id] = config; devices[id] = device
        }
    }
    func sensors() -> [MatterSensorDescription] { catalog.values.sorted { $0.id.rawValue < $1.id.rawValue } }
    func reports() -> AsyncStream<MatterReport> {
        let continuation = channel.continuation
        for (id, device) in devices {
            guard let config = addresses[id], let sensor = catalog[id] else { continue }
            let params = MTRSubscribeParams(minInterval: 1, maxInterval: 60)
            params.shouldReplaceExistingSubscriptions = false
            params.shouldResubscribeAutomatically = true
            let paths = sensor.measurements.sorted { $0.rawValue < $1.rawValue }.map {
                MTRAttributeRequestPath(endpointID: NSNumber(value: config.endpointID), clusterID: NSNumber(value: $0.rawValue), attributeID: 0)
            }
            // Direct BaseDevice subscriptions prime with a network read, not MTRDevice's cache.
            device.subscribe(toAttributePaths: paths, eventPaths: nil, params: params, queue: .main,
                reportHandler: { values, error in
                    do {
                        let rows = try MatterNativeDecoder.result(values, error: error).get()
                        let decoded = try MatterNativeDecoder.measurements(rows, endpoint: config.endpointID, allowed: sensor.measurements)
                        if !decoded.isEmpty { continuation.yield(.values(deviceID: id, values: decoded, cached: false)) }
                    } catch { continuation.yield(.unavailable(deviceID: id)) }
                }, subscriptionEstablished: nil,
                resubscriptionScheduled: { _, _ in continuation.yield(.unavailable(deviceID: id)) })
        }
        return channel.stream
    }
    func read(_ id: DeviceID) async throws -> [MatterMeasurement: MatterRawValue] {
        guard let controller, controller.isRunning else { throw IoTError.notConnected }
        guard let config = addresses[id], let sensor = catalog[id], let device = devices[id] else { throw IoTError.notConfigured }
        let token = generation
        let paths = sensor.measurements.sorted { $0.rawValue < $1.rawValue }.map {
            MTRAttributeRequestPath(endpointID: NSNumber(value: config.endpointID), clusterID: NSNumber(value: $0.rawValue), attributeID: 0)
        }
        let rows: [MatterNativeAttribute] = try await matterReadWithDeadline { completion in
            device.readAttributePaths(paths, eventPaths: nil, params: nil, queue: .main) { values, error in
                completion(MatterNativeDecoder.result(values, error: error))
            }
        }
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        return try MatterNativeDecoder.measurements(rows, endpoint: config.endpointID, allowed: sensor.measurements)
    }
    func disconnect() {
        generation &+= 1
        channel.continuation.finish()
        devices = [:]; addresses = [:]; catalog = [:]
        if let controller {
            // BaseDevice local report handlers require stack/controller shutdown. This is why the
            // initializer requires exclusive ownership rather than a shared app/Home controller.
            controller.shutdown()
            Self.controllerLeases.remove(ObjectIdentifier(controller))
        }
        controller = nil
    }
}

struct MatterNativeAttribute: Sendable {
    let endpoint: UInt16; let cluster: UInt32; let attribute: UInt32; let value: MatterNativeValue
}
enum MatterNativeValue: Sendable { case scalar(MatterRawValue), clusters(Set<UInt32>), invalid }

enum MatterNativeDecoder {
    private static func isInteger(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) != CFBooleanGetTypeID() &&
        ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType))
    }
    static func result(_ rows: [[String: Any]]?, error: Error?) -> Result<[MatterNativeAttribute], any Error> {
        guard error == nil, let rows, rows.count <= 128 else { return .failure(IoTError.invalidResponse) }
        do { return .success(try rows.map(decode)) } catch { return .failure(error) }
    }
    private static func decode(_ row: [String: Any]) throws -> MatterNativeAttribute {
        guard let path = row[MTRAttributePathKey] as? MTRAttributePath,
              isInteger(path.endpoint), isInteger(path.cluster), isInteger(path.attribute),
              path.endpoint.uint64Value < UInt16.max,
              path.cluster.uint64Value <= UInt32.max, path.attribute.uint64Value <= UInt32.max else { throw IoTError.invalidResponse }
        let value: MatterNativeValue
        if row[MTRErrorKey] != nil { value = .invalid }
        else if let data = row[MTRDataKey] as? [String: Any], let type = data[MTRTypeKey] as? String {
            switch type {
            case MTRNullValueType: value = .scalar(.null)
            case MTRSignedIntegerValueType, MTRUnsignedIntegerValueType:
                guard let number = data[MTRValueKey] as? NSNumber, isInteger(number),
                      type != MTRUnsignedIntegerValueType || number.uint64Value <= Int64.max else { throw IoTError.invalidResponse }
                value = .scalar(.integer(number.int64Value))
            case MTRArrayValueType:
                guard let entries = data[MTRValueKey] as? [[String: Any]], entries.count <= 128 else { throw IoTError.invalidResponse }
                var clusters = Set<UInt32>()
                for entry in entries {
                    guard let item = entry[MTRDataKey] as? [String: Any], item[MTRTypeKey] as? String == MTRUnsignedIntegerValueType,
                          let number = item[MTRValueKey] as? NSNumber, isInteger(number),
                          number.uint64Value <= UInt32.max, number.doubleValue == Double(number.uint64Value),
                          clusters.insert(number.uint32Value).inserted else { throw IoTError.invalidResponse }
                }
                value = .clusters(clusters)
            default: value = .invalid
            }
        } else { value = .invalid }
        return MatterNativeAttribute(endpoint: path.endpoint.uint16Value, cluster: path.cluster.uint32Value,
            attribute: path.attribute.uint32Value, value: value)
    }
    static func measurements(_ rows: [MatterNativeAttribute], endpoint: UInt16,
        allowed: Set<MatterMeasurement>) throws -> [MatterMeasurement: MatterRawValue] {
        var values: [MatterMeasurement: MatterRawValue] = [:]
        for row in rows {
            guard row.endpoint == endpoint, row.attribute == 0, let kind = MatterMeasurement(rawValue: row.cluster),
                  allowed.contains(kind), values[kind] == nil, case .scalar(let value) = row.value else { throw IoTError.invalidResponse }
            _ = try kind.decode(value); values[kind] = value
        }
        return values
    }
}
#endif
