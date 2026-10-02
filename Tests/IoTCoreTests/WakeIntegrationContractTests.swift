import Foundation
import Testing
import IoTCore

struct WakeIntegrationContractTests {
    let date = Date(timeIntervalSince1970: 2_000_000_000)
    let owner = ScheduleOwner(appID: "com.example.fixture", installationID: UUID())
    func target(connection: UUID = UUID(), binding: UUID = UUID(), component: String? = nil) throws -> WakeTargetReference {
        try .init(providerID: "fixture", connectionID: connection, bindingID: binding, deviceID: "light.same", component: component)
    }
    func intent(_ target: WakeTargetReference, action: WakeAction = .power(true), off: Int? = nil) throws -> WakeTargetIntent {
        try .init(actionID: UUID(), nonce: UUID(), target: target, start: date.addingTimeInterval(120), action: action, conditionalOffMinutes: off)
    }
    func plan(_ intents: [WakeTargetIntent]) throws -> WakeOccurrencePlan {
        try .init(owner: owner, occurrenceID: UUID(), generation: UUID(), wakeAt: date.addingTimeInterval(720), targets: intents)
    }
    func capabilities(_ target: WakeTargetReference, kind: DeviceKind = .light, manual: Set<WakeFeature> = [.power], autonomous: Set<WakeFeature> = [.power], at: Date? = nil, location: WakeExecutionLocation = .userServer) throws -> WakeCapabilitySnapshot {
        try .init(target: target, kind: kind, availability: .online, manual: manual, autonomous: autonomous, execution: location, verifiedCancellation: true, checkedAt: at ?? date, validUntil: (at ?? date).addingTimeInterval(30))
    }
    @Test func identitiesSeparateConnectionsBindingsAndComponents() throws {
        let c = UUID(), b = UUID()
        let a = try target(connection:c,binding:b,component:"0")
        #expect(a != (try target(connection:c,binding:b,component:"1")))
        #expect(a != (try target(connection:c,binding:UUID(),component:"0")))
        #expect(a != (try target(connection:UUID(),binding:b,component:"0")))
    }
    @Test func manualPowerDoesNotGrantAutonomousSchedule() throws {
        let t = try target(), i = try intent(t), p = try plan([i])
        let result = WakePlanPreflight.evaluate(p, snapshots: [try capabilities(t, autonomous: [], location: .activeApp)], now: date)
        #expect(result[0].issue == .autonomousUnavailable)
    }
    @Test func staleOrChangedBindingCannotQualify() throws {
        let t = try target(), p = try plan([intent(t)])
        #expect(WakePlanPreflight.evaluate(p, snapshots: [try capabilities(t,at:date.addingTimeInterval(-31))],now:date)[0].issue == .staleCapabilities)
        #expect(WakePlanPreflight.evaluate(p,snapshots:[try capabilities(target())],now:date)[0].issue == .connectionUnavailable)
    }
    @Test func eligibleIsNotAScheduledReceiptAndTranslationIsExactlyOnce() throws {
        let t = try target(), i = try intent(t), p = try plan([i])
        #expect(WakePlanPreflight.evaluate(p,snapshots:[try capabilities(t)],now:date)[0].issue == nil)
        let s = try WakePlanPreflight.deviceSchedule(for:i, in:p)
        #expect(s.recurrence == .once && s.start == i.start && s.deviceID == t.deviceID)
        #expect(s.id.rawValue == "wake." + i.nonce.uuidString.lowercased())
    }
    @Test func duplicateTargetsActionsAndNoncesAreRejected() throws {
        let a = try intent(target())
        #expect(throws: WakeContractError.invalidPlan) { try plan([a,a]) }
        #expect(throws: WakeContractError.invalidPlan) { try plan([a,intent(a.target)]) }
    }
    @Test func fanCannotBeTreatedAsLightEvenIfDescriptorClaimsLevel() throws {
        let t = try target(), action = WakeAction.light(try .init(level: UnitInterval(0.5)))
        let p = try plan([intent(t,action:action)])
        #expect(WakePlanPreflight.evaluate(p,snapshots:[try capabilities(t,kind:.fan,autonomous:[.level])],now:date)[0].issue == .incompatibleKind)
    }
    @Test func conditionalOffAndColorAreNeverDroppedByGenericScheduleConversion() throws {
        let t = try target(), light = WakeAction.light(try .init(level:UnitInterval(0.5),transition:600))
        let i = try intent(t,action:light,off:15), p = try plan([i])
        #expect(throws: WakeContractError.adapterRequired) { try WakePlanPreflight.deviceSchedule(for:i,in:p) }
        let color = WakeAction.light(try .init(level:UnitInterval(0.5),kelvin:2700))
        let c = try intent(t,action:color), cp = try plan([c])
        #expect(throws: WakeContractError.adapterRequired) { try WakePlanPreflight.deviceSchedule(for:c,in:cp) }
    }
    @Test func futureVersionsAndUnknownFieldsAreRejectedWithoutMigration() throws {
        let p = try plan([intent(target())]);let data = try JSONEncoder().encode(p)
        #expect(try JSONDecoder().decode(WakeOccurrencePlan.self,from:data) == p)
        var json = try #require(JSONSerialization.jsonObject(with:data) as? [String:Any])
        json["version"] = 2
        #expect(throws:(any Error).self) { try JSONDecoder().decode(WakeOccurrencePlan.self,from:JSONSerialization.data(withJSONObject:json)) }
        json["version"] = 1;json["futureField"] = true
        #expect(throws:(any Error).self) { try JSONDecoder().decode(WakeOccurrencePlan.self,from:JSONSerialization.data(withJSONObject:json)) }
    }
    @Test func unsafeIdentityAndLightParametersAreRejected() throws {
        #expect(throws: WakeContractError.invalidIdentity) { try WakeTargetReference(providerID:"fixture",connectionID:UUID(),bindingID:UUID(),deviceID:"https://private.example/?token=x") }
        #expect(throws: WakeContractError.invalidParameters) { try WakeLightParameters(level:UnitInterval(0.5),transition:.nan) }
        #expect(throws: WakeContractError.invalidParameters) { try WakeLightParameters(level:UnitInterval(0.5),kelvin:2700,rgb:WakeRGB(red:1,green:2,blue:3)) }
    }
}

extension WakeIntegrationContractTests {
    @Test func mixedResultsKeepSuccessFailureAndUncertaintySeparate() throws {
        let intents = try [intent(target()), intent(target()), intent(target())], p = try plan(intents)
        let results = [
            try WakeTargetResult(for:intents[0],in:p,phase:.scheduled,proof:.scheduleReadback,checkedAt:date),
            try WakeTargetResult(for:intents[1],in:p,phase:.rejected,issue:.targetUnavailable,checkedAt:date),
            try WakeTargetResult(for:intents[2],in:p,phase:.uncertain,issue:.transportFailure,checkedAt:date)]
        let report = try WakePreparationReport(plan:p,results:Array(results.reversed()))
        #expect(report.results.map(\.actionID) == intents.map(\.actionID))
        #expect(report.counts[.scheduled] == 1 && report.counts[.rejected] == 1 && report.counts[.uncertain] == 1)
        #expect(report.freshScheduledCount(at:date) == 1)
        #expect(report.freshScheduledCount(at:date.addingTimeInterval(61)) == 0)
    }
    @Test func acknowledgementCannotBecomeExecutionOrScheduleProof() throws {
        let i = try intent(target()), p = try plan([i])
        for phase in [WakeTargetPhase.scheduled, .executed, .cancelledConfirmed] {
            #expect(throws: WakeContractError.invalidEvidence) {
                try WakeTargetResult(for:i,in:p,phase:phase,proof:.acknowledgement,checkedAt:date)
            }
        }
    }
    @Test func foreignGenerationAndIncompleteResultsCannotConfirmAnOccurrence() throws {
        let i = try intent(target()), p = try plan([i]), other = try plan([i])
        let r = try WakeTargetResult(for:i,in:other,phase:.scheduled,proof:.scheduleReadback,checkedAt:date)
        #expect(throws: WakeContractError.invalidEvidence) { try WakePreparationReport(plan:p,results:[r]) }
        #expect(throws: WakeContractError.invalidPlan) { try WakePreparationReport(plan:p,results:[]) }
    }
    @Test func unsupportedTargetDoesNotPreventOtherTargetsPreflight() throws {
        let a = try target(), b = try target(), p = try plan([intent(a),intent(b)])
        let results = WakePlanPreflight.evaluate(p,snapshots:[try capabilities(a),try capabilities(b,autonomous:[],location:.activeApp)],now:date)
        #expect(results.count == 2 && results[0].issue == nil && results[1].issue == .autonomousUnavailable)
    }
    @Test func revokedRangeTransitionAndUnavailableTargetFailClosed() throws {
        let t = try target(), i = try intent(t,action:.light(.init(level:UnitInterval(0.8),transition:600))),p = try plan([i])
        let c = try WakeCapabilitySnapshot(target:t,kind:.light,availability:.online,manual:[.level],autonomous:[.level,.nativeTransition],execution:.userServer,verifiedCancellation:true,checkedAt:date,validUntil:date.addingTimeInterval(30),levelRange:0...0.5,maximumTransition:300)
        #expect(WakePlanPreflight.evaluate(p,snapshots:[c],now:date)[0].issue == .unsupportedParameters)
        let offline = try WakeCapabilitySnapshot(target:t,kind:.light,availability:.offline,manual:[.power],autonomous:[.power],execution:.userServer,verifiedCancellation:true,checkedAt:date,validUntil:date.addingTimeInterval(30))
        #expect(WakePlanPreflight.evaluate(p,snapshots:[offline],now:date)[0].issue == .targetUnavailable)
    }
    @Test func timePrecisionIsNeverRoundedToFitHomeKit() throws {
        let t = try target(), i = try intent(t),p = try plan([i])
        let c = try WakeCapabilitySnapshot(target:t,kind:.light,availability:.online,manual:[.power],autonomous:[.power],execution:.device,verifiedCancellation:true,checkedAt:date,validUntil:date.addingTimeInterval(30),minLead:60,timeQuantum:60)
        #expect(WakePlanPreflight.evaluate(p,snapshots:[c],now:date)[0].issue == .invalidDeadline)
    }
    @Test func unknownNestedKeysAndInvalidDecodedDatesDoNotDisappear() throws {
        let p = try plan([intent(target())]);var json = try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as? [String:Any])
        var targets = try #require(json["targets"] as? [[String:Any]]);targets[0]["unrecognizedAction"] = "keep me";json["targets"] = targets
        #expect(throws:(any Error).self) { try JSONDecoder().decode(WakeOccurrencePlan.self,from:JSONSerialization.data(withJSONObject:json)) }
    }
    @Test func wholeGroupLimitDoesNotTruncateSavedSelections() throws {
        let targets = try (0..<33).map { _ in try intent(target()) }
        #expect(throws: WakeContractError.invalidPlan) { try plan(targets) }
    }
    @Test func diagnosticOmitsTargetAndConnectionIdentifiers() throws {
        let i = try intent(target()),p = try plan([i])
        let r = try WakeTargetResult(for:i,in:p,phase:.uncertain,issue:.timeout,checkedAt:date)
        let text = String(decoding:try JSONEncoder().encode(r.diagnostic),as:UTF8.self)
        #expect(!text.contains(i.target.deviceID.rawValue))
        #expect(!text.contains(i.target.connectionID.uuidString))
        #expect(!text.contains(i.target.bindingID.uuidString))
    }
}
