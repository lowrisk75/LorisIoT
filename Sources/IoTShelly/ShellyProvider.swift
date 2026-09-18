import Foundation
import IoTCore

/// A user-added Shelly device. `mac` (lowercased) is the cloud id for the remote fallback.
public struct ShellyDeviceConfig: Sendable, Hashable, Identifiable {
    public let id: DeviceID
    public let name: String
    public let host: String
    public let switchID: Int
    public let mac: String
    public let password: String?
    public init(id: DeviceID, name: String, host: String, switchID: Int = 0, mac: String = "", password: String? = nil) {
        self.id = id; self.name = name; self.host = host; self.switchID = switchID; self.mac = mac; self.password = password
    }
}

/// Account-level Shelly Cloud credentials (remote on/off fallback).
public struct ShellyCloudConfig: Sendable, Hashable {
    public let server: String
    public let authKey: String
    public init(server: String, authKey: String) { self.server = server; self.authKey = authKey }
}

/// Shelly provider — native local Gen2/3 RPC (control + on-device schedule) with a Shelly-Cloud
/// control-only fallback when off-LAN. Ported from Velya. Capabilities are per device.
public actor ShellyProvider: DeviceProvider {
    public nonisolated let id: ProviderID
    public nonisolated let displayName = "Shelly"

    private var configs: [DeviceID: ShellyDeviceConfig]
    private let cloud: ShellyCloudConfig?
    private let rpc: ShellyRPC
    private let routing: TransportRoutingPolicy
    private let seq = SequenceGen()
    private let events: ConnectionEventHub
    private let validConfiguration: Bool
    private let scheduleOwner: ScheduleOwner?
    private let scheduleStore: (any ScheduleStore)?
    private let qualifiedYearSupport: Set<DeviceID>
    private var schedulers: [DeviceID: ShellyOwnedSchedules] = [:]
    private var deviceInfo: [DeviceID: ShellyInfo] = [:]
    private var cloudHTTP: any ShellyCloudHTTP = ShellyCloudURLSessionHTTP()
    /// Test seam for the secret-bearing cloud boundary.
    func useCloudHTTP(_ http: any ShellyCloudHTTP) { cloudHTTP = http }

    /// `context` is ignored and kept only for source compatibility: pass `routing` to choose local or cloud.
    public init(devices: [ShellyDeviceConfig], cloud: ShellyCloudConfig? = nil,
                context: ExecutionContext = .app, rpc: ShellyRPC = ShellyURLSessionRPC(),
                scheduleOwner: ScheduleOwner? = nil, scheduleStore: (any ScheduleStore)? = nil,
                qualifiedYearSupport: Set<DeviceID> = [], id: ProviderID = "shelly",
                routing: TransportRoutingPolicy = .localFirst) {
        self.id = id; self.events = ConnectionEventHub(providerID: id)
        self.validConfiguration = Set(devices.map(\.id)).count == devices.count
            && devices.allSatisfy { !$0.id.rawValue.isEmpty && $0.switchID >= 0 }
        self.configs = devices.reduce(into: [:]) { $0[$1.id] = $1 }
        self.cloud = cloud
        self.routing = routing
        self.rpc = rpc
        self.scheduleOwner = scheduleOwner; self.scheduleStore = scheduleStore
        self.qualifiedYearSupport = qualifiedYearSupport
    }

    public func connect() async throws {
        guard validConfiguration, !configs.isEmpty else { throw IoTError.notConfigured }
        await events.publish(.connecting)
        // Remote-only routing never depends on the LAN: the configured cloud is the transport.
        if routing == .remoteOnly {
            guard let cloud, configs.values.allSatisfy({ !$0.mac.isEmpty }) else {
                await events.publish(.degraded, reason: "Shelly cloud is not configured")
                throw IoTError.notConfigured
            }
            // Without LAN proof, only the cloud confirming each device earns "connected".
            let listed: [ShellyCloudDevice]
            do {
                listed = try await ShellyCloudClient.fetchDevices(server: cloud.server, authKey: cloud.authKey, http: cloudHTTP)
            } catch {
                await events.publish(.degraded, reason: "Shelly Cloud could not be reached")
                throw error
            }
            let online = Dictionary(listed.map { ($0.id, $0.online) }, uniquingKeysWith: { $0 || $1 })
            let unknown = configs.values.filter { online[$0.mac.lowercased()] == nil }.count
            let offline = configs.values.filter { online[$0.mac.lowercased()] == false }.count
            if unknown > 0 {
                await events.publish(.degraded, reason: "\(unknown) Shelly devices are not in this Shelly Cloud account")
            } else if offline > 0 {
                await events.publish(.degraded, reason: "\(offline) of \(configs.count) Shelly devices offline in Shelly Cloud")
            } else {
                await events.publish(.connected)
            }
            return
        }
        var reached = 0
        var lastFailure: (any Error)?
        for config in configs.values {
            let info: ShellyInfo
            do {
                info = try await ShellyClient(host: config.host, password: config.password, rpc: rpc).probe()
            } catch {
                lastFailure = error // One unreachable device must not take the others down.
                continue
            }
            // A reachable device without the configured relay is a configuration error, not an outage.
            guard info.switchIDs.contains(config.switchID) else {
                await events.publish(.degraded, reason: "Shelly connection failed")
                throw IoTError.notSupported("This Shelly has no configured relay")
            }
            deviceInfo[config.id] = info
            reached += 1
        }
        if reached == configs.count {
            await events.publish(.connected)
            return
        }
        let cloudFallback = cloud != nil && routing != .localOnly
        guard reached > 0 || cloudFallback else {
            await events.publish(.degraded, reason: "Shelly connection failed")
            throw lastFailure ?? IoTError.timeout
        }
        await events.publish(.degraded,
            reason: "\(configs.count - reached) of \(configs.count) Shelly devices unreachable on the local network")
    }
    public func disconnect() async { await events.publish(.disconnected) }

    /// Offline listing from configuration. Scheduling is never listed here because it needs a per-device RPC
    /// probe; `capabilities(for:)` is the authoritative source.
    public func devices() async throws -> [Device] {
        configs.values.map { c in
            Device(id: c.id, providerID: id, nativeID: c.host, name: c.name, kind: .outlet,
                   model: deviceInfo[c.id]?.model,
                   capabilities: [.control, .readState].map { CapabilityDescriptor(id: $0, operations: []) })
        }
    }

    public func capabilities(for deviceID: DeviceID) async throws -> DeviceCapabilitySet {
        guard validConfiguration, let c = configs[deviceID] else { throw IoTError.notConfigured }
        let client = ShellyClient(host: c.host, password: c.password, rpc: rpc)
        // Scheduling needs both complete RPC support and durable app ownership.
        let methods = await client.listMethods()
        let hasSchedule = Set(["Schedule.Create", "Schedule.Update", "Schedule.List", "Schedule.Delete", "Sys.GetConfig"]).isSubset(of: methods)
        var descriptors: [CapabilityDescriptor] = [
            CapabilityDescriptor(id: .readState, operations: [.readState]),
            CapabilityDescriptor(id: .control, operations: [.control]),
        ]
        var schedule: (any ScheduleCapability)?
        if hasSchedule, let owner = scheduleOwner, let store = scheduleStore {
            descriptors.append(CapabilityDescriptor(id: .schedule, operations: [.schedule]))
            if schedulers[deviceID] == nil {
                schedulers[deviceID] = ShellyOwnedSchedules(client: client, deviceID: c.id, switchID: c.switchID,
                    owner: owner, store: store, providerID: id, supportsYear: qualifiedYearSupport.contains(c.id))
            }
            schedule = schedulers[deviceID]
        }
        return DeviceCapabilitySet(
            descriptors: descriptors,
            control: ShellyControlCapability(client: client, config: c, cloud: cloud, routing: routing, seq: seq,
                                             cloudHTTP: cloudHTTP),
            readState: ShellyReadStateCapability(client: client, config: c, seq: seq),
            schedule: schedule)
    }

    public func connectionEvents() async -> AsyncStream<ProviderConnectionEvent> {
        await events.events()
    }
}

// MARK: - Capabilities

private func shellyState(_ on: Bool?, id: DeviceID, seq: UInt64) -> DeviceState {
    DeviceState(deviceID: id, availability: on == nil ? .offline : .online,
                primaryValue: on.map { .bool($0) }, observedAt: Date(), origin: .local,
                revision: StateRevision(localSequence: seq))
}

actor ShellyReadStateCapability: ReadStateCapability {
    public nonisolated let descriptor = CapabilityDescriptor(id: .readState, operations: [.readState])
    private let client: ShellyClient; private let config: ShellyDeviceConfig; private let seq: SequenceGen
    init(client: ShellyClient, config: ShellyDeviceConfig, seq: SequenceGen) { self.client = client; self.config = config; self.seq = seq }
    func state() async throws -> DeviceState {
        let status = try await client.call(method: "Switch.GetStatus", params: ["id": config.switchID])
        guard let on = status["output"] as? Bool,
              status["id"] == nil || status["id"] as? Int == config.switchID else { throw IoTError.invalidResponse }
        var attributes: [String: StateAttribute] = [:]
        func measure(_ key: String, _ value: (any Sendable)?, _ unit: UnitSymbol, scale: Double = 1) {
            guard let number = value as? Double, number.isFinite else { return }
            attributes[key] = StateAttribute(value: .decimal(number * scale), unit: unit)
        }
        measure("power", status["apower"], .watt)
        measure("voltage", status["voltage"], .volt)
        measure("current", status["current"], .ampere)
        measure("device_temperature", (status["temperature"] as? [String: any Sendable])?["tC"], .celsius)
        measure("energy", (status["aenergy"] as? [String: any Sendable])?["total"], .kilowattHour, scale: 0.001)
        return DeviceState(deviceID: config.id, availability: .online, primaryValue: .bool(on),
            attributes: attributes, observedAt: Date(), origin: .local, revision: StateRevision(localSequence: await seq.next()))
    }
}

actor ShellyControlCapability: ControlCapability {
    public nonisolated let descriptor = CapabilityDescriptor(id: .control, operations: [.control])
    private let client: ShellyClient; private let config: ShellyDeviceConfig
    private let cloud: ShellyCloudConfig?; private let routing: TransportRoutingPolicy; private let seq: SequenceGen
    private let cloudHTTP: any ShellyCloudHTTP
    init(client: ShellyClient, config: ShellyDeviceConfig, cloud: ShellyCloudConfig?, routing: TransportRoutingPolicy,
         seq: SequenceGen, cloudHTTP: any ShellyCloudHTTP) {
        self.client = client; self.config = config; self.cloud = cloud; self.routing = routing; self.seq = seq
        self.cloudHTTP = cloudHTTP
    }

    private func cloudSet(_ on: Bool) async -> Bool {
        guard let cloud, !config.mac.isEmpty else { return false }
        return await ShellyCloudClient.setSwitch(server: cloud.server, authKey: cloud.authKey,
                                                 deviceID: config.mac, channel: config.switchID, on: on, http: cloudHTTP)
    }

    /// Follow the selected route, then verify the requested value through a device read.
    func execute<C: DeviceCommand>(_ command: C) async throws -> CommandReceipt {
        guard command.deviceID == config.id else { throw IoTError.notConfigured }
        guard case .setPower(let on) = command.payload else { throw IoTError.notSupported("Shelly control supports power") }
        func receipt(_ o: CommandOutcome, _ s: DeviceState?) -> CommandReceipt {
            CommandReceipt(commandID: command.id, deviceID: config.id, outcome: o, state: s)
        }
        try Task.checkCancellation()
        var sent: Bool
        var viaCloud = false
        if routing == .remoteFirst || routing == .remoteOnly {
            sent = await cloudSet(on); viaCloud = sent
            if !sent, routing == .remoteFirst, command.replayPolicy == .replaySafe, !Task.isCancelled { sent = await client.setSwitch(id: config.switchID, on: on) }
        } else {
            sent = await client.setSwitch(id: config.switchID, on: on)
            if !sent, routing == .localFirst, command.replayPolicy == .replaySafe, !Task.isCancelled { sent = await cloudSet(on); viaCloud = sent }
        }
        guard sent else { return receipt(.uncertain, nil) }
        guard !Task.isCancelled else { return receipt(.uncertain, nil) }
        if routing == .remoteOnly { return receipt(.accepted, nil) }
        let now = await client.switchState(id: config.switchID)
        let s = shellyState(now, id: config.id, seq: await seq.next())
        // Sent OK but can't read back (off-LAN / cloud path) → accepted (not confirmed), not uncertain.
        if now == nil { return receipt(.accepted, nil) }
        if now == on { return receipt(.applied, s) }
        // The cloud only queues the command; the relay may not have switched yet, so this is no refusal.
        return viaCloud ? receipt(.accepted, nil) : receipt(.rejected, s)
    }
}
