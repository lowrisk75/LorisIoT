import Foundation

public enum ModelValidationError: Error, Codable, Hashable, Sendable {
    case unitIntervalOutOfRange(Double)
    case emptyActionName
}

/// A validated 0…1 value (brightness, position…). Rejects NaN/out-of-range at the boundary.
public struct UnitInterval: Codable, Hashable, Sendable, Comparable {
    public let value: Double
    public init(_ value: Double) throws {
        guard value.isFinite, (0.0...1.0).contains(value) else { throw ModelValidationError.unitIntervalOutOfRange(value) }
        self.value = value
    }
    public static func < (l: UnitInterval, r: UnitInterval) -> Bool { l.value < r.value }
    private enum CodingKeys: String, CodingKey { case value }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(container.decode(Double.self, forKey: .value))
    }
    public var percent: Int { Int((value * 100).rounded()) }
}

/// Replay semantics for retries / local→cloud fallback. HTTP can leave a lost-response command in an
/// ambiguous state — never auto-replay a non-idempotent command.
public enum CommandReplayPolicy: Codable, Hashable, Sendable {
    case never
    case replaySafe
    case idempotencyKey(String)
}

public enum CommandPayload: Codable, Hashable, Sendable {
    case setPower(Bool)
    case setLevel(UnitInterval)
    case setAttribute(name: String, value: StateValue)
    case invokeAction(name: String, arguments: [String: StateValue])
}

public protocol DeviceCommand: Codable, Hashable, Sendable {
    var id: CommandID { get }
    var deviceID: DeviceID { get }
    var replayPolicy: CommandReplayPolicy { get }
    var payload: CommandPayload { get }
}

public struct SetPowerCommand: DeviceCommand {
    public let id: CommandID
    public let deviceID: DeviceID
    public let isOn: Bool
    public let replayPolicy: CommandReplayPolicy
    public var payload: CommandPayload { .setPower(isOn) }
    public init(id: CommandID = CommandID(), deviceID: DeviceID, isOn: Bool,
                replayPolicy: CommandReplayPolicy = .replaySafe) {
        self.id = id; self.deviceID = deviceID; self.isOn = isOn; self.replayPolicy = replayPolicy
    }
}

public struct SetLevelCommand: DeviceCommand {
    public let id: CommandID
    public let deviceID: DeviceID
    public let level: UnitInterval
    public let replayPolicy: CommandReplayPolicy
    public var payload: CommandPayload { .setLevel(level) }
    public init(id: CommandID = CommandID(), deviceID: DeviceID, level: UnitInterval,
                replayPolicy: CommandReplayPolicy = .replaySafe) {
        self.id = id; self.deviceID = deviceID; self.level = level; self.replayPolicy = replayPolicy
    }
}

public enum CommandOutcome: String, Codable, Hashable, Sendable {
    case accepted    // provider took it, not yet confirmed applied
    case applied     // confirmed by re-read
    /// The provider refused, or the requested state was not observed on the immediate readback. In the
    /// second case the command may still have executed (a slow integration or transition): never treat
    /// `.rejected` as proof of non-execution or replay it automatically.
    case rejected
    case uncertain   // transport failed after the send may have happened
}

public struct CommandReceipt: Codable, Hashable, Sendable {
    public let commandID: CommandID
    public let deviceID: DeviceID
    public let outcome: CommandOutcome
    public let state: DeviceState?
    public let providerTransactionID: String?
    public let completedAt: Date
    public init(commandID: CommandID, deviceID: DeviceID, outcome: CommandOutcome, state: DeviceState? = nil,
                providerTransactionID: String? = nil, completedAt: Date = Date()) {
        self.commandID = commandID; self.deviceID = deviceID; self.outcome = outcome
        self.state = state; self.providerTransactionID = providerTransactionID; self.completedAt = completedAt
    }
}

// MARK: - Scheduling

public struct ScheduleID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum Weekday: Int, Codable, Hashable, Sendable, CaseIterable {
    case monday = 1, tuesday, wednesday, thursday, friday, saturday, sunday
}

public enum ScheduleRecurrence: Codable, Hashable, Sendable {
    case once, daily, weekly(Set<Weekday>)
}

public struct DeviceSchedule: Codable, Hashable, Sendable, Identifiable {
    public let id: ScheduleID
    public let deviceID: DeviceID
    public let command: CommandPayload
    public let start: Date
    public let recurrence: ScheduleRecurrence
    public let isEnabled: Bool
    public let timeZoneIdentifier: String?
    /// Seconds the device itself takes to reach the commanded level. A luminaire owns its ramp
    /// (Zigbee/Matter Level Control transition time), so a sunrise is one intent, never a step
    /// sequence driven by the app or the server. Nil means apply the command at once.
    public let transition: TimeInterval?
    public init(id: ScheduleID, deviceID: DeviceID, command: CommandPayload, start: Date,
                recurrence: ScheduleRecurrence, isEnabled: Bool, timeZoneIdentifier: String? = nil,
                transition: TimeInterval? = nil) {
        self.id = id; self.deviceID = deviceID; self.command = command; self.start = start
        self.recurrence = recurrence; self.isEnabled = isEnabled
        self.timeZoneIdentifier = timeZoneIdentifier; self.transition = transition
    }
}
