import Foundation
import IoTCore

public enum DreoRegion: String, Sendable { case europe = "EU", northAmerica = "NA"
    var host: String { self == .europe ? "open-api-eu.dreo-tech.com" : "open-api-us.dreo-tech.com" }
}
/// The host app owns authorization and refresh. This module never stores a password/client secret.
public struct DreoAccessToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let value: String
    let accountID: String
    let region: DreoRegion
    let expiresAt: Date
    public init(value: String, accountID: String, region: DreoRegion, expiresAt: Date) throws {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let raw = parts.first, !raw.isEmpty, raw.utf8.count <= 8192,
              raw.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              parts.count == 1 || parts[1] == region.rawValue,
              !accountID.isEmpty, accountID.utf8.count <= 256, expiresAt.timeIntervalSince1970.isFinite else { throw IoTError.notConfigured }
        self.value = String(raw); self.accountID = accountID; self.region = region; self.expiresAt = expiresAt
    }
    public var description: String { "DreoAccessToken(redacted)" }
    public var debugDescription: String { description }
}
public struct DreoHTTPResponse: Sendable {
    public let data: Data; public let status: Int
    public init(data: Data, status: Int) { self.data = data; self.status = status }
}
public protocol DreoHTTP: Sendable { func send(_ request: URLRequest) async throws -> DreoHTTPResponse }
public struct DreoURLSessionHTTP: DreoHTTP {
    private let client: BoundedHTTPClient
    public init(session: URLSession? = nil) { client = BoundedHTTPClient(session: session) }
    public func send(_ request: URLRequest) async throws -> DreoHTTPResponse {
        guard Self.allowed(request) else { throw IoTError.notConfigured }
        let (data, response) = try await client.data(for: request, maxBytes: 2 * 1024 * 1024)
        return .init(data: data, status: response.statusCode)
    }
    static func allowed(_ request: URLRequest) -> Bool {
        guard let url = request.url, let c = URLComponents(url: url, resolvingAgainstBaseURL: true),
              c.scheme == "https", [DreoRegion.europe.host, DreoRegion.northAmerica.host].contains(c.host),
              c.port == nil || c.port == 443, c.user == nil, c.password == nil, c.fragment == nil,
              !c.percentEncodedPath.contains("%"), let query = c.queryItems,
              Set(query.map(\.name)).count == query.count else { return false }
        let state = c.path == "/api/v2/device/state"
        let control = c.path == "/api/v2/device/control"
        guard state || control || c.path == "/api/v2/device/list",
              (request.httpMethod ?? "GET") == (control ? "POST" : "GET"),
              Set(query.map(\.name)) == (state ? ["timestamp", "dreover", "deviceSn"] : ["timestamp", "dreover"]) else { return false }
        return query.allSatisfy {
            guard let value = $0.value else { return false }
            switch $0.name {
            case "dreover": return value == "1.0.0"
            case "timestamp": return !value.isEmpty && value.utf8.count <= 16 && value.utf8.allSatisfy { (48...57).contains($0) }
            case "deviceSn": return validSerial(value)
            default: return false
            }
        }
    }
}
public enum DreoError: Error, Sendable, Equatable { case busy, http(Int), business(Int), inventoryLimit }
/// Discrete speed, not a light brightness percentage. Values are checked against the fresh profile.
public struct DreoFanCommand: DeviceCommand {
    public let id: CommandID; public let deviceID: DeviceID; public let payload: CommandPayload
    public var replayPolicy: CommandReplayPolicy { .never }
    public init(id: CommandID = CommandID(), deviceID: DeviceID, speed: Int) {
        self.id = id; self.deviceID = deviceID; payload = .setAttribute(name: "speed", value: .integer(Int64(speed)))
    }
    public init(id: CommandID = CommandID(), deviceID: DeviceID, mode: String) {
        self.id = id; self.deviceID = deviceID; payload = .setAttribute(name: "mode", value: .string(mode))
    }
}

/// Native Dreo v2 cloud provider. No HA, LAN fiction, implicit power-on, schedules or command replay.
public actor DreoProvider: DeviceProvider {
    public nonisolated let id: ProviderID
    public nonisolated let displayName = "Dreo"
    private let token: @Sendable () async throws -> DreoAccessToken
    private let http: any DreoHTTP
    private let allowsControl: Bool
    private let events: ConnectionEventHub
    private var inventory: [DeviceID: RemoteDevice] = [:]
    private var connected = false
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var lease: UUID?
    private var pending: Task<DreoHTTPResponse, any Error>?
    private var binding: Binding?
    private struct Binding: Equatable { let accountID: String; let region: DreoRegion }

    public init(token: @escaping @Sendable () async throws -> DreoAccessToken,
                allowsControl: Bool = false, id: ProviderID = "dreo", http: any DreoHTTP = DreoURLSessionHTTP()) {
        self.token = token; self.http = http; self.allowsControl = allowsControl; self.id = id
        events = ConnectionEventHub(providerID: id)
    }
    public func connect() async throws {
        if connected { return }
        let operation = try begin(); defer { finish(operation) }
        let epoch = generation; await events.publish(.connecting)
        do {
            let found = try await discover(epoch: epoch)
            try check(epoch); inventory = found; connected = true
            await events.publish(.connected)
        } catch {
            if generation == epoch { inventory = [:]; binding = nil; await events.publish(.degraded, reason: "Dreo connection could not be verified") }
            throw sanitize(error)
        }
    }
    public func disconnect() async {
        generation &+= 1; connected = false; inventory = [:]; binding = nil
        pending?.cancel(); pending = nil; lease = nil
        await events.publish(.disconnected)
    }
    public func connectionEvents() async -> AsyncStream<ProviderConnectionEvent> { await events.events() }
    public func devices() async throws -> [Device] {
        guard connected else { throw IoTError.notConnected }
        return inventory.values.sorted { $0.deviceSn < $1.deviceSn }.map {
            Device(id: $0.id, providerID: id, nativeID: $0.deviceSn, name: $0.deviceName ?? $0.deviceSn,
                   kind: ["fan", "circulation_fan"].contains($0.deviceType) ? .fan : .unknown,
                   manufacturer: "Dreo", model: $0.modelName, capabilities: descriptors($0))
        }
    }
    public func capabilities(for deviceID: DeviceID) async throws -> DeviceCapabilitySet {
        let device = try target(deviceID, epoch: generation)
        let descriptors = descriptors(device)
        return .init(descriptors: descriptors,
            control: descriptors.first(where: { $0.id == .control }).map { DreoControl(provider: self, deviceID: deviceID, epoch: generation, descriptor: $0) },
            readState: DreoRead(provider: self, deviceID: deviceID, epoch: generation))
    }
    fileprivate func read(_ deviceID: DeviceID, epoch: UInt64) async throws -> DeviceState {
        let operation = try begin(); defer { finish(operation) }
        do { return try await state(try target(deviceID, epoch: epoch), epoch: epoch).snapshot }
        catch { throw sanitize(error) }
    }
    fileprivate func execute<C: DeviceCommand>(_ command: C, deviceID: DeviceID, epoch: UInt64) async throws -> CommandReceipt {
        let operation = try begin(); defer { finish(operation) }
        guard allowsControl, command.deviceID == deviceID else { throw IoTError.notConfigured }
        _ = try target(deviceID, epoch: epoch)
        // Membership and limits may change while a UI retains its old capability handle.
        let fresh = try await discover(epoch: epoch)
        guard let device = fresh[deviceID], device.profile != nil else { throw IoTError.notSupported("Dreo fan control") }
        let desired = try device.command(command.payload)
        let before = try await state(device, epoch: epoch)
        guard before.connected == true, before.snapshot.primaryValue != nil else { throw IoTError.unconfirmed }
        let body = try JSONEncoder().encode(WireCommand(devicesn: device.deviceSn, desired: desired))
        do {
            let response = try await request("control", body: body, epoch: epoch)
            _ = try decode(Empty.self, response.data)
        } catch {
            let rejected: Bool
            if case DreoError.business = error { rejected = true }
            else if case DreoError.http(let code) = error { rejected = [400,401,403,404,422].contains(code) }
            else { rejected = false }
            return .init(commandID: command.id, deviceID: deviceID, outcome: rejected ? .rejected : .uncertain)
        }
        let readback = try? await state(device, epoch: epoch).snapshot
        return .init(commandID: command.id, deviceID: deviceID, outcome: .accepted, state: readback)
    }
    private func discover(epoch: UInt64) async throws -> [DeviceID: RemoteDevice] {
        let response = try await request("list", epoch: epoch)
        let values = try decode([RemoteDevice].self, response.data)
        guard values.count <= 1000 else { throw DreoError.inventoryLimit }
        var result: [DeviceID: RemoteDevice] = [:]
        for value in values {
            guard validSerial(value.deviceSn), result[value.id] == nil,
                  (value.deviceName?.utf8.count ?? 0) <= 256, value.modelName.utf8.count <= 64,
                  value.model == nil || value.deviceModel == nil || value.model == value.deviceModel else { throw IoTError.invalidResponse }
            result[value.id] = value
        }
        return result
    }
    private func state(_ device: RemoteDevice, epoch: UInt64) async throws -> (snapshot: DeviceState, connected: Bool?) {
        let response = try await request("state", serial: device.deviceSn, epoch: epoch)
        let value = try decode(RemoteState.self, response.data)
        guard value.deviceSn == nil || value.deviceSn == device.deviceSn else { throw IoTError.invalidResponse }
        var attributes: [String: StateAttribute] = [:]
        if let speed = value.speed { attributes["speed"] = .init(value: .integer(Int64(speed))) }
        if let mode = value.mode, mode.utf8.count <= 64 { attributes["mode"] = .init(value: .string(mode)) }
        if let connected = value.connected { attributes["cloudConnected"] = .init(value: .bool(connected)) }
        sequence &+= 1
        // The published flat state has no device observation timestamp. Never synthesize one.
        let availability: DeviceAvailability = value.connected == false ? .offline : value.connected == true && value.power_switch != nil ? .degraded : .unknown
        return (DeviceState(deviceID: device.id, availability: availability,
            primaryValue: value.power_switch.map(StateValue.bool), attributes: attributes,
            observedAt: .distantPast, receivedAt: Date(), origin: .cloud, revision: .init(localSequence: sequence)), value.connected)
    }
    private func request(_ route: String, serial: String? = nil, body: Data? = nil, epoch: UInt64) async throws -> DreoHTTPResponse {
        try check(epoch)
        let access: DreoAccessToken
        do { access = try await token() } catch { throw IoTError.authenticationFailed(reason: "Dreo authorization unavailable") }
        try check(epoch)
        guard access.expiresAt > Date().addingTimeInterval(5) else { throw IoTError.authenticationFailed(reason: "Dreo authorization expired") }
        let identity = Binding(accountID: access.accountID, region: access.region)
        guard binding == nil || binding == identity else { throw IoTError.authenticationFailed(reason: "Dreo account changed; reconnect explicitly") }
        binding = identity
        var c = URLComponents(); c.scheme = "https"; c.host = access.region.host; c.path = "/api/v2/device/" + route
        c.queryItems = [.init(name: "timestamp", value: String(Int64(Date().timeIntervalSince1970 * 1000))), .init(name: "dreover", value: "1.0.0")]
        if let serial { c.queryItems?.append(.init(name: "deviceSn", value: serial)) }
        guard let url = c.url else { throw IoTError.notConfigured }
        var request = URLRequest(url: url); request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body; request.timeoutInterval = 12
        request.setValue("Bearer " + access.value, forHTTPHeaderField: "Authorization")
        request.setValue("openapi/1.0.0", forHTTPHeaderField: "UA")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard DreoURLSessionHTTP.allowed(request) else { throw IoTError.notConfigured }
        let http = self.http; let task = Task { try await http.send(request) }; pending = task
        let response = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try check(epoch); pending = nil
        guard response.data.count <= 2 * 1024 * 1024 else { throw IoTError.invalidResponse }
        guard response.status == 200 else { throw DreoError.http(response.status) }
        return response
    }
    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let code = try JSONDecoder().decode(Code.self, from: data).code
        guard code == 0 else { throw DreoError.business(code) }
        return try JSONDecoder().decode(Envelope<T>.self, from: data).data
    }
    private func descriptors(_ device: RemoteDevice) -> [CapabilityDescriptor] {
        var result = [CapabilityDescriptor(id: .readState, operations: [.readState])]
        if allowsControl, let profile = device.profile {
            var metadata: [String: StateValue] = ["commands": .array([.string("setPower")])]
            var commands = [StateValue.string("setPower")]
            if let range = profile.speedRange {
                commands.append(.string("setSpeed")); metadata["minimumSpeed"] = .integer(Int64(range.lowerBound)); metadata["maximumSpeed"] = .integer(Int64(range.upperBound))
            }
            if !profile.modes.isEmpty { commands.append(.string("setMode")); metadata["modes"] = .array(profile.modes.map(StateValue.string)) }
            metadata["commands"] = .array(commands)
            result.append(.init(id: .control, operations: [.control], metadata: metadata))
        }
        return result
    }
    private func target(_ id: DeviceID, epoch: UInt64) throws -> RemoteDevice {
        try check(epoch); guard connected else { throw IoTError.notConnected }
        guard let target = inventory[id] else { throw IoTError.notConfigured }; return target
    }
    private func begin() throws -> UUID { guard lease == nil else { throw DreoError.busy }; let id = UUID(); lease = id; return id }
    private func finish(_ operation: UUID) { if lease == operation { lease = nil; pending = nil } }
    private func check(_ epoch: UInt64) throws { try Task.checkCancellation(); guard generation == epoch else { throw IoTError.notConnected } }
    private func sanitize(_ error: any Error) -> any Error {
        if error is CancellationError { return IoTError.cancelled }
        if let value = error as? IoTError { return value }
        if let value = error as? DreoError { return value }
        return IoTError.transport("Dreo request could not be completed")
    }
}
private func validSerial(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }
}
private struct Code: Decodable { let code: Int }
private struct Envelope<T: Decodable>: Decodable { let code: Int; let data: T }
private struct Empty: Decodable {}
private struct RemoteState: Decodable { let deviceSn: String?; let connected: Bool?; let power_switch: Bool?; let speed: Int?; let mode: String? }
private struct RemoteDevice: Decodable {
    let deviceSn: String; let deviceName: String?; let model: String?; let deviceModel: String?; let deviceType: String?; let config: Config?
    var id: DeviceID { .init(rawValue: deviceSn) }
    var modelName: String { model ?? deviceModel ?? "" }
    var profile: FanProfile? {
        guard ["DR-HAF001S", "DR-HAF003S"].contains(modelName), deviceType == "circulation_fan", let fan = config?.fan_entity_config else { return nil }
        return FanProfile(fan)
    }
    func command(_ payload: CommandPayload) throws -> [String: WireValue] {
        guard let profile else { throw IoTError.notSupported("Dreo model control") }
        switch payload {
        case .setPower(let value): return ["power_switch": .bool(value)]
        case .setAttribute(name: "speed", value: .integer(let value)):
            guard let speed = Int(exactly: value), profile.speedRange?.contains(speed) == true else { throw IoTError.notSupported("Dreo fan speed") }
            return ["speed": .integer(speed)]
        case .setAttribute(name: "mode", value: .string(let value)):
            guard profile.modes.contains(value) else { throw IoTError.notSupported("Dreo fan mode") }
            return ["mode": .string(value)]
        default: throw IoTError.notSupported("Dreo command")
        }
    }
}
private struct Config: Decodable { let fan_entity_config: FanConfig? }
private struct FanConfig: Decodable { let speed_range: [Int]?; let preset_modes: [String]? }
private struct FanProfile {
    let speedRange: ClosedRange<Int>?
    let modes: [String]
    init(_ config: FanConfig) {
        if let range = config.speed_range, range.count == 2, range[0] >= 1, range[1] <= 32, range[0] <= range[1] { speedRange = range[0]...range[1] } else { speedRange = nil }
        let advertised = config.preset_modes ?? []
        modes = advertised.count <= 16 && advertised.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 32 }) ? Array(Set(advertised)).sorted() : []
    }
}
private struct WireCommand: Encodable { let devicesn: String; let desired: [String: WireValue] }
private enum WireValue: Encodable {
    case bool(Bool), integer(Int), string(String)
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .bool(let v): try c.encode(v); case .integer(let v): try c.encode(v); case .string(let v): try c.encode(v) }
    }
}
private actor DreoRead: ReadStateCapability {
    nonisolated let descriptor = CapabilityDescriptor(id: .readState, operations: [.readState])
    let provider: DreoProvider; let deviceID: DeviceID; let epoch: UInt64
    init(provider: DreoProvider, deviceID: DeviceID, epoch: UInt64) { self.provider = provider; self.deviceID = deviceID; self.epoch = epoch }
    func state() async throws -> DeviceState { try await provider.read(deviceID, epoch: epoch) }
}
private actor DreoControl: ControlCapability {
    nonisolated let descriptor: CapabilityDescriptor
    let provider: DreoProvider; let deviceID: DeviceID; let epoch: UInt64
    init(provider: DreoProvider, deviceID: DeviceID, epoch: UInt64, descriptor: CapabilityDescriptor) { self.provider = provider; self.deviceID = deviceID; self.epoch = epoch; self.descriptor = descriptor }
    func execute<C: DeviceCommand>(_ command: C) async throws -> CommandReceipt { try await provider.execute(command, deviceID: deviceID, epoch: epoch) }
}
