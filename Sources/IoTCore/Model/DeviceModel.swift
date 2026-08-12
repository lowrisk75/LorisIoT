import Foundation

/// What a provider can do. Gates what the app may ask for — the capability law: an app must never
/// promise a timed action through a provider that lacks `.schedule`.
public enum DeviceCapability: String, Sendable, Hashable, CaseIterable {
    case control     // set on/off / value now
    case readState   // read current state
    case subscribe   // push live updates
    case schedule    // pre-provision a timed action on an always-on system (device / server)
}

/// A vendor-neutral device state. Every provider maps its wire format into this one `Sendable`
/// value — the app never sees provider-specific shapes. `power` is optional to model "unknown"
/// (never optimistic; see the confirm-by-reread contract on `DeviceProvider.setState`).
public struct DeviceState: Sendable, Equatable {
    public var power: Bool?          // on/off, nil = unknown
    public var level: Int?           // 0…100 (brightness/position/speed), nil = n/a
    public var name: String?
    public var reachable: Bool
    public var raw: [String: String] // provider-specific extras, stringly-typed to stay Sendable

    public init(power: Bool? = nil, level: Int? = nil, name: String? = nil,
                reachable: Bool = true, raw: [String: String] = [:]) {
        self.power = power
        self.level = level
        self.name = name
        self.reachable = reachable
        self.raw = raw
    }
}

/// A command to apply to a device.
public enum DeviceCommand: Sendable, Equatable {
    case setPower(Bool)
    case setLevel(Int)          // 0…100
    case toggle
}

/// Identifies which device/channel a command targets within a provider.
public struct DeviceTarget: Sendable, Equatable, Hashable {
    public let id: String       // provider-scoped device id
    public let channel: Int     // relay/endpoint channel (0 when single)
    public init(id: String, channel: Int = 0) { self.id = id; self.channel = channel }
}

/// A timed action to pre-provision on an always-on system (Shelly cron / HomeKit timer / HA
/// input_datetime). `daily` mirrors the Shelly reality (cron, no one-shot date) — the caller
/// re-provisions on each evaluation.
public struct DeviceSchedule: Sendable, Equatable {
    public enum Recurrence: Sendable, Equatable { case daily, weekly(Set<Int>) }  // weekday 1=Sun…7=Sat
    public let target: DeviceTarget
    public let command: DeviceCommand
    public let hour: Int
    public let minute: Int
    public let recurrence: Recurrence

    public init(target: DeviceTarget, command: DeviceCommand, hour: Int, minute: Int,
                recurrence: Recurrence = .daily) {
        self.target = target
        self.command = command
        self.hour = hour
        self.minute = minute
        self.recurrence = recurrence
    }
}

/// Opaque handle to a provisioned schedule so the caller can replace/clear only its own job.
public struct ScheduleHandle: Sendable, Equatable, Hashable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Normalized failure taxonomy. The auth/transport/decode distinction drives recovery: re-pair on
/// `.authenticationFailed`, retry on transport errors.
public enum ProviderError: Error, Sendable, Equatable {
    case notConfigured
    case notConnected
    case authenticationFailed(reason: String)
    case invalidResponse
    case unconfirmed              // setState could not confirm the physical state (confirm-by-reread)
    case timeout
    case cancelled
    case notSupported(String)
    case transport(String)
}
