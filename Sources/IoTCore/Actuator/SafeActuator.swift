import Foundation

/// A vendor-neutral on/off actuator with the **confirm-by-reread** contract: `setOn` must re-read and
/// throw if the requested state isn't confirmed — never optimistic success. Generalized from Piscine
/// `PumpControlling`; any relay/plug/charger conforms.
public protocol Actuator: Sendable {
    nonisolated var vendor: String { get }
    func read() async throws -> ActuatorState
    @discardableResult
    func setOn(_ on: Bool) async throws -> ActuatorState
}

public struct ActuatorState: Sendable, Equatable {
    public var isOn: Bool?     // nil = unknown (never optimistic)
    public var name: String?
    public init(isOn: Bool? = nil, name: String? = nil) { self.isOn = isOn; self.name = name }
}

/// Software safety limits for any scheduled actuator. Generalized from Piscine `PumpSafetyLimits` —
/// applies to a pool pump, an EV charger, a space heater on a smart plug, anything with runtime /
/// forbidden-window constraints. Minutes-of-day are half-open ranges; a night window that wraps
/// midnight is encoded as two ranges.
public struct SafetyLimits: Sendable, Equatable {
    public var maxContinuousRuntime: TimeInterval?          // nil = no runtime cap
    public var forbiddenWindows: [Range<Int>]              // minutes-of-day [start,end)
    public var overrideProtectionActive: Bool              // e.g. freeze/thermal override forces allow

    public init(maxContinuousRuntime: TimeInterval? = nil,
                forbiddenWindows: [Range<Int>] = [],
                overrideProtectionActive: Bool = false) {
        self.maxContinuousRuntime = maxContinuousRuntime
        self.forbiddenWindows = forbiddenWindows
        self.overrideProtectionActive = overrideProtectionActive
    }
}

public enum SafetyDecision: Sendable, Equatable {
    case allow
    case deny(reason: String)
    case forceStop(reason: String)   // runtime overrun → must switch OFF regardless
}

public enum SafetyError: Error, Sendable, Equatable, LocalizedError {
    case denied(String)
    case forcedStop(String)
    public var errorDescription: String? {
        switch self {
        case .denied(let r): return r
        case .forcedStop(let r): return r
        }
    }
}

/// Pure, deterministic safety decision core — clock + calendar injected, fully unit-testable.
/// Priority ladder: (1) runtime overrun → `forceStop` (beats everything, incl. override); (2)
/// forbidden window → `deny` unless an override is active; (3) any OFF request is always allowed.
public enum SafetyEnvelope {
    public static func evaluate(requestOn: Bool,
                                runningSince: Date?,
                                limits: SafetyLimits,
                                now: Date,
                                calendar: Calendar = .current) -> SafetyDecision {
        // (1) Runtime overrun always force-stops — motor/hardware protection wins over all else.
        if let cap = limits.maxContinuousRuntime, let since = runningSince,
           now.timeIntervalSince(since) >= cap {
            return .forceStop(reason: "Maximum continuous runtime reached")
        }
        // (3) Turning OFF is never blocked.
        guard requestOn else { return .allow }
        // (2) Forbidden window denies ON unless an override (e.g. freeze protection) is active.
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        let minuteOfDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let inForbidden = limits.forbiddenWindows.contains { $0.contains(minuteOfDay) }
        if inForbidden && !limits.overrideProtectionActive {
            return .deny(reason: "Within a forbidden operating window")
        }
        return .allow
    }
}

/// Decorator that wraps ANY `Actuator` in the safety envelope. Confines runtime tracking inside the
/// actor; on a `forceStop` it forces the relay OFF *then* throws — impossible to bypass. Generalized
/// from Piscine `SafePumpController`.
public actor SafeActuator: Actuator {
    public nonisolated let vendor: String
    private let wrapped: Actuator
    private let limits: SafetyLimits
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private var runningSince: Date?

    public init(_ wrapped: Actuator,
                limits: SafetyLimits,
                calendar: Calendar = .current,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.wrapped = wrapped
        self.limits = limits
        self.calendar = calendar
        self.now = now
        self.vendor = wrapped.vendor
    }

    public func read() async throws -> ActuatorState { try await wrapped.read() }

    @discardableResult
    public func setOn(_ on: Bool) async throws -> ActuatorState {
        switch SafetyEnvelope.evaluate(requestOn: on, runningSince: runningSince,
                                       limits: limits, now: now(), calendar: calendar) {
        case .forceStop(let reason):
            _ = try? await wrapped.setOn(false)   // force OFF first, then refuse
            runningSince = nil
            throw SafetyError.forcedStop(reason)
        case .deny(let reason):
            throw SafetyError.denied(reason)
        case .allow:
            let state = try await wrapped.setOn(on)
            runningSince = (state.isOn == true) ? (runningSince ?? now()) : nil
            return state
        }
    }
}
