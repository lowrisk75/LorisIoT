import Foundation
import IoTCore

/// Supplied by the app's OAuth coordinator. No client secret, refresh token or account password
/// belongs in this provider. Obtain a fresh access token for every request; never persist it here.
public struct SmartThingsAccessToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let value: String
    let expiresAt: Date
    public init(value: String, expiresAt: Date) throws {
        guard !value.isEmpty, value.utf8.count <= 8192,
              value.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
              expiresAt.timeIntervalSince1970.isFinite else { throw IoTError.notConfigured }
        self.value = value; self.expiresAt = expiresAt
    }
    public var description: String { "SmartThingsAccessToken(redacted)" }
    public var debugDescription: String { description }
}
public struct SmartThingsHTTPResponse: Sendable {
    public let data: Data
    public let status: Int
    public init(data: Data, status: Int) { self.data = data; self.status = status }
}
public protocol SmartThingsHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> SmartThingsHTTPResponse
}
public struct SmartThingsURLSessionHTTP: SmartThingsHTTP {
    private let client: BoundedHTTPClient
    public init(session: URLSession? = nil) { client = BoundedHTTPClient(session: session) }
    public func send(_ request: URLRequest) async throws -> SmartThingsHTTPResponse {
        guard let url = request.url, SmartThingsProvider.allowedURL(url) else { throw IoTError.notConfigured }
        let (data, response) = try await client.data(for: request, maxBytes: 2 * 1024 * 1024)
        return SmartThingsHTTPResponse(data: data, status: response.statusCode)
    }
}
public enum SmartThingsError: Error, Sendable, Equatable {
    case http(Int), busy, inventoryLimit
}

/// Native SmartThings REST provider. No Home Assistant dependency, no polling timer, no automatic
/// replay and no schedule claim. Each component keeps its own identity and advertised capabilities.
public actor SmartThingsProvider: DeviceProvider {
    public nonisolated let id: ProviderID
    public nonisolated let displayName = "SmartThings"
    private let token: @Sendable () async throws -> SmartThingsAccessToken
    private let http: any SmartThingsHTTP
    private let allowsControl: Bool
    private let maxStateAge: TimeInterval
    private let events: ConnectionEventHub
    private var targets: [DeviceID: Target] = [:]
    private var connected = false
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var operation: UUID?
    private var pending: Task<SmartThingsHTTPResponse, any Error>?

    public init(token: @escaping @Sendable () async throws -> SmartThingsAccessToken,
                allowsControl: Bool = false, id: ProviderID = "smartthings", maxStateAge: TimeInterval = 120,
                http: any SmartThingsHTTP = SmartThingsURLSessionHTTP()) {
        self.token = token; self.http = http; self.id = id; self.allowsControl = allowsControl
        self.maxStateAge = maxStateAge
        events = ConnectionEventHub(providerID: id)
    }
    public func connect() async throws {
        if connected { return }
        guard maxStateAge.isFinite, maxStateAge > 0 else { throw IoTError.notConfigured }
        let lease = try begin(); defer { finish(lease) }
        let epoch = generation
        await events.publish(.connecting)
        do {
            var url: URL? = URL(string: "https://api.smartthings.com/v1/devices")!
            var visited = Set<URL>(); var devices = Set<String>(); var discovered: [DeviceID: Target] = [:]
            while let pageURL = url {
                guard visited.insert(pageURL).inserted, visited.count <= 50 else { throw SmartThingsError.inventoryLimit }
                let response = try await request(pageURL, epoch: epoch)
                let page = try JSONDecoder().decode(Page.self, from: response.data)
                guard page.items.count <= 1000 else { throw SmartThingsError.inventoryLimit }
                for item in page.items {
                    guard let uuid = UUID(uuidString: item.deviceId)?.uuidString.lowercased(),
                          devices.insert(uuid).inserted, devices.count <= 1000,
                          !item.components.isEmpty, item.components.count <= 64 else { throw IoTError.invalidResponse }
                    for component in item.components {
                        guard Self.validComponent(component.id), component.capabilities.count <= 128 else { throw IoTError.invalidResponse }
                        let target = Target(uuid: uuid, component: component.id, label: component.id == "main" ? item.label ?? item.name ?? uuid : (item.label ?? item.name ?? uuid) + " · " + (component.label ?? component.id),
                                            capabilities: Set(component.capabilities.map(\.id)), manufacturer: item.manufacturerName)
                        guard discovered[target.id] == nil, discovered.count < 4096 else { throw IoTError.invalidResponse }
                        discovered[target.id] = target
                    }
                }
                if let next = page._links?.next?.href {
                    guard next.utf8.count <= 2048, let nextURL = URL(string: next, relativeTo: pageURL)?.absoluteURL,
                          Self.allowedURL(nextURL), nextURL.path == "/v1/devices",
                          URLComponents(url: nextURL, resolvingAgainstBaseURL: false)?.percentEncodedPath == "/v1/devices" else { throw IoTError.invalidResponse }
                    url = nextURL
                } else { url = nil }
            }
            try check(epoch)
            targets = discovered; connected = true
            await events.publish(.connected)
        } catch {
            if generation == epoch { targets = [:]; connected = false; await events.publish(.degraded, reason: "SmartThings connection could not be verified") }
            throw sanitized(error)
        }
    }
    public func disconnect() async {
        generation &+= 1; connected = false; targets = [:]
        pending?.cancel(); pending = nil; operation = nil
        await events.publish(.disconnected)
    }
    public func devices() async throws -> [Device] {
        guard connected else { throw IoTError.notConnected }
        return targets.values.sorted { $0.id.rawValue < $1.id.rawValue }.map {
            Device(id: $0.id, providerID: id, nativeID: $0.uuid + "/" + $0.component,
                   name: $0.label, kind: $0.kind, manufacturer: $0.manufacturer, capabilities: descriptors($0))
        }
    }
    public func capabilities(for deviceID: DeviceID) async throws -> DeviceCapabilitySet {
        guard connected else { throw IoTError.notConnected }
        guard let target = targets[deviceID] else { throw IoTError.notConfigured }
        return DeviceCapabilitySet(descriptors: descriptors(target),
            control: allowsControl && !target.commands.isEmpty ? SmartThingsControl(provider: self, deviceID: deviceID, epoch: generation) : nil,
            readState: SmartThingsRead(provider: self, deviceID: deviceID, epoch: generation))
    }
    public func connectionEvents() async -> AsyncStream<ProviderConnectionEvent> { await events.events() }

    fileprivate func read(_ deviceID: DeviceID, epoch: UInt64) async throws -> DeviceState {
        let lease = try begin(); defer { finish(lease) }
        return try await readState(try target(deviceID, epoch: epoch), epoch: epoch)
    }
    fileprivate func execute<C: DeviceCommand>(_ command: C, deviceID: DeviceID, epoch: UInt64) async throws -> CommandReceipt {
        let lease = try begin(); defer { finish(lease) }
        guard command.deviceID == deviceID, allowsControl else { throw IoTError.notConfigured }
        let target = try target(deviceID, epoch: epoch)
        let wire = try target.command(command.payload)
        let health = try await health(target, epoch: epoch)
        guard health == "ONLINE" else { throw IoTError.unconfirmed }
        try check(epoch)
        let body = try JSONEncoder().encode(CommandBody(commands: [wire]))
        let response: SmartThingsHTTPResponse
        do {
            response = try await request(URL(string: "https://api.smartthings.com/v1/devices/\(target.uuid)/commands")!, method: "POST", body: body, epoch: epoch)
        } catch {
            // No retry after dispatch may have started. Explicit authorization refusals are known;
            // loss/cancellation/5xx/rate limiting cannot prove that no command reached the device.
            let outcome: CommandOutcome
            if case SmartThingsError.http(let status) = error, [400,401,403,404,422].contains(status) { outcome = .rejected }
            else { outcome = .uncertain }
            return CommandReceipt(commandID: command.id, deviceID: deviceID, outcome: outcome)
        }
        guard let result = try? JSONDecoder().decode(CommandResponse.self, from: response.data),
              result.results.count == 1, let receipt = result.results.first,
              ["ACCEPTED", "COMPLETED", "FAILED"].contains(receipt.status) else {
            return CommandReceipt(commandID: command.id, deviceID: deviceID, outcome: .uncertain)
        }
        if receipt.status == "FAILED" { return CommandReceipt(commandID: command.id, deviceID: deviceID, outcome: .rejected) }
        let observation = try? await readState(target, epoch: epoch)
        // SmartThings status is a cloud snapshot; even a matching value is not causal confirmation.
        return CommandReceipt(commandID: command.id, deviceID: deviceID, outcome: .accepted,
                              state: observation, providerTransactionID: receipt.id)
    }
    private func readState(_ target: Target, epoch: UInt64) async throws -> DeviceState {
        let connection = try await health(target, epoch: epoch)
        let response = try await request(URL(string: "https://api.smartthings.com/v1/devices/\(target.uuid)/status")!, epoch: epoch)
        let status = try JSONDecoder().decode(Status.self, from: response.data)
        guard let values = status.components[target.component], values.count <= 128 else { throw IoTError.invalidResponse }
        var attributes: [String: StateAttribute] = [:]
        for (capability, names) in values {
            guard names.count <= 128, attributes.count + names.count <= 512 else { throw IoTError.invalidResponse }
            for (name, value) in names {
                attributes[capability + "." + name] = StateAttribute(value: value.value?.stateValue ?? .null, unit: UnitSymbol.from(symbol: value.unit))
            }
        }
        let power = values["switch"]?["switch"]
        let level = values["switchLevel"]?["level"]
        let sensor: Attribute? = values["temperatureMeasurement"]?["temperature"]
            ?? values["relativeHumidityMeasurement"]?["humidity"] ?? values["battery"]?["battery"]
            ?? values["contactSensor"]?["contact"] ?? values["motionSensor"]?["motion"]
        let first = power ?? level ?? sensor
        let primary: StateValue? = if let power, case .string(let raw)? = power.value, ["on", "off"].contains(raw) { .bool(raw == "on") }
            else if case .null? = first?.value { nil }
            else { first?.value?.stateValue }
        let now = Date()
        let observed = first?.timestamp.flatMap(Self.date)
        let fresh = observed.map { $0 <= now.addingTimeInterval(5) && now.timeIntervalSince($0) <= maxStateAge } ?? false
        let availability: DeviceAvailability = connection == "OFFLINE" ? .offline : connection != "ONLINE" || primary == nil ? .unknown : fresh ? .online : .degraded
        sequence &+= 1
        return DeviceState(deviceID: target.id, availability: availability, primaryValue: primary,
            primaryUnit: power == nil && level != nil ? .percent : UnitSymbol.from(symbol: first?.unit), attributes: attributes,
            observedAt: observed ?? .distantPast, receivedAt: now, origin: .cloud, revision: .init(localSequence: sequence))
    }
    private func health(_ target: Target, epoch: UInt64) async throws -> String {
        do {
            let response = try await request(URL(string: "https://api.smartthings.com/v1/devices/\(target.uuid)/health")!, epoch: epoch)
            let value = try JSONDecoder().decode(Health.self, from: response.data)
            guard UUID(uuidString: value.deviceId)?.uuidString.lowercased() == target.uuid else { throw IoTError.invalidResponse }
            return value.state
        } catch SmartThingsError.http(404) { return "UNKNOWN" }
    }
    private func request(_ url: URL, method: String = "GET", body: Data? = nil, epoch: UInt64) async throws -> SmartThingsHTTPResponse {
        try check(epoch)
        guard Self.allowedURL(url) else { throw IoTError.notConfigured }
        let access: SmartThingsAccessToken
        do { access = try await token() } catch { throw IoTError.authenticationFailed(reason: "SmartThings authorization unavailable") }
        try check(epoch); try Task.checkCancellation()
        guard access.expiresAt > Date().addingTimeInterval(5) else { throw IoTError.authenticationFailed(reason: "SmartThings authorization expired") }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 12
        request.setValue("Bearer " + access.value, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let http = self.http
        let task = Task { try await http.send(request) }; pending = task
        let response = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try check(epoch); pending = nil
        guard response.data.count <= 2 * 1024 * 1024 else { throw IoTError.invalidResponse }
        guard (200..<300).contains(response.status) else { throw SmartThingsError.http(response.status) }
        return response
    }
    static func allowedURL(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: true), c.scheme == "https", c.host == "api.smartthings.com",
              c.port == nil || c.port == 443, c.user == nil, c.password == nil, c.fragment == nil,
              c.path.hasPrefix("/v1/devices"), !c.percentEncodedPath.contains("%"),
              validPagination(c.queryItems) else { return false }
        if c.path == "/v1/devices" { return true }
        let parts = c.path.split(separator: "/", omittingEmptySubsequences: false)
        return c.query == nil && parts.count == 5 && parts[0].isEmpty && parts[1] == "v1" && parts[2] == "devices"
            && UUID(uuidString: String(parts[3])) != nil && ["health", "status", "commands"].contains(String(parts[4]))
    }
    private static func validPagination(_ items: [URLQueryItem]?) -> Bool {
        guard let items else { return true }
        guard items.count <= 2, Set(items.map(\.name)).count == items.count else { return false }
        return items.allSatisfy {
            guard ["page", "max"].contains($0.name), let value = $0.value,
                  !value.isEmpty, value.utf8.count <= 10 else { return false }
            return value.utf8.allSatisfy { (48...57).contains($0) }
        }
    }
    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 36 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_!.~'()*".contains($0)) }
    }
    private static func date(_ text: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    private func target(_ id: DeviceID, epoch: UInt64) throws -> Target {
        try check(epoch)
        guard connected else { throw IoTError.notConnected }
        guard let target = targets[id] else { throw IoTError.notConfigured }
        return target
    }
    private func begin() throws -> UUID {
        guard operation == nil else { throw SmartThingsError.busy }
        let lease = UUID(); operation = lease; return lease
    }
    private func finish(_ lease: UUID) { if operation == lease { operation = nil; pending = nil } }
    private func check(_ epoch: UInt64) throws {
        try Task.checkCancellation()
        guard generation == epoch else { throw IoTError.notConnected }
    }
    private func descriptors(_ target: Target) -> [CapabilityDescriptor] {
        var result = [CapabilityDescriptor(id: .readState, operations: [.readState])]
        if allowsControl, !target.commands.isEmpty { result.append(.init(id: .control, operations: [.control], metadata: ["commands": .array(target.commands.sorted().map(StateValue.string))])) }
        return result
    }
    private func sanitized(_ error: any Error) -> any Error {
        if error is CancellationError { return IoTError.cancelled }
        if let value = error as? IoTError { return value }
        if case SmartThingsError.http(401) = error { return IoTError.authenticationFailed(reason: "SmartThings authorization expired or revoked") }
        if let value = error as? SmartThingsError { return value }
        return IoTError.transport("SmartThings request could not be completed")
    }
}
private struct Target: Sendable {
    let uuid: String; let component: String; let label: String; let capabilities: Set<String>; let manufacturer: String?
    var id: DeviceID { .init(rawValue: uuid + "/" + component) }
    var kind: DeviceKind { capabilities.contains("switchLevel") ? .light : capabilities.contains("fanSpeed") ? .fan : capabilities.contains("switch") ? .switchDevice : .sensor }
    var commands: Set<String> { Set([(capabilities.contains("switch") ? "setPower" : nil), (capabilities.contains("switchLevel") ? "setLevel" : nil)].compactMap { $0 }) }
    func command(_ payload: CommandPayload) throws -> WireCommand {
        switch payload {
        case .setPower(let on) where capabilities.contains("switch"):
            return .init(component: component, capability: "switch", command: on ? "on" : "off", arguments: [])
        case .setLevel(let level) where capabilities.contains("switchLevel"):
            return .init(component: component, capability: "switchLevel", command: "setLevel", arguments: [level.percent])
        default: throw IoTError.notSupported("SmartThings command capability")
        }
    }
}
private struct Page: Decodable { let items: [RemoteDevice]; let _links: Links? }
private struct Links: Decodable { let next: Link? }
private struct Link: Decodable { let href: String }
private struct RemoteDevice: Decodable { let deviceId: String; let label: String?; let name: String?; let manufacturerName: String?; let components: [Component] }
private struct Component: Decodable { let id: String; let label: String?; let capabilities: [RemoteCapability] }
private struct RemoteCapability: Decodable { let id: String }
private struct Health: Decodable { let deviceId: String; let state: String }
private struct Status: Decodable { let components: [String: [String: [String: Attribute]]] }
private struct Attribute: Decodable { let value: Scalar?; let unit: String?; let timestamp: String? }
private enum Scalar: Decodable, Sendable {
    case string(String), bool(Bool), number(Double), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self), n.isFinite { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { self = .null }
    }
    var stateValue: StateValue { switch self { case .string(let s): .string(s); case .bool(let b): .bool(b); case .number(let n): .decimal(n); case .null: .null } }
}
private struct WireCommand: Encodable { let component: String; let capability: String; let command: String; let arguments: [Int] }
private struct CommandBody: Encodable { let commands: [WireCommand] }
private struct CommandResponse: Decodable { let results: [RemoteReceipt] }
private struct RemoteReceipt: Decodable { let id: String; let status: String }
private actor SmartThingsRead: ReadStateCapability {
    nonisolated let descriptor = CapabilityDescriptor(id: .readState, operations: [.readState])
    let provider: SmartThingsProvider; let deviceID: DeviceID; let epoch: UInt64
    init(provider: SmartThingsProvider, deviceID: DeviceID, epoch: UInt64) { self.provider = provider; self.deviceID = deviceID; self.epoch = epoch }
    func state() async throws -> DeviceState { try await provider.read(deviceID, epoch: epoch) }
}
private actor SmartThingsControl: ControlCapability {
    nonisolated let descriptor = CapabilityDescriptor(id: .control, operations: [.control])
    let provider: SmartThingsProvider; let deviceID: DeviceID; let epoch: UInt64
    init(provider: SmartThingsProvider, deviceID: DeviceID, epoch: UInt64) { self.provider = provider; self.deviceID = deviceID; self.epoch = epoch }
    func execute<C: DeviceCommand>(_ command: C) async throws -> CommandReceipt { try await provider.execute(command, deviceID: deviceID, epoch: epoch) }
}
