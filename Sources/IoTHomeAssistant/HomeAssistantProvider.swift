import Foundation
import CryptoKit
import IoTCore

/// Home Assistant provider — the pivot integration. Exposes each HA entity as a `Device` with
/// per-device capabilities. Scheduling is opt-in and requires the separately provisioned, verified
/// LorisIoT server component. An input_datetime helper name alone never enables scheduling.
public actor HomeAssistantProvider: DeviceProvider {
    public nonisolated let id: ProviderID
    public nonisolated let displayName = "Home Assistant"

    private let config: HAConfig
    let rest: HARestClient
    private let http: any HAHTTP
    private let scheduling: HASchedulingConfiguration?
    private let schedulingProviderID: ProviderID
    private var scheduleHandles: [DeviceID: HAOwnedSchedules] = [:]
    private var scheduleHealthTask: Task<HAScheduleHealth, any Error>?
    private var scheduleHealthCache: (ContinuousClock.Instant, Result<HAScheduleHealth, any Error>)?
    private var scheduleProbeGeneration: UInt64 = 0
    private let seq: SequenceGen
    private let events: ConnectionEventHub
    let stateSession: HAStateSession
    private var connected = false
    /// Advanced by `disconnect()`, so a `connect()` still verifying cannot resurrect the connection.
    private var lifecycle: UInt64 = 0

    public init(config: HAConfig, token: String, http: HAHTTP? = nil, wakeHelperEntity: String? = nil,
                id: ProviderID = "home-assistant",
                makeTransport: (@Sendable () async -> any RealtimeTransport)? = nil,
                scheduling: HASchedulingConfiguration? = nil) {
        self.init(config: config, tokenProvider: { token }, http: http,
                  wakeHelperEntity: wakeHelperEntity, id: id, makeTransport: makeTransport, scheduling: scheduling)
    }

    public init(config: HAConfig, tokenProvider: @escaping @Sendable () async throws -> String,
                http: HAHTTP? = nil, wakeHelperEntity: String? = nil, id: ProviderID = "home-assistant",
                makeTransport: (@Sendable () async -> any RealtimeTransport)? = nil,
                scheduling: HASchedulingConfiguration? = nil) {
        self.id = id
        self.config = config
        let http = http ?? HAURLSessionHTTP(baseURL: config.baseURL, tokenProvider: tokenProvider)
        self.http = http; self.rest = HARestClient(http: http); self.scheduling = scheduling
        let hash = SHA256.hash(data: Data(config.baseURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        self.schedulingProviderID = ProviderID(rawValue: id.rawValue + "." + hash)
        let sequence = SequenceGen()
        let events = ConnectionEventHub(providerID: id)
        self.seq = sequence; self.events = events
        self.stateSession = HAStateSession(url: config.websocketURL, token: tokenProvider, makeTransport: makeTransport,
                                          events: events, sequence: sequence)
    }

    public func connect() async throws {
        let lifecycle = self.lifecycle
        let epoch = await stateSession.pauseEpoch
        await events.publish(.connecting)
        do {
            _ = try await rest.verify()
            // A disconnect requested while verifying wins over this late result.
            guard lifecycle == self.lifecycle else { throw CancellationError() }
            connected = true
            // REST answering does not bring live updates back; the stream reports when it recovers. The session
            // refuses to resume or publish if a disconnect paused it at any point since `epoch`.
            guard await stateSession.restConnected(epoch: epoch) else { throw CancellationError() }
        } catch {
            guard lifecycle == self.lifecycle else { throw error }
            connected = false
            await stateSession.setIdleState(.disconnected)
            guard lifecycle == self.lifecycle else { throw error }
            await events.publish(.degraded, reason: "Home Assistant connection failed")
            throw error
        }
    }
    public func disconnect() async {
        lifecycle &+= 1
        connected = false
        scheduleProbeGeneration &+= 1
        scheduleHealthTask?.cancel(); scheduleHealthTask = nil; scheduleHealthCache = nil
        await stateSession.disconnect()
        await events.publish(.disconnected)
    }

    /// One-shot snapshot of every entity as a `Device`.
    public func devices() async throws -> [Device] {
        let schedulable = Set((try? await schedulingTargets()) ?? [])
        return try await rest.states().map { Self.device(from: $0, provider: id,
            canSchedule: schedulable.contains(DeviceID(rawValue: $0.entityID))) }
    }

    /// Per-device typed capability handles — no casts on the consumer side.
    public func capabilities(for deviceID: DeviceID) async throws -> DeviceCapabilitySet {
        guard HARestClient.isEntityID(deviceID.rawValue) else { throw IoTError.notConfigured }
        var descriptors: [CapabilityDescriptor] = [
            CapabilityDescriptor(id: .readState, operations: [.readState]),
            CapabilityDescriptor(id: .subscribe, operations: [.subscribe]),
        ]
        let controllable = Self.supportsPower(deviceID.rawValue)
        if controllable {
            descriptors.append(CapabilityDescriptor(id: .control, operations: [.control]))
        }
        var schedule: HAOwnedSchedules?
        if controllable, let scheduling,
           let targets = try? await schedulingTargets(), targets.contains(deviceID) {
            if scheduleHandles[deviceID] == nil {
                scheduleHandles[deviceID] = HAOwnedSchedules(http: http, deviceID: deviceID,
                    providerID: schedulingProviderID, configuration: scheduling)
            }
            schedule = scheduleHandles[deviceID]
            descriptors.append(CapabilityDescriptor(id: .schedule, operations: [.schedule]))
        }
        return DeviceCapabilitySet(
            descriptors: descriptors,
            control: controllable ? HAControlCapability(rest: rest, deviceID: deviceID, seq: seq) : nil,
            readState: HAReadStateCapability(rest: rest, deviceID: deviceID, seq: seq),
            schedule: schedule,
            subscribe: HASubscribeCapability(session: stateSession, deviceID: deviceID))
    }

    public func connectionEvents() async -> AsyncStream<ProviderConnectionEvent> {
        await events.events()
    }

    /// Read-only readiness probe. Concurrent callers share a probe; successes and failures expire.
    public func schedulingTargets() async throws -> [DeviceID] {
        guard scheduling != nil else { throw IoTError.notSupported("Server scheduling is not configured") }
        let generation = scheduleProbeGeneration
        let health: HAScheduleHealth
        if let (instant, result) = scheduleHealthCache, instant.duration(to: .now) < .seconds(10) {
            health = try result.get()
        } else if let task = scheduleHealthTask {
            health = try await task.value
        } else {
            let api = HAScheduleAPI(http: http)
            let task = Task { try await api.health() }
            scheduleHealthTask = task
            let result = await task.result
            guard generation == scheduleProbeGeneration else { throw CancellationError() }
            scheduleHealthTask = nil; scheduleHealthCache = (.now, result)
            health = try result.get()
            let allowed = Set(health.allowedTargets)
            scheduleHandles = scheduleHandles.filter { allowed.contains($0.key.rawValue) }
        }
        guard generation == scheduleProbeGeneration else { throw CancellationError() }
        return health.allowedTargets.filter(Self.supportsPower).map(DeviceID.init(rawValue:))
    }

    static func device(from e: HAEntityState, provider: ProviderID, canSchedule: Bool) -> Device {
        var caps = [CapabilityID.readState, .subscribe]
        if supportsPower(e.entityID) { caps.append(.control) }
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

    static func supportsPower(_ entityID: String) -> Bool {
        ["light", "switch", "fan", "input_boolean"].contains(haDomain(of: entityID))
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

    /// Refusals decided before any request byte is sent, or an explicit credential rejection by HA.
    static func provesNotExecuted(_ error: IoTError) -> Bool {
        switch error {
        case .notSupported, .notConfigured: return true
        case .authenticationFailed(let reason): return reason == "HTTP 401" || reason == "HTTP 403"
        default: return false
        }
    }

    /// Execute + confirm-by-reread. Outcome: `.applied` (confirmed), `.rejected` (refused, or the requested state was not observed on the readback — not proof of non-execution),
    /// `.uncertain` (transport failed after the send may have happened — never silently "succeed").
    func execute<C: DeviceCommand>(_ command: C) async throws -> CommandReceipt {
        guard command.deviceID == deviceID else { throw IoTError.notConfigured }
        let domain = haDomain(of: deviceID.rawValue)
        func receipt(_ outcome: CommandOutcome, _ state: DeviceState?) -> CommandReceipt {
            CommandReceipt(commandID: command.id, deviceID: deviceID, outcome: outcome, state: state)
        }
        switch command.payload {
        case .setPower(let on):
            do { try await rest.callService(domain: domain, service: on ? "turn_on" : "turn_off", entityID: deviceID.rawValue) }
            catch let e as IoTError where Self.provesNotExecuted(e) { throw e }
            catch { return receipt(.uncertain, nil) }
            let s: HAEntityState
            do { s = try await rest.state(entityID: deviceID.rawValue) }
            catch { return receipt(.accepted, nil) }
            return receipt(s.isOn == on ? .applied : .rejected, s.deviceState(sequence: await seq.next()))
        case .setLevel(let interval):
            guard domain == "light" else { throw IoTError.notSupported("Brightness requires a light") }
            do { try await rest.callService(domain: domain, service: "turn_on", entityID: deviceID.rawValue, data: ["brightness_pct": interval.percent]) }
            catch let e as IoTError where Self.provesNotExecuted(e) { throw e }
            catch { return receipt(.uncertain, nil) }
            let s: HAEntityState
            do { s = try await rest.state(entityID: deviceID.rawValue) }
            catch { return receipt(.accepted, nil) }
            // Confirm against what was actually sent: HA receives a rounded percent, converts it itself
            // (round(pct × 255 / 100)), and turns the light off at 0 %.
            let sent = interval.percent
            let expected = Int((Double(sent) * 255 / 100).rounded())
            let confirmed = sent == 0 ? s.isOn == false
                : s.isOn == true && s.brightness.map { abs($0 - expected) <= 1 } == true
            return receipt(confirmed ? .applied : .rejected, s.deviceState(sequence: await seq.next()))
        default:
            throw IoTError.notSupported("HA control supports power/level")
        }
    }
}

/// Live `state_changed` for one entity, over the resilient WebSocket (auth handshake + subscribe on
/// every reconnect). Filters the shared stream to this device.
actor HASubscribeCapability: SubscribeCapability {
    public nonisolated let descriptor = CapabilityDescriptor(id: .subscribe, operations: [.subscribe])
    private let session: HAStateSession
    private let deviceID: DeviceID
    init(session: HAStateSession, deviceID: DeviceID) { self.session = session; self.deviceID = deviceID }
    func stateChanges() async -> AsyncThrowingStream<DeviceStateChange, any Error> {
        await session.stream(for: deviceID)
    }
}
