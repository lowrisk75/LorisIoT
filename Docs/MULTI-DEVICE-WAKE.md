# Multi-device wake integration contract v1

Status (2026-10-01): **SUPPORTED — durable coordinator and HA/Shelly/HomeKit adapters implemented; physical and release qualification OPEN.**

The guarantee is one confirmed absolute occurrence. No recurrence without reopening, no physical-effect guarantee, and no phone background timer are implied.

## Ownership and source

`IoTCore` owns the validated contract, `WakeCoordinator`, `FileWakePlanStore` and the generic
`OwnedScheduleWakeAdapter`. HA has `HAWakeSchedulingAdapter`; Shelly and HomeKit expose
`wakeAdapter(for:validateBinding:serializationKey:now:)`. Use adapters through the coordinator.
Velya owns AlarmKit-first orchestration, selections, local enrollment and UI. Existing provider
journals and HA server semantics remain authoritative. This implementation does not deploy a server.

## Persisted selection/intent schema

All new persisted types use Codable, Equatable and Sendable. Decode validates the same bounds as
construction. `WakeTargetReference` is also Hashable. New fields/unknown versions are refused;
the caller keeps the original bytes and exposes an upgrade/recovery state instead of overwriting.
Existing ScheduleStore v1 and HA SQLite schema3 are untouched. This is a new envelope, not a
migration of old schedule journals or a replacement for the Velya alarm model.

```swift
WakeTargetReference(
    providerID: ProviderID,
    connectionID: UUID,
    bindingID: UUID,
    deviceID: DeviceID,
    component: String? = nil
) throws

WakeRGB(red: UInt8, green: UInt8, blue: UInt8) throws
WakeLightParameters(
    level: UnitInterval, kelvin: Int? = nil,
    rgb: WakeRGB? = nil, transition: TimeInterval? = nil
) throws
// WakeAction: .power(Bool), .light(WakeLightParameters)

WakeTargetIntent(
    actionID: UUID, nonce: UUID, target: WakeTargetReference,
    start: Date, action: WakeAction, conditionalOffMinutes: Int? = nil
) throws

WakeOccurrencePlan(
    version: Int = 1, owner: ScheduleOwner,
    occurrenceID: UUID, generation: UUID, wakeAt: Date,
    targets: [WakeTargetIntent]
) throws
```

Identity rules:
- providerID is the registered, nonsecret SDK provider identity, not a brand or account address.
- connectionID is an app-owned persistent UUID for one local connection; bindingID is a persistent
  UUID for its verified endpoint/account/home identity. Rotate bindingID when that identity changes.
  A token refresh for the same proven account need not rotate it. A hostname/IP, display name or
  token hash alone is not proof of continuity. Never put a token/email/URL in these identifiers.
- deviceID is exactly the identifier expected by the chosen provider handle. component distinguishes
  channels/services if not already embedded by that provider. It is not appended or interpreted by
  the generic compiler: the adapter validates exact mapping. Never silently default to channel0/main.
- No merging by name, MAC/IP or presumed physical identity. Known physical duplicates need a user
  route choice; the SDK cannot infer them across providers.
- The same native ID in two connections or homes remains two targets. A copied selection on another
  phone has no authority until its connection mapping and ownership are explicitly established.

Plan rules:
- 1–32 targets; unique target reference, actionID and nonce within the occurrence.
- occurrenceID denotes one absolute occurrence, not just alarmID; generation denotes one immutable
  revision. Velya persists these along with the successful AlarmKit occurrence receipt.
- Each target gets its own nonce, persisted before mutation. Reconciliation reuses the exact nonce
  and intent. Never mint a new nonce merely because a response was lost.
- start is absolute UTC, at wakeAt or up to one hour before it. No daily/weekly recurrence implied.
- Light level0...1, Kelvin1000...40000 as outer schema bounds (the device range is usually narrower),
  RGB8bit, Kelvin/RGB mutually exclusive, transition0...3600seconds. The adapter must reject unsupported
  or narrower ranges. `.light` carries setLevel semantics; it is an explicit light action, not a fan speed.
- Conditional OFF is only representable for a positive light level,1–180minutes after wakeAt.
  It is an obligation attached to that owned ON session, never an independent global OFF action.
- A version1 plan has no arbitrary attributes/actions, group selectors, locks or appliance programs.
  Unsupported devices stay visible in the app with a reason; never broaden to all lights.

## Capabilities and pure preflight

`WakeCapabilitySnapshot` is ephemeral Sendable, deliberately not persisted as truth:

```swift
WakeCapabilitySnapshot(
    target: WakeTargetReference, kind: DeviceKind, availability: DeviceAvailability,
    manual: Set<WakeFeature>, autonomous: Set<WakeFeature>,
    execution: WakeExecutionLocation, verifiedCancellation: Bool,
    checkedAt: Date, validUntil: Date,
    minLead: TimeInterval = 20, maxLead: TimeInterval = 366 * 86400,
    timeQuantum: TimeInterval = 1,
    levelRange: ClosedRange<Double> = 0...1,
    kelvinRange: ClosedRange<Int>? = nil,
    maximumTransition: TimeInterval? = nil
) throws
```

Features: power, level, colorTemperature, rgb, nativeTransition, readState, conditionalOff.
Locations: device, userServer, vendorCloud, activeApp, unsupported. The last two cannot qualify
an autonomous schedule. `readState` does not itself mean an observed physical effect.

The adapter checks actual connection binding, membership, firmware/profile, access rights,
clock and server contract. Do not derive autonomous features merely from manual descriptors.
Checked validity is at most60seconds; UI should refresh before preparation and after interruptions.
`timeQuantum` refuses unrepresentable precision (e.g. HomeKit seconds); it never rounds the deadline.

```swift
WakePlanPreflight.evaluate(
    _ plan: WakeOccurrencePlan, snapshots: [WakeCapabilitySnapshot], now: Date
) -> [WakePreflightResult] // actionID + issue: WakeIssue?

WakePlanPreflight.deviceSchedule(
    for intent: WakeTargetIntent, in plan: WakeOccurrencePlan
) throws -> DeviceSchedule
```

A nil issue means **locally eligible**, not prepared, scheduled, executed or confirmed.
Each target is evaluated independently; stale binding, unavailable target, obsolete ranges or one
manual-only target cannot erase the others' results. Only light/outlet/switch/fan kinds participate;
level/color/transition require a light. At most32 snapshots and one snapshot per exact target.

The existing DeviceSchedule bridge keeps the exact device ID, absolute time, `.once`, requested
power/level and transition. Its schedule ID is `wake.<lowercase nonce UUID>`; do not invent another
ID during recovery. This conversion is not capability qualification and performs no I/O.
It throws `adapterRequired` for color/Kelvin/conditional OFF, never drops parameters. Conditional
sessions must map to HASunriseRequest with its additional exact60–1800second ramp/minute constraints
and current health/allowlist checks; HAWakeSchedulingAdapter implements this exact mapping.

## Adapter boundary and receipts

```swift
public protocol WakeSchedulingAdapter: Actor {
    nonisolated var serializationKey: UUID { get }
    func capabilities(for target: WakeTargetReference) async throws -> WakeCapabilitySnapshot
    func prepare(_ intent: WakeTargetIntent, in plan: WakeOccurrencePlan) async throws -> WakeTargetResult
    func inspect(_ intent: WakeTargetIntent, in plan: WakeOccurrencePlan) async throws -> WakeTargetResult
    func cancel(_ intent: WakeTargetIntent, in plan: WakeOccurrencePlan) async throws -> WakeTargetResult
}

WakeTargetResult(
    for intent: WakeTargetIntent, in plan: WakeOccurrencePlan,
    phase: WakeTargetPhase, proof: WakeProof = .none,
    issue: WakeIssue? = nil, checkedAt: Date
) throws
WakePreparationReport(plan: WakeOccurrencePlan, results: [WakeTargetResult]) throws
```

WakeCoordinator dispatches only the exact adapters supplied by the caller after local enrollment.
Implemented adapters still require qualification against the actual connection and device.
`serializationKey` identifies a shared underlying transport lock. All Govee port users must share
the same key/lease, even if they have separate actors; an actor alone is not cross-instance locking.

Result phases and minimum proof:

| Phase | Proof | UI meaning |
|---|---|---|
| unsupported | none + classified issue | This request is not supported |
| preparing | none | Work started, not yet confirmed |
| scheduled | scheduleReadback | Exact owned schedule read back, not an execution |
| rejected | none/acknowledgement + issue | Refused; not universal proof of zero side effects |
| uncertain | none/acknowledgement + issue | Effect or cancellation may exist; inspect, do not replay |
| executed | stateObservation | Requested state observed; not proof of causation or a physical effect |
| cancelledConfirmed | cancellationReadback or coordinator-only noDispatch | Exact owned cancellation verified, or durable proof the intent was never dispatched |

An acknowledgement cannot construct scheduled/executed/cancelledConfirmed. A scheduled observation
must predate the scheduled start. The adapter is trusted to perform its proof checks: this DTO is
not a cryptographic attestation. Results are transient, not a replacement for durable provider receipts.
The report accepts exactly one result per planned action, checks owner/occurrence/generation/nonce/
target, and restores plan order. `.counts` retains all phases; there is no group success boolean.
`freshScheduledCount(at:maximumAge:)` defaults to30seconds, caps60, excludes future-dated evidence
and schedules whose start has passed. Stale results remain inspectable but are not "ready tomorrow".
`.diagnostic` is the exportable Codable projection: opaque correlation nonce, providerID, phase,
proof, classified issue and timestamp. Do not export the full plan/result/remote payload.

## Implemented orchestration and caller obligations

1. Velya commits/reads back AlarmKit first; IoT failure never disarms the audible alarm.
2. Resolve each binding locally; requalify immediately before mutation. A stale selection stays
   not-configured; never route it through a newly chosen account/server.
3. Persist occurrence/generation/intent before invoking adapters. Reuse existing ScheduleStore
   receipts and withExclusiveOperation for generic owned schedules; preserve the existing
   endpoint-bound HASunrise journal for conditional sessions. The outer plan does not replace either.
4. Use bounded concurrency (maximum4), one active operation per serializationKey,
   queue maximum32, per-target budget≤20seconds and group budget≤160seconds. These budgets are
   **enforced by WakeCoordinator**, with a monotonic deadline.
   An uncancellable transport requires a quarantine/lease until it terminates; do not release it on
   timeout then overlap a second call. Late callbacks may reconcile the same intent, not a new one.
5. Lost reply or crash: preserve pending/uncertain journal, inspect exact nonce/content/ownership.
   No whole-group replay, blind physical rollback or automatic alternate-route fallback.
6. Removing one target cancels only its owned intent. Skip/delete affects only that occurrence's
   future intents. Replan must reconcile/cancel the old generation before creating conflicts.
   Keep pending cancellation after timeout. In-flight/already-started sessions need explicit backend
   semantics; do not pretend cancellation rolled back ON. Two alarms targeting the same light are
   distinct owners/occurrences, subject to real backend overlap policy.
7. Conditional OFF reuses HASunriseClient and server0.2.0 capability sunriseAutoOffVersion1:
   ON context confirmed, foreign/missing context relinquishes ownership, restart of started session
   becomes uncertain, no late OFF. Do not extrapolate to another provider without equivalent proof.
8. Adapters preserve exact classified domain results. A thrown transport/cancellation/storage error
   after possible mutation becomes uncertain; storage failure before send forbids the send.

## Current source capability matrix (not physical qualification)

| Provider | Manual path | Autonomous existing SDK path | Adapter status |
|---|---|---|---|
| HA | Per-device control/state | Owned one-shot power; light level/native transition with qualified server. Conditional OFF via separate HASunriseClient | Implemented: generic + conditional, fixture tested |
| Shelly | LAN control/state | Owned power schedule, exact one-shot needs clock/year or Schedule.Eval qualification; no light ramp on relay | Implemented: exact owned power, fixture tested |
| HomeKit | Apple Home control/state | Owned one-shot power, whole-minute deadline≥60s; no native transition exposed. Home hub execution qualification required | Implemented: exact owned power, fixture tested |
| Govee LAN | Power/brightness/RGB/Kelvin per supported model | Absent; reachable/dimmable does not imply an autonomous wake | Reject autonomous request; no send |
| Meross | Existing native control/state | No qualified owned one-shot path in current provider | Reject autonomous request |
| Dreo | Power/speed/mode per allowed profile, token injected | Absent | Reject autonomous request |
| SmartThings | Power/level per component, token injected | Absent in current module | Reject autonomous request |
| MQTT | Explicit topic/schema control/state | No scheduler/broker persistence contract inferred | Reject unless a separately qualified scheduling adapter exists |
| Webhook | Contract-specific actions | No generic scheduling assumption | Unsupported for this wake contract |

A Home Assistant route for a Govee device may use the HA server only if the exact target, ramp
and timing qualify. This is an explicit alternative connection, not an invisible fallback.
Another always-on system may be added only by a separate deliberate product/server decision.
No Home Assistant installation is required merely to use the schema or the SDK.

## Executable fake-only example and validation

`Tests/IoTCoreTests/WakeIntegrationExampleTests.swift` is the complete compiled example. It imports
only IoTCore and Testing, creates two same-named native IDs in different connections, encodes and
restores a plan, uses a SyntheticWakeAdapter without credentials/transport, then checks two distinct
scheduled fixture results. Its cancellation returns uncertain: it never simulates real proof by default.
Run the targeted tests with:

```sh
swift test --scratch-path /Volumes/DeveloperStorage/BuildScratch/lorisiot-iot-crosscheck-20260921 \
  --filter 'WakeIntegrationContractTests|WakeIntegrationExampleTests'
```

The executable coordinator and adapter regressions are in WakeCoordinatorTests,
HAWakeAdapterTests, ShellyWakeAdapterTests and HomeKitWakeAdapterTests. They cover response loss,
restart from dispatch, noncooperative timeout quarantine, partial results, retained-target nonces,
replanning, cancellation, identity/rights changes and journal failures. They do not prove hardware behavior.

## Durable journal and recovery limits

FileWakePlanStore has a 4 MiB envelope, 128 active generations, 4,096 retired generation IDs and
32,768 retired nonces. Fully cancelled generations compact into replay-prevention tombstones;
unresolved generations never disappear automatically. At capacity, new preparation fails before
send. Do not delete the journal to bypass uncertainty. A future explicit archival/recovery workflow
is required for long-lived installations that exhaust these bounds. The store excludes the journal
from backup, uses atomic replacement and file locks; keep it installation-local, outside sync.

A dispatch is persisted before any mutation. After a lost reply, prepare only inspects the same
nonce. An adapter cannot manufacture noDispatch evidence. Cancellation is durable even when its
adapter is temporarily unavailable. A transport timeout retains its lease until underlying work
terminates, including native HomeKit callbacks; this can deliberately quarantine a broken transport.

Generic provider receipt removal followed by a crash before the outer cancellation tombstone can
leave permanent uncertainty. Never infer cancellation from a missing local receipt; use a reviewed
provider recovery procedure. Cancellation is not a rollback of an already executed ON action.

## App integration / migration

1. Keep existing manual controls and legacy alarm actions intact. Do not auto-migrate opaque scenes.
2. Establish local owner/connection/binding UUIDs through explicit authorization. Synced selections
   are preferences, not authority. Validate endpoint/account/home continuity before each operation.
3. Persist a verified audible-alarm receipt first. Compile a single absolute occurrence with stable
   nonces per unchanged target. Never silently round HomeKit deadlines or strip light parameters.
4. Construct one FileWakePlanStore at a stable private location, reuse provider ScheduleStore,
   supply exact adapters to WakeCoordinator, then prepare. Display per-target proof, including failures.
5. On restart, reconcile the same plan. On removal, cancel only the affected action IDs; on replan,
   retain exact unchanged intents. Keep cancellation pending after loss of contact.
6. Expire scheduled UI evidence after at most 60 seconds or when its start passes. Readback proves
   a schedule, not execution, and never confirms an indefinite repeating alarm.

Velya's local enrollment is deliberately stricter than optional token continuity: any HA credential/
URL or Shelly configuration change requires authorization again. An old binding cannot automatically
cancel through the new endpoint. Explicit recovery remains necessary if the old endpoint is lost.
HA supports level/native transition only when current metadata qualifies; color and software-stepped
ramps are not provided by this adapter. Shelly/HomeKit expose exact power only. No cloud fallback.

## Remaining qualification gates

- Real HA/Shelly/HomeKit schedules, cancellation and ownership preservation, with explicit device consent.
- Two-hour endurance, app killed/locked, network loss, server restart, device clock changes, DST and
  actual overnight wake; verify absence of late conditional OFF and no foreign schedule deletion.
- VoiceOver / localized UI on device, iOS 26 stable separately from the available iOS 27 build lane.
- Signed Release archive, remote CI, supply-chain/security review and verified release manifest.
- Actual server health/version/allowlist; local server tests do not prove the installed deployment.

Provider extensions without an owned autonomous scheduler (Govee LAN, Meross, Dreo, SmartThings,
MQTT, webhook) remain unsupported for this path. Other consumer apps should follow this migration
guide; their code is not modified. No commit, pin, publication or deployment is implied.
