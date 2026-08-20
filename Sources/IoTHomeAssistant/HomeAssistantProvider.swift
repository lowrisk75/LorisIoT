import Foundation
import IoTCore

/// Home Assistant provider — the pivot integration. Exposes each HA entity as a `Device` with
/// per-device capabilities (control/readState/subscribe, +schedule when an input_datetime helper is
/// configured). Reaches Zigbee/Z-Wave/Thread/ESPHome/Tuya-via-HA for free.
public actor HomeAssistantProvider: DeviceProvider {
    public nonisolated let id: ProviderID = "home-assistant"
    public nonisolated let displayName = "Home Assistant"

    private let config: HAConfig
    private let token: String
    let rest: HARestClient
    private let wakeHelperEntity: String?
    private let seq = SequenceGen()
    private var connected = false

    public init(config: HAConfig, token: String, http: HAHTTP? = nil, wakeHelperEntity: String? = nil) {
        self.config = config
        self.token = token
        self.rest = HARestClient(http: http ?? HAURLSessionHTTP(baseURL: config.baseURL, token: token))
        self.wakeHelperEntity = wakeHelperEntity
    }

    public func connect() async throws { _ = try await rest.verify(); connected = true }
    public func disconnect() async { connected = false }

    /// One-shot snapshot of every entity as a `Device`.
    public func devices() async throws -> [Device] {
        try await rest.states().map { Self.device(from: $0, provider: id, canSchedule: wakeHelperEntity != nil) }
    }

    /// Per-device typed capability handles — no casts on the consumer side.
    public func capabilities(for deviceID: DeviceID) async throws -> DeviceCapabilitySet {
        var descriptors: [CapabilityDescriptor] = [
            CapabilityDescriptor(id: .readState, operations: [.readState]),
            CapabilityDescriptor(id: .control, operations: [.control]),
            CapabilityDescriptor(id: .subscribe, operations: [.subscribe]),
        ]
        var schedule: (any ScheduleCapability)?
        if let helper = wakeHelperEntity {
            descriptors.append(CapabilityDescriptor(id: .schedule, operations: [.schedule]))
            schedule = HAScheduleCapability(rest: rest, deviceID: deviceID, helperEntity: helper)
        }
        return DeviceCapabilitySet(
            descriptors: descriptors,
            control: HAControlCapability(rest: rest, deviceID: deviceID, seq: seq),
            readState: HAReadStateCapability(rest: rest, deviceID: deviceID, seq: seq),
            schedule: schedule,
            subscribe: HASubscribeCapability(config: config, token: token, deviceID: deviceID, seq: seq))
    }

    public func connectionEvents() async -> AsyncStream<ProviderConnectionEvent> {
        let connected = self.connected, id = self.id
        return AsyncStream { c in
            c.yield(ProviderConnectionEvent(providerID: id, state: connected ? .connected : .disconnected))
            c.finish()
        }
    }

    static func device(from e: HAEntityState, provider: ProviderID, canSchedule: Bool) -> Device {
        var caps = [CapabilityID.readState, .control, .subscribe]
        if canSchedule { caps.append(.schedule) }
        return Device(id: DeviceID(rawValue: e.entityID), providerID: provider, nativeID: e.entityID,
                      name: e.friendlyName ?? e.entityID, kind: kind(for: e.entityID),
                      capabilities: caps.map { CapabilityDescriptor(id: $0, operations: []) })
    }

    static func kind(for entityID: String) -> DeviceKind {
        switch haDomain(of: entityID) {
        case "light": return .light
        case "switch": return .switchDevice
        case "fan": return .fan
        case "cover": return .cover
        case "lock": return .lock
        case "sensor", "binary_sensor": return .sensor
        case "climate": return .thermostat
        default: return .unknown
        }
    }
}

// MARK: - Capabilities

actor HAReadStateCapability: ReadStateCapability {
    public nonisolated let descriptor = CapabilityDescriptor(id: .readState, operations: [.readState])
    private let rest: HARestClient; private let deviceID: DeviceID; private let seq: SequenceGen
    init(rest: HARestClient, deviceID: DeviceID, seq: SequenceGen) { self.rest = rest; self.deviceID = deviceID; self.seq = seq }
    func state() async throws -> DeviceState {
        try await rest.state(entityID: deviceID.rawValue).deviceState(sequence: await seq.next())
    }
}

actor HAControlCapability: ControlCapability {
    public nonisolated let descriptor = CapabilityDescriptor(id: .control, operations: [.control])
    private let rest: HARestClient; private let deviceID: DeviceID; private let seq: SequenceGen
    init(rest: HARestClient, deviceID: DeviceID, seq: SequenceGen) { self.rest = rest; self.deviceID = deviceID; self.seq = seq }

    /// Execute + confirm-by-reread. Outcome: `.applied` (confirmed), `.rejected` (state didn't change),
    /// `.uncertain` (transport failed after the send may have happened — never silently "succeed").
    func execute<C: DeviceCommand>(_ command: C) async throws -> CommandReceipt {
        let domain = haDomain(of: deviceID.rawValue)
        func receipt(_ outcome: CommandOutcome, _ state: DeviceState?) -> CommandReceipt {
            CommandReceipt(commandID: command.id, deviceID: deviceID, outcome: outcome, state: state)
        }
        switch command.payload {
        case .setPower(let on):
            do { try await rest.callService(domain: domain, service: on ? "turn_on" : "turn_off", entityID: deviceID.rawValue) }
            catch let e as IoTError where e == .authenticationFailed(reason: "HTTP 401") || e == .authenticationFailed(reason: "HTTP 403") { throw e }
            catch { return receipt(.uncertain, nil) }
            let s = try await rest.state(entityID: deviceID.rawValue)
            return receipt(s.isOn == on ? .applied : .rejected, s.deviceState(sequence: await seq.next()))
        case .setLevel(let interval):
            do { try await rest.callService(domain: domain, service: "turn_on", entityID: deviceID.rawValue, data: ["brightness_pct": interval.percent]) }
            catch { return receipt(.uncertain, nil) }
            let s = try await rest.state(entityID: deviceID.rawValue)
            return receipt(s.isOn == true ? .applied : .rejected, s.deviceState(sequence: await seq.next()))
        default:
            throw IoTError.notSupported("HA control supports power/level")
        }
    }
}

/// `.schedule` via an `input_datetime` helper — the server-side pre-provisioning primitive.
actor HAScheduleCapability: ScheduleCapability {
    public nonisolated let descriptor = CapabilityDescriptor(id: .schedule, operations: [.schedule])
    private let rest: HARestClient; private let deviceID: DeviceID; private let helperEntity: String
    init(rest: HARestClient, deviceID: DeviceID, helperEntity: String) { self.rest = rest; self.deviceID = deviceID; self.helperEntity = helperEntity }

    func schedules() async throws -> [DeviceSchedule] { [] }   // HA helper is opaque; we own one slot

    func upsert(_ schedule: DeviceSchedule) async throws -> DeviceSchedule {
        try await rest.setInputDatetime(entityID: helperEntity, isoDate: Self.iso(schedule.start))
        return schedule
    }
    func removeSchedule(id: ScheduleID) async throws {
        try await rest.setInputDatetime(entityID: helperEntity, isoDate: "1970-01-01 00:00:00")
    }
    static func iso(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }
}

/// Live `state_changed` for one entity, over the resilient WebSocket (auth handshake + subscribe on
/// every reconnect). Filters the shared stream to this device.
actor HASubscribeCapability: SubscribeCapability {
    public nonisolated let descriptor = CapabilityDescriptor(id: .subscribe, operations: [.subscribe])
    private let config: HAConfig; private let token: String; private let deviceID: DeviceID; private let seq: SequenceGen
    private var socket: RealtimeSocketClient<HAMessage>?
    init(config: HAConfig, token: String, deviceID: DeviceID, seq: SequenceGen) {
        self.config = config; self.token = token; self.deviceID = deviceID; self.seq = seq
    }

    func stateChanges() async -> AsyncThrowingStream<DeviceStateChange, any Error> {
        guard let wsURL = config.websocketURL else {
            return AsyncThrowingStream { $0.finish(throwing: IoTError.notConfigured) }
        }
        let token = self.token, wanted = deviceID.rawValue, seq = self.seq
        let client = RealtimeSocketClient<HAMessage>(
            makeTransport: { HAWebSocketTransport(url: wsURL) },
            decode: { HAMessage.decode($0) },
            onConnected: { transport in
                _ = try await transport.receive()                        // auth_required
                try await transport.send(HAOutbound.auth(token: token))
                guard case .authOK = HAMessage.decode(try await transport.receive()) else {
                    throw IoTError.authenticationFailed(reason: "auth_invalid")
                }
                try await transport.send(HAOutbound.subscribeStateChanged(id: 1))
            },
            // HA answers pings with an inbound `pong` frame — liveness lands via receive(), not here.
            ping: { transport in try? await transport.send(HAOutbound.ping(id: 999)); return false })
        self.socket = client
        let raw = await client.messages()
        return AsyncThrowingStream { continuation in
            let task = Task {
                for await msg in raw {
                    if case .stateChanged(let e) = msg, e.entityID == wanted {
                        continuation.yield(.snapshot(e.deviceState(sequence: await seq.next())))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
