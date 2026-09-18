import Foundation
import IoTCore

/// HomeKit objects stay on the main actor behind a Sendable bridge. Scheduling requires an explicit
/// installation owner and durable journal; provisioning does not prove that a physical hub will fire.
public actor HomeKitProvider: DeviceProvider {
    public nonisolated let id: ProviderID
    public nonisolated let displayName = "HomeKit"
    private let transport: any HomeKitDeviceTransport
    private let owner: ScheduleOwner?
    private let store: (any ScheduleStore)?
    private let events: ConnectionEventHub
    private let seq = SequenceGen()
    private var scheduleHandles: [DeviceID: HomeKitOwnedSchedules] = [:]

    public init(homeID: UUID? = nil, owner: ScheduleOwner? = nil, store: (any ScheduleStore)? = nil,
                id: ProviderID = "homekit") {
        self.id = id; self.owner = owner; self.store = store
        self.transport = NativeHomeKitBridge(homeID: homeID)
        self.events = ConnectionEventHub(providerID: id)
    }
    init(transport: any HomeKitDeviceTransport, owner: ScheduleOwner? = nil, store: (any ScheduleStore)? = nil) {
        self.id = "homekit"; self.transport = transport; self.owner = owner; self.store = store
        self.events = ConnectionEventHub(providerID: "homekit")
    }
    public func connect() async throws {
        await events.publish(.connecting)
        do {
            _ = try await transport.devices()
            await events.publish(.connected)
        } catch {
            await events.publish(.degraded, reason: "HomeKit is unavailable")
            throw error
        }
    }
    public func disconnect() async {
        await transport.disconnect()
        await events.publish(.disconnected)
    }
    public func devices() async throws -> [Device] {
        try await transport.devices().map {
            Device(id: $0.id, providerID: id, nativeID: $0.id.rawValue, name: $0.name, kind: $0.kind,
                   capabilities: descriptors($0))
        }
    }
    private func descriptors(_ device: HomeKitDeviceDescription) -> [CapabilityDescriptor] {
        var result: [CapabilityDescriptor] = []
        if device.readable { result.append(.init(id: .readState, operations: [.readState])) }
        if device.writable { result.append(.init(id: .control, operations: [.control])) }
        if device.supportsTimers, device.writable, owner != nil, store != nil {
            result.append(.init(id: .schedule, operations: [.schedule]))
        }
        return result
    }
    public func capabilities(for deviceID: DeviceID) async throws -> DeviceCapabilitySet {
        guard UUID(uuidString: deviceID.rawValue) != nil,
              let device = try await transport.devices().first(where: { $0.id == deviceID }) else {
            throw IoTError.notConfigured
        }
        if device.supportsTimers, device.writable, let owner, let store, scheduleHandles[deviceID] == nil {
            scheduleHandles[deviceID] = HomeKitOwnedSchedules(transport: transport, deviceID: deviceID,
                owner: owner, store: store, providerID: id)
        }
        return DeviceCapabilitySet(descriptors: descriptors(device),
            control: device.writable ? HomeKitControlCapability(provider: self, deviceID: deviceID, seq: seq) : nil,
            readState: device.readable ? HomeKitReadStateCapability(provider: self, deviceID: deviceID, seq: seq) : nil,
            schedule: scheduleHandles[deviceID])
    }
    public func connectionEvents() async -> AsyncStream<ProviderConnectionEvent> { await events.events() }
    func setPower(_ deviceID: DeviceID, on: Bool) async throws { try await transport.setPower(deviceID, on: on) }
    func readPower(_ deviceID: DeviceID) async throws -> Bool {
        do { return try await transport.readPower(deviceID) }
        catch {
            await events.publish(.degraded, reason: "The accessory state could not be read")
            throw error
        }
    }
}

struct HomeKitDeviceDescription: Sendable {
    let id: DeviceID
    let name: String
    let kind: DeviceKind
    let readable: Bool
    let writable: Bool
    let supportsTimers: Bool
}

protocol HomeKitDeviceTransport: HomeKitTimerTransport {
    func devices() async throws -> [HomeKitDeviceDescription]
    func readPower(_ deviceID: DeviceID) async throws -> Bool
    func setPower(_ deviceID: DeviceID, on: Bool) async throws
    func disconnect() async
}

func homeKitState(_ on: Bool?, id: DeviceID, seq: UInt64) -> DeviceState {
    DeviceState(deviceID: id, availability: on == nil ? .offline : .online,
                primaryValue: on.map { .bool($0) }, observedAt: Date(), origin: .local,
                revision: StateRevision(localSequence: seq))
}

actor HomeKitControlCapability: ControlCapability {
    nonisolated let descriptor = CapabilityDescriptor(id: .control, operations: [.control])
    private let provider: HomeKitProvider
    private let deviceID: DeviceID
    private let seq: SequenceGen
    init(provider: HomeKitProvider, deviceID: DeviceID, seq: SequenceGen) {
        self.provider = provider; self.deviceID = deviceID; self.seq = seq
    }
    func execute<C: DeviceCommand>(_ command: C) async throws -> CommandReceipt {
        guard command.deviceID == deviceID else { throw IoTError.notConfigured }
        guard case .setPower(let on) = command.payload else { throw IoTError.notSupported("HomeKit power commands only") }
        func receipt(_ outcome: CommandOutcome, _ state: DeviceState? = nil) -> CommandReceipt {
            CommandReceipt(commandID: command.id, deviceID: deviceID, outcome: outcome, state: state)
        }
        try Task.checkCancellation()
        do { try await provider.setPower(deviceID, on: on) }
        catch { return receipt(.uncertain) }
        guard let observed = try? await provider.readPower(deviceID) else { return receipt(.accepted) }
        return receipt(observed == on ? .applied : .rejected,
                       homeKitState(observed, id: deviceID, seq: await seq.next()))
    }
}

actor HomeKitReadStateCapability: ReadStateCapability {
    nonisolated let descriptor = CapabilityDescriptor(id: .readState, operations: [.readState])
    private let provider: HomeKitProvider
    private let deviceID: DeviceID
    private let seq: SequenceGen
    init(provider: HomeKitProvider, deviceID: DeviceID, seq: SequenceGen) {
        self.provider = provider; self.deviceID = deviceID; self.seq = seq
    }
    func state() async throws -> DeviceState {
        homeKitState(try await provider.readPower(deviceID), id: deviceID, seq: await seq.next())
    }
}
