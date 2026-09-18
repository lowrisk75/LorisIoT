import Foundation

/// A vendor-neutral on/off actuator with the **confirm-by-reread** contract: `setOn` must re-read and
/// throw if the requested state isn't confirmed — never optimistic success. Generalized from Piscine
/// `PumpControlling`; any relay/plug/charger conforms.
public protocol Actuator: Sendable {
    nonisolated var vendor: String { get }
    func read() async throws -> ActuatorState
    /// Contract for adapters: once this throws, the command must not execute later (no transport-level
    /// replay or delayed delivery), or the runtime checkpoint can be cleared under a late ON. Report a
    /// confirmed state only when the relay was actually read back.
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
    case stopUnconfirmed
    public var errorDescription: String? {
        switch self {
        case .denied(let r): return r
        case .forcedStop(let r): return r
        case .stopUnconfirmed: return "The device has not confirmed stopping. Check the device."
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
        guard limits.forbiddenWindows.allSatisfy({ $0.lowerBound >= 0 && $0.upperBound <= 1440 }) else {
            return .deny(reason: "Invalid forbidden operating window")
        }
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
/// actor. An unconfirmed OFF keeps the runtime limit latched. This software envelope checks commands;
/// an unattended deadline additionally requires a device/server-side cutoff.
public actor SafeActuator: Actuator {
    public nonisolated let vendor: String
    private let wrapped: Actuator
    private let limits: SafetyLimits
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private var runningSince: Date?
    private let runtimeStore: (any ActuatorRuntimeStore)?
    private var commanding = false
    /// Advanced by every explicit stop, so a start suspended on I/O can tell that a stop overtook it.
    private var stopGeneration: UInt64 = 0
    /// Advanced just before a start writes its checkpoint. Together with `startOnWire` it enforces one rule:
    /// a stop may clear the checkpoint only if no start was dispatching when the stop was issued and none
    /// began before the stop completed. Otherwise the order at the relay is unknown, and only that start's
    /// own confirmed corrective OFF may clear it.
    private var startEpoch: UInt64 = 0
    private var startOnWire = false
    /// How long a stop that overlapped a start waits for that start to resolve before answering.
    private var overlapResolutionTimeout: Duration = .seconds(5)
    func setOverlapResolutionTimeout(_ timeout: Duration) { overlapResolutionTimeout = timeout }

    public init(_ wrapped: Actuator,
                limits: SafetyLimits,
                calendar: Calendar = .current,
                runtimeStore: (any ActuatorRuntimeStore)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.wrapped = wrapped
        self.limits = limits
        self.calendar = calendar
        self.now = now
        self.vendor = wrapped.vendor
        self.runtimeStore = runtimeStore
    }

    public func read() async throws -> ActuatorState { try await wrapped.read() }

    @discardableResult
    public func setOn(_ on: Bool) async throws -> ActuatorState {
        // Neither failed persistence nor a start suspended on I/O may prevent an explicit physical stop,
        // so a stop bypasses the in-flight guard and invalidates any start that is still under way.
        if !on {
            stopGeneration &+= 1
            let epoch = startEpoch
            let overlapped = startOnWire
            let state = try await wrapped.setOn(false)
            guard state.isOn == false else { throw SafetyError.stopUnconfirmed }
            if overlapped || startOnWire {
                // The order at the relay is unknown: let the overlapped start resolve (it sends its own
                // corrective OFF), then report OFF only if the relay reads OFF. Bounded, so a hung start
                // cannot hold the stop's answer forever; that case is honestly unconfirmed.
                let deadline = ContinuousClock.now + overlapResolutionTimeout
                while startOnWire, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
                guard !startOnWire, let observed = try? await wrapped.read(), observed.isOn == false else {
                    throw SafetyError.stopUnconfirmed
                }
                return observed
            }
            func mayClear() -> Bool { !startOnWire && startEpoch == epoch }
            guard mayClear() else { return state }
            try await runtimeStore?.setStartedAt(nil)
            if mayClear() { runningSince = nil }
            return state
        }
        guard !commanding else { throw IoTError.transport("An actuator command is already in progress") }
        commanding = true; defer { commanding = false }
        let startGeneration = stopGeneration
        if let runtimeStore { runningSince = try await runtimeStore.startedAt() }
        if let since = runningSince, since > now() {
            throw SafetyError.denied("The runtime checkpoint is ahead of the clock. Confirm an explicit stop before restarting.")
        }
        switch SafetyEnvelope.evaluate(requestOn: on, runningSince: runningSince,
                                       limits: limits, now: now(), calendar: calendar) {
        case .forceStop(let reason):
            let stopped: ActuatorState
            do { stopped = try await wrapped.setOn(false) }
            catch { throw SafetyError.stopUnconfirmed }
            guard stopped.isOn == false else { throw SafetyError.stopUnconfirmed }
            try await runtimeStore?.setStartedAt(nil)
            runningSince = nil
            if !on { return stopped }
            throw SafetyError.forcedStop(reason)
        case .deny(let reason):
            throw SafetyError.denied(reason)
        case .allow:
            if on, let cap = limits.maxContinuousRuntime, !cap.isFinite || cap <= 0 {
                throw SafetyError.denied("Invalid maximum runtime")
            }
            if on {
                if runningSince == nil, limits.maxContinuousRuntime != nil {
                    let prior = try await wrapped.read()
                    guard prior.isOn == false else {
                        throw SafetyError.denied("Previous runtime is unknown. Confirm an explicit stop before restarting.")
                    }
                }
                if stopGeneration != startGeneration {
                    throw SafetyError.denied("An explicit stop was requested while starting")
                }
                runningSince = runningSince ?? now()
                startEpoch &+= 1
                try await runtimeStore?.setStartedAt(runningSince)
                if stopGeneration != startGeneration {
                    // The stop landed while the checkpoint was being written: undo it before refusing.
                    runningSince = nil
                    try await runtimeStore?.setStartedAt(nil)
                    throw SafetyError.denied("An explicit stop was requested while starting")
                }
            }
            startOnWire = on; defer { startOnWire = false }
            let state: ActuatorState
            do {
                state = try await wrapped.setOn(on)
            } catch {
                // A lost response cannot prove the ON did not execute; if a stop overtook it, the stop wins.
                if on, stopGeneration != startGeneration { try await stopOvertakenStart() }
                throw error
            }
            if on, stopGeneration != startGeneration { try await stopOvertakenStart() }
            guard state.isOn == on else { throw IoTError.unconfirmed }
            if !on { try await runtimeStore?.setStartedAt(nil) }
            runningSince = (state.isOn == true) ? (runningSince ?? now()) : nil
            return state
        }
    }

    /// The stop overtook this start while it was on the wire. The checkpoint is kept until OFF is confirmed.
    private func stopOvertakenStart() async throws -> Never {
        let stopped: ActuatorState
        do { stopped = try await wrapped.setOn(false) } catch { throw SafetyError.stopUnconfirmed }
        guard stopped.isOn == false else { throw SafetyError.stopUnconfirmed }
        try await runtimeStore?.setStartedAt(nil)
        runningSince = nil
        throw SafetyError.denied("An explicit stop was requested while starting")
    }
}
