import Foundation

// MARK: - Capability actors (each mutable capability owns its isolation)

public protocol Capability: Actor {
    nonisolated var descriptor: CapabilityDescriptor { get }
}

/// Execute normalized domain commands. Returns a receipt whose `outcome` distinguishes
/// applied / accepted / rejected / uncertain (drives retry + local→cloud fallback).
public protocol ControlCapability: Capability {
    func execute<C: DeviceCommand>(_ command: C) async throws -> CommandReceipt
}

public protocol ReadStateCapability: Capability {
    func state() async throws -> DeviceState
}

public protocol ScheduleCapability: Capability {
    func schedules() async throws -> [DeviceSchedule]
    func upsert(_ schedule: DeviceSchedule) async throws -> DeviceSchedule
    func removeSchedule(id: ScheduleID) async throws
}

public protocol SubscribeCapability: Capability {
    func stateChanges() async -> AsyncThrowingStream<DeviceStateChange, any Error>
}

public enum DeviceStateChange: Sendable {
    case snapshot(DeviceState)
    case updated(previous: DeviceState?, current: DeviceState)
    case unavailable(deviceID: DeviceID, at: Date)
}

/// Typed capability discovery — the consumer uses whichever handles exist, with **no casts**.
public struct DeviceCapabilitySet: Sendable {
    public let descriptors: [CapabilityDescriptor]
    public let control: (any ControlCapability)?
    public let readState: (any ReadStateCapability)?
    public let schedule: (any ScheduleCapability)?
    public let subscribe: (any SubscribeCapability)?
    public init(descriptors: [CapabilityDescriptor],
                control: (any ControlCapability)? = nil,
                readState: (any ReadStateCapability)? = nil,
                schedule: (any ScheduleCapability)? = nil,
                subscribe: (any SubscribeCapability)? = nil) {
        self.descriptors = descriptors
        self.control = control; self.readState = readState; self.schedule = schedule; self.subscribe = subscribe
    }
}

// MARK: - Provider connectivity

public enum ProviderConnectionState: String, Codable, Hashable, Sendable {
    case disconnected, connecting, connected, degraded
}

public struct ProviderConnectionEvent: Codable, Hashable, Sendable {
    public let providerID: ProviderID
    public let state: ProviderConnectionState
    public let occurredAt: Date
    public let reason: String?
    public init(providerID: ProviderID, state: ProviderConnectionState, occurredAt: Date = Date(), reason: String? = nil) {
        self.providerID = providerID; self.state = state; self.occurredAt = occurredAt; self.reason = reason
    }
}

// MARK: - The single public provider protocol

/// Actor-constrained: sessions, sockets, caches and reconnection stay inside the provider's isolation.
/// Capabilities are discovered **per device** (two devices of the same provider can differ by
/// firmware/profile/rights — e.g. Shelly.ListMethods).
public protocol DeviceProvider: Actor {
    nonisolated var id: ProviderID { get }
    nonisolated var displayName: String { get }
    func connect() async throws
    func disconnect() async
    func devices() async throws -> [Device]
    func capabilities(for deviceID: DeviceID) async throws -> DeviceCapabilitySet
    func connectionEvents() async -> AsyncStream<ProviderConnectionEvent>
}
