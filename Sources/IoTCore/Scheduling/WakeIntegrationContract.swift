import Foundation

/// Contract v1. Pure planning/types only: no network, timers, persistence or automatic replay.
public enum WakeContractError: Error, Equatable, Sendable {
    case invalidIdentity, invalidParameters, invalidPlan, unsupportedVersion, adapterRequired, invalidEvidence
}
private struct WakeCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
func wakeKeys(_ decoder: any Decoder, allowed: Set<String>) throws {
    let keys = try decoder.container(keyedBy: WakeCodingKey.self).allKeys.map(\.stringValue)
    guard Set(keys).isSubset(of: allowed) else { throw WakeContractError.unsupportedVersion }
}
private func wakeIdentifier(_ value: String, limit: Int = 256) -> Bool {
    !value.isEmpty && value.utf8.count <= limit && !value.contains("://") &&
    value.range(of: "^[A-Za-z0-9_.:/-]+$", options: .regularExpression) != nil
}

public struct WakeTargetReference: Codable, Equatable, Sendable {
    public let providerID: ProviderID
    public let connectionID: UUID
    public let bindingID: UUID
    public let deviceID: DeviceID
    public let component: String?
    public init(providerID: ProviderID, connectionID: UUID, bindingID: UUID, deviceID: DeviceID, component: String? = nil) throws {
        guard wakeIdentifier(providerID.rawValue, limit: 64), wakeIdentifier(deviceID.rawValue),
              component.map({ wakeIdentifier($0, limit: 128) }) ?? true else { throw WakeContractError.invalidIdentity }
        self.providerID = providerID
        self.connectionID = connectionID
        self.bindingID = bindingID
        self.deviceID = deviceID
        self.component = component
    }
    private enum CodingKeys: String, CodingKey { case providerID, connectionID, bindingID, deviceID, component }
    public init(from decoder: any Decoder) throws {
        try wakeKeys(decoder, allowed: ["providerID", "connectionID", "bindingID", "deviceID", "component"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(providerID: c.decode(ProviderID.self, forKey: .providerID), connectionID: c.decode(UUID.self, forKey: .connectionID), bindingID: c.decode(UUID.self, forKey: .bindingID), deviceID: c.decode(DeviceID.self, forKey: .deviceID), component: c.decodeIfPresent(String.self, forKey: .component))
    }
}

extension WakeTargetReference: Hashable {}

public struct WakeRGB: Codable, Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public init(red: UInt8, green: UInt8, blue: UInt8) throws {

        self.red = red
        self.green = green
        self.blue = blue
    }
    private enum CodingKeys: String, CodingKey { case red, green, blue }
    public init(from decoder: any Decoder) throws {
        try wakeKeys(decoder, allowed: ["red", "green", "blue"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(red: c.decode(UInt8.self, forKey: .red), green: c.decode(UInt8.self, forKey: .green), blue: c.decode(UInt8.self, forKey: .blue))
    }
}

public struct WakeLightParameters: Codable, Equatable, Sendable {
    public let level: UnitInterval
    public let kelvin: Int?
    public let rgb: WakeRGB?
    public let transition: TimeInterval?
    public init(level: UnitInterval, kelvin: Int? = nil, rgb: WakeRGB? = nil, transition: TimeInterval? = nil) throws {
        guard !(kelvin != nil && rgb != nil), kelvin.map({ (1000...40_000).contains($0) }) ?? true,
              transition.map({ $0.isFinite && (0...3600).contains($0) }) ?? true else { throw WakeContractError.invalidParameters }
        self.level = level
        self.kelvin = kelvin
        self.rgb = rgb
        self.transition = transition
    }
    private enum CodingKeys: String, CodingKey { case level, kelvin, rgb, transition }
    public init(from decoder: any Decoder) throws {
        try wakeKeys(decoder, allowed: ["level", "kelvin", "rgb", "transition"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try wakeKeys(c.superDecoder(forKey: .level), allowed: ["value"])
        try self.init(level: c.decode(UnitInterval.self, forKey: .level), kelvin: c.decodeIfPresent(Int.self, forKey: .kelvin), rgb: c.decodeIfPresent(WakeRGB.self, forKey: .rgb), transition: c.decodeIfPresent(TimeInterval.self, forKey: .transition))
    }
}

public enum WakeAction: Codable, Equatable, Sendable {
    case power(Bool), light(WakeLightParameters)
    private enum CodingKeys: String, CodingKey { case power, light }
    public init(from decoder: any Decoder) throws {
        try wakeKeys(decoder, allowed: ["power", "light"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.allKeys.count == 1 else { throw WakeContractError.invalidParameters }
        if c.contains(.power) { self = .power(try c.decode(Bool.self, forKey: .power)) }
        else { self = .light(try c.decode(WakeLightParameters.self, forKey: .light)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self { case .power(let v): try c.encode(v, forKey: .power); case .light(let v): try c.encode(v, forKey: .light) }
    }
}

public struct WakeTargetIntent: Codable, Equatable, Sendable {
    public let actionID: UUID
    public let nonce: UUID
    public let target: WakeTargetReference
    public let start: Date
    public let action: WakeAction
    public let conditionalOffMinutes: Int?
    public init(actionID: UUID, nonce: UUID, target: WakeTargetReference, start: Date, action: WakeAction, conditionalOffMinutes: Int? = nil) throws {
        guard start.timeIntervalSince1970.isFinite,
              conditionalOffMinutes.map({ (1...180).contains($0) }) ?? true else { throw WakeContractError.invalidParameters }
        if conditionalOffMinutes != nil {
            guard case .light(let light) = action, light.level.value > 0 else { throw WakeContractError.invalidParameters }
        }
        self.actionID = actionID
        self.nonce = nonce
        self.target = target
        self.start = start
        self.action = action
        self.conditionalOffMinutes = conditionalOffMinutes
    }
    private enum CodingKeys: String, CodingKey { case actionID, nonce, target, start, action, conditionalOffMinutes }
    public init(from decoder: any Decoder) throws {
        try wakeKeys(decoder, allowed: ["actionID", "nonce", "target", "start", "action", "conditionalOffMinutes"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(actionID: c.decode(UUID.self, forKey: .actionID), nonce: c.decode(UUID.self, forKey: .nonce), target: c.decode(WakeTargetReference.self, forKey: .target), start: c.decode(Date.self, forKey: .start), action: c.decode(WakeAction.self, forKey: .action), conditionalOffMinutes: c.decodeIfPresent(Int.self, forKey: .conditionalOffMinutes))
    }
}

public struct WakeOccurrencePlan: Codable, Equatable, Sendable {
    public let version: Int
    public let owner: ScheduleOwner
    public let occurrenceID: UUID
    public let generation: UUID
    public let wakeAt: Date
    public let targets: [WakeTargetIntent]
    public init(version: Int = 1, owner: ScheduleOwner, occurrenceID: UUID, generation: UUID, wakeAt: Date, targets: [WakeTargetIntent]) throws {
        guard version == 1 else { throw WakeContractError.unsupportedVersion }
        guard wakeIdentifier(owner.appID), wakeAt.timeIntervalSince1970.isFinite,
              !targets.isEmpty, targets.count <= 32,
              Set(targets.map(\.target)).count == targets.count,
              Set(targets.map(\.actionID)).count == targets.count,
              Set(targets.map(\.nonce)).count == targets.count else { throw WakeContractError.invalidPlan }
        for target in targets {
            guard target.start <= wakeAt, wakeAt.timeIntervalSince(target.start) <= 3600 else { throw WakeContractError.invalidPlan }
            if case .light(let light) = target.action, let transition = light.transition {
                guard target.start.addingTimeInterval(transition) <= wakeAt else { throw WakeContractError.invalidPlan }
            }
        }
        self.version = version
        self.owner = owner
        self.occurrenceID = occurrenceID
        self.generation = generation
        self.wakeAt = wakeAt
        self.targets = targets
    }
    private enum CodingKeys: String, CodingKey { case version, owner, occurrenceID, generation, wakeAt, targets }
    public init(from decoder: any Decoder) throws {
        try wakeKeys(decoder, allowed: ["version", "owner", "occurrenceID", "generation", "wakeAt", "targets"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try wakeKeys(c.superDecoder(forKey: .owner), allowed: ["appID", "installationID"])
        try self.init(version: c.decode(Int.self, forKey: .version), owner: c.decode(ScheduleOwner.self, forKey: .owner), occurrenceID: c.decode(UUID.self, forKey: .occurrenceID), generation: c.decode(UUID.self, forKey: .generation), wakeAt: c.decode(Date.self, forKey: .wakeAt), targets: c.decode([WakeTargetIntent].self, forKey: .targets))
    }
}

public enum WakeFeature: String, Codable, Hashable, Sendable {
    case power, level, colorTemperature, rgb, nativeTransition, readState, conditionalOff
}
public enum WakeExecutionLocation: String, Codable, Sendable {
    case device, userServer, vendorCloud, activeApp, unsupported
    public var isAutonomous: Bool { self == .device || self == .userServer || self == .vendorCloud }
}
/// Ephemeral, qualified by the adapter after checking the current connection and target.
/// A manual feature never implicitly grants its autonomous counterpart. Not persisted as truth.
public struct WakeCapabilitySnapshot: Sendable {
    public let target: WakeTargetReference
    public let kind: DeviceKind
    public let availability: DeviceAvailability
    public let manual: Set<WakeFeature>
    public let autonomous: Set<WakeFeature>
    public let execution: WakeExecutionLocation
    public let verifiedCancellation: Bool
    public let checkedAt: Date
    public let validUntil: Date
    public let minLead: TimeInterval
    public let maxLead: TimeInterval
    public let timeQuantum: TimeInterval
    public let levelRange: ClosedRange<Double>
    public let kelvinRange: ClosedRange<Int>?
    public let maximumTransition: TimeInterval?
    public init(target: WakeTargetReference, kind: DeviceKind, availability: DeviceAvailability,
                manual: Set<WakeFeature>, autonomous: Set<WakeFeature>, execution: WakeExecutionLocation,
                verifiedCancellation: Bool, checkedAt: Date, validUntil: Date,
                minLead: TimeInterval = 20, maxLead: TimeInterval = 366 * 86400, timeQuantum: TimeInterval = 1,
                levelRange: ClosedRange<Double> = 0...1, kelvinRange: ClosedRange<Int>? = nil,
                maximumTransition: TimeInterval? = nil) throws {
        guard checkedAt.timeIntervalSince1970.isFinite, validUntil.timeIntervalSince1970.isFinite,
              (0...60).contains(validUntil.timeIntervalSince(checkedAt)), minLead.isFinite, minLead >= 0,
              maxLead.isFinite, maxLead >= minLead, maxLead <= 366 * 86400,
              timeQuantum.isFinite, (1...60).contains(timeQuantum),
              levelRange.lowerBound.isFinite, levelRange.upperBound.isFinite,
              levelRange.lowerBound >= 0, levelRange.upperBound <= 1,
              kelvinRange.map({ $0.lowerBound >= 1000 && $0.upperBound <= 40_000 }) ?? true,
              maximumTransition.map({ $0.isFinite && (0...3600).contains($0) }) ?? true else { throw WakeContractError.invalidParameters }
        self.target = target; self.kind = kind; self.availability = availability
        self.manual = manual; self.autonomous = autonomous; self.execution = execution
        self.verifiedCancellation = verifiedCancellation; self.checkedAt = checkedAt; self.validUntil = validUntil
        self.minLead = minLead; self.maxLead = maxLead; self.timeQuantum = timeQuantum
        self.levelRange = levelRange; self.kelvinRange = kelvinRange; self.maximumTransition = maximumTransition
    }
}
public enum WakeIssue: String, Codable, Sendable {
    case connectionUnavailable, staleCapabilities, targetUnavailable, incompatibleKind, autonomousUnavailable
    case unsupportedParameters, unverifiedCancellation, invalidDeadline, conflictingCapabilities
    case storageUnavailable, transportFailure, timeout, cancellationPending, ownershipConflict, adapterRequired
}
public struct WakePreflightResult: Sendable {
    public let actionID: UUID
    /// Nil means locally eligible only, never remotely scheduled or physically executed.
    public let issue: WakeIssue?
}
public enum WakePlanPreflight {
    public static func evaluate(_ plan: WakeOccurrencePlan, snapshots: [WakeCapabilitySnapshot], now: Date) -> [WakePreflightResult] {
        plan.targets.map { intent in
            .init(actionID: intent.actionID, issue: issue(intent, snapshots: snapshots, now: now))
        }
    }
    private static func issue(_ intent: WakeTargetIntent, snapshots: [WakeCapabilitySnapshot], now: Date) -> WakeIssue? {
        guard snapshots.count <= 32 else { return .conflictingCapabilities }
        let matches = snapshots.filter { $0.target == intent.target }
        guard !matches.isEmpty else { return .connectionUnavailable }
        guard matches.count == 1 else { return .conflictingCapabilities }
        let c = matches[0]
        guard now.timeIntervalSince1970.isFinite, c.checkedAt <= now, now < c.validUntil else { return .staleCapabilities }
        guard c.availability == .online else { return .targetUnavailable }
        guard [.light, .outlet, .switchDevice, .fan].contains(c.kind) else { return .incompatibleKind }
        guard c.execution.isAutonomous, !c.autonomous.isEmpty else { return .autonomousUnavailable }
        guard c.verifiedCancellation else { return .unverifiedCancellation }
        let lead = intent.start.timeIntervalSince(now)
        guard lead >= c.minLead, lead <= c.maxLead,
              intent.start.timeIntervalSince1970.truncatingRemainder(dividingBy: c.timeQuantum) == 0 else { return .invalidDeadline }
        switch intent.action {
        case .power:
            guard c.autonomous.contains(.power) else { return .unsupportedParameters }
        case .light(let light):
            guard c.kind == .light else { return .incompatibleKind }
            guard c.autonomous.contains(.level), c.levelRange.contains(light.level.value) else { return .unsupportedParameters }
            if let kelvin = light.kelvin {
                guard c.autonomous.contains(.colorTemperature), c.kelvinRange?.contains(kelvin) == true else { return .unsupportedParameters }
            }
            if light.rgb != nil, !c.autonomous.contains(.rgb) { return .unsupportedParameters }
            if let transition = light.transition {
                guard c.autonomous.contains(.nativeTransition), let max = c.maximumTransition, transition <= max else { return .unsupportedParameters }
            }
        }
        if intent.conditionalOffMinutes != nil, !c.autonomous.contains(.conditionalOff) { return .unsupportedParameters }
        return nil
    }
    /// Lossless bridge to existing owned schedules. It does not qualify or send the request.
    /// Conditional OFF/color need a dedicated adapter; never silently omit a requested parameter.
    public static func deviceSchedule(for intent: WakeTargetIntent, in plan: WakeOccurrencePlan) throws -> DeviceSchedule {
        guard plan.targets.contains(intent) else { throw WakeContractError.invalidPlan }
        guard intent.conditionalOffMinutes == nil else { throw WakeContractError.adapterRequired }
        let payload: CommandPayload
        let transition: TimeInterval?
        switch intent.action {
        case .power(let on): payload = .setPower(on); transition = nil
        case .light(let light):
            guard light.kelvin == nil, light.rgb == nil else { throw WakeContractError.adapterRequired }
            payload = .setLevel(light.level); transition = light.transition
        }
        return .init(id: .init(rawValue: "wake." + intent.nonce.uuidString.lowercased()), deviceID: intent.target.deviceID,
                     command: payload, start: intent.start, recurrence: .once, isEnabled: true, transition: transition)
    }
}

public enum WakeTargetPhase: String, Codable, Hashable, Sendable {
    case unsupported, preparing, scheduled, rejected, uncertain, executed, cancelledConfirmed
}
public enum WakeProof: String, Codable, Sendable {
    case none, acknowledgement, scheduleReadback, stateObservation, cancellationReadback, noDispatch
}
/// Minimal evidence payload. No names, URLs, credentials, raw provider replies or free-text errors.
/// Adapters remain responsible for performing the exact checks underlying their proof claim.
public struct WakeTargetResult: Sendable {
    public let owner: ScheduleOwner
    public let occurrenceID: UUID
    public let generation: UUID
    public let actionID: UUID
    public let nonce: UUID
    public let target: WakeTargetReference
    public let start: Date
    public let phase: WakeTargetPhase
    public let proof: WakeProof
    public let issue: WakeIssue?
    public let checkedAt: Date
    public init(for intent: WakeTargetIntent, in plan: WakeOccurrencePlan, phase: WakeTargetPhase,
                proof: WakeProof = .none, issue: WakeIssue? = nil, checkedAt: Date) throws {
        guard plan.targets.contains(intent), checkedAt.timeIntervalSince1970.isFinite else { throw WakeContractError.invalidPlan }
        switch phase {
        case .scheduled: guard proof == .scheduleReadback, issue == nil, checkedAt < intent.start else { throw WakeContractError.invalidEvidence }
        case .executed: guard proof == .stateObservation, issue == nil else { throw WakeContractError.invalidEvidence }
        case .cancelledConfirmed: guard (proof == .cancellationReadback || proof == .noDispatch), issue == nil else { throw WakeContractError.invalidEvidence }
        case .unsupported, .rejected, .uncertain:
            guard issue != nil, proof == .none || proof == .acknowledgement else { throw WakeContractError.invalidEvidence }
        case .preparing: guard proof == .none, issue == nil else { throw WakeContractError.invalidEvidence }
        }
        owner = plan.owner; occurrenceID = plan.occurrenceID; generation = plan.generation
        actionID = intent.actionID; nonce = intent.nonce; target = intent.target; start = intent.start
        self.phase = phase; self.proof = proof; self.issue = issue; self.checkedAt = checkedAt
    }
}
public struct WakePreparationReport: Sendable {
    public let results: [WakeTargetResult]
    public init(plan: WakeOccurrencePlan, results: [WakeTargetResult]) throws {
        guard results.count == plan.targets.count, Set(results.map(\.actionID)).count == results.count else { throw WakeContractError.invalidPlan }
        for r in results {
            guard r.owner == plan.owner, r.occurrenceID == plan.occurrenceID, r.generation == plan.generation,
                  plan.targets.contains(where: { $0.actionID == r.actionID && $0.nonce == r.nonce && $0.target == r.target }) else { throw WakeContractError.invalidEvidence }
        }
        self.results = plan.targets.compactMap { i in results.first { $0.actionID == i.actionID } }
    }
    public var counts: [WakeTargetPhase: Int] { Dictionary(grouping: results, by: \.phase).mapValues(\.count) }
    public func freshScheduledCount(at now: Date, maximumAge: TimeInterval = 30) -> Int {
        guard now.timeIntervalSince1970.isFinite, maximumAge.isFinite, (0...60).contains(maximumAge) else { return 0 }
        return results.filter { $0.phase == .scheduled && now < $0.start && $0.checkedAt <= now && now.timeIntervalSince($0.checkedAt) <= maximumAge }.count
    }
}
/// Implemented by HAWakeSchedulingAdapter and owned Shelly/HomeKit adapters.
/// Use WakeCoordinator for durable group preparation, cancellation and transport quarantine.
/// Adapter must requalify binding/capabilities, persist the nonce BEFORE mutation, inspect exact
/// ownership/readback, keep uncertain receipts, and serialize its underlying transport.
public protocol WakeSchedulingAdapter: Actor {
    nonisolated var serializationKey: UUID { get }
    func capabilities(for target: WakeTargetReference) async throws -> WakeCapabilitySnapshot
    func prepare(_ intent: WakeTargetIntent, in plan: WakeOccurrencePlan) async throws -> WakeTargetResult
    func inspect(_ intent: WakeTargetIntent, in plan: WakeOccurrencePlan) async throws -> WakeTargetResult
    func cancel(_ intent: WakeTargetIntent, in plan: WakeOccurrencePlan) async throws -> WakeTargetResult
}

public struct WakeDiagnostic: Codable, Sendable {
    public let correlationID: UUID
    public let providerID: ProviderID
    public let phase: WakeTargetPhase
    public let proof: WakeProof
    public let issue: WakeIssue?
    public let checkedAt: Date
}
public extension WakeTargetResult {
    var diagnostic: WakeDiagnostic {
        .init(correlationID: nonce, providerID: target.providerID, phase: phase,
              proof: proof, issue: issue, checkedAt: checkedAt)
    }
}
