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
    public nonisolated let id: ProviderID = "shelly"
    public nonisolated let displayName = "Shelly"

    private var configs: [DeviceID: ShellyDeviceConfig]
    private let cloud: ShellyCloudConfig?
    private let rpc: ShellyRPC
    private let context: ExecutionContext
    private let seq = SequenceGen()

    /// - Parameter context: `.systemExtension` (Widget/Siri/Control) routes control **remote-first**
    ///   since those surfaces can't reach the LAN; `.app` is local-first.
    public init(devices: [ShellyDeviceConfig], cloud: ShellyCloudConfig? = nil,
                context: ExecutionContext = .app, rpc: ShellyRPC = ShellyURLSessionRPC()) {
        self.configs = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        self.cloud = cloud
        self.context = context
        self.rpc = rpc
    }

    public func connect() async throws {}
    public func disconnect() async {}

    public func devices() async throws -> [Device] {
        configs.values.map { c in
            Device(id: c.id, providerID: id, nativeID: c.host, name: c.name, kind: .outlet,
                   capabilities: [.control, .readState, .schedule].map { CapabilityDescriptor(id: $0, operations: []) })
        }
    }

    public func capabilities(for deviceID: DeviceID) async throws -> DeviceCapabilitySet {
        guard let c = configs[deviceID] else { throw IoTError.notConfigured }
        let client = ShellyClient(host: c.host, password: c.password, rpc: rpc)
        // Discover what THIS device actually exposes (Shelly.ListMethods); fall back to assuming
        // control+schedule if discovery is unavailable.
        let methods = await client.listMethods()
        let hasSchedule = methods.isEmpty || methods.contains("Schedule.Create")
        var descriptors: [CapabilityDescriptor] = [
            CapabilityDescriptor(id: .readState, operations: [.readState]),
            CapabilityDescriptor(id: .control, operations: [.control]),
        ]
        var schedule: (any ScheduleCapability)?
        if hasSchedule {
            descriptors.append(CapabilityDescriptor(id: .schedule, operations: [.schedule]))
            schedule = ShellyScheduleCapability(client: client, config: c)
        }
        return DeviceCapabilitySet(
            descriptors: descriptors,
            control: ShellyControlCapability(client: client, config: c, cloud: cloud, context: context, seq: seq),
            readState: ShellyReadStateCapability(client: client, config: c, seq: seq),
            schedule: schedule)
    }

    public func connectionEvents() async -> AsyncStream<ProviderConnectionEvent> {
        let id = self.id
        return AsyncStream { c in c.yield(ProviderConnectionEvent(providerID: id, state: .connected)); c.finish() }
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
        shellyState(await client.switchState(id: config.switchID), id: config.id, seq: await seq.next())
    }
}

actor ShellyControlCapability: ControlCapability {
    public nonisolated let descriptor = CapabilityDescriptor(id: .control, operations: [.control])
    private let client: ShellyClient; private let config: ShellyDeviceConfig
    private let cloud: ShellyCloudConfig?; private let context: ExecutionContext; private let seq: SequenceGen
    init(client: ShellyClient, config: ShellyDeviceConfig, cloud: ShellyCloudConfig?, context: ExecutionContext, seq: SequenceGen) {
        self.client = client; self.config = config; self.cloud = cloud; self.context = context; self.seq = seq
    }

    private func cloudSet(_ on: Bool) async -> Bool {
        guard let cloud, !config.mac.isEmpty else { return false }
        return await ShellyCloudClient.setSwitch(server: cloud.server, authKey: cloud.authKey,
                                                 deviceID: config.mac, channel: config.switchID, on: on)
    }

    /// Order local vs cloud by execution context (extension → remote-first), each falling back to the
    /// other; then confirm-by-reread. `.uncertain` when nothing could confirm.
    func execute<C: DeviceCommand>(_ command: C) async throws -> CommandReceipt {
        guard case .setPower(let on) = command.payload else { throw IoTError.notSupported("Shelly control supports power") }
        func receipt(_ o: CommandOutcome, _ s: DeviceState?) -> CommandReceipt {
            CommandReceipt(commandID: command.id, deviceID: config.id, outcome: o, state: s)
        }
        var sent: Bool
        if context.prefersRemoteTransport {                              // extension: cloud-first
            sent = await cloudSet(on)
            if !sent { sent = await client.setSwitch(id: config.switchID, on: on) }
        } else {                                                         // app: local-first
            sent = await client.setSwitch(id: config.switchID, on: on)
            if !sent { sent = await cloudSet(on) }
        }
        guard sent else { return receipt(.uncertain, nil) }
        let now = await client.switchState(id: config.switchID)          // confirm-by-reread (local)
        let s = shellyState(now, id: config.id, seq: await seq.next())
        // Sent OK but can't read back (off-LAN / cloud path) → accepted (not confirmed), not uncertain.
        if now == nil { return receipt(.accepted, nil) }
        return receipt(now == on ? .applied : .rejected, s)
    }
}

/// On-device schedule (Shelly cron). Daily job; replaces its own job id (never the user's schedules).
actor ShellyScheduleCapability: ScheduleCapability {
    public nonisolated let descriptor = CapabilityDescriptor(id: .schedule, operations: [.schedule])
    private let client: ShellyClient; private let config: ShellyDeviceConfig
    private var jobID: Int?
    init(client: ShellyClient, config: ShellyDeviceConfig) { self.client = client; self.config = config }

    func schedules() async throws -> [DeviceSchedule] { [] }

    func upsert(_ schedule: DeviceSchedule) async throws -> DeviceSchedule {
        if let old = jobID { await client.deleteSchedule(jobID: old) }
        let on: Bool = { if case .setPower(let v) = schedule.command { return v }; return true }()
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute], from: schedule.start)
        jobID = await client.createDailySchedule(switchID: config.switchID, on: on, hour: c.hour ?? 0, minute: c.minute ?? 0)
        guard jobID != nil else { throw IoTError.transport("Schedule.Create failed") }
        return schedule
    }

    func removeSchedule(id: ScheduleID) async throws {
        if let old = jobID { await client.deleteSchedule(jobID: old); jobID = nil }
    }
}
