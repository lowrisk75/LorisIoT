import Foundation
import IoTCore

/// One exact HA target and installation owner. The host verifies connection/account continuity;
/// the HTTP transport is immutable for this binding. Route all mutations through WakeCoordinator.
public actor HAWakeSchedulingAdapter: WakeSchedulingAdapter {
    public nonisolated let serializationKey: UUID
    private let target: WakeTargetReference
    private let owner: ScheduleOwner
    private let http: any HAHTTP
    private let scheduleStore: any ScheduleStore
    private let validateBinding: @Sendable () async throws -> Bool
    private let now: @Sendable () -> Date
    private var generic: OwnedScheduleWakeAdapter?
    public init(target: WakeTargetReference, owner: ScheduleOwner, http: any HAHTTP,
                scheduleStore: any ScheduleStore, validateBinding: @escaping @Sendable () async throws -> Bool,
                serializationKey: UUID? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.target = target; self.owner = owner; self.http = http; self.scheduleStore = scheduleStore
        self.validateBinding = validateBinding; self.now = now
        self.serializationKey = serializationKey ?? target.connectionID
    }
    private var scopedProvider: ProviderID { .init(rawValue: "wake-ha." + target.bindingID.uuidString.lowercased()) }
    private func check(_ intent: WakeTargetIntent? = nil, plan: WakeOccurrencePlan? = nil) async throws {
        guard target.component == nil, HARestClient.isEntityID(target.deviceID.rawValue),
              intent.map({ $0.target == target }) ?? true,
              plan.map({ $0.owner == owner && $0.targets.contains(intent!) }) ?? true,
              try await validateBinding() else { throw WakeContractError.invalidIdentity }
        try Task.checkCancellation()
    }
    public func capabilities(for target: WakeTargetReference) async throws -> WakeCapabilitySnapshot {
        guard target == self.target else { throw WakeContractError.invalidIdentity }
        try await check()
        let health = try await HAScheduleAPI(http: http).health()
        guard health.allowedTargets.contains(target.deviceID.rawValue), abs(health.serverTime - now().timeIntervalSince1970) <= 5 else {
            throw IoTError.notSupported("The target or scheduling clock is not qualified")
        }
        let (bytes, status) = try await http.send(method: "GET", path: "api/states/" + target.deviceID.rawValue, body: nil)
        guard status == 200, bytes.count <= 65_536 else { throw IoTError.invalidResponse }
        let state = try JSONDecoder().decode(WakeHAState.self, from: bytes)
        guard state.entityID == target.deviceID.rawValue else { throw WakeContractError.invalidIdentity }
        try await check()
        let kind = HomeAssistantProvider.kind(for: state.entityID)
        var features: Set<WakeFeature> = [.power]
        let modes = Set(state.attributes.supportedColorModes ?? [])
        let brightness = kind == .light && !modes.isDisjoint(with: ["brightness", "white", "color_temp", "hs", "xy", "rgb", "rgbw", "rgbww"])
        if brightness { features.insert(.level) }
        let transition = brightness && (state.attributes.supportedFeatures ?? 0) & 32 != 0
        if transition { features.insert(.nativeTransition) }
        if transition, health.sunriseAutoOffVersion == 1 { features.insert(.conditionalOff) }
        let checkedAt = now()
        return try .init(target: target, kind: kind, availability: ["on", "off"].contains(state.state) ? .online : .unknown,
            manual: features.subtracting([.conditionalOff]), autonomous: features, execution: .userServer,
            verifiedCancellation: true, checkedAt: checkedAt, validUntil: checkedAt.addingTimeInterval(30),
            maximumTransition: transition ? 3600 : nil)
    }
    private func genericAdapter() -> OwnedScheduleWakeAdapter {
        if let generic { return generic }
        let scoped = scopedProvider
        let adapter = OwnedScheduleWakeAdapter(target: target, owner: owner, serializationKey: serializationKey,
            store: scheduleStore, scheduleProviderID: scopedProvider, resolve: { [self] in
                let snapshot = try await self.capabilities(for: target)
                let handle = HAOwnedSchedules(http: http, deviceID: target.deviceID, providerID: scoped,
                    configuration: .init(owner: owner, store: scheduleStore), now: now)
                return (snapshot, handle)
            }, now: now)
        generic = adapter; return adapter
    }
    private func sunrise(_ intent: WakeTargetIntent, _ plan: WakeOccurrencePlan) throws -> HASunriseRequest {
        guard plan.targets.contains(intent), let minutes = intent.conditionalOffMinutes,
              case .light(let light) = intent.action, light.rgb == nil, light.kelvin == nil,
              light.transition == plan.wakeAt.timeIntervalSince(intent.start),
              Double(light.level.percent) / 100 == light.level.value else { throw WakeContractError.invalidParameters }
        return try .init(remoteID: intent.nonce, owner: owner, deviceID: target.deviceID.rawValue,
            start: intent.start, wake: plan.wakeAt, autoOffMinutes: minutes, brightness: light.level.percent)
    }
    public func prepare(_ intent: WakeTargetIntent, in plan: WakeOccurrencePlan) async throws -> WakeTargetResult {
        try await check(intent, plan: plan)
        guard intent.conditionalOffMinutes != nil else { return try await genericAdapter().prepare(intent, in: plan) }
        let request = try sunrise(intent, plan)
        let snapshot = try await capabilities(for: target)
        if let issue = WakePlanPreflight.evaluate(plan, snapshots: [snapshot], now: now()).first(where: { $0.actionID == intent.actionID })?.issue {
            return try .init(for: intent, in: plan, phase: .unsupported, issue: issue, checkedAt: now())
        }
        try await check(intent, plan: plan)
        _ = try await HASunriseClient(http: http).arm(request, now: now())
        return try await inspect(intent, in: plan)
    }
    public func inspect(_ intent: WakeTargetIntent, in plan: WakeOccurrencePlan) async throws -> WakeTargetResult {
        try await check(intent, plan: plan)
        guard intent.conditionalOffMinutes != nil else { return try await genericAdapter().inspect(intent, in: plan) }
        let receipt = try await HASunriseClient(http: http).read(sunrise(intent, plan))
        try await check(intent, plan: plan)
        if receipt?.state == .armed, now() < intent.start {
            return try .init(for: intent, in: plan, phase: .scheduled, proof: .scheduleReadback, checkedAt: now())
        }
        if receipt?.state == .removed {
            return try .init(for: intent, in: plan, phase: .cancelledConfirmed, proof: .cancellationReadback, checkedAt: now())
        }
        // A server terminal status is not a physical state observation by this adapter.
        return try .init(for: intent, in: plan, phase: .uncertain, issue: .transportFailure, checkedAt: now())
    }
    public func cancel(_ intent: WakeTargetIntent, in plan: WakeOccurrencePlan) async throws -> WakeTargetResult {
        try await check(intent, plan: plan)
        guard intent.conditionalOffMinutes != nil else { return try await genericAdapter().cancel(intent, in: plan) }
        let request = try sunrise(intent, plan)
        try await HASunriseClient(http: http).cancel(request)
        try await check(intent, plan: plan)
        guard try await HASunriseClient(http: http).read(request)?.state == .removed else { throw IoTError.unconfirmed }
        return try .init(for: intent, in: plan, phase: .cancelledConfirmed, proof: .cancellationReadback, checkedAt: now())
    }
}

private struct WakeHAState: Decodable {
    let entityID: String
    let state: String
    let attributes: Attributes
    enum CodingKeys: String, CodingKey { case entityID = "entity_id", state, attributes }
    struct Attributes: Decodable {
        let supportedColorModes: [String]?
        let supportedFeatures: Int?
        enum CodingKeys: String, CodingKey {
            case supportedColorModes = "supported_color_modes", supportedFeatures = "supported_features"
        }
    }
}
